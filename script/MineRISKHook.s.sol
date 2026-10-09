// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {RISKHook} from "../src/RISKHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Read-only salt search for the actual factory's direct CREATE2 deployment.
/// @dev No broadcasts, private keys, environment reads, or intermediate deployment wrapper.
contract MineRISKHook {
    function creationCode(IPoolManager manager, address token) public pure returns (bytes memory) {
        return abi.encodePacked(type(RISKHook).creationCode, abi.encode(manager, token));
    }

    function mine(address create2Deployer, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (bool found, bytes32 salt, address predicted)
    {
        bytes32 hash = keccak256(creationCode(manager, token));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.RISK_FLAGS)) return (true, salt, predicted);
        }
        return (false, bytes32(0), address(0));
    }
}
