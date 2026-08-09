module gen

import strings

// Canonical proto3 JSON (protojson) method generator, opt-in via
// GenOpts.json / vpbgen -json. Each message gets json()/json_value() and
// from_json()/from_json_value(); enums get name tables. Emission follows
// the spec: lowerCamelCase names (original names also accepted on parse),
// 64-bit ints as strings, bytes as base64, defaults omitted except
// presence fields, and special forms for the well-known types. Unknown
// JSON fields are ignored on parse; pb_unknown does not survive JSON.

// default lowerCamelCase JSON name derived from a proto field name
fn json_name(name string) string {
	c := camel(name)
	if c.len == 0 {
		return name
	}
	return c[..1].to_lower() + c[1..]
}

// the JSON key a field emits under: an explicit [json_name] wins, else
// the lowerCamel default
fn field_json_name(fld Field) string {
	return if fld.json_name != '' { fld.json_name } else { json_name(fld.name) }
}

// match arm accepting a field's JSON name plus, when different, its
// original proto name — protojson parsers accept both
fn field_json_key_pattern(fld Field) string {
	jn := field_json_name(fld)
	if jn == fld.name {
		return "'${jn}'"
	}
	return "'${jn}', '${fld.name}'"
}

fn json_map_key_emit(key_typ string) string {
	if key_typ == 'string' {
		return 'k'
	}
	// bool keys are stored as int (0/1) but protojson keys them "false"/"true"
	if key_typ == 'bool' {
		return "if k != 0 { 'true' } else { 'false' }"
	}
	return 'k.str()'
}

fn json_map_key_parse(key_typ string) string {
	return match key_typ {
		'string' { 'mk' }
		'bool' { "if mk == 'true' { 1 } else { 0 }" }
		'int32', 'sint32', 'sfixed32' { 'int(protobuf.json_key_i64(mk)!)' }
		'int64', 'sint64', 'sfixed64' { 'protobuf.json_key_i64(mk)!' }
		'uint32', 'fixed32' { 'u32(protobuf.json_key_u64(mk)!)' }
		'uint64', 'fixed64' { 'protobuf.json_key_u64(mk)!' }
		else { '' }
	}
}

fn json_scalar_emit(t string, ve string) string {
	return match t {
		'int32', 'sint32', 'sfixed32' { 'json2.Any(i64(${ve}))' }
		'int64', 'sint64', 'sfixed64' { 'protobuf.json_i64(${ve})' }
		'uint32', 'fixed32' { 'json2.Any(u64(${ve}))' }
		'uint64', 'fixed64' { 'protobuf.json_u64(${ve})' }
		'bool' { 'json2.Any(${ve})' }
		'string' { 'json2.Any(${ve})' }
		'bytes' { 'protobuf.json_b64(${ve})' }
		'float' { 'protobuf.json_f32(${ve})' }
		'double' { 'protobuf.json_f64(${ve})' }
		else { '' }
	}
}

fn json_scalar_parse(t string, ae string) string {
	return match t {
		'int32', 'sint32', 'sfixed32' { 'protobuf.json_int32v(${ae})!' }
		'int64', 'sint64', 'sfixed64' { 'protobuf.json_intv(${ae})!' }
		'uint32', 'fixed32' { 'protobuf.json_uint32v(${ae})!' }
		'uint64', 'fixed64' { 'protobuf.json_uintv(${ae})!' }
		'bool' { 'protobuf.json_boolv(${ae})!' }
		'string' { 'protobuf.json_stringv(${ae})!' }
		'bytes' { 'protobuf.json_bytesv(${ae})!' }
		'float' { 'protobuf.json_f32v(${ae})!' }
		'double' { 'protobuf.json_f64v(${ae})!' }
		else { '' }
	}
}

fn (g &Gen) json_field_emit(info FieldInfo, fld Field, ve string) string {
	return match info.kind {
		.scalar { json_scalar_emit(fld.typ, ve) }
		.enum_ { '${info.vtype.to_lower()}_to_json(${ve})' }
		.message { '${ve}.json_value()' }
	}
}

fn (g &Gen) json_field_parse(info FieldInfo, fld Field, ae string) string {
	return match info.kind {
		.scalar { json_scalar_parse(fld.typ, ae) }
		.enum_ { '${info.vtype.to_lower()}_from_json(${ae})!' }
		.message { '${info.vtype}.from_json_value(${ae})!' }
	}
}

fn (mut g Gen) emit_enum_json(mut b strings.Builder, vname string, e Enum) {
	b.writeln('')
	b.writeln('fn ${vname.to_lower()}_to_json(v ${vname}) json2.Any {')
	b.writeln('\treturn match int(v) {')
	// emit the canonical (first) name per number; aliases would duplicate arms
	mut seen_out := map[int]bool{}
	for val in e.values {
		if val.number in seen_out {
			continue
		}
		seen_out[val.number] = true
		b.writeln("\t\t${val.number} { json2.Any('${val.name}') }")
	}
	b.writeln('\t\telse { json2.Any(i64(int(v))) }')
	b.writeln('\t}')
	b.writeln('}')
	b.writeln('')
	b.writeln('fn ${vname.to_lower()}_from_json(a json2.Any) !${vname} {')
	b.writeln('\tif a is string {')
	b.writeln('\t\tmatch a {')
	// every name (including aliases) parses back to its number
	mut seen_in := map[string]bool{}
	for val in e.values {
		if val.name in seen_in {
			continue
		}
		seen_in[val.name] = true
		b.writeln("\t\t\t'${val.name}' { return unsafe { ${vname}(${val.number}) } }")
	}
	b.writeln("\t\t\telse { return error('protojson: unknown value `\${a}` for ${vname}') }")
	b.writeln('\t\t}')
	b.writeln('\t}')
	b.writeln('\treturn unsafe { ${vname}(int(protobuf.json_intv(a)!)) }')
	b.writeln('}')
}

// wkt_json_form says which well-known types replace the generic object
// mapping with a special JSON form
fn wkt_json_form(name string) bool {
	return name in ['Timestamp', 'Duration', 'Struct', 'Value', 'ListValue', 'FieldMask', 'Any',
		'DoubleValue', 'FloatValue', 'Int64Value', 'UInt64Value', 'Int32Value', 'UInt32Value',
		'BoolValue', 'StringValue', 'BytesValue']
}

// value-wrapped types use {"@type":..,"value":<json>} inside an Any; normal
// messages spread their fields alongside "@type". Same set as the special
// JSON forms, gated to the real google.protobuf package by the caller.
fn wkt_value_wrapped(name string) bool {
	return wkt_json_form(name)
}

fn (mut g Gen) emit_json_methods(mut b strings.Builder, vname string, scope []string, path []string, m Message) ! {
	b.writeln('')
	b.writeln('pub fn (m &${vname}) json() string {')
	b.writeln('\treturn m.json_value().json_str()')
	b.writeln('}')
	b.writeln('')
	b.writeln('pub fn ${vname}.from_json(s string) !${vname} {')
	b.writeln('\treturn ${vname}.from_json_value(protobuf.json_parse(s)!)')
	b.writeln('}')

	if g.cur_file_pkg == 'google.protobuf' && path.len == 0 && wkt_json_form(m.name) {
		g.emit_wkt_json(mut b, vname, m.name)
		return
	}

	b.writeln('')
	b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
	if m.fields.len == 0 {
		b.writeln('\treturn json2.Any(map[string]json2.Any{})')
	} else {
		b.writeln('\tmut o := map[string]json2.Any{}')
		for fld in m.fields {
			g.emit_json_field_out(mut b, scope, vname, fld)!
		}
		b.writeln('\treturn json2.Any(o)')
	}
	b.writeln('}')

	b.writeln('')
	b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
	if m.fields.len == 0 {
		b.writeln('\t_ := protobuf.json_object(a)!')
		b.writeln('\treturn ${vname}{}')
	} else {
		b.writeln('\tobj := protobuf.json_object(a)!')
		b.writeln('\tmut m := ${vname}{}')
		b.writeln('\tfor jk, jv in obj {')
		b.writeln('\t\tif jv is json2.Null {')
		b.writeln('\t\t\tcontinue')
		b.writeln('\t\t}')
		b.writeln('\t\tmatch jk {')
		for fld in m.fields {
			g.emit_json_field_in(mut b, scope, vname, fld)!
		}
		b.writeln('\t\t\telse {}')
		b.writeln('\t\t}')
		b.writeln('\t}')
		b.writeln('\treturn m')
	}
	b.writeln('}')
}

fn (mut g Gen) emit_json_field_out(mut b strings.Builder, scope []string, vname string, fld Field) ! {
	info := g.field_info(scope, vname, fld)!
	name := sanitize(fld.name)
	jn := field_json_name(fld)
	if fld.oneof != '' {
		b.writeln('\tif ov := m.${sanitize(fld.oneof)} {')
		b.writeln('\t\tif ov is ${vname}_${camel(fld.name)} {')
		b.writeln("\t\t\to['${jn}'] = ${g.json_field_emit(info, fld, 'ov.value')}")
		b.writeln('\t\t}')
		b.writeln('\t}')
		return
	}
	if fld.is_map {
		b.writeln('\tif m.${name}.len > 0 {')
		b.writeln('\t\tmut ${name}_o := map[string]json2.Any{}')
		b.writeln('\t\tmut ${name}_ks := m.${name}.keys()')
		b.writeln('\t\t${name}_ks.sort()')
		b.writeln('\t\tfor k in ${name}_ks {')
		b.writeln('\t\t\tv := m.${name}[k]')
		b.writeln('\t\t\t${name}_o[${json_map_key_emit(fld.key_typ)}] = ${g.json_field_emit(info,
			fld, 'v')}')
		b.writeln('\t\t}')
		b.writeln("\t\to['${jn}'] = json2.Any(${name}_o)")
		b.writeln('\t}')
		return
	}
	if fld.label == .repeated {
		b.writeln('\tif m.${name}.len > 0 {')
		b.writeln('\t\tmut ${name}_a := []json2.Any{cap: m.${name}.len}')
		b.writeln('\t\tfor v in m.${name} {')
		b.writeln('\t\t\t${name}_a << ${g.json_field_emit(info, fld, 'v')}')
		b.writeln('\t\t}')
		b.writeln("\t\to['${jn}'] = json2.Any(${name}_a)")
		b.writeln('\t}')
		return
	}
	if fld.label == .optional || info.kind == .message {
		b.writeln('\tif ${name} := m.${name} {')
		b.writeln("\t\to['${jn}'] = ${g.json_field_emit(info, fld, name)}")
		b.writeln('\t}')
		return
	}
	guard := if info.kind == .enum_ {
		'int(m.${name}) != 0'
	} else {
		zero_check(fld.typ, 'm.${name}')
	}
	b.writeln('\tif ${guard} {')
	b.writeln("\t\to['${jn}'] = ${g.json_field_emit(info, fld, 'm.${name}')}")
	b.writeln('\t}')
}

fn (mut g Gen) emit_json_field_in(mut b strings.Builder, scope []string, vname string, fld Field) ! {
	info := g.field_info(scope, vname, fld)!
	name := sanitize(fld.name)
	pattern := field_json_key_pattern(fld)
	b.writeln('\t\t\t${pattern} {')
	if fld.oneof != '' {
		b.writeln('\t\t\t\tm.${sanitize(fld.oneof)} = ${vname}_${camel(fld.name)}{')
		b.writeln('\t\t\t\t\tvalue: ${g.json_field_parse(info, fld, 'jv')}')
		b.writeln('\t\t\t\t}')
	} else if fld.is_map {
		b.writeln('\t\t\t\tfor mk, mv in protobuf.json_object(jv)! {')
		b.writeln('\t\t\t\t\tm.${name}[${json_map_key_parse(fld.key_typ)}] = ${g.json_field_parse(info,
			fld, 'mv')}')
		b.writeln('\t\t\t\t}')
	} else if fld.label == .repeated {
		b.writeln('\t\t\t\tfor it in protobuf.json_array(jv)! {')
		b.writeln('\t\t\t\t\tm.${name} << ${g.json_field_parse(info, fld, 'it')}')
		b.writeln('\t\t\t\t}')
	} else if info.kind == .message && g.is_boxed(scope, fld.number) {
		b.writeln('\t\t\t\tbox_${name} := ${g.json_field_parse(info, fld, 'jv')}')
		b.writeln('\t\t\t\tm.${name} = &box_${name}')
	} else {
		b.writeln('\t\t\t\tm.${name} = ${g.json_field_parse(info, fld, 'jv')}')
	}
	b.writeln('\t\t\t}')
}

fn (mut g Gen) emit_wkt_json(mut b strings.Builder, vname string, name string) {
	wrapper_scalar := {
		'DoubleValue': 'double'
		'FloatValue':  'float'
		'Int64Value':  'int64'
		'UInt64Value': 'uint64'
		'Int32Value':  'int32'
		'UInt32Value': 'uint32'
		'BoolValue':   'bool'
		'StringValue': 'string'
		'BytesValue':  'bytes'
	}
	value_v := g.vname_for('google.protobuf', [], 'Value')
	struct_v := g.vname_for('google.protobuf', [], 'Struct')
	list_v := g.vname_for('google.protobuf', [], 'ListValue')
	match name {
		'Any' {
			b.writeln('')
			b.writeln('// canonical JSON: {"@type": url, ...fields} for normal messages,')
			b.writeln('// {"@type": url, "value": <form>} for value-wrapped WKTs. Uses the')
			b.writeln('// generated fileset resolver; unresolvable types degrade to a raw')
			b.writeln('// base64 form rather than erroring (json_value cannot fail).')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln("\tif m.type_url == '' {")
			b.writeln('\t\treturn json2.Any(map[string]json2.Any{})')
			b.writeln('\t}')
			b.writeln("\tname := m.type_url.all_after_last('/')")
			b.writeln('\tinner, wrapped := pb_any_to_json(name, m.value) or {')
			b.writeln('\t\tmut raw := map[string]json2.Any{}')
			b.writeln("\t\traw['@type'] = json2.Any(m.type_url)")
			b.writeln("\t\traw['value'] = protobuf.json_b64(m.value)")
			b.writeln('\t\treturn json2.Any(raw)')
			b.writeln('\t}')
			b.writeln('\tmut o := map[string]json2.Any{}')
			b.writeln("\to['@type'] = json2.Any(m.type_url)")
			b.writeln('\tif wrapped {')
			b.writeln("\t\to['value'] = inner")
			b.writeln('\t} else if inner is map[string]json2.Any {')
			b.writeln('\t\tfor k, v in inner {')
			b.writeln('\t\t\to[k] = v')
			b.writeln('\t\t}')
			b.writeln('\t} else {')
			b.writeln("\t\to['value'] = inner")
			b.writeln('\t}')
			b.writeln('\treturn json2.Any(o)')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\tobj := protobuf.json_object(a)!')
			b.writeln('\tif obj.len == 0 {')
			b.writeln('\t\treturn ${vname}{}')
			b.writeln('\t}')
			b.writeln('\ttu := obj[\'@type\'] or { return error(\'protojson: Any missing "@type"\') }')
			b.writeln('\ttype_url := protobuf.json_stringv(tu)!')
			b.writeln("\tname := type_url.all_after_last('/')")
			b.writeln('\tvalue := pb_any_from_json(name, obj)!')
			b.writeln('\treturn ${vname}{')
			b.writeln('\t\ttype_url: type_url')
			b.writeln('\t\tvalue:    value')
			b.writeln('\t}')
			b.writeln('}')
		}
		'Timestamp' {
			b.writeln('')
			b.writeln('// canonical JSON form: RFC 3339 in UTC')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\tt := time.unix(m.seconds)')
			b.writeln('\tmut frac := ""')
			b.writeln('\tif m.nanos != 0 {')
			b.writeln('\t\tif m.nanos % 1_000_000 == 0 {')
			b.writeln("\t\t\tfrac = '.\${(m.nanos / 1_000_000):03d}'")
			b.writeln('\t\t} else if m.nanos % 1_000 == 0 {')
			b.writeln("\t\t\tfrac = '.\${(m.nanos / 1_000):06d}'")
			b.writeln('\t\t} else {')
			b.writeln("\t\t\tfrac = '.\${m.nanos:09d}'")
			b.writeln('\t\t}')
			b.writeln('\t}')
			b.writeln("\treturn json2.Any('\${t.year:04d}-\${t.month:02d}-\${t.day:02d}T\${t.hour:02d}:\${t.minute:02d}:\${t.second:02d}\${frac}Z')")
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\ts := protobuf.json_stringv(a)!')
			b.writeln("\tt := time.parse_rfc3339(s) or { return error('protojson: bad timestamp `\${s}`') }")
			b.writeln('\treturn ${vname}{')
			b.writeln('\t\tseconds: t.unix()')
			b.writeln('\t\tnanos:   t.nanosecond')
			b.writeln('\t}')
			b.writeln('}')
		}
		'Duration' {
			b.writeln('')
			b.writeln('// canonical JSON form: decimal seconds with an s suffix')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\tmut s := m.seconds')
			b.writeln('\tmut n := m.nanos')
			b.writeln('\tneg := s < 0 || n < 0')
			b.writeln('\tif s < 0 {')
			b.writeln('\t\ts = -s')
			b.writeln('\t}')
			b.writeln('\tif n < 0 {')
			b.writeln('\t\tn = -n')
			b.writeln('\t}')
			b.writeln('\tmut frac := ""')
			b.writeln('\tif n != 0 {')
			b.writeln('\t\tif n % 1_000_000 == 0 {')
			b.writeln("\t\t\tfrac = '.\${(n / 1_000_000):03d}'")
			b.writeln('\t\t} else if n % 1_000 == 0 {')
			b.writeln("\t\t\tfrac = '.\${(n / 1_000):06d}'")
			b.writeln('\t\t} else {')
			b.writeln("\t\t\tfrac = '.\${n:09d}'")
			b.writeln('\t\t}')
			b.writeln('\t}')
			b.writeln("\tsign := if neg { '-' } else { '' }")
			b.writeln("\treturn json2.Any('\${sign}\${s}\${frac}s')")
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\tstr := protobuf.json_stringv(a)!')
			b.writeln("\tif !str.ends_with('s') || str.len < 2 {")
			b.writeln("\t\treturn error('protojson: bad duration `\${str}`')")
			b.writeln('\t}')
			b.writeln('\tmut body := str[..str.len - 1]')
			b.writeln("\tneg := body.starts_with('-')")
			b.writeln('\tif neg {')
			b.writeln('\t\tbody = body[1..]')
			b.writeln('\t}')
			b.writeln("\tparts := body.split('.')")
			b.writeln('\tif parts.len > 2 {')
			b.writeln("\t\treturn error('protojson: bad duration `\${str}`')")
			b.writeln('\t}')
			b.writeln('\tmut secs := protobuf.json_key_i64(parts[0])!')
			b.writeln('\tmut nanos := i64(0)')
			b.writeln('\tif parts.len == 2 {')
			b.writeln('\t\tif parts[1].len == 0 || parts[1].len > 9 {')
			b.writeln("\t\t\treturn error('protojson: bad duration `\${str}`')")
			b.writeln('\t\t}')
			b.writeln("\t\tnanos = protobuf.json_key_i64(parts[1] + '0'.repeat(9 - parts[1].len))!")
			b.writeln('\t}')
			b.writeln('\tif neg {')
			b.writeln('\t\tsecs = -secs')
			b.writeln('\t\tnanos = -nanos')
			b.writeln('\t}')
			b.writeln('\treturn ${vname}{')
			b.writeln('\t\tseconds: secs')
			b.writeln('\t\tnanos:   int(nanos)')
			b.writeln('\t}')
			b.writeln('}')
		}
		'Struct' {
			b.writeln('')
			b.writeln('// canonical JSON form: a plain object')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\tmut o := map[string]json2.Any{}')
			b.writeln('\tmut ks := m.fields.keys()')
			b.writeln('\tks.sort()')
			b.writeln('\tfor k in ks {')
			b.writeln('\t\to[k] = m.fields[k].json_value()')
			b.writeln('\t}')
			b.writeln('\treturn json2.Any(o)')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\tmut m := ${vname}{}')
			b.writeln('\tfor k, v in protobuf.json_object(a)! {')
			b.writeln('\t\tm.fields[k] = ${value_v}.from_json_value(v)!')
			b.writeln('\t}')
			b.writeln('\treturn m')
			b.writeln('}')
		}
		'Value' {
			b.writeln('')
			b.writeln('// canonical JSON form: the value itself')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\tif k := m.kind {')
			b.writeln('\t\tmatch k {')
			b.writeln('\t\t\t${vname}_NullValue {')
			b.writeln('\t\t\t\treturn json2.Any(json2.Null{})')
			b.writeln('\t\t\t}')
			b.writeln('\t\t\t${vname}_NumberValue {')
			b.writeln('\t\t\t\treturn protobuf.json_f64(k.value)')
			b.writeln('\t\t\t}')
			b.writeln('\t\t\t${vname}_StringValue {')
			b.writeln('\t\t\t\treturn json2.Any(k.value)')
			b.writeln('\t\t\t}')
			b.writeln('\t\t\t${vname}_BoolValue {')
			b.writeln('\t\t\t\treturn json2.Any(k.value)')
			b.writeln('\t\t\t}')
			b.writeln('\t\t\t${vname}_StructValue {')
			b.writeln('\t\t\t\treturn k.value.json_value()')
			b.writeln('\t\t\t}')
			b.writeln('\t\t\t${vname}_ListValue {')
			b.writeln('\t\t\t\treturn k.value.json_value()')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t}')
			b.writeln('\treturn json2.Any(json2.Null{})')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\tmatch a {')
			b.writeln('\t\tjson2.Null {')
			b.writeln('\t\t\treturn ${vname}{')
			b.writeln('\t\t\t\tkind: ${vname}_NullValue{}')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t\tbool {')
			b.writeln('\t\t\treturn ${vname}{')
			b.writeln('\t\t\t\tkind: ${vname}_BoolValue{')
			b.writeln('\t\t\t\t\tvalue: a')
			b.writeln('\t\t\t\t}')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t\tstring {')
			b.writeln('\t\t\treturn ${vname}{')
			b.writeln('\t\t\t\tkind: ${vname}_StringValue{')
			b.writeln('\t\t\t\t\tvalue: a')
			b.writeln('\t\t\t\t}')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t\tmap[string]json2.Any {')
			b.writeln('\t\t\treturn ${vname}{')
			b.writeln('\t\t\t\tkind: ${vname}_StructValue{')
			b.writeln('\t\t\t\t\tvalue: ${struct_v}.from_json_value(a)!')
			b.writeln('\t\t\t\t}')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t\t[]json2.Any {')
			b.writeln('\t\t\treturn ${vname}{')
			b.writeln('\t\t\t\tkind: ${vname}_ListValue{')
			b.writeln('\t\t\t\t\tvalue: ${list_v}.from_json_value(a)!')
			b.writeln('\t\t\t\t}')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t\telse {')
			b.writeln('\t\t\treturn ${vname}{')
			b.writeln('\t\t\t\tkind: ${vname}_NumberValue{')
			b.writeln('\t\t\t\t\tvalue: protobuf.json_floatv(a)!')
			b.writeln('\t\t\t\t}')
			b.writeln('\t\t\t}')
			b.writeln('\t\t}')
			b.writeln('\t}')
			b.writeln('}')
		}
		'ListValue' {
			b.writeln('')
			b.writeln('// canonical JSON form: a plain array')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\tmut arr := []json2.Any{cap: m.values.len}')
			b.writeln('\tfor v in m.values {')
			b.writeln('\t\tarr << v.json_value()')
			b.writeln('\t}')
			b.writeln('\treturn json2.Any(arr)')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\tmut m := ${vname}{}')
			b.writeln('\tfor it in protobuf.json_array(a)! {')
			b.writeln('\t\tm.values << ${value_v}.from_json_value(it)!')
			b.writeln('\t}')
			b.writeln('\treturn m')
			b.writeln('}')
		}
		'FieldMask' {
			b.writeln('')
			b.writeln('// canonical JSON form: comma-joined lowerCamel paths')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\tmut parts := []string{cap: m.paths.len}')
			b.writeln('\tfor p in m.paths {')
			b.writeln('\t\tparts << protobuf.json_camel_path(p)')
			b.writeln('\t}')
			b.writeln("\treturn json2.Any(parts.join(','))")
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\ts := protobuf.json_stringv(a)!')
			b.writeln('\tmut m := ${vname}{}')
			b.writeln("\tif s != '' {")
			b.writeln("\t\tfor p in s.split(',') {")
			b.writeln('\t\t\tm.paths << protobuf.json_snake_path(p)')
			b.writeln('\t\t}')
			b.writeln('\t}')
			b.writeln('\treturn m')
			b.writeln('}')
		}
		else {
			// a wrapper: the JSON form is the wrapped scalar itself
			st := wrapper_scalar[name]
			b.writeln('')
			b.writeln('// canonical JSON form: the wrapped value')
			b.writeln('pub fn (m &${vname}) json_value() json2.Any {')
			b.writeln('\treturn ${json_scalar_emit(st, 'm.value')}')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_json_value(a json2.Any) !${vname} {')
			b.writeln('\treturn ${vname}{')
			b.writeln('\t\tvalue: ${json_scalar_parse(st, 'a')}')
			b.writeln('\t}')
			b.writeln('}')
		}
	}
}
