# protobuf.v

[![CI](https://github.com/we-be/protobuf.v/actions/workflows/ci.yml/badge.svg)](https://github.com/we-be/protobuf.v/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/we-be/protobuf.v)](https://github.com/we-be/protobuf.v/releases)

Complete Protocol Buffers (proto3) for V: a `.proto` → V code generator, a
wire-format runtime, canonical JSON, and gRPC/Connect service stubs.
Byte-exact against protoc, JSON-conformant against Go's protojson, and
**2–3× faster than `google.golang.org/protobuf` on both encode and decode**.

- **The full proto3 language** — messages, enums, `optional`, `repeated`,
  `map`, `oneof`, nested types, `import` with embedded well-known types,
  unknown-field preservation, services
- **Deterministic encoding** — same message, same bytes, every time
- **Canonical JSON** (protojson) with the spec's WKT special forms
- **gRPC client + [Connect](https://connectrpc.com) server codegen** for
  [we-be/grpc.v](https://github.com/we-be/grpc.v)
- **Passes the official protobuf conformance suite** — 1468/1468 applicable
  proto3 cases, 0 unexpected failures (see [`conformance/`](conformance/))
- **Recursive messages** (`descriptor.proto`-style self-references) and proto3
  message-merge semantics
- **Five independent oracles** — protoc, protobuf-go's protojson, the official
  conformance runner, and (in grpc.v's CI) live grpc-go and connect-go peers

## Stability

**1.0 — the public API is stable and follows [SemVer](https://semver.org).** The
contract covers the generated message surface (`encode`/`decode`/`json`/
`from_json`/`to_any`/`as_time`…), the generated enums and oneof sum types, and
`protobuf.Encoder`/`Decoder`/`WireType`/`zigzag_*`. The `protobuf.json_*` helpers
are `pub` only so generated code can reach them across modules — they are
runtime-internal and may change. See [`CHANGELOG.md`](CHANGELOG.md).

## Quickstart

```sh
v install --git https://github.com/we-be/protobuf.v
```

Write a schema:

```proto
// ping.proto
syntax = "proto3";

import "google/protobuf/timestamp.proto";

message Ping {
  string host = 1;
  google.protobuf.Timestamp at = 2;
  map<string, int64> latencies_ns = 3;
  oneof result {
    int32 code = 4;
    string error = 5;
  }
}
```

Generate (or grab a prebuilt `vpbgen` from
[releases](https://github.com/we-be/protobuf.v/releases)):

```sh
v run ~/.vmodules/protobuf/cmd/vpbgen -m main -json -o ping_pb.v ping.proto
```

Use it:

```v
import time

p := Ping{
	host:         'example.com'
	at:           GoogleProtobuf_Timestamp.from_time(time.now())
	latencies_ns: {
		'p50': i64(1_200_000)
	}
	result:       Ping_Code{
		value: 200
	}
}

bin := p.encode() // deterministic wire bytes
q := Ping.decode(bin)! // and back — q == p

j := p.json() // {"host":"example.com","at":"2026-08-08T…Z","latenciesNs":{"p50":"1200000"},"code":200}
r := Ping.from_json(j)!

if res := q.result {
	match res {
		Ping_Code { println('code ${res.value}') }
		Ping_Error { println('error ${res.value}') }
	}
}
```

### vpbgen

```
vpbgen [-m module] [-I dir]... [-json] [-o out_pb.v] [-grpc out_grpc.v] schema.proto
```

| flag | effect |
|---|---|
| `-m module` | module name for the generated file (default `main`) |
| `-I dir` | import search path, repeatable, tried in order |
| `-o out.v` | write message code here (stdout if omitted) |
| `-json` | add canonical-JSON `json()` / `from_json()` methods |
| `-grpc out.v` | also emit gRPC client stubs + Connect server glue for the file's services |

Imports resolve against `-I` dirs, then the schema's own directory, then
embedded copies of the `google/protobuf` well-known types — so
`import "google/protobuf/timestamp.proto"` needs no files on disk. Output
is self-contained (imported types are generated in), so run vpbgen once
per V module.

## Performance

Paired V and Go harnesses over the same schema — identical deterministic
data, identical timing methodology, byte-identical output verified — in
[bench/](bench). V/Go time, lower is faster than Go (Go 1.26,
protobuf-go v1.36.11, V `-prod`):

| payload | encode | decode |
|---|---|---|
| 86 B | **0.25** | **0.37** |
| 15 KB | **0.31** | **0.32** |
| 1.6 MB | **0.49** | **0.38** |

The schema exercises maps, a oneof, and a Timestamp submessage — and the
gap *widened* when those were added: Go pays a heap pointer per submessage
and an interface box per oneof arm; V's inline structs and boxed sum types
don't. The design behind it: single-pass encoding into one exactly-sized
buffer (`encoded_size()` + `encode_to()`, no length backpatching), `&`
receivers on generated methods, a decode path that borrows sub-buffers
(`read_view`) instead of cloning them, and a single-byte-varint fast path
so the common tag/field read skips the loop. CI attaches a fresh
benchmark report to every release.

Ratios are hardware-dependent, and we report both rather than cherry-pick.
On desktop cores (Zen 2 above, including pinned to 4 CPUs) V wins every
cell. On GitHub's shared Azure vCPUs encode wins comfortably (0.50–0.69),
and decode wins for realistic payloads too — 0.79 at 15 KB, 0.82 at 1.6 MB
— with only sub-100-byte decode at ~1.1× Go, where fixed per-call setup
dominates. CI runs the full benchmark on every push with per-op regression
gates, prints the runner's table to the log, and fails the build if either
path slows relative to Go.

## What generates to what

| proto3 | V |
|---|---|
| `message`, nested types | struct, flattened names (`Person.Phone` → `Person_Phone`) |
| scalars | native types; zero values elided on the wire |
| `optional`, message fields | `?T` — absent is distinguishable from zero |
| `repeated` | `[]T`, packed by default, `[packed = false]` honored |
| `map<K, V>` | `map[K]V`; entries encode sorted by key (deterministic) |
| `oneof` | sum type over per-arm wrapper structs, `match`-friendly; a set arm encodes even at its zero value |
| `enum` | V enum, open — unknown values survive roundtrips |
| `import` | cross-package references; foreign packages get a CamelCase prefix (`google.protobuf.Timestamp` → `GoogleProtobuf_Timestamp`) |
| `Timestamp`, `Duration` | `as_time()`/`from_time()` ↔ `time.Time`, `as_duration()`/`from_duration()` ↔ `time.Duration` (saturating, like protobuf-go) |
| unknown fields | preserved in `pb_unknown []u8`, re-emitted on encode — older schemas forward newer data losslessly |
| `Any` | when `google/protobuf/any.proto` is imported, every message gets `m.to_any()` and `T.from_any(any)!`; JSON does canonical `@type` expansion (fields spread for normal messages, `value`-wrapped for WKTs) via a resolver generated over the fileset — no runtime type registry |
| `[deprecated = true]` | field carries V's `@[deprecated]` attribute — the compiler warns on cross-module use |
| `service`/`rpc` | with `-grpc`: a `<Service>Client` (unary methods over `grpc.Client`) plus a `<Service>Handler` interface and dispatch struct for `grpc.ConnectServer` |

Canonical JSON (with `-json`) follows the protojson spec: lowerCamel names
(or an explicit `[json_name = "..."]` override; the original proto name is
also accepted on parse), 64-bit ints as strings, bytes as base64, enums by
name, defaults omitted except presence fields, and the WKT special forms —
RFC 3339 timestamps, `"1.5s"` durations, unwrapped wrappers, `Struct` as
plain JSON, camelCase field masks.

Known edges, stated plainly: `map<bool, …>` is rejected (V maps cannot key
on bool); an `Any` whose `type_url` names a type outside the generated
fileset can't be JSON-expanded, so it degrades to a raw
`{"@type", "value": <base64>}` form rather than erroring; unknown *JSON*
keys are ignored on parse; V's `==` includes `pb_unknown`; recursion
through singular message fields is rejected (repeated/map/oneof recursion
is fine).

## How it's validated

- **protoc byte oracle** ([interop/run.sh](interop/run.sh)): generated
  code encodes fuzzed messages over every feature; protoc decodes and
  re-encodes them; the bytes must match exactly, both directions.
- **protojson oracle**: Go's protojson must accept every JSON document we
  emit (and decode it `proto.Equal` to the binary), and we must parse
  every document it emits back to byte-identical re-encodings.
- **Live service oracles** (in [grpc.v](https://github.com/we-be/grpc.v)'s
  CI): the generated client runs against a real grpc-go server over
  TLS/HTTP-2, and connect-go clients run against the generated Connect
  server in both codecs.
- **Adversarial fuzzing**: decoder-level fuzz in `v test .`, plus
  generated-code fuzzing with bit-flipped, truncated, and spliced buffers
  — decode errors or succeeds, never panics.

```sh
v test .                # unit + fuzz
interop/run.sh          # protoc + protojson oracles, 300 messages
interop/run.sh 2000 7   # more messages, different seed
```

## The wire layer

The runtime under the generated code is small and policy-free — field
helpers write tag + value unconditionally, zero-elision is the generated
code's decision. You can target it by hand; generated code is exactly this
shape:

```v
import protobuf

struct Person {
mut:
	name string
	id   int
}

fn (p Person) encode() []u8 {
	mut e := protobuf.Encoder{}
	if p.name != '' {
		e.write_string_field(1, p.name)
	}
	if p.id != 0 {
		e.write_int32_field(2, p.id)
	}
	return e.buf
}

fn Person.decode(buf []u8) !Person {
	mut p := Person{}
	mut d := protobuf.Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 { p.name = d.read_string()! }
			2 { p.id = d.read_int32()! }
			else { d.skip(wt)! }
		}
	}
	return p
}
```

Decoding is defensive throughout: truncated or overlong varints, field
number 0, group wire types, and length prefixes past the buffer end are
errors, never panics. Public `read_bytes` copies, so decoded messages
never alias the input; sub-decoding borrows views internally.

## Example app

[examples/addressbook](examples/addressbook) — the protobuf tutorial app
as a V CLI whose data file protoc reads natively:

```sh
cd examples/addressbook
v run . add "Ada Lovelace" --email ada@analytical.uk --mobile +44-555-0100
v run . list
protoc --decode=tutorial.AddressBook addressbook.proto < addressbook.bin
```

For a full service built on this stack — vlang/leveldb storage behind a
Connect API, everything between generated — see
[grpc.v's kvd example](https://github.com/we-be/grpc.v/tree/main/examples/kvd).

## License

MIT
