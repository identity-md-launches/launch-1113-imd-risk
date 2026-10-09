// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./RISKHook.t.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {RISK} from "src/RISK.sol";
import {RISKHook} from "src/RISKHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Ghost fees and buybacks come from the manager's raw Swap events, not hook getters.
contract RISKLifecycleHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    RISK public immutable risk;
    RISKHook public immutable hook;
    PoolRouter public immutable router;
    PoolKey private key;
    address private immutable pair;
    uint256 public liquidity = 1e24;
    uint256 public pairFees;
    uint256 public tokenFees;
    uint256 public spent;
    uint256 public bought;
    uint256 public swept;
    uint256 public swaps;
    uint256 public batches;
    uint256 public rejectedBatches;
    bytes32 private constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    constructor(IPoolManager manager_, RISK risk_, RISKHook hook_, PoolRouter router_) {
        manager = manager_;
        risk = risk_;
        hook = hook_;
        router = router_;
        key = hook_.poolKey();
        pair = hook_.IMD();
        risk_.approve(address(router_), type(uint256).max);
        IERC20(pair).approve(address(router_), type(uint256).max);
    }

    function advance(uint16 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 7200));
    }

    function swap(bool buy, bool exactOut, uint96 amountSeed, uint8 tickSeed) external {
        bool zeroForOne = buy ? pair < address(risk) : address(risk) < pair;
        uint256 amount = bound(amountSeed, 1, 1e22);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        int24 tick = TickMath.getTickAtSqrtPrice(current);
        int24 distance = int24(int256(bound(tickSeed, 1, 60)));
        uint160 limit = TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? -distance : distance));
        uint256 dead = risk.balanceOf(hook.DEAD());
        uint256 last = hook.lastBatch();
        vm.recordLogs();
        router.swap(key, SwapParams(zeroForOne, exactOut ? int256(amount) : -int256(amount), limit));
        _recordSwapFees(buy != exactOut);
        assertEq(risk.balanceOf(hook.DEAD()), dead);
        assertEq(hook.lastBatch(), last);
        ++swaps;
    }

    function _recordSwapFees(bool feeInToken) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP) continue;
            ++count;
            (int128 a0, int128 a1,,,, uint24 lpFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lpFee, 12500);
            // Exact input fees are on output; exact output fees are on input.
            bool feeIs0 = Currency.unwrap(key.currency0) == (feeInToken ? address(risk) : pair);
            int256 raw = feeIs0 ? int256(a0) : int256(a1);
            uint256 fee = uint256(raw < 0 ? -raw : raw) / 100;
            if (feeInToken) tokenFees += fee;
            else pairFees += fee;
        }
        assertEq(count, 1, "normal swap must not trigger a buyback");
    }

    function changeLiquidity(uint96 seed, bool empty) external {
        uint256 next = empty ? 0 : bound(seed, 1e19, 1e24);
        uint256 pairBefore = hook.pending();
        uint256 tokenBefore = hook.pendingBurn();
        // v4 refuses a zero-delta fee collection on an already empty position.
        if (next == 0 && liquidity == 0) vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, int256(next) - int256(liquidity), bytes32(0)));
        liquidity = next;
        assertEq(hook.pending(), pairBefore);
        assertEq(hook.pendingBurn(), tokenBefore);
    }

    function sweep(uint8 callerSeed) external {
        uint256 burn = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        vm.prank(_keeper(callerSeed));
        hook.sweep();
        assertEq(risk.balanceOf(hook.DEAD()) - dead, burn);
        swept += burn;
    }

    function batch(uint8 callerSeed) external {
        uint256 pairBefore = hook.pending();
        uint256 tokenBefore = hook.pendingBurn();
        uint256 last = hook.lastBatch();
        uint256 dead = risk.balanceOf(hook.DEAD());
        if (block.timestamp - last < 3600) {
            vm.prank(_keeper(callerSeed));
            vm.expectRevert(RISKHook.TooSoon.selector);
            hook.executeBatch();
            assertEq(hook.lastBatch(), last);
            assertEq(hook.pending(), pairBefore);
            assertEq(hook.pendingBurn(), tokenBefore);
            assertEq(risk.balanceOf(hook.DEAD()), dead);
            ++rejectedBatches;
            return;
        }
        vm.recordLogs();
        vm.prank(_keeper(callerSeed));
        hook.executeBatch();
        (uint256 used, uint256 output) = _batchFill();
        assertLe(used, pairBefore / 4);
        assertEq(pairBefore - hook.pending(), used);
        assertEq(risk.balanceOf(hook.DEAD()) - dead, output);
        assertEq(hook.pendingBurn(), tokenBefore);
        assertEq(hook.lastBatch(), block.timestamp);
        spent += used;
        bought += output;
        ++batches;
    }

    function _batchFill() private returns (uint256 used, uint256 output) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP) continue;
            ++count;
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(hook));
            (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            bool pairIs0 = Currency.unwrap(key.currency0) == pair;
            used = uint256(-int256(pairIs0 ? a0 : a1));
            output = uint256(int256(pairIs0 ? a1 : a0));
        }
        assertLe(count, 1);
    }

    function _keeper(uint8 seed) private pure returns (address) {
        // Synthetic test callers are unrelated to deployment configuration.
        return address(uint160(0x10000 + uint256(seed)));
    }
}

contract RISKLifecycleInvariantTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    RISKLifecycleHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new RISKLifecycleHandler(manager, risk, hook, router);
        risk.transfer(address(handler), risk.balanceOf(address(this)));
        IERC20(IMD).transfer(address(handler), IERC20(IMD).balanceOf(address(this)));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.changeLiquidity.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.sweep.selector;
        selectors[4] = handler.batch.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_claimsAndAssetsSurviveLiquidityAndMaintenanceSequences() public view {
        assertEq(hook.pending() + handler.spent(), handler.pairFees());
        assertEq(hook.pendingBurn() + handler.swept(), handler.tokenFees());
        assertEq(risk.balanceOf(hook.DEAD()), handler.swept() + handler.bought());
        assertEq(risk.totalSupply(), 1e27);
        assertEq(
            risk.balanceOf(address(handler)) + risk.balanceOf(address(manager)) + risk.balanceOf(hook.DEAD()), 1e27
        );
        assertEq(IERC20(IMD).balanceOf(address(handler)) + IERC20(IMD).balanceOf(address(manager)), 1e30);
        assertGe(risk.balanceOf(address(manager)), hook.pendingBurn());
        assertGe(IERC20(IMD).balanceOf(address(manager)), hook.pending());
        assertEq(risk.balanceOf(address(hook)), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(manager.getLiquidity(key.toId()), handler.liquidity());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertLe(hook.lastBatch(), block.timestamp);
        assertGt(hook.referencePrice(), 0);
    }
}
