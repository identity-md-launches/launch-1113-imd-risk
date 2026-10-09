// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MineRISKHook} from "../script/MineRISKHook.s.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {RISKHook} from "../src/RISKHook.sol";
import {RISK} from "../src/RISK.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeploymentTest is Test {
    function test_mineAndDeployDirectlyAtPredictedAddress() public {
        MineRISKHook miner = new MineRISKHook();
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        RISK token = new RISK();
        (bool found, bytes32 salt, address expected) = miner.mine(address(this), manager, address(token), 0, 200_000);
        assertTrue(found);
        address pair = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        address t = address(token);
        PoolKey memory key = PoolKey(
            Currency.wrap(t < pair ? t : pair), Currency.wrap(t < pair ? pair : t), 12500, 60, IHooks(expected)
        );
        // The required initialization bit prevents opening the pool before the hook has code.
        vm.expectRevert();
        manager.initialize(key, 79228162514264337593543950336);
        RISKHook hook = new RISKHook{salt: salt}(manager, address(token));
        assertEq(address(hook), expected);
        assertEq(HookFlags.flagsOf(expected), 0x20c4);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(hook.referencePrice(), 0);
        vm.expectRevert(RISKHook.NotInitialized.selector);
        hook.executeBatch();
        vm.expectRevert(RISKHook.NotInitialized.selector);
        hook.sweep();
        (bool emptySearch,,) = miner.mine(address(this), manager, address(token), 0, 0);
        assertFalse(emptySearch);
        PoolKey memory invalid = hook.poolKey();
        invalid.fee = 3000;
        vm.expectRevert();
        manager.initialize(invalid, 79228162514264337593543950336);
        invalid.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(invalid, 79228162514264337593543950336);
        invalid = hook.poolKey();
        invalid.tickSpacing = 1;
        vm.expectRevert();
        manager.initialize(invalid, 79228162514264337593543950336);
        invalid = hook.poolKey();
        invalid.currency0 = Currency.wrap(address(100));
        vm.expectRevert();
        manager.initialize(invalid, 79228162514264337593543950336);
        key = hook.poolKey();
        vm.prank(makeAddr("factory"));
        manager.initialize(key, 79228162514264337593543950336);
        assertTrue(hook.initialized());
        assertEq(hook.referencePrice(), 79228162514264337593543950336);
    }

    function test_constructorRefusesInvalidInputsAndPermissionAddress() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        RISK token = new RISK();
        vm.expectRevert(RISKHook.InvalidConfiguration.selector);
        new RISKHook(manager, makeAddr("noCode"));
        vm.expectRevert(RISKHook.InvalidConfiguration.selector);
        new RISKHook(IPoolManager(makeAddr("noManagerCode")), address(token));
        vm.expectRevert();
        new RISKHook(manager, address(token));
    }
}
