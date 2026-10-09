// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./RISKHook.t.sol";
import {RISK} from "../src/RISK.sol";
import {RISKHook} from "../src/RISKHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regressions for the stale-reference sandwich and the two documented advisory behaviors.
contract RISKBatchLimitTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    struct Batch {
        uint256 budget;
        uint256 spent;
        uint256 bought;
        uint160 limit;
    }

    function setUp() public virtual override {
        _setUpOrdering(address(uint160(IMD) + 1));
    }

    function _setUpOrdering(address tokenAddress) internal {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new RISK()).code);
        deployCodeTo("RISK.sol:RISK", tokenAddress);
        _launch(RISK(tokenAddress));
    }

    function _runBatch() internal returns (Batch memory batch) {
        uint160 ref = hook.referencePrice();
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        uint256 accrued = hook.pending();
        uint256 burn = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        vm.recordLogs();
        hook.executeBatch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("BatchExecuted(uint256,uint256,uint256,uint160)")
            ) {
                batch = abi.decode(logs[i].data, (Batch));
                found = true;
            }
        }
        assertTrue(found, "missing batch event");
        assertEq(batch.budget, accrued / 4);
        assertEq(batch.spent, accrued - hook.pending());
        assertEq(batch.bought, risk.balanceOf(hook.DEAD()) - dead);
        assertLe(batch.spent, batch.budget);
        assertEq(hook.pendingBurn(), burn, "batch paid a hook fee");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        // The sole execution limit must respect BOTH price bands, regardless of reference age.
        _assertBand(batch.limit, ref);
        _assertBand(batch.limit, spot);
    }

    function _assertBand(uint160 limit, uint160 anchor) internal view {
        uint256 ratio = uint256(limit) * 1e18 / anchor;
        uint256 priceRatio = ratio * ratio / 1e18;
        // A few wei of WAD tolerance for the independent squared-ratio calculation.
        if (_direction(true)) assertGe(priceRatio, 0.97e18 - 3, "limit exceeds spot/reference band");
        else assertLe(priceRatio, 1.03e18, "limit exceeds spot/reference band");
    }

    function test_idleReferenceCannotWidenBatchLimit() public {
        _idleDrop(2 days, 3e23);
        _runBatch();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_idleReferenceCannotWidenBatchLimit(uint32 idle, uint96 dump) public {
        _idleDrop(bound(idle, 3600, 365 days), bound(dump, 1e22, 6e23));
        _runBatch();
    }

    function _idleDrop(uint256 idle, uint256 dump) internal {
        _swap(false, false, 5e22);
        vm.warp(vm.getBlockTimestamp() + idle);
        uint160 ref = hook.referencePrice();
        _swap(false, false, dump);
        assertEq(hook.referencePrice(), ref, "idle period must finish with the old tick");
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _accrueAndDrop(uint128 depth, uint256 dump) internal {
        if (depth < LIQUIDITY) {
            router.liquidity(
                key, ModifyLiquidityParams(-887220, 887220, -int256(uint256(LIQUIDITY - depth)), bytes32(0))
            );
        }
        uint256 start = vm.getBlockTimestamp();
        // Real trading creates the claims; no hook/manager storage or oracle state is injected.
        for (uint256 i; i < 320; ++i) {
            uint256 before = IERC20(IMD).balanceOf(address(this));
            _swap(false, false, depth / 10);
            _swap(true, false, IERC20(IMD).balanceOf(address(this)) - before);
        }
        vm.warp(start + 3599);
        _swap(false, false, dump);
        vm.warp(start + 3600);
    }

    function test_staleBandPartialFillRetainsBudgetAndNextBatchProgresses() public {
        _accrueAndDrop(1e22, 5e21);
        Batch memory batch = _runBatch();
        assertGt(batch.spent, 0);
        assertLt(batch.spent, batch.budget, "large budget must stop at tightened spot limit");
        assertGt(batch.bought, 0);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, batch.limit);
        vm.warp(vm.getBlockTimestamp() + 3600);
        Batch memory next = _runBatch();
        assertGt(next.spent, 0, "unspent claims must remain usable");
    }

    function test_reportedThinPoolSandwichLosesMoney() public {
        _accrueAndDrop(1e22, 5e21);
        _sandwichSizes();
    }

    function test_reportedDeepPoolSandwichLosesMoney() public {
        _accrueAndDrop(1e24, 3e23);
        _sandwichSizes();
    }

    function _sandwichSizes() internal {
        bool z = _direction(true);
        uint160 ref = hook.referencePrice();
        uint256 product = uint256(ref) * (z ? 984885780179610473 : 1014889156509221946);
        uint160 oldLimit = uint160(z ? (product + 1e18 - 1) / 1e18 : product / 1e18);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        address searcher = makeAddr("searcher");
        deal(IMD, searcher, 1e27);
        vm.startPrank(searcher);
        IERC20(IMD).approve(address(router), type(uint256).max);
        risk.approve(address(router), type(uint256).max);
        vm.stopPrank();
        // Includes the reported 30%-of-window point; each trial starts from identical market state.
        for (uint256 percent = 2; percent < 100; percent += 2) {
            uint256 snapshot = vm.snapshotState();
            uint160 frontLimit = z
                ? oldLimit + uint160(uint256(spot - oldLimit) * percent / 100)
                : oldLimit - uint160(uint256(oldLimit - spot) * percent / 100);
            vm.prank(searcher);
            router.swap(key, SwapParams(z, -int256(1e27), frontLimit));
            _runBatch();
            uint256 bought = risk.balanceOf(searcher);
            vm.prank(searcher);
            _swap(false, false, bought);
            assertLt(IERC20(IMD).balanceOf(searcher), 1e27, "same-block sandwich earned IMD");
            assertEq(risk.balanceOf(searcher), 0);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_sortedRatioConvention() public {
        vm.warp(vm.getBlockTimestamp() + 3600);
        uint160 ref = hook.referencePrice();
        Batch memory batch = _runBatch();
        uint256 ratio = _direction(true) ? uint256(ref) * 1e18 / batch.limit : uint256(batch.limit) * 1e18 / ref;
        uint256 pairedPriceRatio = ratio * ratio / 1e18;
        assertApproxEqAbs(pairedPriceRatio, _direction(true) ? uint256(1e20) / 97 : 1.03e18, 10);
    }

    function test_zeroFillStillConsumesCooldownAndRetainsClaims() public {
        _swap(false, false, 1e22);
        vm.warp(hook.lastBatch() + 3600);
        uint256 pairBefore = IERC20(IMD).balanceOf(address(this));
        uint256 riskBefore = risk.balanceOf(address(this));
        _swap(true, false, 1.6e22);
        Batch memory batch = _runBatch();
        assertGt(batch.budget, 0);
        assertEq(batch.spent, 0);
        assertEq(batch.bought, 0);
        assertEq(hook.lastBatch(), vm.getBlockTimestamp());
        _swap(false, false, risk.balanceOf(address(this)) - riskBefore);
        assertLt(IERC20(IMD).balanceOf(address(this)), pairBefore, "grief must cost the trader IMD");
        vm.expectRevert(RISKHook.TooSoon.selector);
        hook.executeBatch();
        vm.warp(hook.lastBatch() + 3599);
        vm.expectRevert(RISKHook.TooSoon.selector);
        hook.executeBatch();
        vm.warp(hook.lastBatch() + 3600);
        assertGt(_runBatch().spent, 0);
    }
}

contract RISKBatchLimitReverseOrderingTest is RISKBatchLimitTest {
    function setUp() public override {
        _setUpOrdering(address(uint160(IMD) - 1));
    }
}
