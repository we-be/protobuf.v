# Changelog

All notable changes to protobuf.v are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

The stable public API is the generated message surface — `encode`/`encoded_size`/
`encode_to`, `decode`, and (with `-json`) `json`/`from_json`/`json_value`/
`from_json_value`, plus `to_any`/`from_any`, the `as_time`/`as_duration` WKT
mappings, and generated enums/oneof sum types — together with `protobuf.Encoder`,
`protobuf.Decoder`, `protobuf.WireType`, and `zigzag_encode`/`zigzag_decode`. The
`protobuf.json_*` helpers are `pub` only so generated code can call them across
modules; they are runtime-internal and not covered by the semver contract.

## [1.2.1] - 2026-08-10

### Fixed
- **Reserved V type names.** A message whose generated V name would collide
  with a V builtin type (`Error`, `IError`, `Option`, `Result`) now gets a
  trailing underscore (`Error` → `Error_`), mirroring how field names dodge
  keywords, so such schemas compile. The wire `type_url` is unchanged.
  Surfaced generating the Connect conformance suite's protos, which define a
  message named `Error`.

## [1.2.0] - 2026-08-10

### Changed
- **gRPC/Connect server glue (`vpbgen -grpc`)** now threads a
  `grpc.ServerContext` through the generated handler and dispatch: each method
  is `fn (mut h H) rpc(mut ctx grpc.ServerContext, req In) !Out` (was
  `(req In) !Out`), and `<Svc>Service.call` gains a trailing
  `mut ctx grpc.ServerContext`. Handlers can now read request metadata and set
  response headers, trailers, and typed error details. Requires grpc.v with
  `ServerContext` (≥ the Gate 3 metadata release).

As with 1.1.0, the generated gRPC-stub *shape* is outside protobuf.v's frozen
1.0 message API, so this ships as a minor.

## [1.1.1] - 2026-08-10

### Fixed
- **Hostile-input crash in JSON parsing.** A bare top-level scalar or empty
  document (e.g. `1e`, `-`, `x`, `""`) could drive V's json2 checker past EOF
  and crash its error formatter (a `substr` underflow) instead of returning an
  error — a denial-of-service reachable through `from_json` and the gRPC
  Connect JSON codec. `json_precheck` now rejects empty input and fully
  validates bare scalars (numbers via the JSON grammar; `true`/`false`/`null`)
  before json2 sees them. Surfaced by grpc.v's Gate 2 fuzzing.

## [1.1.0] - 2026-08-09

### Changed
- **gRPC client stubs (`vpbgen -grpc`)** now take functional call options and
  return response metadata: each method is
  `fn (mut c SvcClient) rpc(req In, opts ...grpc.CallOption) !grpc.Reply[Out]`
  (was `!Out`), enabling per-call deadlines and metadata via
  `grpc.timeout(...)` / `grpc.header(...)` and surfacing the server's response
  metadata on `Reply`. Requires grpc.v with `CallOption`/`Reply`.

The generated gRPC-stub *shape* is not part of protobuf.v's frozen 1.0 API
(the message surface is); it evolves with grpc.v and stabilizes when grpc.v
reaches 1.0. This is why a stub-shape change ships as a minor, not a major.

## [1.0.0] - 2026-08-09

First stable release. proto3 is feature-complete and validated against the
**official protobuf conformance suite** (built from protobuf v34.1): **0
unexpected failures** across the applicable proto3 cases; proto2, editions,
text-format, and JSPB are out of scope and reported as skipped. See
`conformance/`.

### Added
- **Recursive messages.** A singular field that closes a type cycle is emitted
  as `?&T` (optional heap pointer, the only recursive shape V allows), and any
  message holding one gets a value-equality `==` (V compares `?&T` by pointer
  otherwise). `descriptor.proto`-style self-referential schemas now work.
- **`map<bool, V>`**, stored as `map[int]V` (`0`=false, `1`=true), faithful on
  the wire and in JSON.
- **`allow_alias` enums** — repeated value numbers keep the first (canonical)
  name as the V member; every alias name still parses back.
- **Message merge on decode** — repeated occurrences of a message field merge
  per the proto3 spec, for both singular fields and message oneof arms.
- **Conformance harness** (`conformance/`): a testee speaking the length-delimited
  stdin/stdout protocol plus `run.sh` to build and drive the official runner.

### Changed
- **BREAKING: `json()` is now `!string` and `json_value()` is `!json2.Any`.**
  Canonical-JSON serialization can genuinely fail (a `Timestamp` outside
  0001–9999, or a `Duration` beyond ±315576000000s or with mismatched
  seconds/nanos signs, is not representable), so it now returns a Result and
  errors on those inputs instead of emitting a bogus value. Update call sites
  with `!` or `or {}`; generated gRPC stubs already do.
- **Strict protojson parsing** — reject out-of-range/empty/overflowing integer
  strings (and accept exponential spellings for integer fields), reject numeric
  literals that overflow float/double, require strict RFC 3339 timestamps
  (uppercase `T`/`Z`, 0001–9999), reject duplicate members of the same oneof,
  and reject overlong wire tag varints.
- **`json_name` derivation** now matches protobuf's `ToJsonName` exactly
  (previously mangled names with a leading capital or leading underscore).
- **Field-name mangling** — proto field names are lowercased and stripped of
  leading underscores to form valid V identifiers (JSON names are unaffected;
  they derive from the original proto name).

### Fixed
- **`sint32` decode** truncated to 32 bits *after* zigzag-decoding; a legal
  non-minimal wire varint (bits set above bit 32) decoded to the wrong value.
  Now truncates first, matching protoc.
- **JSON string aliasing** on macOS/arm64 — parsed string values could alias a
  reused decode buffer and corrupt map/repeated string values; parsing now
  returns owned copies.
- `google.protobuf.Value` fields accept JSON `null` (→ `NullValue`); `null`
  still means "leave at default" for every other field.

## [0.7.0] - 2026-08-09

### Added
- **`Any`**: real binary `to_any`/`from_any` pack/unpack, and canonical
  `@type` JSON expansion via a generated whole-fileset resolver (no runtime
  registry / globals).
- `[json_name = ...]` honored on emit and parse (via general field-option
  parsing); `[deprecated = true]` → V's `@[deprecated]` attribute.
- `vpbgen -grpc` emits Connect-protocol server glue per service.

### Changed
- Decode fast path: single-byte varint shortcut and `@[inline]` on the hot
  readers, closing the cloud decode gap (KB+ payloads now beat Go).
- CI perf gate with per-op thresholds.

### Fixed
- Guarded two json2 parser pathologies (deep-nesting segfault, an
  infinite-loop input) in the protojson entry point.

## [0.6.0] - 2026-08-08

### Added
- Canonical JSON (protojson) via `vpbgen -json`: `json()`/`from_json()`,
  lowerCamel names, i64-as-string, WKT special forms.
- Unknown-field preservation: every message carries `pb_unknown`, re-emitted
  after known fields on encode.

## [0.5.0] - 2026-08-08

### Added
- Service/RPC parsing into the AST with type checking.
- `vpbgen -grpc`: gRPC client stubs for services.
- Imports: transitive loader, cross-package resolution, embedded well-known
  types; output is self-contained.
- `Timestamp`/`Duration` ↔ `time.Time`/`time.Duration` mappings on the WKTs.

## [0.1.0] - [0.4.0]

Initial proto3 wire runtime and `vpbgen` code generation: messages, nested
types, enums (open), scalars, `optional`, `repeated`/`packed`, `map<K,V>`, and
`oneof` (sum types), with a protoc byte-oracle and adversarial fuzzing.

[1.1.1]: https://github.com/we-be/protobuf.v/releases/tag/v1.1.1
[1.1.0]: https://github.com/we-be/protobuf.v/releases/tag/v1.1.0
[1.0.0]: https://github.com/we-be/protobuf.v/releases/tag/v1.0.0
[0.7.0]: https://github.com/we-be/protobuf.v/releases/tag/v0.7.0
[0.6.0]: https://github.com/we-be/protobuf.v/releases/tag/v0.6.0
[0.5.0]: https://github.com/we-be/protobuf.v/releases/tag/v0.5.0
