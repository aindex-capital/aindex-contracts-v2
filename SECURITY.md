# Security

## Status

Deployed to Robinhood Chain mainnet on 2026-09-24 (addresses in `README.md` and
`deployments/4663.json`). Not audited. See `audits/README.md`.

## Reporting

Security issues go to the maintainers privately rather than to the issue tracker.

## What the design rests on

Stated here because a reviewer should be able to check the claims rather than find them scattered
through comments.

- **The vault never prices anything.** Mint and redeem are proportional against balances Folio
  reads directly. No oracle sits on a path that can move backing.
- **The fee hook cannot reach backing.** It takes from the swap output via `afterSwap` and holds
  what it takes. It has no authority over any vault.
- **The router lends its position salt to exactly one address**, the factory, and only to add
  liquidity. Withdrawal always derives its salt from `msg.sender`.
- **A rebalance is an auction, not a price.** `MonthlyMandate` queues, has an independent reviewer
  approve, and settles through Folio. Nothing in this repository decides what an asset is worth.
- **Roles recover on a delay.** Seven days, authorised by the two other role holders, and
  acceptance invalidates outstanding proposals.
