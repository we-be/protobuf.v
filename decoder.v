module protobuf

import math

// Decoder walks a message buffer: read_tag, then a typed read per known
// field, skip() for unknown ones. read_bytes returns a copy, so decoded
// messages don't alias the input buffer. Nested messages and packed
// repeated fields decode by looping a sub-Decoder over read_bytes output.
pub struct Decoder {
pub:
	buf []u8
pub mut:
	pos int
}

pub fn (d &Decoder) more() bool {
	return d.pos < d.buf.len
}

pub fn (mut d Decoder) read_varint() !u64 {
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
	b := d.read_exact(4)!
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24)
}

pub fn (mut d Decoder) read_fixed64() !u64 {
	lo := d.read_fixed32()!
	hi := d.read_fixed32()!
	return u64(lo) | (u64(hi) << 32)
}

pub fn (mut d Decoder) read_bytes() ![]u8 {
	n := d.read_varint()!
	if n > u64(d.buf.len - d.pos) {
		return error('length ${n} exceeds remaining ${d.buf.len - d.pos} bytes')
	}
	return d.read_exact(int(n))
}

pub fn (mut d Decoder) read_string() !string {
	return d.read_bytes()!.bytestr()
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
	return int(zigzag_decode(d.read_varint()!))
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

fn (mut d Decoder) read_exact(n int) ![]u8 {
	start := d.pos
	d.advance(n)!
	return d.buf[start..d.pos].clone()
}
