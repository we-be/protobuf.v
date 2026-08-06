module protobuf

import math

// Encoder builds a message via append-only writes. Field helpers write
// tag + value unconditionally; proto3 zero-elision is the caller's policy.
// No length backpatching: length prefixes are known up front — generated
// code sizes sub-messages via encoded_size(), hand-written code passes
// pre-encoded buffers to write_message_field / write_bytes_field.
pub struct Encoder {
pub mut:
	buf []u8
}

pub fn (mut e Encoder) write_varint(v u64) {
	mut x := v
	for x >= 0x80 {
		e.buf << u8(x & 0x7f | 0x80)
		x >>= 7
	}
	e.buf << u8(x)
}

pub fn (mut e Encoder) write_tag(field u32, wt WireType) {
	e.write_varint(u64(field) << 3 | u64(int(wt)))
}

pub fn (mut e Encoder) write_fixed32(v u32) {
	e.buf << u8(v)
	e.buf << u8(v >> 8)
	e.buf << u8(v >> 16)
	e.buf << u8(v >> 24)
}

pub fn (mut e Encoder) write_fixed64(v u64) {
	e.write_fixed32(u32(v))
	e.write_fixed32(u32(v >> 32))
}

pub fn (mut e Encoder) write_len_prefixed(b []u8) {
	e.write_varint(u64(b.len))
	e.buf << b
}

// untagged float writes, for packed repeated payloads
pub fn (mut e Encoder) write_f32(v f32) {
	e.write_fixed32(math.f32_bits(v))
}

pub fn (mut e Encoder) write_f64(v f64) {
	e.write_fixed64(math.f64_bits(v))
}

// int32/int64/enum negatives sign-extend to 64 bits: always 10 bytes on the wire.
pub fn (mut e Encoder) write_int32_field(field u32, v int) {
	e.write_tag(field, .varint)
	e.write_varint(u64(i64(v)))
}

pub fn (mut e Encoder) write_int64_field(field u32, v i64) {
	e.write_tag(field, .varint)
	e.write_varint(u64(v))
}

pub fn (mut e Encoder) write_uint32_field(field u32, v u32) {
	e.write_tag(field, .varint)
	e.write_varint(u64(v))
}

pub fn (mut e Encoder) write_uint64_field(field u32, v u64) {
	e.write_tag(field, .varint)
	e.write_varint(v)
}

pub fn (mut e Encoder) write_sint32_field(field u32, v int) {
	e.write_tag(field, .varint)
	e.write_varint(zigzag_encode(i64(v)))
}

pub fn (mut e Encoder) write_sint64_field(field u32, v i64) {
	e.write_tag(field, .varint)
	e.write_varint(zigzag_encode(v))
}

pub fn (mut e Encoder) write_bool_field(field u32, v bool) {
	e.write_tag(field, .varint)
	e.write_varint(if v { u64(1) } else { u64(0) })
}

pub fn (mut e Encoder) write_string_field(field u32, s string) {
	e.write_tag(field, .len_delim)
	e.write_varint(u64(s.len))
	// append straight from the string's storage — s.bytes() would clone
	unsafe { e.buf.push_many(s.str, s.len) }
}

pub fn (mut e Encoder) write_bytes_field(field u32, b []u8) {
	e.write_tag(field, .len_delim)
	e.write_len_prefixed(b)
}

pub fn (mut e Encoder) write_message_field(field u32, encoded []u8) {
	e.write_bytes_field(field, encoded)
}

pub fn (mut e Encoder) write_float_field(field u32, v f32) {
	e.write_tag(field, .fixed32)
	e.write_fixed32(math.f32_bits(v))
}

pub fn (mut e Encoder) write_double_field(field u32, v f64) {
	e.write_tag(field, .fixed64)
	e.write_fixed64(math.f64_bits(v))
}

pub fn (mut e Encoder) write_fixed32_field(field u32, v u32) {
	e.write_tag(field, .fixed32)
	e.write_fixed32(v)
}

pub fn (mut e Encoder) write_fixed64_field(field u32, v u64) {
	e.write_tag(field, .fixed64)
	e.write_fixed64(v)
}

pub fn (mut e Encoder) write_sfixed32_field(field u32, v int) {
	e.write_tag(field, .fixed32)
	e.write_fixed32(u32(v))
}

pub fn (mut e Encoder) write_sfixed64_field(field u32, v i64) {
	e.write_tag(field, .fixed64)
	e.write_fixed64(u64(v))
}
