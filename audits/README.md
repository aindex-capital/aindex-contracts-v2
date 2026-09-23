# Audits

**There are none.** Nothing in this repository has been audited or reviewed by anyone outside the
project, and it has never held real money.

This directory exists so that the absence is stated where a reader looks for the presence, rather
than inferred from a missing folder. Reserve's own repository, which this one depends on, carries
four: cantina, pashov, trail-of-bits and trust-security. That is the standard this is measured
against and does not meet.

When an audit happens, one subdirectory per auditor with the report and the commit it covers.

## What most needs review, in order

1. `MonthlyMandate` holds the rebalance authority and the role recovery.
2. `ShareFeeHook` sits in the swap path of every trade.
3. `ShareMarketRouter` moves user funds and lends its position salt to the factory.
4. `IndexMarketRegistry` and `IndexFactory` decide what a launch is.

`lib/reserve-index-dtf` is Reserve's audited code, unmodified, pinned by commit and lockfile hash,
and cloned immutably. That is the one part with review behind it, and the review is theirs.
