module protobuf

import json2
import encoding.base64
import math
import strconv

// Runtime support for the generated canonical-JSON (protojson) methods.
// Parsers are tolerant the way the spec demands: 64-bit ints arrive as
// numbers or strings, floats as numbers or "NaN"/"Infinity" strings,
// bytes as standard or URL-safe base64.

pub fn json_parse(src string) !json2.Any {
	return json2.decode[json2.Any](src)
}

pub fn json_object(a json2.Any) !map[string]json2.Any {
	if a is map[string]json2.Any {
		return a
	}
	return error('protojson: expected object, got ${a.type_name()}')
}

pub fn json_array(a json2.Any) ![]json2.Any {
	if a is []json2.Any {
		return a
	}
	return error('protojson: expected array, got ${a.type_name()}')
}

pub fn json_stringv(a json2.Any) !string {
	if a is string {
		return a
	}
	return error('protojson: expected string, got ${a.type_name()}')
}

pub fn json_boolv(a json2.Any) !bool {
	if a is bool {
		return a
	}
	return error('protojson: expected bool, got ${a.type_name()}')
}

pub fn json_intv(a json2.Any) !i64 {
	match a {
		i64 {
			return a
		}
		int {
			return a
		}
		i32 {
			return i64(a)
		}
		i16 {
			return i64(a)
		}
		i8 {
			return i64(a)
		}
		u8 {
			return i64(a)
		}
		u16 {
			return i64(a)
		}
		u32 {
			return i64(a)
		}
		u64 {
			if a > 9223372036854775807 {
				return error('protojson: integer out of i64 range')
			}
			return i64(a)
		}
		f64 {
			if a != f64(i64(a)) {
				return error('protojson: expected integer, got fraction')
			}
			return i64(a)
		}
		f32 {
			if f64(a) != f64(i64(a)) {
				return error('protojson: expected integer, got fraction')
			}
			return i64(a)
		}
		string {
			return json_key_i64(a)
		}
		else {
			return error('protojson: expected integer, got ${a.type_name()}')
		}
	}
}

pub fn json_uintv(a json2.Any) !u64 {
	match a {
		u64 {
			return a
		}
		u32 {
			return u64(a)
		}
		u16 {
			return u64(a)
		}
		u8 {
			return u64(a)
		}
		i64, int, i32, i16, i8 {
			v := json_intv(a)!
			if v < 0 {
				return error('protojson: negative value for unsigned field')
			}
			return u64(v)
		}
		f64 {
			if a < 0 || a != f64(u64(a)) {
				return error('protojson: expected unsigned integer')
			}
			return u64(a)
		}
		f32 {
			if a < 0 || f64(a) != f64(u64(a)) {
				return error('protojson: expected unsigned integer')
			}
			return u64(a)
		}
		string {
			return json_key_u64(a)
		}
		else {
			return error('protojson: expected unsigned integer, got ${a.type_name()}')
		}
	}
}

pub fn json_floatv(a json2.Any) !f64 {
	match a {
		f64 {
			return a
		}
		f32 {
			return f64(a)
		}
		i64 {
			return f64(a)
		}
		int {
			return f64(a)
		}
		i32 {
			return f64(a)
		}
		i16 {
			return f64(a)
		}
		i8 {
			return f64(a)
		}
		u64 {
			return f64(a)
		}
		u32 {
			return f64(a)
		}
		u16 {
			return f64(a)
		}
		u8 {
			return f64(a)
		}
		string {
			match a {
				'NaN' {
					return math.nan()
				}
				'Infinity' {
					return math.inf(1)
				}
				'-Infinity' {
					return math.inf(-1)
				}
				else {
					return strconv.atof64(a) or {
						return error('protojson: bad float string `${a}`')
					}
				}
			}
		}
		else {
			return error('protojson: expected number, got ${a.type_name()}')
		}
	}
}

pub fn json_bytesv(a json2.Any) ![]u8 {
	s := json_stringv(a)!
	if s == '' {
		return []u8{}
	}
	if s.contains('-') || s.contains('_') {
		return base64.url_decode(s)
	}
	out := base64.decode(s)
	if out.len == 0 {
		return error('protojson: invalid base64 `${s}`')
	}
	return out
}

pub fn json_int32v(a json2.Any) !int {
	v := json_intv(a)!
	if v < -2147483648 || v > 2147483647 {
		return error('protojson: value ${v} out of int32 range')
	}
	return int(v)
}

pub fn json_uint32v(a json2.Any) !u32 {
	v := json_uintv(a)!
	if v > 4294967295 {
		return error('protojson: value ${v} out of uint32 range')
	}
	return u32(v)
}

// FieldMask paths: snake_case segments <-> lowerCamel segments
pub fn json_camel_path(p string) string {
	mut segs := []string{}
	for seg in p.split('.') {
		mut out := ''
		mut up := false
		for c in seg {
			if c == `_` {
				up = true
			} else if up {
				out += c.ascii_str().to_upper()
				up = false
			} else {
				out += c.ascii_str()
			}
		}
		segs << out
	}
	return segs.join('.')
}

pub fn json_snake_path(p string) string {
	mut segs := []string{}
	for seg in p.split('.') {
		mut out := ''
		for c in seg {
			if c >= `A` && c <= `Z` {
				out += '_' + c.ascii_str().to_lower()
			} else {
				out += c.ascii_str()
			}
		}
		segs << out
	}
	return segs.join('.')
}

// map keys arrive as strings regardless of the proto key type
pub fn json_key_i64(k string) !i64 {
	v := strconv.parse_int(k, 10, 64) or { return error('protojson: bad integer `${k}`') }
	return v
}

pub fn json_key_u64(k string) !u64 {
	v := strconv.parse_uint(k, 10, 64) or { return error('protojson: bad integer `${k}`') }
	return v
}

// emission: 64-bit ints are JSON strings (JS numbers lose precision),
// non-finite floats are the spec's string spellings
pub fn json_i64(v i64) json2.Any {
	return json2.Any(v.str())
}

pub fn json_u64(v u64) json2.Any {
	return json2.Any(v.str())
}

pub fn json_f64(v f64) json2.Any {
	if math.is_nan(v) {
		return json2.Any('NaN')
	}
	if math.is_inf(v, 1) {
		return json2.Any('Infinity')
	}
	if math.is_inf(v, -1) {
		return json2.Any('-Infinity')
	}
	return json2.Any(v)
}

pub fn json_f32(v f32) json2.Any {
	if math.is_nan(f64(v)) {
		return json2.Any('NaN')
	}
	if math.is_inf(f64(v), 1) {
		return json2.Any('Infinity')
	}
	if math.is_inf(f64(v), -1) {
		return json2.Any('-Infinity')
	}
	return json2.Any(v)
}

pub fn json_b64(b []u8) json2.Any {
	return json2.Any(base64.encode(b))
}
