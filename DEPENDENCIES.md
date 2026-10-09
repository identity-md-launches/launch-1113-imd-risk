# Vendored dependencies

These are ordinary repository files, not submodules. Only source and license files needed by this project are included; upstream test suites, dependency directories and repository configuration are omitted. No install step is necessary.

| Directory | Upstream | Pinned revision | Included license |
| --- | --- | --- | --- |
| lib/v4-core | https://github.com/Uniswap/v4-core | 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 | BUSL-1.1 and MIT in licenses/; individual source SPDX notices |
| lib/forge-std | https://github.com/foundry-rs/forge-std | 77041d2ce690e692d6e03cc812b57d1ddaa4d505 (v1.9.7) | MIT and Apache-2.0 |
| lib/solmate | https://github.com/transmissions11/solmate | 89365b880c4f3c786bdd453d4b8e8fe410344a69 | MIT for Owned.sol; root LICENSE defers to individual source SPDX notices |
| lib/openzeppelin-contracts | https://github.com/OpenZeppelin/openzeppelin-contracts | 69c8def5f222ff96f2b5beff05dfba996368aa79 (v5.1.0) | MIT |

The v4 interfaces/libraries are imported by the hook. PoolManager and its Solmate Owned dependency are compiled for local integration tests only; they are not linked into the deployed RISKHook. OpenZeppelin's ERC20 and its transitive dependencies implement RISK. Forge standard library is used only in tests.
