module protobuf

import json2
import math

// pins the two json2 pathologies json_precheck guards against: ~10k
// nesting segfaults its recursive parser, and `{"a":[1,21` loops forever

fn test_depth_bomb_rejected() {
	s := '['.repeat(50000) + ']'.repeat(50000)
	if _ := json_parse(s) {
		assert false, 'depth bomb accepted'
	} else {
		assert err.msg().contains('nesting'), err.msg()
	}
	ok := '['.repeat(999) + '1' + ']'.repeat(999)
	if _ := json_parse(ok) {
	} else {
		assert false, 'depth 999 should parse: ${err.msg()}'
	}
}

fn test_truncated_documents_rejected() {
	for s in ['{"a":[1,21', '[1,', '{"a":1', '"abc', '[[]', '{"a":"x\\'] {
		if _ := json_parse(s) {
			assert false, 'accepted truncated `${s}`'
		} else {
			// precheck catches most; json2 may catch the rest — erroring
			// (rather than hanging) is the contract
		}
	}
}

fn test_unbalanced_rejected() {
	for s in [']', '}', '[1]]', '{"a":1}}'] {
		if _ := json_parse(s) {
			assert false, 'accepted unbalanced `${s}`'
		}
	}
}

fn test_bare_scalars_and_empty_never_crash_json2() {
	// these previously crashed json2 (a past-EOF substr in its checker_error)
	// or are otherwise not a JSON value; json_parse must ERROR, never panic
	for s in ['', ' ', '\t\n', 'x', '-', '1e', '1.', '1E+', '1e+', 'tru', 't', 'nul', 'n', 'fals',
		'01', '.5', '+1', '1 2', '--1'] {
		if _ := json_parse(s) {
			assert false, 'accepted invalid scalar `${s}`'
		}
	}
	// valid bare scalars and containers still parse
	for s in ['true', 'false', 'null', '0', '-1', '1.5', '2e10', '-3.14e-2', '"hi"', '{}', '[]',
		'{"a":1}', '  42  '] {
		json_parse(s) or { assert false, 'rejected valid `${s}`: ${err.msg()}' }
	}
}

fn test_brackets_inside_strings_are_fine() {
	v := json_parse('{"a":"}{][","b":"\\"[","c":1}') or {
		assert false, err.msg()
		return
	}
	o := json_object(v) or {
		assert false, err.msg()
		return
	}
	assert (o['a'] or { json2.Any('') }) as string == '}{]['
}

fn test_nonfinite_numbers_rejected_for_ints() {
	for bad in [math.inf(1), math.inf(-1), math.nan(), 1e300] {
		if _ := json_intv(json2.Any(bad)) {
			assert false, 'i64 accepted ${bad}'
		}
		if _ := json_uintv(json2.Any(bad)) {
			assert false, 'u64 accepted ${bad}'
		}
	}
	// integral in-range floats still convert
	assert json_intv(json2.Any(f64(-3))) or { -1 } == -3
	assert json_uintv(json2.Any(f64(7))) or { 0 } == 7
}
