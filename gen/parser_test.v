module gen

import os

const book_src = '
// tutorial addressbook, with a block comment /* nested-ish */ elsewhere
syntax = "proto3";

package tutorial;

option java_package = "com.example.tutorial";

message Person {
	string name = 1;
	int32 id = 2;
	string email = 3;

	enum PhoneType {
		PHONE_TYPE_UNSPECIFIED = 0;
		PHONE_TYPE_MOBILE = 1;
		PHONE_TYPE_HOME = 2;
		PHONE_TYPE_WORK = 3;
	}

	message PhoneNumber {
		string number = 1;
		PhoneType type = 2;
	}

	repeated PhoneNumber phones = 4;
	reserved 90, 91;
	repeated int32 lucky_numbers = 5 [packed = false, deprecated = true];
}

message AddressBook {
	repeated Person people = 1;
}
'

fn test_parse_addressbook() ! {
	f := parse(book_src)!
	assert f.package == 'tutorial'
	assert f.messages.len == 2
	person := f.messages[0]
	assert person.name == 'Person'
	assert person.fields.len == 5
	assert person.fields[0].typ == 'string' && person.fields[0].name == 'name'
	assert person.fields[0].number == 1
	assert person.fields[3].label == .repeated
	assert person.fields[3].typ == 'PhoneNumber'
	assert person.fields[4].has_packed && person.fields[4].packed == false
	assert person.enums.len == 1
	assert person.enums[0].values.len == 4
	assert person.enums[0].values[1].name == 'PHONE_TYPE_MOBILE'
	assert person.enums[0].values[1].number == 1
	assert person.messages.len == 1
	assert person.messages[0].name == 'PhoneNumber'
	assert person.messages[0].fields[1].typ == 'PhoneType'
	assert f.messages[1].name == 'AddressBook'
}

fn test_parse_repo_protos() ! {
	root := os.dir(os.dir(@FILE))
	scalars := parse(os.read_file(os.join_path(root, 'interop', 'scalars.proto'))!)!
	assert scalars.messages.len == 2
	assert scalars.messages[1].name == 'Scalars'
	assert scalars.messages[1].fields.len == 25
	assert scalars.enums[0].name == 'Color'

	book :=
		parse(os.read_file(os.join_path(root, 'examples', 'addressbook', 'addressbook.proto'))!)!
	assert book.package == 'tutorial'
	assert book.messages[0].messages[0].name == 'PhoneNumber'
}

fn expect_parse_error(src string, want string) {
	parse(src) or {
		assert err.msg().contains(want), 'got: ${err.msg()}'
		return
	}
	assert false, 'expected error containing "${want}"'
}

fn test_rejections() {
	expect_parse_error('message M { int32 a = 1; }', 'syntax')
	expect_parse_error('syntax = "proto2"; message M {}', 'only proto3')
	expect_parse_error('syntax = "proto3"; import "other.proto";', 'import')
	expect_parse_error('syntax = "proto3"; message M { oneof x { int32 a = 1; } }', 'oneof')
	expect_parse_error('syntax = "proto3"; message M { repeated map<string, int32> m = 1; }',
		'cannot be repeated')
	expect_parse_error('syntax = "proto3"; message M { map<bool, int32> m = 1; }',
		'cannot key on bool')
	expect_parse_error('syntax = "proto3"; message M { map<float, int32> m = 1; }',
		'invalid map key type')
	expect_parse_error('syntax = "proto3"; message M { map<bytes, int32> m = 1; }',
		'invalid map key type')
	expect_parse_error('syntax = "proto3"; message M { map<string, map<string, int32>> m = 1; }',
		'cannot be maps')
	expect_parse_error('syntax = "proto3"; message M { required int32 a = 1; }', 'proto2')
	expect_parse_error('syntax = "proto3"; message M { int32 a = 1; int64 b = 1; }',
		'duplicate field number')
	expect_parse_error('syntax = "proto3"; message M { int32 a = 0; }', 'out of range')
	expect_parse_error('syntax = "proto3"; enum E { A = 1; }', 'first value')
}

fn test_services_are_skipped() ! {
	f := parse('syntax = "proto3";
service CodegenService {
	rpc Generate (GenerateRequest) returns (GenerateResponse) {
		option idempotency_level = NO_SIDE_EFFECTS;
	}
}
message GenerateRequest { int32 x = 1; }')!
	assert f.messages.len == 1
	assert f.messages[0].name == 'GenerateRequest'
}

fn test_map_fields() ! {
	f := parse('syntax = "proto3"; message M {
	map<string, int32> tags = 1;
	map<sint64, Nested> refs = 2;
	message Nested { int32 x = 1; }
}')!
	m := f.messages[0]
	assert m.fields.len == 2
	assert m.fields[0].is_map
	assert m.fields[0].key_typ == 'string'
	assert m.fields[0].typ == 'int32'
	assert m.fields[0].label == .plain
	assert m.fields[1].key_typ == 'sint64'
	assert m.fields[1].typ == 'Nested'
	assert m.fields[1].number == 2
}

fn test_enum_negative_and_options() ! {
	f := parse('syntax = "proto3"; enum E { ZERO = 0; NEG = -2; DEP = 3 [deprecated = true]; }')!
	assert f.enums[0].values[1].number == -2
	assert f.enums[0].values[2].name == 'DEP'
	assert f.enums[0].values[2].number == 3
}
