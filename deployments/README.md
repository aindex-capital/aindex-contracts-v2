# Deployments

One file per chain, recording what is live, at which commit, and where its verification input is.

**`4663.json` is Robinhood Chain mainnet, deployed 2026-09-24 at block 71125167** from
`0x916817f2c44c44f0255249140300E78AfD6c492C`. The transactions are in
`broadcast/Deploy.s.sol/4663/`. The source is verified on Blockscout from the Standard JSON inputs
`forge verify-contract --show-standard-json-input` produces.

`script/Deploy.s.sol` writes `4663.json` itself.

The v1 contracts are recorded in the `aindex-contracts` repository, not here. They were retired on
2026-09-24: every vault paused and emptied of everything but 1 wei per token.
