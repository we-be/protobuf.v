#!/usr/bin/env bash
# Run the official protobuf conformance suite against protobuf.v.
#
# Steps: locate (or clone) a protobuf source tree, build its
# conformance_test_runner, generate V bindings for the conformance protos with
# vpbgen, build the testee, and run the suite against failure_list.txt.
#
# Env:
#   PROTOBUF_SRC  path to a protobuf checkout (default: clone v34.1 here)
#   VEXE          the V compiler (default: v)
#   EDITION       --maximum_edition value (default: 2023)
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
REPO="$(dirname "$HERE")"
: "${VEXE:=v}"
: "${EDITION:=2023}"
: "${PROTOBUF_SRC:=$HERE/.protobuf-src}"

command -v cmake >/dev/null || { echo "cmake required to build the runner"; exit 1; }
command -v ninja >/dev/null || { echo "ninja required to build the runner"; exit 1; }

# 1. protobuf source (runner + conformance protos)
if [ ! -d "$PROTOBUF_SRC" ]; then
  echo ">> cloning protobuf v34.1 into $PROTOBUF_SRC"
  git clone --depth 1 --branch v34.1 https://github.com/protocolbuffers/protobuf.git "$PROTOBUF_SRC"
fi

# 2. build conformance_test_runner (once)
RUNNER="$PROTOBUF_SRC/build/conformance_test_runner"
if [ ! -x "$RUNNER" ]; then
  echo ">> building conformance_test_runner"
  cmake -S "$PROTOBUF_SRC" -B "$PROTOBUF_SRC/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_CONFORMANCE=ON -DCMAKE_DISABLE_FIND_PACKAGE_absl=ON
  ninja -C "$PROTOBUF_SRC/build" conformance_test_runner
fi

# 3. generate V bindings for conformance.proto + test_messages_proto3.proto.
#    test_messages lives under google/protobuf/ so its WKT imports resolve to
#    protobuf.v's embedded copies rather than the source tree.
STAGE="$HERE/.stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/conformance" "$STAGE/google/protobuf"
cp "$PROTOBUF_SRC/conformance/conformance.proto" "$STAGE/conformance/"
cp "$PROTOBUF_SRC/src/google/protobuf/test_messages_proto3.proto" "$STAGE/google/protobuf/"
cat > "$STAGE/root.proto" <<'PROTO'
syntax = "proto3";
import "conformance/conformance.proto";
import "google/protobuf/test_messages_proto3.proto";
PROTO
echo ">> generating conf_pb.v"
VEXE="$VEXE" "$VEXE" run "$REPO/cmd/vpbgen" -m main -json -I "$STAGE" -o "$HERE/conf_pb.v" "$STAGE/root.proto"

# 4. build the testee (testee.v + generated conf_pb.v)
echo ">> building testee"
"$VEXE" -o "$HERE/.testee_bin" "$HERE"

# 5. run the suite
echo ">> running conformance suite"
"$RUNNER" --maximum_edition "$EDITION" --failure_list "$HERE/failure_list.txt" "$HERE/.testee_bin"
