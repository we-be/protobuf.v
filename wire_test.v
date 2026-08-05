module protobuf

// Golden byte vectors come from the protobuf.dev encoding docs
// (Test1..Test4 examples) plus hand-computed boundary cases.

struct VarintVector {
	v    u64
	data []u8
}

fn test_varint_goldens() ! {
	vectors := [
		VarintVector{0, [u8(0x00)]},
		VarintVector{1, [u8(0x01)]},
		VarintVector{127, [u8(0x7f)]},
		VarintVector{128, [u8(0x80), 0x01]},
		VarintVector{150, [u8(0x96), 0x01]},
		VarintVector{300, [u8(0xac), 0x02]},
		VarintVector{18446744073709551615, [u8(0xff), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
			0xff, 0x01]},
	]
	for vec in vectors {
		mut e := Encoder{}
		e.write_varint(vec.v)
		assert e.buf == vec.data, 'encode ${vec.v}'
		mut d := Decoder{
			buf: vec.data
		}
		assert d.read_varint()! == vec.v
		assert !d.more()
	}
}

fn test_varint_roundtrip_boundaries() ! {
	mut cases := []u64{}
	for k := u32(0); k <= 9; k++ {
		base := u64(1) << (7 * k)
		cases << base - 1
		cases << base
		cases << base + 1
	}
	cases << u64(0xFFFFFFFFFFFFFFFF)
	for v in cases {
		mut e := Encoder{}
		e.write_varint(v)
		mut d := Decoder{
			buf: e.buf
		}
		assert d.read_varint()! == v
		assert !d.more()
	}
}

fn test_zigzag() {
	assert zigzag_encode(0) == 0
	assert zigzag_encode(-1) == 1
	assert zigzag_encode(1) == 2
	assert zigzag_encode(-2) == 3
	assert zigzag_encode(2) == 4
	assert zigzag_encode(2147483647) == 4294967294
	assert zigzag_encode(-2147483648) == 4294967295
	assert zigzag_decode(zigzag_encode(-123456789)) == -123456789
	assert zigzag_encode(i64(-9223372036854775807) - 1) == 18446744073709551615
	assert zigzag_decode(18446744073709551615) == i64(-9223372036854775807) - 1
}

fn test_field_goldens() {
	// Test1 { int32 a = 1 } with a = 150 -> 08 96 01
	mut e1 := Encoder{}
	e1.write_int32_field(1, 150)
	assert e1.buf == [u8(0x08), 0x96, 0x01]

	// Test2 { string b = 2 } with b = "testing" -> 12 07 74 65 73 74 69 6e 67
	mut e2 := Encoder{}
	e2.write_string_field(2, 'testing')
	assert e2.buf == [u8(0x12), 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67]

	// Test3 { Test1 c = 3 } embedding a = 150 -> 1a 03 08 96 01
	mut e3 := Encoder{}
	e3.write_message_field(3, e1.buf)
	assert e3.buf == [u8(0x1a), 0x03, 0x08, 0x96, 0x01]

	// Test4 { repeated int32 d = 4 [packed] } with [3, 270, 86942]
	// -> 22 06 03 8e 02 9e a7 05
	mut packed := Encoder{}
	for v in [u64(3), 270, 86942] {
		packed.write_varint(v)
	}
	mut e4 := Encoder{}
	e4.write_bytes_field(4, packed.buf)
	assert e4.buf == [u8(0x22), 0x06, 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05]
}

fn test_packed_decode() ! {
	data := [u8(0x22), 0x06, 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05]
	mut d := Decoder{
		buf: data
	}
	field, wt := d.read_tag()!
	assert field == 4 && wt == .len_delim
	mut vals := []int{}
	mut sub := Decoder{
		buf: d.read_bytes()!
	}
	for sub.more() {
		vals << sub.read_int32()!
	}
	assert vals == [3, 270, 86942]
}

fn test_negative_int32_sign_extends() ! {
	mut e := Encoder{}
	e.write_int32_field(1, -1)
	assert e.buf == [u8(0x08), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
	mut d := Decoder{
		buf: e.buf
	}
	f, wt := d.read_tag()!
	assert f == 1 && wt == .varint
	assert d.read_int32()! == -1
}

fn test_sint_fields() ! {
	mut e := Encoder{}
	e.write_sint32_field(1, -1)
	assert e.buf == [u8(0x08), 0x01]
	mut d := Decoder{
		buf: e.buf
	}
	_, _ := d.read_tag()!
	assert d.read_sint32()! == -1

	mut e2 := Encoder{}
	e2.write_sint64_field(1, -123456789012345)
	mut d2 := Decoder{
		buf: e2.buf
	}
	_, _ := d2.read_tag()!
	assert d2.read_sint64()! == -123456789012345
}

fn test_float_double() ! {
	// double a = 1 with 1.0: tag 09, bits 3FF0000000000000 little-endian
	mut e := Encoder{}
	e.write_double_field(1, 1.0)
	assert e.buf == [u8(0x09), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f]
	mut d := Decoder{
		buf: e.buf
	}
	_, wt := d.read_tag()!
	assert wt == .fixed64
	assert d.read_double()! == 1.0

	// float b = 2 with 1.5: tag 15, bits 3FC00000 little-endian
	mut e2 := Encoder{}
	e2.write_float_field(2, 1.5)
	assert e2.buf == [u8(0x15), 0x00, 0x00, 0xc0, 0x3f]
	mut d2 := Decoder{
		buf: e2.buf
	}
	_, _ := d2.read_tag()!
	assert d2.read_float()! == 1.5
}

fn test_fixed_goldens() ! {
	mut e := Encoder{}
	e.write_fixed32_field(1, u32(0xDEADBEEF))
	assert e.buf == [u8(0x0d), 0xef, 0xbe, 0xad, 0xde]
	mut d := Decoder{
		buf: e.buf
	}
	_, wt := d.read_tag()!
	assert wt == .fixed32
	assert d.read_fixed32()! == u32(0xDEADBEEF)

	mut e2 := Encoder{}
	e2.write_fixed64_field(2, u64(0x0123456789ABCDEF))
	mut d2 := Decoder{
		buf: e2.buf
	}
	_, wt2 := d2.read_tag()!
	assert wt2 == .fixed64
	assert d2.read_fixed64()! == u64(0x0123456789ABCDEF)
}

fn test_multibyte_tag() ! {
	// field 16 is the first tag needing two bytes: 16<<3 = 128
	mut e := Encoder{}
	e.write_tag(16, .varint)
	assert e.buf == [u8(0x80), 0x01]

	// max field number 2^29 - 1
	mut e2 := Encoder{}
	e2.write_tag(536870911, .varint)
	mut d := Decoder{
		buf: e2.buf
	}
	f, _ := d.read_tag()!
	assert f == 536870911
}

// TestPerson mirrors the shape codegen will emit for a proto3 message.
struct TestPerson {
mut:
	name   string
	id     int
	email  string
	phones []string
}

fn (p TestPerson) encode() []u8 {
	mut e := Encoder{}
	if p.name != '' {
		e.write_string_field(1, p.name)
	}
	if p.id != 0 {
		e.write_int32_field(2, p.id)
	}
	if p.email != '' {
		e.write_string_field(3, p.email)
	}
	for ph in p.phones {
		e.write_string_field(4, ph)
	}
	return e.buf
}

fn TestPerson.decode(buf []u8) !TestPerson {
	mut p := TestPerson{}
	mut d := Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 { p.name = d.read_string()! }
			2 { p.id = d.read_int32()! }
			3 { p.email = d.read_string()! }
			4 { p.phones << d.read_string()! }
			else { d.skip(wt)! }
		}
	}
	return p
}

fn test_message_roundtrip() ! {
	p := TestPerson{
		name:   'Hunter'
		id:     42
		email:  'hunterjsb@gmail.com'
		phones: ['+1-555-0100', '+1-555-0199']
	}
	got := TestPerson.decode(p.encode())!
	assert got == p
}

fn test_unknown_fields_skipped() ! {
	mut e := Encoder{}
	e.write_string_field(1, 'Hunter')
	e.write_uint64_field(99, 12345)
	e.write_bytes_field(100, [u8(1), 2, 3])
	e.write_fixed32_field(101, 7)
	e.write_double_field(102, 3.14)
	e.write_int32_field(2, 7)
	p := TestPerson.decode(e.buf)!
	assert p.name == 'Hunter'
	assert p.id == 7
}

fn expect_varint_error(data []u8) bool {
	mut d := Decoder{
		buf: data
	}
	_ := d.read_varint() or { return true }
	return false
}

fn expect_tag_error(data []u8) bool {
	mut d := Decoder{
		buf: data
	}
	_, _ := d.read_tag() or { return true }
	return false
}

fn test_malformed_varints() {
	assert expect_varint_error([]u8{})
	assert expect_varint_error([u8(0x80)])
	assert expect_varint_error([u8(0x80), 0x80])
	// 11-byte varint
	assert expect_varint_error([u8(0xff), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		0x01])
}

fn test_bad_tags() {
	assert expect_tag_error([u8(0x00)]) // field 0
	assert expect_tag_error([u8(0x0b)]) // group start, wire type 3
	assert expect_tag_error([u8(0x0c)]) // group end, wire type 4
	assert expect_tag_error([u8(0x0e)]) // wire type 6
	assert expect_tag_error([u8(0x0f)]) // wire type 7
}

fn test_truncated_len_payload() ! {
	// string field claims 5 bytes, only 1 present
	mut d := Decoder{
		buf: [u8(0x12), 0x05, 0x61]
	}
	_, _ := d.read_tag()!
	if s := d.read_string() {
		assert false, 'expected error, got "${s}"'
	}
	// skip must hit the same wall
	mut d2 := Decoder{
		buf: [u8(0x12), 0x05, 0x61]
	}
	_, wt := d2.read_tag()!
	if _ := d2.skip(wt) {
		assert false, 'expected skip error'
	}
}
