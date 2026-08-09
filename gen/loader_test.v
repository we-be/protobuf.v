module gen

import os

fn write_protos(dir string, files map[string]string) ! {
	os.mkdir_all(dir)!
	for name, src in files {
		os.mkdir_all(os.dir(os.join_path(dir, name)))!
		os.write_file(os.join_path(dir, name), src)!
	}
}

fn test_cross_file_same_package() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_same_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'a.proto': 'syntax = "proto3";
package kv;
import "b.proto";
message A { B b = 1; }'
		'b.proto': 'syntax = "proto3";
package kv;
message B { int32 x = 1; }'
	})!
	fs := load(os.join_path(dir, 'a.proto'), LoadOpts{})!
	assert fs.files.len == 2
	code := generate_set(fs, GenOpts{})!
	// same package as the root: bare names, and the field is unprefixed
	assert code.contains('pub struct A {')
	assert code.contains('pub struct B {')
	assert code.contains('b ?B')
}

fn test_cross_package_prefixing() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_xpkg_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'main.proto':         'syntax = "proto3";
package app;
import "common/types.proto";
message Wrapper { common.types.Id id = 1; }'
		'common/types.proto': 'syntax = "proto3";
package common.types;
message Id { string value = 1; }'
	})!
	fs := load(os.join_path(dir, 'main.proto'), LoadOpts{})!
	code := generate_set(fs, GenOpts{})!
	assert code.contains('pub struct Wrapper {')
	assert code.contains('pub struct CommonTypes_Id {')
	assert code.contains('id ?CommonTypes_Id')
}

fn test_diamond_import_deduped() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_diamond_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'root.proto':  'syntax = "proto3";
import "left.proto";
import "right.proto";
message R { L l = 1; Rt r = 2; }'
		'left.proto':  'syntax = "proto3";
import "base.proto";
message L { Base b = 1; }'
		'right.proto': 'syntax = "proto3";
import "base.proto";
message Rt { Base b = 1; }'
		'base.proto':  'syntax = "proto3";
message Base { int32 x = 1; }'
	})!
	fs := load(os.join_path(dir, 'root.proto'), LoadOpts{})!
	assert fs.files.len == 4
	code := generate_set(fs, GenOpts{})!
	assert code.count('pub struct Base {') == 1
}

fn test_import_cycle_rejected() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_cycle_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'a.proto': 'syntax = "proto3";
import "b.proto";'
		'b.proto': 'syntax = "proto3";
import "a.proto";'
	})!
	if _ := load(os.join_path(dir, 'a.proto'), LoadOpts{}) {
		assert false, 'cycle should fail'
	} else {
		assert err.msg().contains('cycle'), err.msg()
	}
}

fn test_missing_import() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_miss_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'a.proto': 'syntax = "proto3";
import "nope.proto";'
	})!
	if _ := load(os.join_path(dir, 'a.proto'), LoadOpts{}) {
		assert false, 'missing import should fail'
	} else {
		assert err.msg().contains('not found'), err.msg()
	}
}

fn test_search_paths() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_inc_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'proj/a.proto':     'syntax = "proto3";
import "shared.proto";
message A { S s = 1; }'
		'inc/shared.proto': 'syntax = "proto3";
message S { int32 x = 1; }'
	})!
	fs := load(os.join_path(dir, 'proj', 'a.proto'), LoadOpts{
		paths: [os.join_path(dir, 'inc')]
	})!
	assert fs.files.len == 2
}

fn test_embedded_wkt_import() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_load_wkt_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'ts.proto': 'syntax = "proto3";
import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";
import "google/protobuf/struct.proto";
message Event {
	google.protobuf.Timestamp at = 1;
	google.protobuf.Struct meta = 2;
}
service Ping {
	rpc Poke (google.protobuf.Empty) returns (Event);
}'
	})!
	fs := load(os.join_path(dir, 'ts.proto'), LoadOpts{})!
	code := generate_set(fs, GenOpts{})!
	assert code.contains('pub struct GoogleProtobuf_Timestamp {')
	assert code.contains('seconds i64')
	assert code.contains('at ?GoogleProtobuf_Timestamp')
	// struct.proto exercises map + oneof + recursion in one import
	assert code.contains('fields map[string]GoogleProtobuf_Value')
	assert code.contains('pub type GoogleProtobuf_Value_Kind =')
	stubs := generate_grpc_set(fs, GenOpts{})!
	assert stubs.contains('poke(req GoogleProtobuf_Empty) !Event {')
	// time mappings ride along with the WKT emission
	assert code.contains('import time')
	assert code.contains('pub fn (m &GoogleProtobuf_Timestamp) as_time() time.Time {')
	assert code.contains('pub fn GoogleProtobuf_Timestamp.from_time(t time.Time) GoogleProtobuf_Timestamp {')
}

fn test_any_pack_unpack_e2e() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_any_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'a.proto': 'syntax = "proto3";
package demo;
import "google/protobuf/any.proto";
message Point { int32 x = 1; int32 y = 2; }
message Envelope { string note = 1; google.protobuf.Any payload = 2; }
message Outer { message Inner { int32 v = 1; } }'
	})!
	fs := load(os.join_path(dir, 'a.proto'), LoadOpts{})!
	code := generate_set(fs, GenOpts{})!
	// the type_url carries the dotted proto full name, not the V name
	assert code.contains("type_url: 'type.googleapis.com/demo.Point'")
	assert code.contains('pub fn (m &Point) to_any() GoogleProtobuf_Any {')
	assert code.contains('pub fn Point.from_any(a GoogleProtobuf_Any) !Point {')
	// nested type: dotted proto path (pkg.Outer.Inner), V name Outer_Inner
	assert code.contains("type_url: 'type.googleapis.com/demo.Outer.Inner'")
	assert code.contains('pub fn (m &Outer_Inner) to_any() GoogleProtobuf_Any {')

	edir := os.join_path(dir, 'e2e')
	os.mkdir_all(edir)!
	os.write_file(os.join_path(edir, 'a_pb.v'), code)!
	os.write_file(os.join_path(edir, 'main.v'), "fn main() {
	p := Point{
		x: 3
		y: -7
	}
	any := p.to_any()
	assert any.type_url == 'type.googleapis.com/demo.Point'
	assert any.type_name() == 'demo.Point'
	// roundtrip through a real Envelope encode/decode
	env := Envelope{
		note:    'hi'
		payload: any
	}
	dec := Envelope.decode(env.encode()) or { panic(err) }
	got := dec.payload or { panic('no payload') }
	back := Point.from_any(got) or { panic(err) }
	assert back == p
	// wrong target type is refused, not silently mis-decoded
	if _ := Envelope.from_any(got) {
		panic('should have rejected type mismatch')
	}
	// a bare (host-less) type_url still resolves by name
	bare := GoogleProtobuf_Any{
		type_url: 'demo.Point'
		value:    p.encode()
	}
	assert Point.from_any(bare) or { panic(err) } == p
	println('ANY OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(edir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('ANY OK'), res.output
}

fn test_wkt_time_mappings_e2e() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_wkt_time_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	write_protos(dir, {
		'x.proto': 'syntax = "proto3";
import "google/protobuf/timestamp.proto";
import "google/protobuf/duration.proto";
message Span {
	google.protobuf.Timestamp at = 1;
	google.protobuf.Duration length = 2;
}'
	})!
	fs := load(os.join_path(dir, 'x.proto'), LoadOpts{})!
	code := generate_set(fs, GenOpts{})!
	edir := os.join_path(dir, 'e2e')
	os.mkdir_all(edir)!
	os.write_file(os.join_path(edir, 'x_pb.v'), code)!
	os.write_file(os.join_path(edir, 'main.v'), "fn main() {
	ts := GoogleProtobuf_Timestamp{
		seconds: 1700000000
		nanos:   123456789
	}
	t := ts.as_time()
	assert t.unix() == 1700000000
	assert GoogleProtobuf_Timestamp.from_time(t) == ts
	// pre-epoch: negative seconds, spec-positive nanos
	old := GoogleProtobuf_Timestamp{
		seconds: -1
		nanos:   500000000
	}
	assert GoogleProtobuf_Timestamp.from_time(old.as_time()) == old
	// duration: exact, negative, and roundtrip
	d := GoogleProtobuf_Duration{
		seconds: 90
		nanos:   500000000
	}
	assert i64(d.as_duration()) == 90500000000
	nd := GoogleProtobuf_Duration{
		seconds: -1
		nanos:   -500000000
	}
	assert i64(nd.as_duration()) == -1500000000
	assert GoogleProtobuf_Duration.from_duration(nd.as_duration()) == nd
	// saturation: far out, and the hair's-breadth case where seconds fit
	// in i64 nanos but seconds+nanos does not
	big := GoogleProtobuf_Duration{
		seconds: 315576000000
	}
	assert i64(big.as_duration()) == 9223372036854775807
	neg := GoogleProtobuf_Duration{
		seconds: -315576000000
	}
	assert i64(neg.as_duration()) == i64(-9223372036854775807) - 1
	edge := GoogleProtobuf_Duration{
		seconds: 9223372036
		nanos:   999999999
	}
	assert i64(edge.as_duration()) == 9223372036854775807
	println('WKT TIME OK')
}")!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(edir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('WKT TIME OK'), res.output
}
