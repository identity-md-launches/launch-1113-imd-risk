# Local security review

Reviewed against the pinned v4 security and Ethereum testing/security references, using the assignment's M1 mechanics where the background references describe different fee handling. This is a local review of the delivered code; an independent release review remains an operational responsibility.

## Accounting and authority

- Enabled callbacks and unlockCallback check the immutable PoolManager. Initialization fixes one exact sorted token/IMD pool, static fee 12500, tick spacing 60, and this hook. The constructor validates its address flags. Invalid keys, absent code, invalid flags, premature initialization and unauthorized callbacks are tested.
- beforeSwap returns zero delta and zero fee override. beforeSwapReturnDelta is disabled. The hook cannot swallow the swap as a custom curve or dynamically alter its LP fee.
- afterSwap derives the unspecified side from direction and exact-input/output mode, widens the actual int128 delta before taking its absolute value, and rounds a 1% fee down. Fee claims create an opposite hook delta; the returned afterSwap delta credits it by the same amount. Test expectations come from the manager's raw Swap event and real balance changes rather than the hook's fee event.
- For exact-input swaps, the fee reduces actual output. For exact-output swaps, it increases actual input. No fee is reserved on an unfilled specified amount, and no reconciliation/refund path is needed. Both modes are tested with actual price-limited partial fills, in both directions and both currency orderings.
- sweep burns RISK claims and takes exactly those tokens to the fixed sink. Batch swaps incur no hook callbacks in v4's self-call path, burn only spent IMD claims to cancel input debt, and take actual bought tokens to the sink. Unfilled budget is never redeemed and therefore needs no transfer refund. All successful unlocks leave zero nonzero deltas.
- No external token code runs during fee collection. The hook's batch input settlement consumes IMD claims without transferring IMD. Only the fixed, standard RISK token is transferred during sweep and output collection. This avoids fresh-manager balance dependence during callbacks, token approvals, arbitrary destinations and paired-token callback reentrancy. Public operations also use a guard, and unlockCallback requires an operation to be active.
- RISK is a fixed-supply OpenZeppelin ERC20 with no public mint, burn, administrative or upgrade interface. No owner or mutable configuration exists on either deployed contract. The runtime scan excludes PUSH immediates and verifies absence of SELFDESTRUCT, DELEGATECALL and CALLCODE. Hook initcode is well below EIP-3860 and runtime below EIP-170.

## Batch execution and oracle

The previous tick is time-weighted before each spot update. Same-timestamp swaps have zero time weight. The geometric TWAP rounds negative average ticks downward and completes only after at least 3600 seconds. The oracle has constant storage and constant-time updates, and quiet periods are integrated rather than rejected for staleness. Tests check a two-price weighted interval and same-block price manipulation, including executing a zero-fill batch beyond its reference bound and progressing in a later period.

The price-bound multiplication fits uint256 because a uint160 sqrt price times a roughly 1e18 factor needs at most 221 bits. Fixed factors and final division round towards a tighter limit, then clamp to valid v4 bounds. No spot-dependent minimum output or hardcoded LP-fee adjustment is present. Successful partial fills, unchanged pendingBurn on self swaps, budget conservation, one-hour boundaries and no-room/empty paths are tested. Cooldown is consumed by a successful zero-fill batch; failure rolls back state atomically.

Fee arithmetic widens int128 before negation, so int128.min can be represented. Fee division yields a positive value that fits int128. Requested magnitudes use a safe expression even for int256.min; nominal requests whose magnitude plus 1% exceeds int256.max revert with UnrepresentableFee. The batch caps its input budget to int128.max. Price tick averages stay within the observed TickMath domain. Timestamp arithmetic relies on Ethereum timestamps being representable as signed int256, far beyond the operational lifetime of the chain.

The oracle reflects this pool rather than an external market. Sustained price manipulation and absent liquidity remain economic risks, and public batch timing can attract MEV within the immutable price guard. Arbitrary direct ERC20 donations are not collected fees and cannot be recovered. The contracts provide neither rescue powers nor upgrade paths.

## Validation evidence

- Real local PoolManager tests: full fills and partial fills for exact-input/output buys/sells, both currency orderings, a manager with zero native balance, burn sweep, complete and partial batch execution, cooldown failures, TWAP behavior, unauthorized callbacks, constructor/initialization failures, and deployment mining.
- Fee fuzzing: 1,000 cases in the primary ordering, plus the inherited reverse-ordering fuzz test.
- Stateful invariant: 128 runs, 64 actions each, 8,192 calls, zero reverts. Physical token supply, paired-token conservation, pending plus spent/burned claim accounting, sink proceeds, no hook fee on batches, and manager settlement are checked after randomized operations.
- Mainnet fork at block 26151185: real IMD metadata and transfers, deployed PoolManager, all four full and partial swap modes, sweep and batch passed. Default offline execution reports an explicit skip for this suite.
- Solidity 0.8.26 build and Foundry tests run locally; formatting checked with forge fmt --check.

No Slither, Mythril, formal verification or independent external audit was performed. Factory-specific distribution, its liquidity range and actual deployment simulation must be reviewed by the launch operator with the factory implementation. No onchain deployment was made.
