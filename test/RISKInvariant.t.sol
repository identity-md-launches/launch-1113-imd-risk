// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./RISKHook.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RISKInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    uint256 private measuredPairFees;
    uint256 private measuredTokenFees;
    uint256 private measuredSpent;
    uint256 private measuredBurned;
    uint256 private measuredBought;

    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = this.actSwap.selector;
        selectors[1] = this.actSweep.selector;
        selectors[2] = this.actBatch.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), selectors));
    }

    function actSwap(bool buy, bool exactOut, uint256 amount, uint16 advance) external {
        vm.warp(block.timestamp + bound(advance, 0, 600));
        amount = bound(amount, 1e10, 1e21);
        uint256 pairBefore = hook.pending();
        uint256 tokenBefore = hook.pendingBurn();
        _checkedSwap(buy, exactOut, amount, _limit(_direction(buy)));
        measuredPairFees += hook.pending() - pairBefore;
        measuredTokenFees += hook.pendingBurn() - tokenBefore;
    }

    function actSweep() external {
        uint256 fees = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        hook.sweep();
        assertEq(risk.balanceOf(hook.DEAD()) - dead, fees);
        measuredBurned += fees;
    }

    function actBatch(uint16 advance) external {
        vm.warp(block.timestamp + bound(advance, 3600, 7200));
        uint256 pairBefore = hook.pending();
        uint256 tokenBefore = hook.pendingBurn();
        uint256 dead = risk.balanceOf(hook.DEAD());
        hook.executeBatch();
        uint256 spent = pairBefore - hook.pending();
        assertLe(spent, pairBefore / 4);
        assertEq(hook.pendingBurn(), tokenBefore);
        measuredSpent += spent;
        measuredBought += risk.balanceOf(hook.DEAD()) - dead;
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationAndClaimAccounting() public view {
        assertEq(risk.totalSupply(), 1e27);
        assertEq(risk.balanceOf(address(this)) + risk.balanceOf(address(manager)) + risk.balanceOf(hook.DEAD()), 1e27);
        assertEq(IERC20(IMD).balanceOf(address(this)) + IERC20(IMD).balanceOf(address(manager)), 1e30);
        assertEq(hook.pending() + measuredSpent, measuredPairFees);
        assertEq(hook.pendingBurn() + measuredBurned, measuredTokenFees);
        assertEq(risk.balanceOf(hook.DEAD()), measuredBurned + measuredBought);
        assertEq(risk.balanceOf(address(hook)), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}
