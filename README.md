# aindex-contracts-v2

An index is a fully funded, non-rebasing ERC-20 share over a basket, trading on an ordinary
Uniswap v4 pool from the moment it launches, and rebalanced at most once a month through an auction,
within per-token limits. Tokens are removed by rebalancing them to zero and added by announcement:
`announceToken` on the mandate, then `addToken` after at least seven days (or the index's notice,
if longer); any role holder can cancel. At most 16 tokens; `retireToken` frees the place of one no
longer held.

Who runs it is the creator's choice. One wallet may hold every role (propose, approve prices,
cancel), so a creator can run an index alone; a self-reviewed rebalance must then be announced at
least 24 hours ahead, and redemption is free, so holders can leave before it executes. Or the
creator names an independent reviewer and guardian, and the notice can be as short as an hour. An
index nobody rebalances simply keeps its basket.

**Separate from `aindex-contracts`, which holds the live v1 marketplace.** They are two products
on two sets of addresses with two sets of compiler settings, and merging them into one project
would mean recompiling deployed contracts under different optimizer settings than they were
shipped with. Uniswap does the same thing: v2-core, v3-core and v4-core are separate repositories.

**Not audited, never deployed.** See `SECURITY.md` and `audits/README.md`.

## Layout

```
src/            the contracts
test/           unit and integration, offline
test/fork/      needs an RPC; `script/test.mjs` skips these
script/         bootstrap and the test runner
deployments/    what is live, per chain. Empty.
audits/         what has been reviewed. Empty, and says so.
lib/            pinned dependencies, fetched by bootstrap, gitignored
remappings.txt  import paths, as a file rather than inline in foundry.toml
```

`src/` is flat because there are seven contracts. It gains `interfaces/` and `libraries/`
subdirectories when it needs them and not before.

## Implemented

- Fully funded, nonrebasing ERC-20 shares using pinned Reserve Folio. Mint/redeem use the current proportional basket; secondary transfers do not touch backing.
- Atomic factory launch with any token contract as an asset (admission is open) and a fixed monthly mandate whose roles one wallet may hold alone, or share with an independent reviewer and guardian. The creator never holds a role on the index contract itself.
- Delayed single-role recovery: both other current role holders authorize a replacement, which accepts after at least seven days. New launches require three distinct role addresses. Acceptance invalidates old proposals and closes active auctions without resetting monthly capacity.
- One bounded auction per monthly cycle, announced in advance and approved shortly before execution. Permissionless bidders settle through Folio. Partial fills change actual holdings; expiry does not pretend target allocations were reached.
- Ordinary Uniswap v4 SHARE/quote markets carrying one fee hook, `ShareFeeHook`, which takes its fee in `afterSwap` after the pool's own arithmetic has run. Swap events report real amounts, pools hold real reserves, LP positions are account-owned, and payments, quotes, minimum outputs and withdrawals are bounded. No dealer inventory or NAV oracle on the swap path.
- A launch opens its market. `createManagedWithMarket` creates the index, registers and initializes its pool, and opens the creator's full-range position in one transaction. The price is given as quote per share whichever way the new share sorts, and the position can only ever be withdrawn by the creator. `createManaged` remains for tests and leaves an index with no market.
- Creator-owned metadata URI registry; metadata cannot alter portfolio permissions.
- Explicit creator adoption of an existing canonical pool, bound to its exact reviewed price and a maximum five-minute deadline. The launch UI compares that price against the intended quote-per-share price before offering confirmation.
- Generated ABIs, coherent block/hash reads, versioned `/v2` API, historical tables, reorg rewind and per-index failure isolation.
- Launch, buy/sell, supply/withdraw, basket mint/redeem and committed-proposal review/execute screens. Managed products also resolve on `/i/:address` and appear under `/indexes` when configured.

## Reproduce

Run the npm commands below from the sibling `aindex/` application repository. Contract sources, tests, pinned dependencies and Foundry artifacts live here; application ABI export and local integration scripts live in `aindex/deploy/`. To run only Solidity checks from this directory, use `node script/test.mjs`.

Foundry, Node **22.13 or newer** and pnpm **11.8.0** are required for dependency bootstrap. Install the existing JavaScript workspace dependencies too.

```sh
npm run contracts:bootstrap
npm run test:contracts
npm test
```

Bootstrap downloads clean pinned sources to ignored `vendor/`. Tests check the source pins and Reserve lockfile hash, compile the real PoolManager separately with Solidity 0.8.26, and compile Folio/AINDEX with 0.8.28. The runner also verifies generated ABIs. After intentional ABI changes, run `node deploy/export-managed-abis.mjs` and review the diff.

Start a local chain in one terminal:

```sh
anvil --host 127.0.0.1 --port 8547 --chain-id 31337
```

Deploy and check the local flow:

```sh
AINDEX_DEMO_RPC=http://127.0.0.1:8547 npm run demo:managed
npm run test:managed:integration
```

The deployment uses unlocked Anvil accounts and locally minted test assets. It refuses non-loopback endpoints and non-31337 chains and never reads private keys. Public addresses/runtime hashes go to `.local/managed-deployment.json`; participant addresses go to `.local/managed-demo.json`.

Set `AINDEX_DEMO_DIR` on both deployment and integration commands to use a separate output directory for an isolated test chain. New manifests declare `mandateVersion: 2`; omitted/1 retains the original fixed-role read path. Existing immutable factories and mandates are not upgraded. A new factory/runtime manifest is required to launch recovery-enabled indexes.

The integration check snapshots Anvil, mines a fresh block, exercises discovery → buy → sell → proposal → independent approval → auction fill → proportional redemption → indexed history, then verifies delayed role recovery, proposal invalidation, preserved monthly capacity and API/indexer authority state for version 2. It reverts its changes afterward. Do not interact with that development chain while the check owns its snapshot.

Run these services in separate terminals:

```sh
AINDEX_MANAGED_DEPLOYMENT=.local/managed-deployment.json AINDEX_DB=.local/managed.sqlite npm run indexer:managed
```

```sh
AINDEX_MANAGED_DEPLOYMENT=.local/managed-deployment.json AINDEX_DB=.local/managed.sqlite AINDEX_API_PORT=8082 npm run api
```

```sh
NEXT_PUBLIC_AINDEX_API=http://localhost:8082 AINDEX_API_INTERNAL=http://localhost:8082 npm run web
```

Open `/create`, `/indexes` or `/i/<demo address>`, or run `npm run dev:managed` from `aindex/` to start the whole stack in one command. Connect a development wallet and use the page's network switch. An idle Anvil does not produce blocks; mine one before requesting a quote after a long idle period.

`AINDEX_MANAGED_RPC` overrides only the server RPC. The manifest's `publicRpc` must be public and contain no API secrets. Readers and transaction helpers verify chain ID and configured runtime hashes. Without a managed manifest, `/v2` is unavailable and legacy indexes retain their old interpretation.

## Deploy

`script/Deploy.s.sol` deploys to Robinhood Chain. It signs through a Foundry keystore and never reads a key. Simulate without `--broadcast` first; the simulation runs against live state and reads every contract back before it reports success.

```sh
AINDEX_PROTOCOL_RECIPIENT=0x...                              # immutable; receives protocol fees
AINDEX_QUOTES=0x5fc5360d0400a0fd4f2af552add042d716f1d168     # comma-separated admitted quote tokens
forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account <keystore> --sender <address> [--broadcast]
```

Send nothing else from the deploying account while it runs: the registry's address is predicted from the nonce and the hook is bound to it. Afterwards the deploying account holds no role on any contract. The addresses are written to `deployments/4663.json`; from `aindex/`, `node deploy/managed-manifest.mjs` turns that into the application manifest, reading every figure from the chain and running the application's own identity check on it.

## Authority map

| Component | Authority / funds |
| --- | --- |
| Folio clone | Holds one index's backing and processes proportional claims/auctions; no upgrade path added here |
| IndexFactory | Seeds clones and hands each index to its mandate; open admission, no asset list and no owner |
| MonthlyMandate | Sole Folio admin/manager/auction launcher; no arbitrary calls, fee setters, withdrawals or engine role grants |
| Proposer | Queues within fixed asset/quantity constraints |
| Reviewer | Approves the committed payload for at most five minutes; trusted to assess prices |
| Guardian/reviewer | Cancels proposals/auctions without restoring consumed monthly capacity |
| Two other role holders | Jointly authorize delayed replacement of the third role; cannot change portfolio rules or gain engine administration |
| IndexMarketRegistry | Creator-selected admitted quote, registered by the creator or by the factory during that creator's launch; registration alone provides no liquidity |
| ShareFeeHook | Takes 15 bps of each swap's output, split 40 creator / 40 protocol / 20 holders; no owner; registrar and protocol recipient immutable |
| ShareMarketRouter | Settles directly with PoolManager; LP ownership is namespaced by wallet and salt; only the factory may open a position on someone else's behalf, and only to add |
| FixedFeeRegistry | Immutable fee parameters/recipient; no portfolio withdrawal authority |

`PrototypeIndexFactory` is an evaluation base. Its standalone `create` grants creator administration. **Do not deploy it as the managed product.** `IndexFactory` disables that entry point.

### Role recovery operations

Role ids are proposer `0`, reviewer `1`, guardian `2`. One of the two other holders requests a replacement. The second confirms that request's nonce within seven days. Confirmation starts a delay of `max(7 days, mandate notice)`; the replacement wallet then has seven days to accept. Either authorizing holder can cancel or supersede a request, restarting authorization/notice. The target holder cannot veto its own replacement. Requests cannot merge role addresses; distinct addresses still need operationally independent control.

Acceptance advances the authority version, invalidates every other outstanding role request, clears the pending allocation proposal and price approval, and closes any active auction. Proposal hashes bind the authority version. It preserves the monthly cooldown, asset universe, quantity limits, fees and sole engine authority of the mandate contract. Management controls and coherent snapshots expose the request, notice, expiry and current authority version. Full event history is not yet exposed.

This recovers one unavailable key, not two. Two cooperating holders can replace the third. A compromised target may continue exercising its existing powers during notice; the surviving reviewer/guardian must use cancellation when appropriate. Key rotation does not rotate the creator's metadata authority or fee entitlement. The delay/quorum policy is a candidate requiring independent release review.

## Boundaries and release gates

- Weight bounds are raw token quantities per basket unit, not percentage-of-NAV loss limits. Trade caps are token amounts, not dollars. Manual planning prices require independent review. Approval freshness is not oracle freshness; colluding or mistaken authorized parties can cause losses within the limits.
- The universe, limits and fees are fixed. Operational role addresses support the delayed recovery process above in mandate version 2. There is no arbitrary asset rescue, automatic allocation selection or unattended price approval. Guardian cancellation does not disable secondary trading or ordinary redemption.
- An index holds 1 to 16 assets, and **any token contract can be one**. Launch refuses an address with no code and a token that does not arrive in full, which catches transfer taxes. It cannot catch a token that later pauses, blacklists the index or starts reverting, and because `redeem` transfers every asset in one loop, one such token blocks redemption of the whole basket. Which tokens are known to be sound is shown by the application as verification; it is not enforced here.
- LPs supply both sides and bear inventory risk. A trade costs **0.30%**: 15 bps to liquidity
  providers through the pool's own fee, and 15 bps to `ShareFeeHook`, split 40 creator / 40
  protocol / 20 holders. The hook's 15 bps is charged on the unspecified side: the output of an
  exact-input swap, which the trader receives less of, or the input of an exact-output swap, which
  the trader pays more of. The holders' share is paid as **rising backing**, not a claim: Folio is
  23 bytes under the EIP-170 limit and cannot be subclassed, so a per-holder accumulator is
  impossible. `payHolders` redeems share-denominated fees into the basket, sends basket-asset fees
  straight in, and buys a quote token that is not in the basket back into shares first, with a
  caller-supplied `minSharesOut`. It is permissionless; the application offers it on each index
  and `aindex/deploy/pay-holders.ts` runs it as a keeper. A mint costs **1.35%**, split 100 bps to
  the creator and 35 to the protocol. There is no redeem fee: Folio has none, and `redeem` is
  directly callable so a wrapper would be bypassable.
- The factory's **1% annual management fee** is split between the creator and the protocol in the
  same proportion as the mint fee: `FixedFeeRegistry` gives the protocol 35/135 of both, so about
  **0.74% a year to the creator and 0.26% to the protocol**, paid in newly minted shares. The 1%
  rate is candidate pricing and these are not approved commercial terms.
- Fresh canonical registration still fails if the pool is already initialized. A separate `adoptExisting` operation lets only the creator accept its exact reviewed price, with an expiry no more than five minutes away. The UI requires the observed quote-per-share price to be within 1% of the entered intended price, binds review to wallet/network/index/quote/price, and never automatically adopts after initialization fails. The 1% comparison is a UI guard, not an oracle or an onchain NAV constraint. Swaps that change the reviewed price make adoption revert. This neither resets a badly priced pool nor guarantees progress against continued price manipulation; unacceptable pools must remain unregistered. Adoption leaves existing LP ownership unchanged and provides no liquidity. Funding still requires a separately reviewed, bounded transaction.
- Indicative portfolio NAV is wired to recorded platform prices on chain 4663, with optional on-chain USD feeds. Closed-bucket source, sample age, unknown underlying source age and explicit peg assumptions are exposed. No price is required for proportional issuance/redemption or secondary swaps. Missing backing prices withhold NAV. Sampled charts remain distinct from the paginated proposal/fill/fee event ledger and do not establish historical LP returns.
- Runtime hashes are identity checks, not audits. Local native Swap events do not prove target-chain aggregator or third-party indexer behaviour.

See [implementation status](../../aindex/research/managed-index-implementation-status.md) for evidence and outstanding W0–W7 work. Independent review, target-chain valuation/reporting evidence, broad asset admission and price-review operations, launch recovery acceptance, approved fee terms and target-chain discovery/routing must precede public deployment. Automation, agents and strategy-vault integrations are later milestones.


### Read-only operating monitor

The indexer separately retries failed historical snapshot checkpoints, five due jobs per iteration. Retry delay grows from one minute to a maximum of one day; current discovery and event ingestion continue. Inspect `managed_snapshot_retries` in the platform database for unresolved blocks, their recorded hashes, attempt counts and next attempt times. An archive outage leaves these records pending rather than substituting current holdings. A detected checkpoint reorg rewinds only the affected factory's derived data. These are sampled checkpoints, not a complete observation for every historical block. The history API exposes recovery coverage, and the monitor emits `SNAPSHOT_RECOVERY_PENDING` or `SNAPSHOT_RECOVERY_UNKNOWN` with structured `historyRecovery` data. A caught-up event cursor does not clear either warning.

From `aindex/`, run `node --import tsx deploy/monitor-managed.ts <index-address> ...` with `AINDEX_MANAGED_DEPLOYMENT` set to the reviewed manifest. Set `AINDEX_DB` to the platform database for recorded USD prices and event-cursor checks. The monitor emits structured JSON and exits 0 for no detected issues, 1 for warnings, 2 for critical reads/health issues. It never signs or submits transactions. A healthy output is not security approval or completion of the monitored pilot.


### Optional target-chain forks

`AINDEX_FORK_RPC` enables `RobinhoodMarketForkTest`, `RobinhoodAssetsForkTest` and `RobinhoodSeededLaunchForkTest`. The first uses the real chain-4663 PoolManager with disposable tokens; the second checks managed custody of WETH/USDG using local cheatcode balances; the third runs the production launch path, `createManagedWithMarket` through `ShareFeeHook`, against the real PoolManager with WETH and USDG in the basket and USDG as the quote, then trades both ways, claims fees, pays holders and withdraws the creator's seed. Set `AINDEX_FORK_BLOCK` for a reproducible historical block; without it, each fixture selects fresh pinned state and logs the block. Missing archive state fails rather than silently falling back. With no RPC configured, the fork tests are skipped. Run them individually with `npm run test:contracts -- --match-contract RobinhoodMarketForkTest --threads 1 --compute-units-per-second 20 -vv` (or `RobinhoodAssetsForkTest`) from `aindex/`.

No fork test broadcasts public transactions. Their passing does not establish external router discovery, browser execution or compatibility of the entire catalog. Current measurements are recorded in [target-chain evidence](../../aindex/research/managed-target-chain-evidence-2026-09-21.md).


### LP cash-flow events

New routers emit `LiquidityChanged` and use manifest `routerVersion: 2`. Signed token deltas are actual owner payments/receipts, with settled fees included. The API reconciles this ledger by owner, canonical pool, namespaced salt and tick range. Old routers have no retroactive owner-attributed history. Current position value plus token funding totals is insufficient for historical USD returns; those require historical marks for each cash flow. This router bytecode change requires a new verified deployment and runtime manifest.


The indexer now runs a bounded historical LP mark worker after event ingestion. The UI reports indicative cash-flow-adjusted USD P/L only with reconciled token flows, complete historical/current price evidence and unchanged price sources. Marks use each event block's closing pool price; they exclude gas and are not realized USD receipts. Missing archive data does not stop event ingestion. See the implementation status for tests and remaining target-chain/browser gates.
