module protobuf

// Deterministic decoder fuzz: random buffers and mutated valid encodings
// must come back as errors, never crashes. splitmix64 keeps runs reproducible.

struct FuzzRng {
mut:
	state u64
}

fn (mut r FuzzRng) next() u64 {
	r.state += u64(0x9E3779B97F4A7C15)
	mut z := r.state
	z = (z ^ (z >> 30)) * u64(0xBF58476D1CE4E5B9)
	z = (z ^ (z >> 27)) * u64(0x94D049BB133111EB)
	return z ^ (z >> 31)
}

// Walk a buffer the way generated decoders do: tag, then read or skip,
// recursing into len-delimited payloads as if they were sub-messages.
fn fuzz_walk(buf []u8, depth int) {
	mut d := Decoder{
		buf: buf
	}
	for d.more() {
		_, wt := d.read_tag() or { return }
		if wt == .len_delim && depth < 3 {
			sub := d.read_bytes() or { return }
			fuzz_walk(sub, depth + 1)
		} else {
			d.skip(wt) or { return }
		}
	}
}

fn test_fuzz_random_buffers() {
	mut r := FuzzRng{
		state: 42
	}
	for _ in 0 .. 5000 {
		n := int(r.next() % 64)
		mut buf := []u8{cap: n}
		for _ in 0 .. n {
			buf << u8(r.next())
		}
		fuzz_walk(buf, 0)
		mut d1 := Decoder{
			buf: buf
		}
		_ := d1.read_varint() or { u64(0) }
		mut d2 := Decoder{
			buf: buf
		}
		_ := d2.read_bytes() or { []u8{} }
		mut d3 := Decoder{
			buf: buf
		}
		_ := d3.read_fixed64() or { u64(0) }
	}
}

struct FuzzMsg {
mut:
	name   string
	id     int
	email  string
	phones []string
}

fn (p FuzzMsg) encode() []u8 {
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

fn FuzzMsg.decode(buf []u8) !FuzzMsg {
	mut p := FuzzMsg{}
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

fn test_fuzz_mutated_valid_encodings() {
	base := FuzzMsg{
		name:   'fuzz target'
		id:     999999
		email:  'fuzz@example.com'
		phones: ['1', '22', '333', '4444']
	}.encode()
	mut r := FuzzRng{
		state: 1337
	}
	for _ in 0 .. 5000 {
		mut buf := base.clone()
		for _ in 0 .. int(r.next() % 3) + 1 {
			idx := int(r.next() % u64(buf.len))
			buf[idx] = u8(r.next())
		}
		if r.next() % 4 == 0 {
			buf = buf[..int(r.next() % u64(buf.len + 1))].clone()
		}
		_ := FuzzMsg.decode(buf) or { FuzzMsg{} }
	}
}

fn test_fuzz_roundtrip_random_messages() ! {
	mut r := FuzzRng{
		state: 7
	}
	for _ in 0 .. 2000 {
		mut p := FuzzMsg{}
		if r.next() % 2 == 0 {
			p.name = 'n${r.next() % 1000}'
		}
		if r.next() % 2 == 0 {
			p.id = int(r.next())
		}
		if r.next() % 2 == 0 {
			p.email = 'e${r.next() % 1000}@x.io'
		}
		for _ in 0 .. r.next() % 4 {
			p.phones << '${r.next() % 100000}'
		}
		got := FuzzMsg.decode(p.encode())!
		assert got.name == p.name && got.email == p.email && got.phones == p.phones
		// id 0 elides on encode, so both sides agree on the default
		assert got.id == p.id || (p.id == 0 && got.id == 0)
	}
}
