"""Prove each Standard JSON input here compiles to the on-chain code.

Usage (from anywhere): python3 verify/v3/prove.py [out.json]
Compiles with ~/.svm/0.8.28/solc-0.8.28, compares runtime (immutables masked) with cast code,
and checks the compiled creation code is a prefix of the CREATE input found by tracing the creation
tx; the remainder is the constructor args. Optional out.json receives the per-contract rows.
"""
import json, subprocess, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
V = os.path.dirname(os.path.abspath(__file__))
SOLC = os.path.expanduser("~/.svm/0.8.28/solc-0.8.28")
RPC = "https://rpc.ordofi.network"

ENTRIES = [
    # name, address, file, source path, creation tx
    ("IndexFactory", "0x1A74fE285816f5cf8CBAe9C98C9B303A1459eEcf", "IndexFactory.json", "src/IndexFactory.sol", "0xc7fa9eba988dac2e10140bbc180e9810ab351f1367ef7a22d2346ae7e0c5accd"),
    ("IndexMarketRegistry", "0x2F8015CA784f7eEEb0AbcF854c92A363D58E9f7e", "IndexMarketRegistry.json", "src/IndexMarketRegistry.sol", "0x6641e883e99ae4a5c141386a115152e2119dc09395cd07d87aa6d4967952b978"),
    ("FixedFeeRegistry", "0x705fE898c4637aE4f5d1c7C27A97d5999879bb3c", "FixedFeeRegistry.json", "src/FixedFeeRegistry.sol", "0x710b29c5227902bd92c21d0f64fa2cb3c58e66b64709bab69a67d3a0dc26a71b"),
    ("MandateDeployer", "0x283b524A38f8d9d4c866C14a78BeD30aB7587534", "MandateDeployer.json", "src/MandateDeployer.sol", "0xc7fa9eba988dac2e10140bbc180e9810ab351f1367ef7a22d2346ae7e0c5accd"),
    ("IndexZap", "0x5F807BB130739F8d9A96d7d4383A1318E0669bFF", "IndexZap.json", "src/IndexZap.sol", "0x05969166a683bbcff084d380cab98d7ca1c8c162b6fd9eabd8d524e3298a9549"),
    ("AuctionFiller", "0x9baA0f86868212Dd4eDdd3454Ee6e042f932CD00", "AuctionFiller.json", "src/AuctionFiller.sol", "0x0aa3f076e2c494cb78edd995b5fc61d5ea6a12756418daa56f082fa55804e455"),
    ("AixDistributor", "0xbfCf27E1eAB345c34950b3227F9693513acE20F2", "AixDistributor.json", "src/AixDistributor.sol", "0x92d2dea7f11d43e094be70d9b709582752b3c5743debe69e8f8bdfa14faefc25"),
    ("MonthlyMandate", "0x87db6223da2644a8e10e0cd06278e4014719d60a", "MonthlyMandate.json", "src/MonthlyMandate.sol", "0xde7a826f50a9989cc30da4fd7a64eee89fe98404dd2eea52422abcc13f92da3e", "AR10 mandate"),
    ("MonthlyMandate", "0x711a1e5d66c44b22677dd7b1314188a1efe9c3a4", "MonthlyMandate.json", "src/MonthlyMandate.sol", "0x12fdc95be51c3f6931a844fea637e86a2f5a552e575576b58082d1146c42f29a", "ADIV mandate"),
    ("MonthlyMandate", "0x4b325e464f57fac0dcb4dcabf74f1a3fd30a9799", "MonthlyMandate.json", "src/MonthlyMandate.sol", "0x12698833d8334184e1d2eb1980a4092d8d6cdc7eb5449d491e0c210258d49afa", "AIXSTR mandate"),
]


def rpc(method, params):
    out = subprocess.check_output(["cast", "rpc", method, *[json.dumps(p) if not isinstance(p, str) else p for p in params], "--rpc-url", RPC])
    return json.loads(out)


def strip_cbor(h):
    # last 2 bytes = CBOR length
    n = int(h[-4:], 16)
    return h[: -(n + 2) * 2], h[-(n + 2) * 2 :]


def mask(h, refs):
    b = bytearray(bytes.fromhex(h))
    for lst in refs.values():
        for r in lst:
            b[r["start"] : r["start"] + r["length"]] = b"\0" * r["length"]
    return b.hex()


compiled = {}


def compile_file(f, src, name):
    key = (f, name)
    if key in compiled:
        return compiled[key]
    inp = json.load(open(os.path.join(V, f)))
    out = json.loads(subprocess.run([SOLC, "--standard-json", "--base-path", ROOT], input=json.dumps(inp).encode(), capture_output=True, check=True).stdout)
    errs = [e for e in out.get("errors", []) if e["severity"] == "error"]
    if errs:
        raise SystemExit(f"{f}: {errs[0]['formattedMessage']}")
    c = out["contracts"][src][name]
    compiled[key] = c
    return c


def find_create(frame, addr):
    if frame.get("type", "").startswith("CREATE") and frame.get("to", "").lower() == addr.lower():
        return frame
    for c in frame.get("calls", []) or []:
        r = find_create(c, addr)
        if r:
            return r
    return None


report = []
manifest = []
for e in ENTRIES:
    name, addr, f, src, tx = e[:5]
    label = e[5] if len(e) > 5 else name
    c = compile_file(f, src, name)
    ev = c["evm"]
    local_rt = ev["deployedBytecode"]["object"]
    imm = ev["deployedBytecode"].get("immutableReferences", {})
    chain_rt = subprocess.check_output(["cast", "code", addr, "--rpc-url", RPC]).decode().strip()[2:]
    lb, lc = strip_cbor(local_rt)
    cb, cc = strip_cbor(chain_rt)
    rt_ok = len(local_rt) == len(chain_rt) and mask(lb, imm) == mask(cb, imm)
    cbor_ok = lc == cc
    # creation input
    trace = rpc("debug_traceTransaction", [tx, {"tracer": "callTracer"}])
    fr = find_create(trace, addr)
    init = fr["input"][2:]
    local_init = ev["bytecode"]["object"]
    init_ok = init.startswith(local_init)
    args = init[len(local_init):] if init_ok else None
    report.append(f"{label:22} {addr} runtime={'MATCH' if rt_ok else 'DIFF'} cbor={'same' if cbor_ok else 'diff'} creation={'MATCH' if init_ok else 'DIFF'} args={len(args)//2 if args is not None else '?'}B immutables={sum(len(v) for v in imm.values())}")
    manifest.append({
        "label": label,
        "address": addr,
        "contractName": f"{src}:{name}",
        "compilerVersion": "v0.8.28+commit.7893614a",
        "constructorArgs": "0x" + args if args else "",
        "libraries": {},
        "file": f,
        "creationTx": tx,
        "proof": {"runtimeMatchesIgnoringImmutables": rt_ok, "cborIdentical": cbor_ok, "creationCodeIsPrefixOfCreationInput": init_ok},
    })

print("\n".join(report))
if len(sys.argv) > 1:
    json.dump(manifest, open(sys.argv[1], "w"), indent=2)
