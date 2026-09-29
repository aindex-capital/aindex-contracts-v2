# Security

## Status

The v3 contracts are deployed on Robinhood Chain mainnet (chain id 4663) and hold user funds.
Addresses are in [README.md](README.md#deployment-robinhood-chain-mainnet-v3) and
`deployments/4663-v3.json`. **They have not been audited.** See [audits/README.md](audits/README.md).
The contracts are immutable, so a vulnerability cannot be patched in place; a fix means a new
deployment and a migration.

## Reporting a vulnerability

Report privately through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability** (GitHub private vulnerability reporting). Do not open a public issue or pull
request for a vulnerability.

Please include the affected contract and address, a description of the issue, and a proof of
concept (for example a Foundry test, which can run against a mainnet fork as described in the
README).

## Scope

In scope:

- The contracts in `src/` as deployed at the v3 addresses listed in the README.
- `LiquidityLocker`, which is not deployed yet.
- `script/Deploy.s.sol` and `script/deploy-v3.sh`, where a flaw would affect a deployment.

Out of scope:

- Reserve's Folio (`reserve-protocol/reserve-index-dtf`) and Uniswap v4-core. Report issues in
  them to their maintainers, unless the issue arises from how these contracts use them.
- The retired v2 deployment in `deployments/4663.json`.
- Websites, APIs and other off-chain software.
- Risks already described in the README's Risks section, such as a basket token that stops
  transferring, unless you find a way to cause harm beyond what is described there.

## Bug bounty

There is no bug bounty program at this time.

## What the design relies on

These are the properties a reviewer should be able to check against the code.

- **Minting and redeeming never use a price.** Folio mints and redeems proportionally against the
  balances it holds. No oracle is on a path that can change backing.
- **The fee hook has no authority over any index.** It takes its fee in `afterSwap` from the swap
  result and holds it until `claim` or `payHolders` pays fixed destinations.
- **The router lends its position salt to exactly one address**, the factory, and only to add
  liquidity. Removing liquidity always derives the position from `msg.sender`.
- **A rebalance is one auction on bounded prices.** `MonthlyMandate` builds the auction's price
  bands from reviewer prices that must stay within fixed limits of the queued proposal, and opens
  exactly one auction per interval.
- **Each index's only admin is its mandate**, checked at activation and before every execution.
- **Roles recover on a delay** of at least 7 days, authorised by the two other role holders, and
  acceptance invalidates outstanding proposals.
