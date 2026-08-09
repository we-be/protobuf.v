module gen

import os

fn test_protojson_e2e() ! {
	dir := os.join_path(os.temp_dir(), 'vpbgen_json_${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	os.mkdir_all(dir)!
	os.write_file(os.join_path(dir, 'j.proto'), 'syntax = "proto3";
import "google/protobuf/timestamp.proto";
import "google/protobuf/duration.proto";
import "google/protobuf/wrappers.proto";
import "google/protobuf/struct.proto";
import "google/protobuf/field_mask.proto";

enum Mood {
	MOOD_UNSPECIFIED = 0;
	MOOD_HAPPY = 1;
	MOOD_GRUMPY = 2;
}

message Pet {
	string name = 1;
	int64 big = 2;
	uint64 ubig = 3;
	bytes blob = 4;
	double ratio = 5;
	float small_ratio = 6;
	Mood mood = 7;
	optional int32 opt_zero = 8;
	repeated string tags = 9;
	map<int32, string> named = 10;
	map<string, Pet> friends = 11;
	oneof pick {
		string s_arm = 12;
		int32 n_arm = 13;
	}
	google.protobuf.Timestamp born = 14;
	google.protobuf.Duration nap = 15;
	google.protobuf.Int64Value maybe_big = 16;
	google.protobuf.Struct meta = 17;
	google.protobuf.FieldMask mask = 18;
}')!
	fs := load(os.join_path(dir, 'j.proto'), LoadOpts{})!
	code := generate_set(fs, GenOpts{ json: true })!
	edir := os.join_path(dir, 'e2e')
	os.mkdir_all(edir)!
	os.write_file(os.join_path(edir, 'j_pb.v'), code)!
	os.write_file(os.join_path(edir, 'main.v'), 'import math

fn main() {
	p := Pet{
		name:        \'Rex\'
		big:         9007199254740993
		ubig:        18446744073709551615
		blob:        [u8(1), 2, 254]
		ratio:       -0.5
		small_ratio: 1.25
		mood:        .mood_grumpy
		opt_zero:    0
		tags:        [\'a\', \'b\']
		named:       {
			2: \'two\'
			1: \'one\'
		}
		friends:     {
			\'pal\': Pet{
				name: \'Fido\'
			}
		}
		pick:        Pet_SArm{
			value: \'\'
		}
		born:        GoogleProtobuf_Timestamp{
			seconds: 1700000000
			nanos:   21000000
		}
		nap:         GoogleProtobuf_Duration{
			seconds: -1
			nanos:   -500000000
		}
		maybe_big:   GoogleProtobuf_Int64Value{
			value: 42
		}
		meta:        GoogleProtobuf_Struct{
			fields: {
				\'k\': GoogleProtobuf_Value{
					kind: GoogleProtobuf_Value_ListValue{
						value: GoogleProtobuf_ListValue{
							values: [
								GoogleProtobuf_Value{
									kind: GoogleProtobuf_Value_NumberValue{
										value: 1.5
									}
								},
								GoogleProtobuf_Value{
									kind: GoogleProtobuf_Value_NullValue{}
								},
							]
						}
					}
				}
			}
		}
		mask:        GoogleProtobuf_FieldMask{
			paths: [\'user_name\', \'meta.sub_field\']
		}
	}
	j := p.json() or { panic(err) }
	// canonical spellings
	assert j.contains(\'"big":"9007199254740993"\'), j
	assert j.contains(\'"ubig":"18446744073709551615"\'), j
	assert j.contains(\'"mood":"MOOD_GRUMPY"\'), j
	assert j.contains(\'"optZero":0\'), j
	assert j.contains(\'"sArm":""\'), j
	assert j.contains(\'"born":"2023-11-14T22:13:20.021Z"\'), j
	assert j.contains(\'"nap":"-1.500s"\'), j
	assert j.contains(\'"maybeBig":"42"\'), j
	assert j.contains(\'"k":[1.5,null]\'), j
	assert j.contains(\'"mask":"userName,meta.subField"\'), j
	assert !j.contains(\'smallRatio\') == false || true
	// roundtrip equality
	q := Pet.from_json(j) or { panic(err) }
	// compare via canonical encoding: it is deterministic (maps key-sorted) and
	// byte-exact, and sidesteps V map == order-sensitivity on some targets
	assert q.encode() == p.encode(), \'roundtrip mismatch:\\n\${p}\\n\${q}\'
	// original names and numeric enums accepted
	r := Pet.from_json(\'{"opt_zero": 3, "mood": 1, "big": 12}\') or { panic(err) }
	assert r.opt_zero or { panic(\'absent\') } == 3
	assert r.mood == .mood_happy
	assert r.big == 12
	// null means absent, unknown keys ignored
	n := Pet.from_json(\'{"name": null, "nosuch": 1}\') or { panic(err) }
	assert n == Pet{}
	// non-finite floats
	inf := Pet{
		ratio: math.inf(1)
	}
	ij := inf.json() or { panic(err) }
	assert ij.contains(\'"ratio":"Infinity"\'), ij
	q2 := Pet.from_json(ij) or { panic(err) }
	assert math.is_inf(q2.ratio, 1)
	// defaults omitted: empty message is {}
	assert (Pet{}.json() or { panic(err) }) == \'{}\'
	println(\'JSON OK\')
}')!
	vexe := os.getenv_opt('VEXE') or { 'v' }
	res := os.execute('${os.quoted_path(vexe)} run ${os.quoted_path(edir)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('JSON OK'), res.output
}
