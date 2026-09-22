#!/usr/bin/env bash
# Export (or with --check, verify) compiler-derived ABIs into docs/abi/ and their canonical
# keccak256 hashes into docs/abi-hashes.json. Offline; no RPC, wallet or network access.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-write}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
declare -A CONTRACTS=(
  [MiniSwapToken]="src/MiniSwapToken.sol:MiniSwapToken"
  [MiniPair]="src/MiniPair.sol:MiniPair"
)
forge build --offline >/dev/null
printf '{\n' > "$TMP/hashes.json"
first=1
for name in MiniSwapToken MiniPair; do
  forge inspect --offline "${CONTRACTS[$name]}" abi --json > "$TMP/$name.json"
  canonical=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",", ":")), end="")' "$TMP/$name.json")
  digest=$(cast keccak "0x$(printf '%s' "$canonical" | od -An -v -tx1 | tr -d ' \n')")
  [ $first -eq 1 ] || printf ',\n' >> "$TMP/hashes.json"
  first=0
  printf '  "%s": "%s"' "$name" "$digest" >> "$TMP/hashes.json"
done
printf '\n}\n' >> "$TMP/hashes.json"
if [ "$MODE" = "--check" ]; then
  for name in MiniSwapToken MiniPair; do
    cmp -s "$TMP/$name.json" "docs/abi/$name.json" || { echo "docs/abi/$name.json is stale"; exit 1; }
  done
  cmp -s "$TMP/hashes.json" docs/abi-hashes.json || { echo "docs/abi-hashes.json is stale"; exit 1; }
  echo "ABI exports are up to date"
else
  cp "$TMP/MiniSwapToken.json" "$TMP/MiniPair.json" docs/abi/
  cp "$TMP/hashes.json" docs/abi-hashes.json
  echo "ABI exports written to docs/abi/ and docs/abi-hashes.json"
fi
