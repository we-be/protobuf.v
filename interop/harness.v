// Interop harness, driven by run.sh:
//   gen <dir> <count> <seed>    encode known + fuzzed Scalars to <dir>
//   check <dir> <count> <seed>  decode protoc's re-encodings, compare
// check regenerates the same PRNG sequence, so any drift between what we
// encoded and what protoc round-tripped shows up as a value or byte diff.
module main

import os
import protobuf

struct Rng {
mut:
	state u64
}

fn (mut r Rng) next() u64 {
	r.state += u64(0x9E3779B97F4A7C15)
	mut z := r.state
	z = (z ^ (z >> 30)) * u64(0xBF58476D1CE4E5B9)
	z = (z ^ (z >> 27)) * u64(0x94D049BB133111EB)
	return z ^ (z >> 31)
}

fn (mut r Rng) below(n int) int {
	return int(r.next() % u64(n))
}

fn (mut r Rng) chance(pct int) bool {
	return r.below(100) < pct
}

struct Nested {
mut:
	name string
	num  int
}

struct Scalars {
mut:
	a          int
	b          i64
	c          u32
	d          u64
	e          int
	f          i64
	g          bool
	h          string
	i          []u8
	j          f32
	k          f64
	l          u32
	m          u64
	n          int
	o          i64
	p          int
	rp         []int
	rs         []string
	has_nested bool
	nested     Nested
	rn         []Nested
}

fn (n Nested) encode() []u8 {
	mut e := protobuf.Encoder{}
	if n.name != '' {
		e.write_string_field(1, n.name)
	}
	if n.num != 0 {
		e.write_int32_field(2, n.num)
	}
	return e.buf
}

fn Nested.decode(buf []u8) !Nested {
	mut n := Nested{}
	mut d := protobuf.Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 { n.name = d.read_string()! }
			2 { n.num = d.read_int32()! }
			else { d.skip(wt)! }
		}
	}
	return n
}

// Fields in ascending number order with proto3 zero-elision, matching
// protoc's serialization so the oracle can compare byte-for-byte.
fn (s Scalars) encode() []u8 {
	mut e := protobuf.Encoder{}
	if s.a != 0 {
		e.write_int32_field(1, s.a)
	}
	if s.b != 0 {
		e.write_int64_field(2, s.b)
	}
	if s.c != 0 {
		e.write_uint32_field(3, s.c)
	}
	if s.d != 0 {
		e.write_uint64_field(4, s.d)
	}
	if s.e != 0 {
		e.write_sint32_field(5, s.e)
	}
	if s.f != 0 {
		e.write_sint64_field(6, s.f)
	}
	if s.g {
		e.write_bool_field(7, s.g)
	}
	if s.h != '' {
		e.write_string_field(8, s.h)
	}
	if s.i.len > 0 {
		e.write_bytes_field(9, s.i)
	}
	if s.j != 0 {
		e.write_float_field(10, s.j)
	}
	if s.k != 0 {
		e.write_double_field(11, s.k)
	}
	if s.l != 0 {
		e.write_fixed32_field(12, s.l)
	}
	if s.m != 0 {
		e.write_fixed64_field(13, s.m)
	}
	if s.n != 0 {
		e.write_sfixed32_field(14, s.n)
	}
	if s.o != 0 {
		e.write_sfixed64_field(15, s.o)
	}
	if s.p != 0 {
		e.write_int32_field(16, s.p)
	}
	if s.rp.len > 0 {
		mut packed := protobuf.Encoder{}
		for v in s.rp {
			packed.write_varint(u64(i64(v)))
		}
		e.write_bytes_field(17, packed.buf)
	}
	for v in s.rs {
		e.write_string_field(18, v)
	}
	if s.has_nested {
		e.write_message_field(19, s.nested.encode())
	}
	for n in s.rn {
		e.write_message_field(20, n.encode())
	}
	return e.buf
}

fn Scalars.decode(buf []u8) !Scalars {
	mut s := Scalars{}
	mut d := protobuf.Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 {
				s.a = d.read_int32()!
			}
			2 {
				s.b = d.read_int64()!
			}
			3 {
				s.c = d.read_uint32()!
			}
			4 {
				s.d = d.read_uint64()!
			}
			5 {
				s.e = d.read_sint32()!
			}
			6 {
				s.f = d.read_sint64()!
			}
			7 {
				s.g = d.read_bool()!
			}
			8 {
				s.h = d.read_string()!
			}
			9 {
				s.i = d.read_bytes()!
			}
			10 {
				s.j = d.read_float()!
			}
			11 {
				s.k = d.read_double()!
			}
			12 {
				s.l = d.read_fixed32()!
			}
			13 {
				s.m = d.read_fixed64()!
			}
			14 {
				s.n = d.read_sfixed32()!
			}
			15 {
				s.o = d.read_sfixed64()!
			}
			16 {
				s.p = d.read_int32()!
			}
			17 {
				// proto3 parsers accept packed or expanded repeated scalars
				if wt == .len_delim {
					mut sub := protobuf.Decoder{
						buf: d.read_bytes()!
					}
					for sub.more() {
						s.rp << sub.read_int32()!
					}
				} else {
					s.rp << d.read_int32()!
				}
			}
			18 {
				s.rs << d.read_string()!
			}
			19 {
				s.nested = Nested.decode(d.read_bytes()!)!
				s.has_nested = true
			}
			20 {
				s.rn << Nested.decode(d.read_bytes()!)!
			}
			else {
				d.skip(wt)!
			}
		}
	}
	return s
}

const tricky_i32 = [0, 1, -1, 127, 128, 300, 2147483647, -2147483648, 1000000, -1000000]
const tricky_i64 = [i64(0), 1, -1, 300, 9223372036854775807, i64(-9223372036854775807) - 1,
	123456789012345, -123456789012345]
const tricky_u32 = [u32(0), 1, 127, 128, 4294967295, 65536]
const tricky_u64 = [u64(0), 1, 18446744073709551615, 4294967296]
const string_pool = ['', 'a', 'hello', 'héllo wörld', '🚀🌍', '日本語テキスト',
	'line\nbreak', 'tab\there', 'quote"and\'quote']

fn (mut r Rng) i32val() int {
	return tricky_i32[r.below(tricky_i32.len)]
}

fn (mut r Rng) i64val() i64 {
	return tricky_i64[r.below(tricky_i64.len)]
}

fn (mut r Rng) strval() string {
	return string_pool[r.below(string_pool.len)]
}

fn gen_nested(mut r Rng) Nested {
	return Nested{
		name: r.strval()
		num:  r.i32val()
	}
}

fn gen_scalars(mut r Rng) Scalars {
	mut s := Scalars{}
	if r.chance(60) {
		s.a = r.i32val()
	}
	if r.chance(60) {
		s.b = r.i64val()
	}
	if r.chance(60) {
		s.c = tricky_u32[r.below(tricky_u32.len)]
	}
	if r.chance(60) {
		s.d = tricky_u64[r.below(tricky_u64.len)]
	}
	if r.chance(60) {
		s.e = r.i32val()
	}
	if r.chance(60) {
		s.f = r.i64val()
	}
	if r.chance(60) {
		s.g = true
	}
	if r.chance(60) {
		s.h = r.strval()
	}
	if r.chance(60) {
		n := r.below(20)
		for _ in 0 .. n {
			s.i << u8(r.next())
		}
	}
	// floats built from small ints over powers of two stay exact in
	// binary, text format, and back
	if r.chance(60) {
		s.j = f32(r.below(2000) - 1000) / f32(16.0)
	}
	if r.chance(60) {
		s.k = f64(r.below(2000000) - 1000000) / 64.0
	}
	if r.chance(60) {
		s.l = tricky_u32[r.below(tricky_u32.len)]
	}
	if r.chance(60) {
		s.m = tricky_u64[r.below(tricky_u64.len)]
	}
	if r.chance(60) {
		s.n = r.i32val()
	}
	if r.chance(60) {
		s.o = r.i64val()
	}
	if r.chance(60) {
		s.p = r.below(4)
	}
	if r.chance(50) {
		for _ in 0 .. r.below(6) {
			s.rp << r.i32val()
		}
	}
	if r.chance(50) {
		for _ in 0 .. r.below(4) {
			s.rs << r.strval()
		}
	}
	if r.chance(50) {
		s.has_nested = true
		s.nested = gen_nested(mut r)
	}
	if r.chance(40) {
		for _ in 0 .. r.below(3) {
			s.rn << gen_nested(mut r)
		}
	}
	return s
}

// Every field at an extreme value, plus an intentionally empty nested
// message in rn (empty messages still encode as LEN 0 under proto3).
fn known_scalars() Scalars {
	return Scalars{
		a:          -1
		b:          i64(-9223372036854775807) - 1
		c:          4294967295
		d:          18446744073709551615
		e:          -2147483648
		f:          i64(-9223372036854775807) - 1
		g:          true
		h:          'héllo 🌍 wörld'
		i:          [u8(0), 1, 255, 0, 127]
		j:          1.5
		k:          3.141592653589793
		l:          u32(0xDEADBEEF)
		m:          u64(0x0123456789ABCDEF)
		n:          -1
		o:          i64(-9223372036854775807) - 1
		p:          3
		rp:         [0, -1, 2147483647, -2147483648, 150]
		rs:         ['', 'a', '🚀']
		has_nested: true
		nested:     Nested{
			name: 'nested'
			num:  150
		}
		rn:         [Nested{}, Nested{
			name: 'x'
		}]
	}
}

fn eq(a Scalars, b Scalars) bool {
	return a == b
}

fn fail(msg string) {
	eprintln('FAIL: ${msg}')
	exit(1)
}

fn main() {
	if os.args.len < 5 {
		fail('usage: harness <gen|check> <dir> <count> <seed>')
	}
	mode := os.args[1]
	dir := os.args[2]
	count := os.args[3].int()
	seed := os.args[4].u64()
	mut r := Rng{
		state: seed
	}
	match mode {
		'gen' {
			os.write_file_array('${dir}/known.bin', known_scalars().encode())!
			for i in 0 .. count {
				os.write_file_array('${dir}/fuzz_${i}.bin', gen_scalars(mut r).encode())!
			}
			println('generated ${count} fuzz messages + known.bin')
		}
		'check' {
			known_pb := os.read_bytes('${dir}/known.protoc.bin')!
			known_dec := Scalars.decode(known_pb)!
			if !eq(known_dec, known_scalars()) {
				fail('known: decode of protoc bytes != expected struct')
			}
			if known_dec.encode() != known_pb {
				fail('known: re-encode != protoc bytes')
			}
			for i in 0 .. count {
				want := gen_scalars(mut r)
				pb := os.read_bytes('${dir}/fuzz_${i}.protoc.bin')!
				got := Scalars.decode(pb)!
				if !eq(got, want) {
					fail('fuzz_${i}: decode of protoc bytes != generated struct\nwant: ${want}\ngot:  ${got}')
				}
				if got.encode() != pb {
					fail('fuzz_${i}: re-encode != protoc bytes')
				}
			}
			println('checked ${count} fuzz messages + known.bin against protoc')
		}
		else {
			fail('unknown mode ${mode}')
		}
	}
}
