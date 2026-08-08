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
}
