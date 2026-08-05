# protobuf

Protocol Buffers (proto3) for V. Wire-format runtime today; `.proto` → V code generation next.

Why: V has no maintained protobuf library — [vproto](https://github.com/emily33901/vproto) has been abandoned since 2022 and breaks against current compilers, protobuf-v never worked. Things worth building in V (a sqlc plugin, gRPC once V's HTTP/2 lands) speak protobuf.

## Status

- [x] Wire runtime: varints, zigzag, fixed32/64, length-delimited, tags, unknown-field skipping
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

Golden byte vectors from the [protobuf encoding docs](https://protobuf.dev/programming-guides/encoding/), boundary roundtrips, and malformed-input cases:

```sh
v test .
```
