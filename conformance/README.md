# Conformance

protobuf.v is validated against the **official protobuf conformance suite**
(the same `conformance_test_runner` that gates the C++, Go, and other
implementations).

## Result (proto3)

```
CONFORMANCE SUITE PASSED: 1468 successes, 4134 skipped, 0 expected failures, 0 unexpected failures.
```

- **All 1468 applicable proto3 tests pass (100%), 0 unexpected failures.**
- **4134 skipped**: proto2, editions, and the text-format / JSPB wire formats —
  all documented non-goals; the testee returns `skipped` for them.
- A few *Recommended* (optional, non-gating) cases remain — see
  `failure_list.txt` for the list; they surface only as warnings.

## Running it

Needs `cmake`, `ninja`, and a C++ toolchain (to build the runner once), plus the
V compiler.

```sh
VEXE=~/v/v ./run.sh
```

The script clones protobuf v34.1 (matching the pinned `protoc`), builds
`conformance_test_runner`, generates `conf_pb.v` from the upstream conformance
protos with `vpbgen`, builds `testee.v`, and runs the suite against
`failure_list.txt`. Point `PROTOBUF_SRC` at an existing checkout to skip the
clone.

## Files

- `testee.v` — speaks the length-delimited `ConformanceRequest`/`Response`
  protocol on stdin/stdout, decoding/re-serializing `TestAllTypesProto3`.
- `failure_list.txt` — the 10 known-failing cases, with rationale.
- `run.sh` — end-to-end harness.
- `conf_pb.v`, `.stage/`, `.protobuf-src/`, `.testee_bin` — generated/build
  artifacts (gitignored).
