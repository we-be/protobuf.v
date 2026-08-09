module protobuf

import math

// Decoder walks a message buffer: read_tag, then a typed read per known
// field, skip() for unknown ones. read_bytes returns a copy, so decoded
// messages don't alias the input buffer. Nested messages, packed repeated
// fields, and map entries decode by looping a sub-Decoder over read_view
// output — borrowed, not copied, since leaf reads copy what they keep.
pub struct Decoder {
pub:
	buf []u8
pub mut:
	pos int
}

pub fn (d &Decoder) more() bool {
	return d.pos < d.buf.len
}

@[inline]
pub fn (mut d Decoder) read_varint() !u64 {
	// single-byte fast path: the overwhelmingly common case (small field
	// tags and values) skips the loop, shift, and continuation checks
	if d.pos < d.buf.len {
		b0 := d.buf[d.pos]
		if b0 & 0x80 == 0 {
			d.pos++
			return u64(b0)
		}
	}
	mut result := u64(0)
	mut shift := u32(0)
	for shift < 70 {
		if d.pos >= d.buf.len {
			return error('truncated varint')
		}
		b := d.buf[d.pos]
		d.pos++
		result |= u64(b & 0x7f) << shift
		if b & 0x80 == 0 {
			return result
		}
		shift += 7
	}
	return error('varint exceeds 10 bytes')
}

pub fn (mut d Decoder) read_tag() !(u32, WireType) {
	v := d.read_varint()!
	field := v >> 3
	if field == 0 || field > 0x1FFFFFFF {
		return error('invalid field number ${field}')
	}
	wt := wire_type_from(v & 7)!
	return u32(field), wt
}

pub fn (mut d Decoder) read_fixed32() !u32 {
	start := d.pos
	d.advance(4)!
	mut v := u32(d.buf[start])
	v |= u32(d.buf[start + 1]) << 8
	v |= u32(d.buf[start + 2]) << 16
	v |= u32(d.buf[start + 3]) << 24
	return v
}

pub fn (mut d Decoder) read_fixed64() !u64 {
	lo := d.read_fixed32()!
	hi := d.read_fixed32()!
	return u64(lo) | (u64(hi) << 32)
}

pub fn (mut d Decoder) read_bytes() ![]u8 {
	return d.read_view()!.clone()
}

// read_view is read_bytes without the copy: the slice aliases the decoder's
// buffer, so it must not outlive it. It exists for sub-decoding (nested
// messages, packed fields, map entries), where every retained value makes
// its own copy at the leaf anyway.
pub fn (mut d Decoder) read_view() ![]u8 {
	n := d.read_varint()!
	if n > u64(d.buf.len - d.pos) {
		return error('length ${n} exceeds remaining ${d.buf.len - d.pos} bytes')
	}
	start := d.pos
	d.advance(int(n))!
	return d.buf[start..d.pos]
}

pub fn (mut d Decoder) read_string() !string {
	// bytestr copies, so the view never escapes
	return d.read_view()!.bytestr()
}

// int32/int64 arrive sign-extended to 64 bits; truncation restores them.
pub fn (mut d Decoder) read_int32() !int {
	return int(d.read_varint()!)
}

pub fn (mut d Decoder) read_int64() !i64 {
	return i64(d.read_varint()!)
}

pub fn (mut d Decoder) read_uint32() !u32 {
	return u32(d.read_varint()!)
}

pub fn (mut d Decoder) read_uint64() !u64 {
	return d.read_varint()!
}

pub fn (mut d Decoder) read_sint32() !int {
	// sint32 truncates the wire varint to 32 bits BEFORE zigzag-decoding, per
	// protoc; bits above 32 must not survive into the result (else a value like
	// 0x1_FFFFFFFD would decode to 1 instead of -2147483647)
	return int(zigzag_decode(u64(u32(d.read_varint()!))))
}

pub fn (mut d Decoder) read_sint64() !i64 {
	return zigzag_decode(d.read_varint()!)
}

pub fn (mut d Decoder) read_sfixed32() !int {
	return int(d.read_fixed32()!)
}

pub fn (mut d Decoder) read_sfixed64() !i64 {
	return i64(d.read_fixed64()!)
}

pub fn (mut d Decoder) read_bool() !bool {
	return d.read_varint()! != 0
}

pub fn (mut d Decoder) read_float() !f32 {
	return math.f32_from_bits(d.read_fixed32()!)
}

pub fn (mut d Decoder) read_double() !f64 {
	return math.f64_from_bits(d.read_fixed64()!)
}

pub fn (mut d Decoder) skip(wt WireType) ! {
	match wt {
		.varint {
			_ := d.read_varint()!
		}
		.fixed64 {
			d.advance(8)!
		}
		.len_delim {
			n := d.read_varint()!
			if n > u64(d.buf.len - d.pos) {
				return error('length ${n} exceeds remaining ${d.buf.len - d.pos} bytes')
			}
			d.advance(int(n))!
		}
		.fixed32 {
			d.advance(4)!
		}
	}
}

fn (mut d Decoder) advance(n int) ! {
	if n < 0 || n > d.buf.len - d.pos {
		return error('truncated: need ${n} bytes, have ${d.buf.len - d.pos}')
	}
	d.pos += n
}
