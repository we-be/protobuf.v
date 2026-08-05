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
- [ ] `.proto` parser + V codegen (proto3 subset: messages, nested messages, enums, repeated/packed)
- [ ] maps + oneof
- [ ] sqlc process-plugin PoC (protobuf `CodeGenRequest`/`CodeGenResponse` over stdin/stdout)

## Usage

Hand-written today, generated tomorrow — this is exactly the shape codegen will emit:

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
- **No length backpatching.** Sub-messages and packed repeated fields are encoded into their own buffer, then embedded with `write_message_field` / `write_bytes_field`.
- **Defensive decoding.** Truncated varints, overlong varints (>10 bytes), field number 0, deprecated group wire types, and length prefixes past the end of the buffer are all errors, never panics.
- **Copies, not views.** `read_bytes` clones, so decoded messages never alias the input buffer.

## Tests

Golden byte vectors from the [protobuf encoding docs](https://protobuf.dev/programming-guides/encoding/), boundary roundtrips, malformed-input cases, and deterministic decoder fuzzing:

```sh
v test .
```

The interop suite uses protoc as an oracle — V encodes fuzzed messages, protoc decodes and re-encodes them, bytes must match exactly, then V decodes protoc's bytes back to the original values:

```sh
interop/run.sh          # 300 messages, seed 42
interop/run.sh 1000 7   # more messages, different seed
```

## Example

[examples/addressbook](examples/addressbook) — the classic protobuf tutorial app as a V CLI. Its data file is a real `tutorial.AddressBook`:

```sh
cd examples/addressbook
v run . add "Ada Lovelace" --email ada@analytical.uk --mobile +44-555-0100
v run . list
protoc --decode=tutorial.AddressBook addressbook.proto < addressbook.bin
```
