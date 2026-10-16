# Hamster (HAMSTER)

The custom launch token for Hamster. Official Twitter / X: [@hamsterhourgame](https://x.com/hamsterhourgame).

| | |
|---|---|
| Solidity contract | `HamsterToken` (`src/HamsterToken.sol`) |
| `name()` / `symbol()` | `Hamster` / `HAMSTER` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 HAMSTER = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Application contracts | none |

## Behaviour

- A plain, fixed-supply ERC-20 built on OpenZeppelin Contracts v5.1.0 `ERC20`.
- The constructor mints the whole supply once to `msg.sender` (the launch factory). No function can
  mint more afterwards.
- No owner, admin, fee, tax, pause, blocklist, freeze or seize: nobody can move or freeze a holder's
  balance. Transfers move exactly the amount requested.
- `TWITTER()` returns `"@hamsterhourgame"`; `TOTAL_SUPPLY()` returns the supply constant.

## Distribution (performed by the launch, not by the token)

The token holds no distribution logic. The factory receives the whole supply and pays it out:

| Share | Amount | Destination |
|---|---|---|
| 10% swarm | 100,000,000 HAMSTER | the launch's MerkleDistributor (set by the launch, not configurable here) |
| 10% pool | 100,000,000 HAMSTER | single-sided seed of the Uniswap v4 pool (`economics.poolBps = 1000`) |
| 80% dev vault | 800,000,000 HAMSTER | `0xee2aaa315cf7ed169f93148d30d24af9318dbb66` (`economics.remainderTo`) |

Launch parameters (decided by the launch, recorded here for reference; `launch.json` is written by
the separate manifest step):

- Chain: Ethereum mainnet (chain id 1).
- Pair: IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals).
- Pool fee 12500 (1.25%), tick spacing 60.
- Opening market cap: 2,500 IMD for the whole supply (`initialMarketCapWei = 2500000000000000000000`);
  the deployer derives the opening price from it.

## Assumptions

- "Dev vault" means the requester's address `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`, which the
  launch's `economics.remainderTo` names. The token does not lock or vest these tokens; any vesting
  is the requester's own responsibility.
- "Swarm" means the IMD launch's swarm share, which the factory sends to the MerkleDistributor.
- No transfer fee or tax was requested, so none exists.

## Operational responsibilities

- Nothing to configure after launch: the contract has no settings and no owner, so there is no
  "After launch" step and no key that can change the token.
- The dev vault's holder controls 80% of the supply. Buyers should treat it as a concentrated
  holding.
- Tests passing is not an audit. The contract is a thin wrapper around audited OpenZeppelin code,
  but an independent review before release is still recommended.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Compiler pinned in `foundry.toml`: solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`.
Dependencies are vendored as plain files under `lib/` (forge-std, OpenZeppelin Contracts v5.1.0
`contracts/` only); no network is needed to build.

Tests (`test/HamsterToken.t.sol`) cover metadata, the one-time mint to the deployer, the exact
10/10/80 launch payout, transfer/approve success and failure paths (insufficient balance and
allowance, zero addresses), the absence of mint/owner/pause/blocklist/seize entry points, and fuzzed
supply conservation.
