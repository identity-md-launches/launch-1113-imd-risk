# IMD RISK launch

This project deploys `RISK` and the immutable, directly deployed `RISKHook` for Ethereum mainnet. The token mints exactly 1,000,000,000 tokens (1e27 units, 18 decimals) to its deployer. The launch factory distributes 10% through its swarm Merkle distributor and seeds 90% into the IMD/RISK pool; remainder handling belongs to the factory. Neither contract performs distribution.

## Deployment

Build with `forge build`. Solidity 0.8.26, Cancun, optimizer 200 runs and metadata hash disabled are pinned in `foundry.toml`. All Solidity dependencies are ordinary vendored files, with provenance in `DEPENDENCIES.md`; no installation or network is required for the default build or tests once the pinned compiler is available.

`launch.json` names the bare contracts and resolves the hook's two constructor arguments:

- `$poolManager`: Ethereum mainnet Uniswap v4 PoolManager, `0x000000000004444c5dc75cB358380D2e3dE08A90`.
- `$token`: the RISK address deployed by the factory immediately before the hook.

The paired currency is fixed as IMD, `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`. The sorted pool key uses static fee **12500 (1.25%)**, tick spacing **60**, and the hook itself. The manifest's initial sqrt price `79228162514264337593543950336` is provenance; the factory chooses the opening price from launch economics. The hook accepts any valid opening price for this pool.

Mine a CREATE2 salt using the *actual CREATE2 deployer*, the final constructor arguments, and the compiled creation code. `script/MineRISKHook.s.sol` exposes a pure `mine(deployer, manager, token, start, attempts)` helper and `creationCode(manager, token)`. It never broadcasts. A successful search returns `found=true`, the salt, and predicted address. A failed search is only a search result, never a deployment parameter; continue with another range. The low 14 address bits must equal **0x20c4**:

| Callback | Flag |
| --- | --- |
| beforeInitialize | 0x2000 |
| beforeSwap | 0x0080 |
| afterSwap | 0x0040 |
| afterSwapReturnDelta | 0x0004 |

Deploy RISKHook's own initcode directly with CREATE2. The constructor validates these permissions and checks that both constructor arguments have code. There is no wrapper, owner, setter, proxy, pause, or upgrade path. Factory deployment and pool initialization should be atomic. The initialization permission prevents PoolManager from initializing the predicted address before code exists; the callback then verifies the exact launch key and returns its selector. No caller-specific initialization gate is required.

## Fees and burn accounting

Every ordinary swap pays the static LP fee plus **1% of the absolute actual BalanceDelta in the unspecified currency**, rounded down to the smallest token unit. Nothing is reserved before the swap and the LP fee is never overridden. Exact-input trades tax the output, while exact-output trades add the hook fee to the actual input. Thus exact-output buys generally accrue IMD, and exact-output sells generally accrue RISK. Price-limited partial fills pay only for the fill; output quantities and input estimates should account for this hook fee.

Fees are minted as PoolManager ERC-6909 claims owned by the hook. `pending()` reports IMD claims and `pendingBurn()` reports RISK claims. No token transfer or buyback occurs in a swap callback, so collection works on a freshly token-funded manager with zero ETH and does not depend on the manager's immediate balance of the fee currency. The known IMD and standard RISK are the only supported currencies; arbitrary fee-on-transfer or rebasing pairs are not supported.

Anyone can call `sweep()` to redeem all RISK fee claims directly to `0x000000000000000000000000000000000000dEaD`. This is a sink transfer: the ERC-20 total supply stays fixed. Empty sweeps succeed. Unrelated direct donations of ERC-20 tokens to the hook are not fee claims and are outside its accounting; senders should not transfer tokens directly to the hook.

Anyone can call `executeBatch()` at least **3600 seconds** after initialization or the preceding successful batch. The budget is **floor(pending()/4)**, capped at int128.max to fit v4's delta representation. It unlocks PoolManager and buys RISK with exact-input IMD through the launch pool. Self swaps pay the pool's LP fee and no hook fee. Only actually spent IMD claims are burned to settle input; unspent claims remain pending. Bought RISK goes directly to the dead address. There is no minimum-output check.

## Time-weighted price and limit

The hook accumulates the previous pool tick multiplied by elapsed seconds. Observation periods start at initialization or the last completed period and complete on the first observation at least one hour later. The reference is the floored time-weighted average tick over that completed period, converted to sqrtPriceX96: a geometric TWAP of the sorted currency1/currency0 price. Quiet periods may be longer than an hour. Until the first completed period, the opening tick is the reference; buybacks also wait the first hour. `referencePrice()` includes elapsed time for a mature period even before a keeper touches it.

Swaps checkpoint elapsed time before recording the new tick, so a same-block price move receives zero time weight. Batch execution checkpoints the reference before trading and records the resulting tick afterwards because v4 suppresses a hook's own callbacks. Reference changes emit `ReferenceUpdated`.

The buyback price limit uses the tighter of the time-weighted reference and the spot sqrt price read immediately before the batch swap: `max(reference, spot)` for zeroForOne, or `min(reference, spot)` for oneForZero. Multiply that anchor by sqrt(0.97) or sqrt(1.03), respectively. This preserves the 300 bps reference-price bound while preventing an old reference from allowing a larger adverse move from pre-batch spot. Fixed-point factors and final division round conservatively, and limits clamp inside v4's valid price bounds. The bound applies to the sorted pair's price ratio: when IMD is currency0, a 3% decrease in RISK/IMD permits an approximately 3.0928% increase in IMD/RISK; when IMD is currency1, the IMD/RISK increase is 3%. It is the sole slippage guard and does not bake in an assumed LP-fee subtraction. Partial fills succeed and retain unspent claims for future batches.

If the current price is already at or beyond the reference bound, the batch succeeds with zero spend and retains all claims. Its cooldown still advances, as does an empty batch's cooldown, preserving the at-most-once-per-hour rule for successful batch calls. A caller can pay to push spot beyond the reference band, trigger a zero-fill batch, and unwind, delaying execution another hour. This documented delay risk is retained; a later batch can progress as the time-weighted reference and liquidity allow.

A pool-derived TWAP cannot guarantee fair external prices in a thin or inactive market. Same-block manipulation receives no weight, but a price held over time influences the reference. Keepers should monitor pool depth, the reference, pending balances, and batch events. No contract can guarantee liquidity or that anyone pays gas to maintain it.

## Checks and operational responsibilities

Run:

```sh
forge build
forge test
forge fmt --check
```

Default tests use the actual vendored PoolManager implementation and a standard local token at the fixed IMD address. They cover both currency orderings, all four swap modes, explicit exact-input/output partial fills, 1,000 fee fuzz cases, cooldown boundaries, empty operations, successful and partial batches, zero-fill recovery, time weighting, authorization, constructor validation, direct CREATE2 mining, pre-code initialization refusal, static fee enforcement, and bytecode size/opcode restrictions. Batch-limit regressions exercise a two-day idle period followed by a price drop, 256 idle/drop fuzz cases per ordering, and the reported thin/deep-pool sandwiches at 49 front-run sizes per ordering. They check both reference and spot bounds, partial-fill recovery, retained cooldown behavior and the sorted-price convention. Stateful tests run 128 sequences of 64 actions and check physical token conservation, fee-claim conservation, sink receipts, fee-free batches, and complete PoolManager delta settlement.

The opt-in fork suite uses the real mainnet PoolManager and IMD contracts, verifies IMD's symbol and decimals, funds the test account with Foundry balance cheatcodes, and executes full and partial fills in all four modes, a sweep, and a buyback. It skips explicitly in offline/default runs, without reading or setting environment variables. The revised hook passed the fork rehearsal at block **26151445**. Reproduce with a mainnet RPC that retains state at that block:

```sh
forge test --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26151445 --match-contract RISKHookMainnetForkTest -vv
```

`SECURITY_REVIEW.md` records the local adversarial review. Before release, the launch operator must independently review the immutable contracts, verify compiled and deployed bytes and permission flags, rehearse the actual factory's distribution and liquidity position, and verify the contracts on an explorer. The included tests rehearse the hook and manager, not an unspecified factory implementation. After launch, anyone may service `sweep` and `executeBatch`; no configuration changes or privileged operator are needed. This project broadcasts no transactions and stores no keys.
