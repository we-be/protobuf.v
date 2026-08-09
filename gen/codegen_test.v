module gen

import os

const demo_src = '
syntax = "proto3";

package demo;

enum PersonKind {
	PERSON_KIND_UNSPECIFIED = 0;
	PERSON_KIND_USER = 1;
	PERSON_KIND_ADMIN = 2;
}

message Person {
	string name = 1;
	int32 id = 2;
	repeated int32 scores = 3;
	repeated string tags = 4;
	bytes data = 5;
	double ratio = 6;
	PersonKind kind = 7;
	optional int32 opt_rank = 8;
	Address home = 9;
	repeated Address addrs = 10;
	repeated int32 unpacked = 11 [packed = false];
	sint64 delta = 12;
	fixed32 checksum = 13;
	map<string, int32> attrs = 14;
	map<int32, Address> places = 15;
	map<uint64, PersonKind> kinds = 16;
	map<string, bool> flags = 17;

	oneof contact {
		string handle = 18;
		Address extra = 19;
		int32 ext = 20;
	}

	message Address {
		string street = 1;
		int32 zip = 2;
	}
}
'

const harness_src = "
fn main() {
	p := Person{
		name:     'Ada 🚀'
		id:       -42
		scores:   [1, -1, 2147483647]
		tags:     ['a', '']
		data:     [u8(0), 255]
		ratio:    1.5
		kind:     .person_kind_admin
		opt_rank: 0
		home:     Person_Address{
			street: 'x'
		}
		addrs:    [Person_Address{
			street: 'y'
		}, Person_Address{}]
		unpacked: [7, 8]
		delta:    -123456789
		checksum: 42
		attrs:    {
			'x': 1
			'':  0
		}
		places:   {
			3:  Person_Address{
				street: 'p'
			}
			-2: Person_Address{}
		}
		kinds:    {
			u64(5): PersonKind.person_kind_user
			u64(9): PersonKind.person_kind_unspecified
		}
		flags:    {
			't': true
			'f': false
		}
		// zero-valued arm: oneof presence must survive the roundtrip
		contact:  Person_Handle{}
	}
	enc := p.encode()
	q := Person.decode(enc) or { panic(err) }
	assert q == p
	// re-encode must be byte-identical
	assert q.encode() == enc
	// insertion order must not leak into the encoding: same entries,
	// reversed insertion, identical bytes
	mut p2 := p
	p2.attrs = {
		'':  0
		'x': 1
	}
	assert p2.encode() == enc
	// empty message: absent optional stays none, absent submessage stays none
	r := Person.decode(Person{}.encode()) or { panic(err) }
	assert r == Person{}
	assert r.opt_rank == none
	assert r.home == none
	assert r.attrs.len == 0
	assert r.contact == none
	// concatenated messages merge, so the last oneof arm on the wire wins
	mut p3 := Person{
		contact: Person_Extra{
			value: Person_Address{
				street: 's'
			}
		}
	}
	mut wire := p3.encode()
	wire << Person{
		contact: Person_Ext{
			value: 7
		}
	}.encode()
	q3 := Person.decode(wire) or { panic(err) }
	if c := q3.contact {
		assert c is Person_Ext
	} else {
		panic('oneof arm lost in merge')
	}
	println('ROUNDTRIP OK')
}
"

fn test_generate_structure() ! {
	f := parse(demo_src)!
	code := generate(f, GenOpts{ module_name: 'demopb' })!
	assert code.contains('module demopb')
	assert code.contains('pub enum PersonKind {')
	assert code.contains('person_kind_admin = 2')
	assert code.contains('pub struct Person {')
	assert code.contains('pub struct Person_Address {')
	assert code.contains('pub fn (m &Person) encode() []u8 {')
	assert code.contains('pub fn Person.decode(buf []u8) !Person {')
	assert code.contains('opt_rank ?int')
	assert code.contains('home ?Person_Address')
	assert code.contains('addrs []Person_Address')
	assert code.contains('delta i64')
	assert code.contains('checksum u32')
	assert code.contains('attrs map[string]int')
	assert code.contains('places map[int]Person_Address')
	assert code.contains('kinds map[u64]PersonKind')
	assert code.contains('flags map[string]bool')
	assert code.contains('pub struct Person_Handle {')
	assert code.contains('pub type Person_Contact = Person_Handle | Person_Extra | Person_Ext')
	assert code.contains('contact ?Person_Contact')
}

fn test_generated_roundtrip() ! {
	f := parse(demo_src)!
	code := generate(f, GenOpts{})!
	dir := os.join_path(os.temp_dir(), 'vpbgen_e2e_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'demo_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), harness_src)!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('ROUNDTRIP OK'), res.output
}

fn expect_gen_error(src string, want string) {
	f := parse(src) or {
		assert false, 'parse failed: ${err.msg()}'
		return
	}
	generate(f, GenOpts{}) or {
		assert err.msg().contains(want), 'got: ${err.msg()}'
		return
	}
	assert false, 'expected generate error containing "${want}"'
}

fn test_unknown_field_preservation_e2e() ! {
	f := parse('syntax = "proto3";
message Narrow {
	int32 keep = 1;
}
message Wide {
	int32 keep = 1;
	string extra_s = 2;
	repeated int32 extra_rp = 3;
	Narrow extra_m = 4;
	fixed64 extra_f = 5;
}
message Hollow {}')!
	code := generate(f, GenOpts{})!
	dir := os.join_path(os.temp_dir(), 'vpbgen_unknown_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'u_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), "fn main() {
	w := Wide{
		keep:     7
		extra_s:  'kept'
		extra_rp: [1, 2, 3]
		extra_m:  Narrow{
			keep: 9
		}
		extra_f:  u64(0xDEADBEEF)
	}
	enc := w.encode()
	// narrow decode keeps what it knows and preserves the rest
	n := Narrow.decode(enc) or { panic(err) }
	assert n.keep == 7
	assert n.pb_unknown.len > 0
	w2 := Wide.decode(n.encode()) or { panic(err) }
	assert w2 == w
	// a zero-field message must carry the whole payload byte-exactly
	h := Hollow.decode(enc) or { panic(err) }
	assert h.encode() == enc
	w3 := Wide.decode(h.encode()) or { panic(err) }
	assert w3 == w
	// no unknowns in a same-schema roundtrip
	assert Wide.decode(enc) or { panic(err) }.pb_unknown.len == 0
	println('UNKNOWN OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('UNKNOWN OK'), res.output
}

fn test_qualified_and_custom_option_codegen_e2e() ! {
	// leading-dot + qualified types with custom options must not just
	// parse — they must resolve and generate working code
	f := parse('syntax = "proto3";
package demo;
message Inner { int32 v = 1; }
message Outer {
	.demo.Inner a = 1 [(google.api.field_behavior) = REQUIRED];
	demo.Inner b = 2;
}')!
	code := generate(f, GenOpts{})!
	assert code.contains('a ?Inner')
	assert code.contains('b ?Inner')
	dir := os.join_path(os.temp_dir(), 'vpbgen_qual_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'q_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), "fn main() {
	o := Outer{
		a: Inner{ v: 7 }
		b: Inner{ v: 9 }
	}
	q := Outer.decode(o.encode()) or { panic(err) }
	assert q == o
	println('QUAL OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('QUAL OK'), res.output
}

fn test_map_bool_key_e2e() ! {
	// map<bool,V> has no V map-key type, so it is stored as map[int]V
	// (0=false, 1=true) yet stays true to bool on the wire and in JSON.
	f := parse('syntax = "proto3";
message Nested { int32 v = 1; }
message Rec {
	map<bool, int32> flags = 1;
	map<bool, string> names = 2;
	map<bool, Nested> nodes = 3;
}')!
	code := generate(f, GenOpts{ json: true })!
	assert code.contains('flags map[int]int')
	assert code.contains('names map[int]string')
	assert code.contains('nodes map[int]Nested')
	dir := os.join_path(os.temp_dir(), 'vpbgen_boolmap_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'b_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), "fn main() {
	m := Rec{
		flags: {
			0: 10
			1: 20
		}
		names: {
			1: 'yes'
		}
		nodes: {
			0: Nested{
				v: 5
			}
		}
	}
	// wire roundtrip, deterministic (false entry precedes true)
	enc := m.encode()
	m2 := Rec.decode(enc) or { panic(err) }
	assert m2 == m
	assert m2.encode() == enc
	// JSON roundtrip with canonical bool keys
	js := m.json()
	assert js.contains('\"false\"') && js.contains('\"true\"'), js
	m3 := Rec.from_json(js) or { panic(err) }
	assert m3 == m
	println('BOOLMAP OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('BOOLMAP OK'), res.output
}

fn test_deprecated_field_annotation() ! {
	f := parse('syntax = "proto3"; message M {
	int32 keep = 1;
	int32 old = 2 [deprecated = true];
	repeated string old_list = 3 [deprecated = true];
}')!
	code := generate(f, GenOpts{})!
	assert code.contains('old int @[deprecated]')
	assert code.contains('old_list []string @[deprecated]')
	// non-deprecated fields stay clean
	assert code.contains('keep int\n') || code.contains('\tkeep int\n')
	assert !code.contains('keep int @[deprecated]')
}

fn test_allow_alias_enum() ! {
	f := parse('syntax = "proto3";
enum Kind {
	option allow_alias = true;
	KIND_UNKNOWN = 0;
	KIND_A = 1;
	KIND_ALPHA = 1;
	KIND_B = 2;
}
message Holder { Kind k = 1; }')!
	code := generate(f, GenOpts{ json: true })!
	// only the first name per number becomes a V enum member (distinct values)
	assert code.contains('kind_a = 1')
	assert !code.contains('kind_alpha = 1')
	// but every alias name still parses back from JSON
	assert code.contains("'KIND_ALPHA'")
}

fn test_field_name_mangling_e2e() ! {
	// uppercase and leading-underscore proto names must become valid V
	// identifiers, used consistently across encode/decode/json
	f := parse('syntax = "proto3";
message Rec {
	int32 fieldName7 = 1;
	int32 FieldName8 = 2;
	int32 _leading = 3;
	int32 __two = 4;
}')!
	code := generate(f, GenOpts{ json: true })!
	assert code.contains('fieldname7 int')
	assert code.contains('fieldname8 int')
	assert code.contains('leading int')
	assert code.contains('two int')
	dir := os.join_path(os.temp_dir(), 'vpbgen_mangle_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'm_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), "fn main() {
	r := Rec{
		fieldname7: 7
		fieldname8: 8
		leading:    3
		two:        4
	}
	r2 := Rec.decode(r.encode()) or { panic(err) }
	assert r2 == r
	// JSON emit and parse must agree (they derive keys from the proto name)
	back := Rec.from_json(r.json()) or { panic(err) }
	assert back == r
	println('MANGLE OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('MANGLE OK'), res.output
}

fn test_gen_errors() {
	expect_gen_error('syntax = "proto3"; message M { Unknown u = 1; }', 'unknown type')
	expect_gen_error('syntax = "proto3"; enum E { A = 0; B = 0; }', 'allow_alias')
	expect_gen_error('syntax = "proto3"; service S { rpc M (A) returns (B); } message A { int32 x = 1; }',
		'unknown type')
	expect_gen_error('syntax = "proto3"; service S { rpc M (A) returns (E); } message A { int32 x = 1; } enum E { Z = 0; }',
		'must be a message')
	expect_gen_error('syntax = "proto3"; message M { int32 pb_unknown = 1; }', 'reserved')
}

fn test_repeated_self_reference_is_fine() ! {
	f := parse('syntax = "proto3"; message Node { int32 val = 1; repeated Node children = 2; }')!
	code := generate(f, GenOpts{})!
	assert code.contains('children []Node')
}

fn test_map_self_reference_is_fine() ! {
	f := parse('syntax = "proto3"; message Node { int32 val = 1; map<string, Node> kids = 2; }')!
	code := generate(f, GenOpts{})!
	assert code.contains('kids map[string]Node')
}

fn test_recursive_message_e2e() ! {
	// direct self-recursion (Node.next) and a mutual cycle (Branch<->Leaf).
	// the back-edge singular field is boxed as ?&T and a value == is generated.
	f := parse('syntax = "proto3";
message Node {
	int32 val = 1;
	Node next = 2;
}
message Branch {
	Leaf leaf = 1;
}
message Leaf {
	int32 v = 1;
	Branch back = 2;
}')!
	code := generate(f, GenOpts{ json: true })!
	assert code.contains('next ?&Node') // self-cycle back-edge boxed
	assert code.contains('leaf ?Leaf') // inline, not the back-edge
	assert code.contains('back ?&Branch') // mutual-cycle back-edge boxed
	assert code.contains('fn (a Node) == (b Node) bool')
	assert code.contains('fn (a Leaf) == (b Leaf) bool')
	dir := os.join_path(os.temp_dir(), 'vpbgen_rec_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'r_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), "fn main() {
	list := Node{
		val:  1
		next: &Node{
			val:  2
			next: &Node{
				val: 3
			}
		}
	}
	enc := list.encode()
	got := Node.decode(enc) or { panic(err) }
	// value equality across independent heap allocations, not pointer identity
	assert got == list
	assert got.encode() == enc
	assert got.next != none
	// JSON roundtrip through the recursion
	js := list.json()
	back := Node.from_json(js) or { panic(err) }
	assert back == list
	// differing deep content compares unequal
	other := Node{
		val:  1
		next: &Node{
			val: 99
		}
	}
	assert other != list
	println('REC OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('REC OK'), res.output
}

// sum types box their variants, so a oneof arm may recurse; prove it
// end-to-end since the recursion check waves it through
fn test_oneof_self_reference_e2e() ! {
	f :=
		parse('syntax = "proto3"; message Node { int32 val = 1; oneof next { Node child = 2; bool stop = 3; } }')!
	code := generate(f, GenOpts{})!
	dir := os.join_path(os.temp_dir(), 'vpbgen_oneof_rec_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'node_pb.v'), code)!
	os.write_file(os.join_path(dir, 'main.v'), "fn main() {
	n := Node{
		val:  1
		next: Node_Child{
			value: Node{
				val:  2
				next: Node_Stop{
					value: false
				}
			}
		}
	}
	q := Node.decode(n.encode()) or { panic(err) }
	assert q == n
	println('REC OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(dir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('REC OK'), res.output
}
