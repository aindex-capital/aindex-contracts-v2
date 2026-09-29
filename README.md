# aindex-contracts-v2

Smart contracts for AINDEX indexes on Robinhood Chain (chain id 4663).

**These contracts have not been audited.** They are deployed on mainnet and hold user funds. The
contracts are immutable: a flaw cannot be patched in place. Read [Risks](#risks),
[SECURITY.md](SECURITY.md) and [audits/README.md](audits/README.md) before relying on them.

## What an index is

An AINDEX index is an ERC-20 share backed by a basket of ERC-20 tokens that the index contract
itself holds on chain. Anyone can mint shares by depositing the basket in proportion, and anyone
can redeem shares for their proportional part of the basket. Minting and redeeming happen at
backing: no price or oracle is involved in either.

Each index is a clone of Reserve's Folio (from
[reserve-protocol/reserve-index-dtf](https://github.com/reserve-protocol/reserve-index-dtf)). Folio
is used unmodified. It is not copied into this repository: `script/bootstrap.mjs` clones it at the
commit pinned in `dependencies.json` and checks the hash of its lockfile, and the test runner
refuses to run against any other revision or a modified checkout. Uniswap v4-core is pinned the same
way.

Each index also has:

- a `MonthlyMandate`, the only admin of the index, which controls how and when the basket is
  rebalanced;
- a Uniswap v4 pool against USDG, created and seeded in the launch transaction, whose swaps go
  through `ShareFeeHook`.

## Contracts

| Contract | Role |
| --- | --- |
| `IndexFactory` | Creates an index, its mandate and its market. `createManagedWithMarket` is the production entry point. The plain `create` inherited from `IndexFactoryBase` always reverts here. |
| `IndexFactoryBase` | Clones the Folio implementation, pulls the seed basket (rejecting tokens that do not arrive in full, such as fee-on-transfer tokens) and initializes the fee settings. |
| `MandateDeployer` | Holds `MonthlyMandate`'s creation code so `IndexFactory` stays under the contract size limit. Permissionless; a mandate it deploys has no power unless an index grants it roles, which only the factory's launch path does. |
| `MonthlyMandate` | Rebalance authority for one index (version 3, see below). |
| `IndexMarketRegistry` | Records one canonical pool per index. Only allowed quote tokens (USDG on mainnet), pool fee 0.15%, tick spacing 60, and the fee hook, all fixed at deployment. |
| `ShareMarketRouter` | ERC-20 router for swaps and liquidity on those pools. It only trades through no hook or the one fee hook it was deployed with. Liquidity positions belong to `msg.sender`; the factory may add liquidity on a creator's behalf at launch, never remove it. |
| `ShareFeeHook` | Uniswap v4 `afterSwap` hook that charges the share's trade fee and splits it. |
| `FixedFeeRegistry` | Implements Folio's fee registry interface with a fixed protocol portion and recipient. Holds no funds. |
| `IndexZap` | Buys an index with ETH or an ERC-20 by buying the basket through Uniswap's Universal Router and minting, or sells by redeeming and selling the basket, in one transaction. Only indexes created by the factory. Holds nothing between transactions. |
| `AuctionFiller` | Fills a rebalance auction without inventory: bids with a callback, swaps through the Universal Router, and pays any USDG margin to the caller, reverting below `minUsdgOut`. Only indexes created by the factory. |
| `AixDistributor` | Cumulative Merkle distributor that pays AIX token holders in one ERC-20 (shares of an AINDEX index). One immutable poster sets roots; a root can never allocate more than has been paid out plus the current balance. No owner. |
| `LiquidityLocker` | Holds an index's official pool liquidity as a band around backing plus a full-range backstop, with capped recenters and an optional time lock. It has an owner. **Built and tested, not deployed on mainnet.** |
| `CompilePoolManager` | Compile-only file so the pinned v4 `PoolManager` is built with its own compiler version for tests. Not deployed. |

### MonthlyMandate (v3)

A rebalance is a sequence of public steps. The limits below are enforced in the contract.

1. **Launch limits.** Each token has a rule: a minimum and maximum amount one share may hold (raw
   token units per share, not a percentage of value) and a cap on how much one auction may trade.
   The configuration is fixed at launch: 2 to 16 tokens, a notice of at least 1 hour, an interval
   of at least 28 days, an auction length of 120 seconds to 1 hour, and a price spread of at most
   5% (`maxPriceSpreadBps` up to 500).
2. **Queue.** The proposer queues target weights and one reference price per token. The proposal
   is committed as a hash; the full contents are emitted in `ProposalQueued`. Only one proposal can
   be pending.
3. **Notice.** Nothing can happen until the index's notice has passed. If one wallet is both
   proposer and reviewer, the notice must be at least 24 hours (`SELF_REVIEW_NOTICE`). Redemption
   is always available, so holders can exit during the notice.
4. **Approval with fresh prices.** After the notice, the reviewer approves with one fresh price
   per token. Each fresh price must be within `MAX_REPRICE_BPS` (1500, 15%) of its queued
   reference, and the moves of all tokens relative to their references must lie within
   `MAX_RELATIVE_BPS` (500, 5%) of each other. The approval lasts at most 5 minutes.
5. **Bands built by the mandate.** The reviewer does not supply auction price ranges. The mandate
   builds each token's band from its fresh price: a token the index sells gets a band starting
   just under the fresh price and rising; a token it buys, a band starting just over it and falling.
   The offset past the fresh price is `EDGE_BPS` (100, 1%) per side, or a third of the spread if
   that is smaller. Each auction pair therefore starts in the index's favour and ends at most about
   2% past the fresh prices.
6. **Execute.** Anyone may execute an approved proposal. The mandate starts a Folio rebalance,
   opens exactly one Dutch auction, and ends the rebalance in the same call, so no second auction
   can be opened for it. The next execution is not allowed until `interval` (at least 28 days)
   later. Cancelling does not reset that wait.
7. **Cancel.** The reviewer or guardian can cancel a pending proposal or close a running auction.
   An expired proposal can be cleared by anyone.

**Token universe.** The proposer announces a new token with its rule (`announceToken`, minimum
weight must be zero). It can be added with `addToken` only after `MIN_ADDITION_NOTICE` (7 days) or
the index's notice, whichever is longer, and only when no proposal or auction is active. Any role
holder can cancel an announcement. A token is removed by rebalancing it to zero; once Folio no
longer holds it, `retireToken` frees its slot. At most 16 tokens, never fewer than 2.

**Roles.** There are three: proposer, reviewer and guardian. One wallet may hold all three. A role
can be replaced only by the other two holders together: one requests, the other confirms, and the
replacement can accept after `max(notice, 7 days)`. Accepting cancels any pending proposal and
running auction and invalidates proposals made under the old roles. The holder being replaced
cannot veto.

The mandate exposes no arbitrary calls, role grants on the index, withdrawals, fee changes or
upgrades.

### Fees

**Trade fee: 0.40% per swap on the index pool.**

| Part | bps | Paid to |
| --- | ---: | --- |
| Pool fee | 15 | Liquidity providers, by Uniswap |
| Hook fee, creator | 8 | Index creator, via `claim` |
| Hook fee, protocol | 9 | Protocol fee recipient, via `claim` |
| Hook fee, holders | 8 | Index backing, via `payHolders` |

The hook fee (25 bps, split 32/36/32) is taken from the unspecified side of the swap (the output
on exact input, the input on exact output). `claim` and `payHolders` are permissionless and pay
fixed destinations. `payHolders` adds the holders' part to the index's backing: a basket token is
sent to the index, a share is redeemed and its basket sent back, and a quote token outside the
basket is used to buy shares in the pool that are then handled the same way (the caller sets
`minSharesOut`).

**Mint fee: 0.50%, no redeem fee, no yearly fee.**

| Part | bps | Paid to |
| --- | ---: | --- |
| Protocol | 20 | Protocol fee recipient |
| Holders | 15 | Folio's `folioFeeForSelf`: handed back to backing over time |
| Creator | 15 | Index creator |

The yearly (TVL) fee is set to zero and the registry's fee floor is zero, so holding an index costs
nothing. Fee rates, splits and recipients are constants or immutables.

## Admin model

- **Each index's only admin is its mandate.** At launch the factory grants the index's admin,
  rebalance manager and auction launcher roles to the mandate and renounces its own admin role.
  `MonthlyMandate.activate` then checks that the mandate is the sole holder of each of those roles,
  that trusted fillers are off, that bids are on, that the auction length matches, and that the
  basket matches the token rules. The launch reverts otherwise. The same role check runs before
  every execution and role change.
- **No owner on the factory, registry, router, hook or fee registry.** The factory's deployer
  could call `wireMarket` once to connect the registry and router; on mainnet this has been done
  and cannot be repeated.
- **What an index's creator can change:** the index's metadata URI (`IndexFactory.setMetadata`).
  Mandate roles are separate and change only through role recovery.
- **What cannot change after launch:** the fee rates and splits, the protocol fee recipient, the
  pool fee, tick spacing, hook and allowed quote tokens, the mandate's notice, interval, auction
  length, spread and methodology hash, and the rules of tokens already in the universe. Index
  clones are not upgradeable.
- `AixDistributor` has one immutable poster that can set roots and nothing else.
- `LiquidityLocker` (not deployed) has an owner and an optional operator, bounded as described in
  its header.

## Risks

- **Not audited.** No external party has reviewed this code. See `audits/README.md`.
- **The reviewer is trusted within bounds.** Within the 15% and 5% limits above, a reviewer who
  approves wrong prices can move value between the index and auction bidders. The notice, the
  5-minute approval window, one auction per interval and the per-token trade cap limit how much,
  and the guardian or reviewer can cancel. Where one wallet holds every role, holders rely on the
  24-hour notice and on redeeming.
- **Any token contract can be put in a basket.** The factory checks only that a token has code and
  that the seed arrives in full. Folio's `redeem` transfers every basket token in one call, so a
  single token that reverts on transfer (paused, blacklisting the index, or broken) blocks
  redemption of the whole index. Tokens whose issuer can pause or freeze transfers carry this risk
  by design. Check each basket token before holding an index.
- **Pool price is not backing.** The share's market price can differ from its backing. Mint and
  redeem at backing are always available (subject to the token risk above).
- **Holder fee buyback.** A `payHolders` call that buys shares with a quote token uses the caller's
  `minSharesOut`; a caller could pass zero and sandwich it. The exposure is bounded by the accrued
  holder fee.
- **Router calldata.** `IndexZap` and `AuctionFiller` run Universal Router calldata planned off
  chain. They only act on their own balances within one transaction, and callers set minimum
  outputs.
- **Dependencies.** Folio and Uniswap v4 are external code. Folio's own audits are in its
  repository.

## Deployment: Robinhood Chain mainnet (v3)

Chain id 4663. Deployed at block 74953548. Record: [`deployments/4663-v3.json`](deployments/4663-v3.json);
transactions: `broadcast/Deploy.s.sol/4663/`; deploy script: `script/deploy-v3.sh`.

| Contract | Address |
| --- | --- |
| IndexFactory | [`0x1A74fE285816f5cf8CBAe9C98C9B303A1459eEcf`](https://robinhoodchain.blockscout.com/address/0x1A74fE285816f5cf8CBAe9C98C9B303A1459eEcf) |
| MandateDeployer (created by the factory) | [`0x283b524A38f8d9d4c866C14a78BeD30aB7587534`](https://robinhoodchain.blockscout.com/address/0x283b524A38f8d9d4c866C14a78BeD30aB7587534) |
| IndexMarketRegistry | [`0x2F8015CA784f7eEEb0AbcF854c92A363D58E9f7e`](https://robinhoodchain.blockscout.com/address/0x2F8015CA784f7eEEb0AbcF854c92A363D58E9f7e) |
| ShareMarketRouter | [`0xCf09BE3c10e4D8D4853589FC4Bc77F822CAD998a`](https://robinhoodchain.blockscout.com/address/0xCf09BE3c10e4D8D4853589FC4Bc77F822CAD998a) |
| ShareFeeHook | [`0x640247c04170a8465eCBF76A17293632Ec6B0044`](https://robinhoodchain.blockscout.com/address/0x640247c04170a8465eCBF76A17293632Ec6B0044) |
| FixedFeeRegistry | [`0x705fE898c4637aE4f5d1c7C27A97d5999879bb3c`](https://robinhoodchain.blockscout.com/address/0x705fE898c4637aE4f5d1c7C27A97d5999879bb3c) |
| Folio implementation | [`0xa49Ef4F63c4De525e63F0790AC6FB1a2BEC77a0c`](https://robinhoodchain.blockscout.com/address/0xa49Ef4F63c4De525e63F0790AC6FB1a2BEC77a0c) |
| IndexZap | [`0x5F807BB130739F8d9A96d7d4383A1318E0669bFF`](https://robinhoodchain.blockscout.com/address/0x5F807BB130739F8d9A96d7d4383A1318E0669bFF) |
| AuctionFiller | [`0x9baA0f86868212Dd4eDdd3454Ee6e042f932CD00`](https://robinhoodchain.blockscout.com/address/0x9baA0f86868212Dd4eDdd3454Ee6e042f932CD00) |
| AixDistributor | [`0xbfCf27E1eAB345c34950b3227F9693513acE20F2`](https://robinhoodchain.blockscout.com/address/0xbfCf27E1eAB345c34950b3227F9693513acE20F2) |

Related addresses:

| | Address |
| --- | --- |
| Uniswap v4 PoolManager | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |
| USDG (the only allowed quote token) | [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) |
| Protocol fee recipient | [`0x230C4Df28A0065216F2BEf86122125c0F8e4A5af`](https://robinhoodchain.blockscout.com/address/0x230C4Df28A0065216F2BEf86122125c0F8e4A5af) |
| Deployer | [`0x916817f2c44c44f0255249140300E78AfD6c492C`](https://robinhoodchain.blockscout.com/address/0x916817f2c44c44f0255249140300E78AfD6c492C) |

`LiquidityLocker` is not deployed.

**v2 is retired.** An earlier deployment is recorded in `deployments/4663.json` (block 71125167).
Its indexes were redeemed and relaunched on v3. Do not use the v2 addresses.

## Build and test

Requirements: [Foundry](https://book.getfoundry.sh/), git, Node 22.13 or newer, and pnpm 11.8.0
(the version Reserve's repository pins).

```sh
node script/bootstrap.mjs   # clone Folio and v4-core into lib/ at the pinned commits, install Folio's pinned packages
node script/test.mjs        # check the pins, build PoolManager, run forge test
```

`script/test.mjs` passes any extra arguments to `forge test`, for example
`node script/test.mjs --match-contract MonthlyMandateTest -vv`. It runs with `FOUNDRY_OFFLINE=true`,
so solc 0.8.26 (PoolManager) and 0.8.28 (everything else) must already be installed; run
`forge build` once online if they are not. Compiler settings are in `foundry.toml` (optimizer 200
runs, `evm_version` cancun, `bytecode_hash` none).

### Fork tests

The tests in `test/fork/` skip unless `AINDEX_FORK_RPC` is set. They fork Robinhood Chain mainnet
and run against the deployed Uniswap v4 PoolManager and real tokens; `LiquidityLockerFork` also
reads the deployed v3 registry and an existing index pool. No transaction is broadcast.

```sh
AINDEX_FORK_RPC=https://rpc.ordofi.network node script/test.mjs --match-path 'test/fork/*' -vv
```

Set `AINDEX_FORK_BLOCK` to pin a block (the RPC must then serve archive state). The
`LiquidityLockerFork` test also needs `AINDEX_AR10_NAV_USD18`, the AR10 index's backing per share
in USD with 18 decimals; see the comment at the top of that file.

## Reproduce the source verification

`verify/v3/` holds the Standard JSON compiler input for each v3 contract, and `manifest.json`
records addresses, creation transactions and constructor arguments. `prove.py` compiles each input
and compares it with the chain:

```sh
python3 verify/v3/prove.py
```

It needs Python 3, Foundry's `cast`, solc 0.8.28 at `~/.svm/0.8.28/solc-0.8.28` (where Foundry
installs it), and an RPC that supports `debug_traceTransaction` (the script uses
`https://rpc.ordofi.network`). For each contract it checks that the runtime code matches the
on-chain code with immutables masked, that the metadata is identical, and that the compiled
creation code is a prefix of the creation transaction's input (the rest is the constructor
arguments).

## Repository layout

```
src/            contracts
test/           unit tests; test/fork/ for mainnet fork tests
script/         Deploy.s.sol, deploy-v3.sh, bootstrap.mjs, test.mjs, mine-hook-salt.py
deployments/    deployed addresses per chain
broadcast/      Foundry broadcast logs of the mainnet deployments
verify/v3/      verification inputs and prove.py
audits/         audit reports (none yet)
```

## License

MIT. See [LICENSE](LICENSE). Folio and Uniswap v4-core are fetched from their own repositories
under their own licenses.
