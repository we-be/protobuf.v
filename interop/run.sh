#!/usr/bin/env bash
# Cross-validate the V runtime against protoc:
#   1. V encodes N fuzzed messages + one all-extremes known message
#   2. protoc decodes each to text and re-encodes to binary
#   3. byte-compare V's encoding vs protoc's (serialization order matches)
#   4. V decodes protoc's bytes and re-verifies values + re-encoding
set -euo pipefail
cd "$(dirname "$0")"

command -v protoc >/dev/null || { echo "protoc required (brew install protobuf)"; exit 1; }

COUNT="${1:-300}"
SEED="${2:-42}"

# scalars_pb.v is generated — refuse to run against a stale copy
regen="$(mktemp -d)/scalars_pb.v"
v run ../cmd/vpbgen -m main -o "$regen" scalars.proto >/dev/null
if ! cmp -s "$regen" scalars_pb.v; then
  echo "FAIL: scalars_pb.v is stale — regenerate with:"
  echo "  v run cmd/vpbgen -m main -o interop/scalars_pb.v interop/scalars.proto"
  exit 1
fi

rm -rf out && mkdir out
v run . gen out "$COUNT" "$SEED"

for f in out/known.bin out/fuzz_*.bin; do
  base="${f%.bin}"
  protoc --decode=Scalars scalars.proto < "$f" > "$base.txt"
  protoc --encode=Scalars scalars.proto < "$base.txt" > "$base.protoc.bin"
  if ! cmp -s "$f" "$base.protoc.bin"; then
    echo "FAIL: $f differs from protoc's re-encoding"
    diff <(xxd "$f") <(xxd "$base.protoc.bin") | head -20
    exit 1
  fi
done
echo "byte-compare vs protoc: $COUNT fuzz + known.bin identical"

v run . check out "$COUNT" "$SEED"
echo "interop OK (generated code)"
