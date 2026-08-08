# protobuf

[![CI](https://github.com/we-be/protobuf.v/actions/workflows/ci.yml/badge.svg)](https://github.com/we-be/protobuf.v/actions/workflows/ci.yml)

Protocol Buffers (proto3) for V. Wire-format runtime today; `.proto` → V code generation next.

## Install

```sh
v install --git https://github.com/we-be/protobuf.v
```

Then:

```v
import protobuf
```

Why: V has no maintained protobuf library — [vproto](https://github.com/emily33901/vproto) has been abandoned since 2022 and breaks against current compilers, protobuf-v never worked. Things worth building in V (a sqlc plugin, gRPC once V's HTTP/2 lands) speak protobuf.

## Status

- [x] Wire runtime: varints, zigzag, fixed32/64, length-delimited, tags, unknown-field skipping
- [x] Cross-validated against protoc (`interop/run.sh`): 300 fuzzed messages over every scalar type, byte-for-byte identical serialization both directions
- [x] Decoder fuzzing: 17k random/mutated buffers, errors only, no crashes
- [x] PoC app: [examples/addressbook](examples/addressbook) — CLI whose data file protoc reads natively, and vice versa
- [x] `.proto` → V codegen (`cmd/vpbgen`): messages, nested types, enums, repeated/packed, `optional` — validated against protoc by the same byte oracle
- [x] `map<K, V>` fields → `map[K]V` (`map<bool, ...>` is rejected: V maps cannot key on bool)
- [ ] oneof

## Usage

Generate V code from a `.proto` file:

```sh
v run cmd/vpbgen -m main -o person_pb.v person.proto
```

Every message becomes a struct with `encode() []u8` and a static `decode(buf) !T`. Proto3 semantics carry over: `optional` scalars and singular message fields map to `?T` (absent ≠ zero), enums are open (unknown values survive roundtrips), repeated scalars are packed unless `[packed = false]`, and `map<K, V>` fields become `map[K]V` (entries serialize sorted by key, so encoding is deterministic).

The generated code is exactly this shape, which you can also write by hand against the wire runtime:

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

## Design

- **Policy-free wire layer.** Field helpers write tag + value unconditionally; proto3 zero-elision is the generated code's decision, not the runtime's.
- **Single-pass encoding, no length backpatching.** Generated `encoded_size()` computes the exact wire size, `encode()` allocates one right-sized buffer, and `encode_to()` writes everything in a single pass — no per-submessage temporaries. Generated methods take `&` receivers, which sidesteps a V codegen pathology where loops over by-value receivers emit a per-iteration GC-keepalive walk of the whole struct (quadratic on large repeated fields). Hand-written wire code can still embed pre-encoded buffers via `write_message_field` / `write_bytes_field`.
- **Defensive decoding.** Truncated varints, overlong varints (>10 bytes), field number 0, deprecated group wire types, and length prefixes past the end of the buffer are all errors, never panics.
- **Copies, not views.** `read_bytes` clones, so decoded messages never alias the input buffer.

## Tests

Golden byte vectors from the [protobuf encoding docs](https://protobuf.dev/programming-guides/encoding/), boundary roundtrips, malformed-input cases, and deterministic decoder fuzzing:

```sh
v test .
```

The interop suite uses protoc as an oracle — vpbgen-generated code encodes fuzzed messages, protoc decodes and re-encodes them, bytes must match exactly, then the generated decoder reads protoc's bytes back to the original values:

```sh
interop/run.sh          # 300 messages, seed 42
interop/run.sh 1000 7   # more messages, different seed
```

## Benchmarks

[bench/](bench) holds paired V and Go harnesses over the same schema — identical deterministic data, identical timing methodology — measuring against `google.golang.org/protobuf` and verifying both implementations produce byte-identical encodings. `bench/run.sh` writes a full report; CI attaches a fresh one to every release.

From a local run (Go 1.26, protobuf-go v1.36.11, V `-prod`; V/Go time, lower = V faster):

| payload | encode | decode |
|---|---|---|
| 77 B | 0.49 | 0.69 |
| 10 KB | 0.74 | 0.90 |
| 1 MB | 0.75 | 1.03 |

Encode beats Go at every size; decode sits at parity or better. This relies on the single-pass `encoded_size()`/`encode_to()` design plus `&` receivers on generated methods (see Design) — an earlier draft with by-value receivers and per-submessage buffers was 243× slower than Go on the 1 MB encode.

## Example

[examples/addressbook](examples/addressbook) — the classic protobuf tutorial app as a V CLI. Its data file is a real `tutorial.AddressBook`:

```sh
cd examples/addressbook
v run . add "Ada Lovelace" --email ada@analytical.uk --mobile +44-555-0100
v run . list
protoc --decode=tutorial.AddressBook addressbook.proto < addressbook.bin
```
