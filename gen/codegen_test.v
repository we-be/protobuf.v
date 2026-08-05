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
	}
	enc := p.encode()
	q := Person.decode(enc) or { panic(err) }
	assert q == p
	// re-encode must be byte-identical
	assert q.encode() == enc
	// empty message: absent optional stays none, absent submessage stays none
	r := Person.decode(Person{}.encode()) or { panic(err) }
	assert r == Person{}
	assert r.opt_rank == none
	assert r.home == none
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
	assert code.contains('pub fn (m Person) encode() []u8 {')
	assert code.contains('pub fn Person.decode(buf []u8) !Person {')
	assert code.contains('opt_rank ?int')
	assert code.contains('home ?Person_Address')
	assert code.contains('addrs []Person_Address')
	assert code.contains('delta i64')
	assert code.contains('checksum u32')
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

fn test_gen_errors() {
	expect_gen_error('syntax = "proto3"; message M { Unknown u = 1; }', 'unknown type')
	expect_gen_error('syntax = "proto3"; message Node { Node next = 1; }', 'recursive')
	expect_gen_error('syntax = "proto3"; message A { B b = 1; } message B { A a = 1; }',
		'recursive')
	expect_gen_error('syntax = "proto3"; enum E { A = 0; B = 0; }', 'allow_alias')
}

fn test_repeated_self_reference_is_fine() ! {
	f := parse('syntax = "proto3"; message Node { int32 val = 1; repeated Node children = 2; }')!
	code := generate(f, GenOpts{})!
	assert code.contains('children []Node')
}
