# RISK test coverage

Run the complete offline suite with `forge build` and `forge test`. All imports are
already vendored in the repository. No environment variables are changed by tests.
The fork contracts explicitly skip when not running on a mainnet fork.

The existing tests cover deployment permissions, fixed token supply, all four swap
modes, partial fills, claim redemption, batch budgeting, and both currency orders.
The additional suites cover:

- `RISKHookAdversarial.t.sol`: large representable requests with small actual fills,
  exact overflow errors through PoolManager, dust fee rounding, zero-liquidity
  swaps and recovery, zero-reserve first buys, deferred maintenance, nested unlock
  refusal, failed-transfer rollback and retry, protocol fees during partial
  buybacks, and irregular time-weighted observations. Transfer failures are
  injected solely to check atomic rollback; the deployed RISK token is unchanged.
- `RISKLifecycleInvariant.t.sol`: a separate handler randomizes liquidity removal
  and replacement, all swap modes with tight limits, time advances, sweeps, and
  batch attempts by different callers. Expected cooldown and empty-position
  rejections are checked explicitly; unexpected reverts fail the invariant.
  Ghost accounting derives swap fees and buyback inputs/outputs from PoolManager
  events. It checks conservation, claim backing, budget limits, burn destination,
  fixed supply, and complete settlement over 256 sequences of 64 actions.

New fuzz properties use 1,000 runs in inline configuration. Offline tests use the
vendored, real Uniswap v4 PoolManager and an ordinary ERC20 at the fixed IMD
address. The mainnet fork uses the deployed PoolManager and IMD contracts, with
test balances supplied by Foundry and a newly CREATE2-mined RISKHook.

Reproduce the mainnet checks at block **26,151,212** with a mainnet archive RPC:

```sh
forge test --match-contract 'RISKHook.*MainnetForkTest' \
  --fork-url "$MAINNET_RPC_URL" --fork-block-number 26151212
```

This command runs the original integration test and the added adversarial fork
suite. The offline suite remains self-contained when the verifier has no network.
