#!/usr/bin/env bash
#
# Deploy v3 to Robinhood Chain mainnet: the factory stack (Deploy.s.sol), then the index zap and the
# auction filler bound to the new factory. Writes every address to deployments/4663-v3.json.
#
#   script/deploy-v3.sh            from aindex-contracts-v2/, with .env holding DEPLOYER_PRIVATE_KEY,
#                                  AINDEX_PROTOCOL_RECIPIENT and AINDEX_QUOTES (the same as v2)
#
# Rehearsed on a mainnet fork on 2026-09-28 (Deploy.s.sol's own read-back checks all passed).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
RPC="${AINDEX_RPC:-https://rpc.mainnet.chain.robinhood.com}"
OUT=deployments/4663-v3.json
ROUTER=0x8876789976dEcBfCbBbe364623C63652db8C0904
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
[ -e "$OUT" ] && { echo "$OUT exists: v3 is already deployed. Remove it only if you mean to deploy again."; exit 1; }

echo "==> 1/3 factory stack"
AINDEX_DEPLOYMENT_OUT="$OUT" forge script script/Deploy.s.sol --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --slow
FACTORY=$(node -e 'console.log(require("./'"$OUT"'").factory)')
echo "factory $FACTORY"

echo "==> 2/3 index zap"
ZAP=$(forge create src/IndexZap.sol:IndexZap --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --json \
  --constructor-args "$ROUTER" "$FACTORY" "$WETH" "$USDG" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).deployedTo))')
echo "zap $ZAP"

echo "==> 3/3 auction filler"
FILLER=$(forge create src/AuctionFiller.sol:AuctionFiller --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --json \
  --constructor-args "$ROUTER" "$FACTORY" "$USDG" "$WETH" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).deployedTo))')
echo "filler $FILLER"

node -e '
const fs=require("fs"),p=process.argv[1],r=JSON.parse(fs.readFileSync(p,"utf8"));
r.zap=process.argv[2];r.filler=process.argv[3];fs.writeFileSync(p,JSON.stringify(r,null,2)+"\n");' "$OUT" "$ZAP" "$FILLER"
echo "==> done: $OUT"
cat "$OUT"
