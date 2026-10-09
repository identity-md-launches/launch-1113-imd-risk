// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RISK} from "../src/RISK.sol";
import {RISKHook} from "../src/RISKHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolRouter} from "./PoolRouter.sol";

contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 internal constant ONE = 79228162514264337593543950336;
    uint128 internal constant LIQUIDITY = 1e24;
    IPoolManager internal manager;
    RISK internal risk;
    RISKHook internal hook;
    PoolRouter internal router;
    PoolKey internal key;

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new RISK()).code);
        _launch(new RISK());
    }

    function _launch(RISK launchToken) internal {
        risk = launchToken;
        bytes memory code = abi.encodePacked(type(RISKHook).creationCode, abi.encode(manager, address(risk)));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (!HookFlags.matches(predicted, HookFlags.RISK_FLAGS)) continue;
            address at;
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            require(at == predicted && at != address(0), "CREATE2 failed");
            hook = RISKHook(at);
            break;
        }
        require(address(hook) != address(0), "no salt");
        key = hook.poolKey();
        manager.initialize(key, ONE);
        router = new PoolRouter(manager);
        deal(IMD, address(this), 1e30);
        IERC20(IMD).approve(address(router), type(uint256).max);
        risk.approve(address(router), type(uint256).max);
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, int256(uint256(LIQUIDITY)), bytes32(0)));
    }

    function _direction(bool buy) internal view returns (bool) {
        return buy ? IMD < address(risk) : address(risk) < IMD;
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swap(bool buy, bool exactOut, uint256 amount) internal returns (BalanceDelta) {
        bool z = _direction(buy);
        return router.swap(key, SwapParams(z, exactOut ? int256(amount) : -int256(amount), _limit(z)));
    }

    // Check the fee against the manager's raw Swap event, independently of the hook's return value.
    function _checkedSwap(bool buy, bool exactOut, uint256 amount, uint160 limit) internal returns (BalanceDelta raw) {
        bool z = _direction(buy);
        bool unspecifiedIs0 = exactOut == z;
        Currency currency = unspecifiedIs0 ? key.currency0 : key.currency1;
        uint256 claimBefore = manager.balanceOf(address(hook), currency.toId());
        uint256 b0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 b1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta net = router.swap(key, SwapParams(z, exactOut ? int256(amount) : -int256(amount), limit));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(manager)
                    || logs[i].topics[0]
                        != keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) continue;
            (int128 a0, int128 a1,,,, uint24 feeTier) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(feeTier, 12500, "LP fee changed");
            raw = toBalanceDelta(a0, a1);
            found = true;
            break;
        }
        assertTrue(found, "missing swap");
        int256 filled = unspecifiedIs0 ? int256(raw.amount0()) : int256(raw.amount1());
        uint256 fee = uint256(filled < 0 ? -filled : filled) / 100;
        assertEq(manager.balanceOf(address(hook), currency.toId()) - claimBefore, fee, "fee != actual fill /100");
        assertEq(int256(net.amount0()), int256(raw.amount0()) - (unspecifiedIs0 ? int256(fee) : int256(0)));
        assertEq(int256(net.amount1()), int256(raw.amount1()) - (unspecifiedIs0 ? int256(0) : int256(fee)));
        assertEq(
            int256(IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this))) - int256(b0), int256(net.amount0())
        );
        assertEq(
            int256(IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this))) - int256(b1), int256(net.amount1())
        );
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), currency), 0);
        assertEq(risk.balanceOf(address(hook)), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
    }
}

contract RISKHookTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_allSwapModesAndSweep() public {
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool exactOut = i >= 2;
            _checkedSwap(buy, exactOut, 1e20, _limit(_direction(buy)));
        }
        uint256 burn = hook.pendingBurn();
        uint256 pair = hook.pending();
        assertGt(burn, 0);
        assertGt(pair, 0);
        uint256 deadBefore = risk.balanceOf(hook.DEAD());
        vm.prank(makeAddr("anyone"));
        hook.sweep();
        assertEq(risk.balanceOf(hook.DEAD()) - deadBefore, burn);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.pending(), pair);
        hook.sweep();
        assertEq(risk.totalSupply(), 1e27, "sink transfer leaves ERC20 supply fixed");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeTracksActualPartialFill(bool buy, bool exactOut, uint256 amount, uint24 move) public {
        amount = bound(amount, 1e10, 1e23);
        int24 ticks = int24(int256(bound(move, 1, 100)));
        bool z = _direction(buy);
        uint160 limit = TickMath.getSqrtPriceAtTick(z ? -ticks : ticks);
        BalanceDelta raw = _checkedSwap(buy, exactOut, amount, limit);
        int256 specified =
            exactOut ? int256(z ? raw.amount1() : raw.amount0()) : -int256(z ? raw.amount0() : raw.amount1());
        assertLe(uint256(specified), amount);
    }

    function test_exactInputAndOutputPartialFillsBothDirections() public {
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool exactOut = i >= 2;
            (, int24 tick,,) = manager.getSlot0(key.toId());
            bool z = _direction(buy);
            uint160 limit = TickMath.getSqrtPriceAtTick(tick + (z ? int24(-10) : int24(10)));
            BalanceDelta raw = _checkedSwap(buy, exactOut, 1e23, limit);
            int256 specified =
                exactOut ? int256(z ? raw.amount1() : raw.amount0()) : -int256(z ? raw.amount0() : raw.amount1());
            assertGt(specified, 0);
            assertLt(uint256(specified), 1e23, "must actually hit price limit");
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, limit);
        }
    }

    function test_permissionsInitAndAuthorization() public {
        assertEq(HookFlags.flagsOf(address(hook)), 0x20c4);
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap && p.afterSwapReturnDelta);
        assertFalse(p.beforeSwapReturnDelta);
        vm.expectRevert(RISKHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        vm.expectRevert(RISKHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, ONE / 2), "");
        vm.expectRevert(RISKHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, ONE / 2), toBalanceDelta(-100, 100), "");
        vm.expectRevert(RISKHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(true));
        vm.prank(address(manager));
        vm.expectRevert(RISKHook.ReentrantOperation.selector);
        hook.unlockCallback(abi.encode(true));
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, ONE);
        vm.expectRevert();
        manager.initialize(key, ONE);
    }

    function test_batchCooldownAndBudget() public {
        _swap(false, false, 1e22);
        uint256 accrued = hook.pending();
        assertGt(accrued, 0);
        vm.expectRevert(RISKHook.TooSoon.selector);
        hook.executeBatch();
        vm.warp(hook.lastBatch() + 3599);
        vm.expectRevert(RISKHook.TooSoon.selector);
        hook.executeBatch();
        vm.warp(hook.lastBatch() + 3600);
        uint256 deadBefore = risk.balanceOf(hook.DEAD());
        uint256 burnBefore = hook.pendingBurn();
        vm.prank(makeAddr("keeper"));
        hook.executeBatch();
        assertEq(accrued - hook.pending(), accrued / 4, "full budget should fit");
        assertGt(risk.balanceOf(hook.DEAD()), deadBefore);
        assertEq(hook.pendingBurn(), burnBefore, "self swap must not pay hook fee");
        assertEq(hook.lastBatch(), block.timestamp);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        vm.expectRevert(RISKHook.TooSoon.selector);
        hook.executeBatch();
    }

    function test_batchPartialFillRetainsClaimsAndCanRunAgain() public {
        _swap(false, false, 1e23);
        uint256 accrued = hook.pending();
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, -int256(uint256(LIQUIDITY - 1e20)), bytes32(0)));
        vm.warp(hook.lastBatch() + 3600);
        uint160 ref = hook.referencePrice();
        bool z = IMD < address(risk);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (z ? current > ref : current < ref) ref = current;
        uint256 product = uint256(ref) * (z ? 984885780179610473 : 1014889156509221946);
        uint160 limit = uint160(z ? (product + 1e18 - 1) / 1e18 : product / 1e18);
        uint256 deadBefore = risk.balanceOf(hook.DEAD());
        hook.executeBatch();
        uint256 spent = accrued - hook.pending();
        assertGt(spent, 0);
        assertLt(spent, accrued / 4);
        assertGt(risk.balanceOf(hook.DEAD()), deadBefore);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        uint256 leftover = hook.pending();
        vm.warp(block.timestamp + 3600);
        hook.executeBatch();
        assertLt(hook.pending(), leftover, "subsequent batch progresses");
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_spotBeyondLimitDoesNotDeadlock() public {
        _swap(false, false, 1e22);
        vm.warp(hook.lastBatch() + 3600);
        uint160 ref = hook.referencePrice();
        // Zero elapsed time for this manipulation: the completed TWAP cannot follow it.
        _swap(true, false, 1e23);
        assertEq(hook.referencePrice(), ref);
        uint256 accrued = hook.pending();
        uint256 deadBefore = risk.balanceOf(hook.DEAD());
        hook.executeBatch();
        assertEq(hook.pending(), accrued);
        assertEq(risk.balanceOf(hook.DEAD()), deadBefore);
        vm.warp(block.timestamp + 3600);
        hook.executeBatch();
        assertLt(hook.pending(), accrued);
    }

    function test_timeWeightedReferenceAndSameBlockResistance() public {
        uint256 start = block.timestamp;
        vm.warp(start + 1800);
        _swap(false, false, 1e23);
        (, int24 changedTick,,) = manager.getSlot0(key.toId());
        assertEq(hook.referencePrice(), ONE);
        vm.warp(start + 3600);
        int24 average = changedTick / 2;
        if (changedTick < 0 && changedTick % 2 != 0) --average;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(average));
        uint160 before = hook.referencePrice();
        _swap(true, false, 1e23);
        assertEq(hook.referencePrice(), before);
    }

    function test_emptyBatchAndEmptySweep() public {
        hook.sweep();
        vm.warp(block.timestamp + 3600);
        hook.executeBatch();
        assertEq(hook.pending(), 0);
        assertEq(hook.lastBatch(), block.timestamp);
    }

    function test_dustAndUnrepresentableRequests() public {
        _checkedSwap(true, false, 1, _limit(_direction(true)));
        vm.prank(address(manager));
        vm.expectRevert(RISKHook.UnrepresentableFee.selector);
        hook.beforeSwap(address(router), key, SwapParams(true, type(int256).max, ONE / 2), "");
        vm.prank(address(manager));
        vm.expectRevert(RISKHook.UnrepresentableFee.selector);
        hook.beforeSwap(address(router), key, SwapParams(true, type(int256).min, ONE / 2), "");
    }

    function test_creationSizeAndRuntimeNoEscapeHatches() public view {
        assertLe(type(RISKHook).creationCode.length + 64, 49152);
        assertLe(address(hook).code.length, 24576);
        _scan(address(hook).code);
        _scan(address(risk).code);
    }

    function _scan(bytes memory code) internal pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xf4 && op != 0xff && op != 0xf2, "unsafe opcode");
        }
    }
}

/// @notice Exercise the same economic checks with IMD sorted as currency0.
contract RISKHookReverseOrderingTest is RISKHookTest {
    function setUp() public override {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new RISK()).code);
        address highToken = address(uint160(type(uint160).max - 100));
        deployCodeTo("RISK.sol:RISK", highToken);
        _launch(RISK(highToken));
    }
}

/// @notice Opt-in using forge test --fork-url URL --match-contract RISKHookMainnetForkTest.
/// No environment reads; default offline runs report a skip, never a false pass.
contract RISKHookMainnetForkTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        if (block.chainid != 1 || MAINNET_MANAGER.code.length == 0 || IMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        manager = IPoolManager(MAINNET_MANAGER);
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        _launch(new RISK());
    }

    function test_mainnetFourSwapModesPartialFillsSweepAndBatch() public {
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool out = i >= 2;
            bool z = _direction(buy);
            _checkedSwap(buy, out, 1e20, _limit(z));
            (, int24 tick,,) = manager.getSlot0(key.toId());
            _checkedSwap(buy, out, 1e23, TickMath.getSqrtPriceAtTick(tick + (z ? int24(-30) : int24(30))));
        }
        uint256 burn = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        hook.sweep();
        assertEq(risk.balanceOf(hook.DEAD()) - dead, burn);
        uint256 accrued = hook.pending();
        vm.warp(hook.lastBatch() + 3600);
        hook.executeBatch();
        assertLe(accrued - hook.pending(), accrued / 4);
        assertGt(risk.balanceOf(hook.DEAD()), dead + burn);
    }
}
