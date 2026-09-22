#!/usr/bin/env python3
"""
Find a CREATE2 salt whose deployed address carries the hook's permission bits.

Uniswap v4 reads a hook's permissions from the low 14 bits of its own address, so a hook cannot
simply be deployed: the address has to be mined. `ShareFeeHook` needs afterSwap and
afterSwapReturnDelta, which is 0x0044, so about one address in 16,384 will do.

    python3 script/mine-hook-salt.py <deployer> <poolManager> <registrar> <protocolRecipient>

Deploy with CREATE2 from <deployer> using the printed salt and these exact constructor arguments.
Anything else produces a different address and the constructor reverts `BadFlags`, which is the
check that stops a mismatch ever reaching the chain.

Python rather than .mjs, against this repo's convention, because `eth_hash` is already present
here and `viem` is not reachable from this directory without adding a dependency to a project
whose whole point is pinned, auditable inputs.
"""
import json, sys, time, pathlib
from eth_hash.auto import keccak

FLAGS = 0x0044
MASK = (1 << 14) - 1

def main():
    if len(sys.argv) != 5:
        sys.exit("usage: mine-hook-salt.py <deployer> <poolManager> <registrar> <protocolRecipient>")
    deployer, pool_manager, registrar, protocol = (a.lower() for a in sys.argv[1:5])

    art = json.loads(pathlib.Path(__file__).parent.joinpath("../out/ShareFeeHook.sol/ShareFeeHook.json").read_text())
    bytecode = bytes.fromhex(art["bytecode"]["object"][2:])
    args = b"".join(bytes.fromhex(a[2:]).rjust(32, b"\x00") for a in (pool_manager, registrar, protocol))
    init_hash = keccak(bytecode + args)
    dep = bytes.fromhex(deployer[2:])

    started = time.time()
    for i in range(20_000_000):
        salt = i.to_bytes(32, "big")
        addr = int.from_bytes(keccak(b"\xff" + dep + salt + init_hash)[12:], "big")
        if addr & MASK == FLAGS:
            print(json.dumps({
                "salt": "0x" + salt.hex(),
                "address": "0x" + format(addr, "040x"),
                "initCodeHash": "0x" + init_hash.hex(),
                "flags": "0x" + format(addr & MASK, "04x"),
                "tried": i,
                "seconds": round(time.time() - started, 1),
                "constructorArgs": {"poolManager": pool_manager, "registrar": registrar,
                                    "protocolRecipient": protocol},
            }, indent=2))
            return
    sys.exit("no salt in 20m attempts, which should be impossible at 1 in 16384")

if __name__ == "__main__":
    main()
