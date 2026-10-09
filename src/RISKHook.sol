// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Immutable launch-pool fee collector and permissionless, bounded buyback executor.
contract RISKHook {
    using StateLibrary for IPoolManager;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BATCH_BPS = 2500;
    uint256 public constant LIMIT_BPS = 300;
    uint256 public constant INTERVAL = 3600;
    uint24 public constant LP_FEE = 12500;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    address public immutable token;
    uint256 public lastBatch;
    bool public initialized;

    uint256 private periodStart;
    uint256 private observedAt;
    int256 private tickSeconds;
    int24 private spotTick;
    int24 private referenceTick;
    bool private operating;

    error OnlyPoolManager();
    error InvalidConfiguration();
    error InvalidPool();
    error NotInitialized();
    error TooSoon();
    error ReentrantOperation();
    error UnrepresentableFee();

    event FeeAccrued(address indexed currency, uint256 amount);
    event Swept(uint256 amount);
    event BatchExecuted(uint256 budget, uint256 spent, uint256 bought, uint160 limit);
    event ReferenceUpdated(int24 tick, uint256 duration);

    constructor(IPoolManager manager, address launchToken) {
        if (address(manager).code.length == 0 || launchToken.code.length == 0 || launchToken == IMD) {
            revert InvalidConfiguration();
        }
        poolManager = manager;
        token = launchToken;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier operation() {
        if (operating) revert ReentrantOperation();
        operating = true;
        _;
        operating = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token < IMD ? token : IMD),
            currency1: Currency.wrap(token < IMD ? IMD : token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyManager
        returns (bytes4)
    {
        PoolKey memory expected = poolKey();
        if (initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(expected.toId())) revert InvalidPool();
        initialized = true;
        spotTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        referenceTick = spotTick;
        periodStart = block.timestamp;
        observedAt = block.timestamp;
        lastBatch = block.timestamp;
        return IHooks.beforeInitialize.selector;
    }

    /// @dev No specified-side reservation and no LP fee override.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Reject requests whose nominal amount plus 1% cannot be represented in int256.
        uint256 magnitude =
            params.amountSpecified < 0 ? uint256(-(params.amountSpecified + 1)) + 1 : uint256(params.amountSpecified);
        if (magnitude > uint256(type(int256).max) - magnitude / 100) revert UnrepresentableFee();
        _observe();
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        _observe();
        (, spotTick,,) = poolManager.getSlot0(key.toId());
        if (sender == address(this)) return (IHooks.afterSwap.selector, 0);
        bool unspecifiedIs0 = (params.amountSpecified < 0) != params.zeroForOne;
        int256 filled = unspecifiedIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 fee = uint256(filled < 0 ? -filled : filled) / 100;
        if (fee != 0) {
            Currency currency = unspecifiedIs0 ? key.currency0 : key.currency1;
            // Claims do not transfer a token or run token code in the swap callback.
            poolManager.mint(address(this), currency.toId(), fee);
            emit FeeAccrued(Currency.unwrap(currency), fee);
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function pending() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(IMD).toId());
    }

    function pendingBurn() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(token).toId());
    }

    /// @notice Geometric TWAP as sqrtPriceX96, using a completed observation period of at least one hour.
    function referencePrice() public view returns (uint160) {
        if (!initialized) return 0;
        uint256 duration = block.timestamp - periodStart;
        int24 tick = referenceTick;
        if (duration >= INTERVAL) {
            int256 cumulative = tickSeconds + int256(spotTick) * int256(block.timestamp - observedAt);
            tick = _meanTick(cumulative, duration);
        }
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function sweep() external operation {
        if (!initialized) revert NotInitialized();
        poolManager.unlock(abi.encode(false));
    }

    function executeBatch() external operation {
        if (!initialized) revert NotInitialized();
        if (block.timestamp - lastBatch < INTERVAL) revert TooSoon();
        lastBatch = block.timestamp;
        _observe();
        poolManager.unlock(abi.encode(true));
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!operating) revert ReentrantOperation();
        if (!abi.decode(data, (bool))) {
            uint256 amount = pendingBurn();
            if (amount != 0) {
                poolManager.burn(address(this), Currency.wrap(token).toId(), amount);
                poolManager.take(Currency.wrap(token), DEAD, amount);
            }
            emit Swept(amount);
            return "";
        }
        uint256 budget = pending() / 4;
        // Each PoolManager swap delta must fit int128; oversized accrual is spent over multiple batches.
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        PoolKey memory key = poolKey();
        bool zeroForOne = IMD < token;
        uint160 ref = referencePrice();
        // sqrt(0.97), rounded UP; sqrt(1.03), rounded DOWN: conservative price bounds.
        uint256 product = uint256(ref) * (zeroForOne ? 984885780179610473 : 1014889156509221946);
        uint256 scaled = zeroForOne ? (product + 1e18 - 1) / 1e18 : product / 1e18;
        uint160 limit = uint160(
            scaled < TickMath.MIN_SQRT_PRICE + 1
                ? TickMath.MIN_SQRT_PRICE + 1
                : scaled > TickMath.MAX_SQRT_PRICE - 1 ? TickMath.MAX_SQRT_PRICE - 1 : scaled
        );
        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        // No room within the guard: a successful zero-fill batch, with all claims retained.
        if (budget == 0 || (zeroForOne ? current <= limit : current >= limit)) {
            emit BatchExecuted(budget, 0, 0, limit);
            return "";
        }
        BalanceDelta delta = poolManager.swap(key, SwapParams(zeroForOne, -int256(budget), limit), "");
        uint256 spent = uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 bought = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
        if (spent != 0) poolManager.burn(address(this), Currency.wrap(IMD).toId(), spent);
        if (bought != 0) poolManager.take(Currency.wrap(token), DEAD, bought);
        (, spotTick,,) = poolManager.getSlot0(key.toId());
        emit BatchExecuted(budget, spent, bought, limit);
        return "";
    }

    function _observe() private {
        uint256 now_ = block.timestamp;
        tickSeconds += int256(spotTick) * int256(now_ - observedAt);
        observedAt = now_;
        uint256 duration = now_ - periodStart;
        if (duration >= INTERVAL) {
            referenceTick = _meanTick(tickSeconds, duration);
            tickSeconds = 0;
            periodStart = now_;
            emit ReferenceUpdated(referenceTick, duration);
        }
    }

    function _meanTick(int256 cumulative, uint256 duration) private pure returns (int24) {
        int256 mean = cumulative / int256(duration);
        if (cumulative < 0 && cumulative % int256(duration) != 0) --mean;
        return int24(mean);
    }
}
