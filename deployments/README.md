# Deployments

One file per chain and version, recording what is live and where its verification input is.

**`4663-v3.json` is the live deployment on Robinhood Chain mainnet (chain id 4663), deployed
2026-09-28 at block 74953548** from `0x916817f2c44c44f0255249140300E78AfD6c492C` by
`script/deploy-v3.sh`. The transactions are in `broadcast/Deploy.s.sol/4663/`. Standard JSON
verification inputs, with a script that proves each compiles to the on-chain code, are in
`verify/v3/`.

**`4663.json` is v2, deployed 2026-09-24 at block 71125167, and retired on 2026-09-28.** Its indexes
were redeemed and relaunched on v3; only rounding dust remains in the v2 contracts.

An earlier v1 generation, from a separate codebase, was retired on 2026-09-24.
