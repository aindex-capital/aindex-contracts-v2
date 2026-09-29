# Audits

**There are none.** Nothing in this repository has been audited or reviewed by anyone outside the
project. The v3 contracts are nevertheless deployed on Robinhood Chain mainnet and hold user funds,
and they are immutable, so a flaw cannot be patched in place.

This directory states that absence where a reader would look for reports. When an audit is done,
each auditor's report will be added here in its own subdirectory, together with the commit it
covers.

## Suggested review order

1. `MonthlyMandate`: rebalance authority, price bounds, token additions and role recovery.
2. `ShareFeeHook`: in the swap path of every trade on an index pool; holds accrued fees.
3. `ShareMarketRouter`: moves user funds and lends its position salt to the factory.
4. `IndexFactory`, `IndexFactoryBase` and `IndexMarketRegistry`: what a launch creates and who
   holds which role afterwards.
5. `IndexZap` and `AuctionFiller`: execute off-chain planned router calldata.
6. `AixDistributor`: Merkle payouts.
7. `LiquidityLocker`: not deployed yet.

## Dependencies

Reserve's Folio (`reserve-protocol/reserve-index-dtf`) is used unmodified, pinned by commit and
lockfile hash in `dependencies.json`. Its own audit reports are in the `audits/` directory of that
repository. Those audits cover Folio, not the contracts in this repository.
