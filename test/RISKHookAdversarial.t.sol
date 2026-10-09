// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./RISKHook.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {RISK} from "src/RISK.sol";
import {RISKHook} from "src/RISKHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Tries maintenance while a third party already holds the manager's unlock.
contract NestedMaintenanceProbe {
    IPoolManager immutable manager;
    RISKHook immutable hook;

    constructor(IPoolManager manager_, RISKHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attempt() external returns (bytes memory) {
        return manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool batchOK, bytes memory batchError) = address(hook).call(abi.encodeCall(hook.executeBatch, ()));
        (bool sweepOK, bytes memory sweepError) = address(hook).call(abi.encodeCall(hook.sweep, ()));
        return abi.encode(batchOK, batchError, sweepOK, sweepError);
    }
}

abstract contract RISKAdversarialScenarios is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_hugeRepresentableRequestsOnlyPayForSmallPartialFill() public {
        // Safe nominal size close to int256.max, but the tight limit permits only a small fill.
        uint256 nominal = uint256(type(int256).max) / 101 * 100;
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool exactOut = i >= 2;
            bool z = _direction(buy);
            (uint160 current,,,) = manager.getSlot0(key.toId());
            // v4's stored tick can be one lower after crossing an exact boundary.
            int24 tick = TickMath.getTickAtSqrtPrice(current);
            uint160 limit = TickMath.getSqrtPriceAtTick(tick + (z ? int24(-1) : int24(1)));
            BalanceDelta raw = _checkedSwap(buy, exactOut, nominal, limit);
            int256 filled =
                exactOut ? int256(z ? raw.amount1() : raw.amount0()) : -int256(z ? raw.amount0() : raw.amount1());
            assertGt(filled, 0);
            assertLt(uint256(filled), nominal);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, limit);
        }
    }

    function test_unrepresentableRequestsRevertThroughRealManagerAndLeaveNoFees() public {
        bytes memory reason = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(RISKHook.UnrepresentableFee.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        uint256 last = hook.lastBatch();
        for (uint256 i; i < 4; ++i) {
            bool z = i % 2 == 0;
            vm.expectRevert(reason);
            router.swap(key, SwapParams(z, i < 2 ? type(int256).max : type(int256).min, _limit(z)));
        }
        assertEq(hook.pending(), 0);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.lastBatch(), last);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        _checkedSwap(true, false, 1e20, _limit(_direction(true)));
    }

    function test_zeroLiquiditySwapsChargeNothingInEveryMode() public {
        _changeLiquidity(-int256(uint256(LIQUIDITY)));
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool z = _direction(buy);
            (, int24 tick,,) = manager.getSlot0(key.toId());
            BalanceDelta raw =
                _checkedSwap(buy, i >= 2, 1e23, TickMath.getSqrtPriceAtTick(tick + (z ? int24(-10) : int24(10))));
            assertEq(BalanceDelta.unwrap(raw), 0);
        }
        assertEq(hook.pending(), 0);
        assertEq(hook.pendingBurn(), 0);
        _changeLiquidity(int256(uint256(LIQUIDITY)));
        _checkedSwap(false, false, 1e20, _limit(_direction(false)));
        assertGt(hook.pending(), 0);
    }

    function test_batchWithoutLiquidityPreservesBudgetAndRecovers() public {
        _swap(false, false, 1e22);
        uint256 pending = hook.pending();
        uint256 dead = risk.balanceOf(hook.DEAD());
        _changeLiquidity(-int256(uint256(LIQUIDITY)));
        vm.warp(hook.lastBatch() + 3600);
        hook.executeBatch();
        assertEq(hook.pending(), pending);
        assertEq(risk.balanceOf(hook.DEAD()), dead);
        assertEq(hook.lastBatch(), block.timestamp);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        _changeLiquidity(int256(uint256(LIQUIDITY)));
        vm.warp(block.timestamp + 3600);
        hook.executeBatch();
        assertLt(hook.pending(), pending);
        assertLe(pending - hook.pending(), pending / 4);
        assertGt(risk.balanceOf(hook.DEAD()), dead);
    }

    function test_overdueSwapsNeverRunMaintenanceInsideCallback() public {
        _swap(false, false, 1e22);
        _swap(true, false, 1e21);
        uint256 last = hook.lastBatch();
        uint256 dead = risk.balanceOf(hook.DEAD());
        vm.warp(last + 10 days);
        for (uint256 i; i < 4; ++i) {
            uint256 pending = hook.pending();
            uint256 burn = hook.pendingBurn();
            vm.recordLogs();
            _swap(i % 2 == 0, i >= 2, 1e20);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 swapCount;
            for (uint256 j; j < logs.length; ++j) {
                bytes32 topic = logs[j].topics[0];
                if (
                    logs[j].emitter == address(manager)
                        && topic == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
                ) ++swapCount;
                if (logs[j].emitter == address(hook)) {
                    assertTrue(topic != keccak256("BatchExecuted(uint256,uint256,uint256,uint160)"));
                    assertTrue(topic != keccak256("Swept(uint256)"));
                }
            }
            assertEq(swapCount, 1, "callback executed a nested swap");
            assertGe(hook.pending(), pending);
            assertGe(hook.pendingBurn(), burn);
            assertEq(hook.lastBatch(), last);
            assertEq(risk.balanceOf(hook.DEAD()), dead);
        }
    }

    function test_failedSweepRestoresClaimsAndCanBeRetried() public {
        _swap(true, false, 1e22);
        uint256 burn = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        assertGt(burn, 0);
        // Fault injection only: RISK itself is the fixed, ordinary ERC20.
        vm.mockCallRevert(address(risk), abi.encodeCall(IERC20.transfer, (hook.DEAD(), burn)), "transfer fault");
        vm.expectRevert();
        hook.sweep();
        assertEq(hook.pendingBurn(), burn);
        assertEq(risk.balanceOf(hook.DEAD()), dead);
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        vm.clearMockedCalls();
        hook.sweep();
        assertEq(hook.pendingBurn(), 0);
        assertEq(risk.balanceOf(hook.DEAD()) - dead, burn);
    }

    function test_failedBatchRestoresCooldownPriceAndClaims() public {
        _swap(false, false, 1e22);
        uint256 pending = hook.pending();
        uint256 last = hook.lastBatch();
        uint256 dead = risk.balanceOf(hook.DEAD());
        (uint160 price,,,) = manager.getSlot0(key.toId());
        vm.warp(last + 3600);
        uint160 refPrice = hook.referencePrice();
        vm.mockCallRevert(
            address(risk), abi.encodePacked(IERC20.transfer.selector, abi.encode(hook.DEAD())), "transfer fault"
        );
        vm.expectRevert();
        hook.executeBatch();
        assertEq(hook.lastBatch(), last);
        assertEq(hook.pending(), pending);
        assertEq(hook.referencePrice(), refPrice);
        assertEq(risk.balanceOf(hook.DEAD()), dead);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        vm.clearMockedCalls();
        hook.executeBatch();
        assertLt(hook.pending(), pending);
        assertGt(risk.balanceOf(hook.DEAD()), dead);
        assertEq(hook.lastBatch(), block.timestamp);
    }

    function test_nestedMaintenanceCannotConsumeCooldownOrClaims() public {
        _swap(false, false, 1e22);
        _swap(true, false, 1e21);
        uint256 pending = hook.pending();
        uint256 burn = hook.pendingBurn();
        uint256 last = hook.lastBatch();
        vm.warp(last + 3600);
        NestedMaintenanceProbe probe = new NestedMaintenanceProbe(manager, hook);
        (bool batchOK, bytes memory batchError, bool sweepOK, bytes memory sweepError) =
            abi.decode(probe.attempt(), (bool, bytes, bool, bytes));
        assertFalse(batchOK);
        assertFalse(sweepOK);
        assertEq(batchError, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(sweepError, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(hook.lastBatch(), last);
        assertEq(hook.pending(), pending);
        assertEq(hook.pendingBurn(), burn);
        hook.executeBatch();
        hook.sweep();
        assertLt(hook.pending(), pending);
        assertEq(hook.pendingBurn(), 0);
    }

    function _checkDustFees(bool buy, bool exactOut, uint16 seed) internal {
        _checkedSwap(buy, exactOut, bound(seed, 1, 10_000), _limit(_direction(buy)));
    }

    function _changeLiquidity(int256 change) internal {
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, change, bytes32(0)));
    }
}

contract RISKHookAdversarialTest is RISKAdversarialScenarios {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_dustFeesUseFilledAmount(bool buy, bool exactOut, uint16 seed) public {
        _checkDustFees(buy, exactOut, seed);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_referenceWeightsIrregularDurations(uint16 first, uint16 second, bool firstBuy) public {
        uint256 start = vm.getBlockTimestamp();
        uint256 d1 = bound(first, 1, 3598);
        uint256 d2 = bound(second, 1, 3599 - d1);
        vm.warp(start + d1);
        _swap(firstBuy, false, 1e22);
        (, int24 tick1,,) = manager.getSlot0(key.toId());
        vm.warp(start + d1 + d2);
        _swap(!firstBuy, false, 2e22);
        (, int24 tick2,,) = manager.getSlot0(key.toId());
        vm.warp(start + 3600);
        int256 weighted = int256(tick1) * int256(d2) + int256(tick2) * int256(3600 - d1 - d2);
        int256 mean = weighted / 3600;
        if (weighted < 0 && weighted % 3600 != 0) --mean;
        uint160 expected = TickMath.getSqrtPriceAtTick(int24(mean));
        assertEq(hook.referencePrice(), expected);
        _swap(true, false, 1e6);
        assertEq(hook.referencePrice(), expected, "same-timestamp swap changed completed reference");
        (, int24 latestTick,,) = manager.getSlot0(key.toId());
        vm.warp(start + 7199);
        assertEq(hook.referencePrice(), expected, "incomplete interval replaced reference");
        vm.warp(start + 7200);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(latestTick));
    }

    function test_batchPriceFeedsNextObservationDespiteSelfCallbackExemption() public {
        _swap(false, false, 1e23);
        (, int24 beforeTick,,) = manager.getSlot0(key.toId());
        vm.warp(hook.lastBatch() + 3600);
        hook.executeBatch();
        (, int24 afterTick,,) = manager.getSlot0(key.toId());
        assertTrue(beforeTick != afterTick);
        vm.warp(block.timestamp + 3600);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(afterTick));
    }

    function test_dustBudgetRetainsClaimsAndStillEnforcesCooldown() public {
        _swap(false, false, 203);
        uint256 pending = hook.pending();
        assertGt(pending, 0);
        assertLt(pending, 4);
        vm.warp(hook.lastBatch() + 3600);
        hook.executeBatch();
        assertEq(hook.pending(), pending);
        assertEq(hook.lastBatch(), block.timestamp);
        vm.expectRevert(RISKHook.TooSoon.selector);
        hook.executeBatch();
    }

    function test_batchAcceptsProtocolFeesAndStillUsesOnlyPriceLimit() public {
        _swap(false, false, 1e23);
        // Make the budget exceed the liquidity inside the permitted price interval.
        _changeLiquidity(-int256(uint256(LIQUIDITY - 1e20)));
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        vm.warp(hook.lastBatch() + 3600);
        uint256 accrued = hook.pending();
        uint256 burn = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        Currency pair = Currency.wrap(IMD);
        uint256 protocolBefore = manager.protocolFeesAccrued(pair);
        uint160 refPrice = hook.referencePrice();
        (uint160 spotBefore,,,) = manager.getSlot0(key.toId());
        hook.executeBatch();
        uint256 spent = accrued - hook.pending();
        assertGt(spent, 0);
        assertLt(spent, accrued / 4, "must partially fill");
        assertGt(risk.balanceOf(hook.DEAD()), dead);
        assertGt(manager.protocolFeesAccrued(pair), protocolBefore);
        assertEq(hook.pendingBurn(), burn, "batch paid a hook fee");
        (uint160 price,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        _assertPartialBatchPrice(price, refPrice, spotBefore);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function _assertPartialBatchPrice(uint160 price, uint160 refPrice, uint160 spotBefore) internal view {
        // Check both 3% bands in price space without copying the hook's sqrt multipliers.
        // A partial fill must reach the tighter band; a stale reference may only tighten it.
        uint256 refRatio = uint256(price) * 1e18 / refPrice;
        refRatio = refRatio * refRatio / 1e18;
        uint256 spotRatio = uint256(price) * 1e18 / spotBefore;
        spotRatio = spotRatio * spotRatio / 1e18;
        if (_direction(true)) {
            assertGe(refRatio, 0.97e18 - 10, "batch exceeded reference band");
            assertGe(spotRatio, 0.97e18 - 10, "batch exceeded spot band");
            assertApproxEqAbs(refRatio < spotRatio ? refRatio : spotRatio, 0.97e18, 10);
        } else {
            assertLe(refRatio, 1.03e18 + 10, "batch exceeded reference band");
            assertLe(spotRatio, 1.03e18 + 10, "batch exceeded spot band");
            assertApproxEqAbs(refRatio > spotRatio ? refRatio : spotRatio, 1.03e18, 10);
        }
    }
}

contract RISKHookAdversarialReverseTest is RISKAdversarialScenarios {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_dustFeesUseFilledAmount(bool buy, bool exactOut, uint16 seed) public {
        _checkDustFees(buy, exactOut, seed);
    }

    function setUp() public override {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new RISK()).code);
        address highToken = address(uint160(type(uint160).max - 100));
        deployCodeTo("RISK.sol:RISK", highToken);
        _launch(RISK(highToken));
    }
}

contract RISKHookFreshManagerTest is HookFixture {
    function _seed() internal override {
        // Seed exclusively RISK in an out-of-range position. The manager holds no IMD.
        bool riskIs0 = address(risk) < IMD;
        router.liquidity(
            key,
            ModifyLiquidityParams(
                riskIs0 ? int24(60) : int24(-600),
                riskIs0 ? int24(600) : int24(-60),
                int256(uint256(LIQUIDITY)),
                bytes32(0)
            )
        );
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_firstBuyWorksWithZeroPairedCurrencyReserves(bool exactOut, uint96 seed) public {
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
        _checkedSwap(true, exactOut, bound(seed, 1e6, 1e22), _limit(_direction(true)));
        if (exactOut) assertGt(hook.pending(), 0, "input fee must accrue before IMD settlement");
        else assertGt(hook.pendingBurn(), 0);
    }
}

/// @notice Run with --fork-url URL --fork-block-number BLOCK; offline runs explicitly skip.
contract RISKHookAdversarialMainnetForkTest is RISKAdversarialScenarios {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_dustFeesUseFilledAmount(bool buy, bool exactOut, uint16 seed) public {
        _checkDustFees(buy, exactOut, seed);
    }

    function setUp() public override {
        if (block.chainid != 1 || MAINNET_MANAGER.code.length == 0 || IMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        manager = IPoolManager(MAINNET_MANAGER);
        _launch(new RISK());
    }
}
