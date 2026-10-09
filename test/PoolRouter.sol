// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A minimal synchronous settlement router exercising the actual PoolManager.
contract PoolRouter {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, true, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params) external {
        manager.unlock(abi.encode(msg.sender, key, false, abi.encode(params)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, bool swapping, bytes memory args) =
            abi.decode(data, (address, PoolKey, bool, bytes));
        BalanceDelta delta;
        if (swapping) delta = manager.swap(key, abi.decode(args, (SwapParams)), "");
        else (delta,) = manager.modifyLiquidity(key, abi.decode(args, (ModifyLiquidityParams)), "");
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            uint256 owed = uint256(-int256(delta));
            require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed));
            require(manager.settle() == owed);
        } else if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        }
    }
}
