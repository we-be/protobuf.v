module gen

import strings

// V code generator for parsed proto3 files. Emits one V source file with
// structs, enums, encoded_size()/encode_to()/encode() methods and static
// decode() functions. Encoding is single-pass: encoded_size() computes the
// exact wire size, encode() allocates once, and encode_to() writes into
// the shared buffer — no per-submessage temporaries (GC-friendly).
//
// Mapping decisions:
// - nested types are flattened: Person.PhoneNumber -> Person_PhoneNumber
// - optional scalars and singular message fields become ?T (set-to-zero
//   is distinguishable from absent, matching proto3 presence semantics)
// - enums are open: unknown values survive a decode/encode roundtrip via
//   unsafe cast, like other proto3 implementations
// - repeated scalars/enums are packed unless [packed = false]
// - map<K,V> becomes map[K]V; entries encode sorted by key with key and
//   value always written, matching protoc's text-format roundtrip so the
//   interop oracle stays byte-identical
// - recursion through singular message fields is rejected (a ?T field
//   stores its value inline in V, so the type would be infinitely sized)

pub struct GenOpts {
pub:
	module_name string = 'main'
}

struct Sym {
	vname   string
	is_enum bool
}

enum FieldKind {
	scalar
	enum_
	message
}

struct FieldInfo {
	kind  FieldKind
	vtype string // base V type, before []/? wrapping
	sym   Sym
}

struct Gen {
	file File
mut:
	syms map[string]Sym
}

const v_keywords = ['as', 'asm', 'assert', 'atomic', 'break', 'const', 'continue', 'defer', 'dump',
	'else', 'enum', 'false', 'fn', 'for', 'go', 'goto', 'if', 'implements', 'import', 'in',
	'interface', 'is', 'isreftype', 'lock', 'match', 'module', 'mut', 'none', 'or', 'pub', 'return',
	'rlock', 'select', 'shared', 'sizeof', 'spawn', 'static', 'struct', 'true', 'type', 'typeof',
	'union', 'unsafe', 'volatile']

fn sanitize(name string) string {
	if name in v_keywords {
		return name + '_'
	}
	return name
}

fn v_scalar_type(t string) string {
	return match t {
		'int32', 'sint32', 'sfixed32' { 'int' }
		'int64', 'sint64', 'sfixed64' { 'i64' }
		'uint32', 'fixed32' { 'u32' }
		'uint64', 'fixed64' { 'u64' }
		'bool' { 'bool' }
		'string' { 'string' }
		'bytes' { '[]u8' }
		'float' { 'f32' }
		'double' { 'f64' }
		else { '' }
	}
}

fn is_packable(t string) bool {
	return t !in ['string', 'bytes'] && v_scalar_type(t) != ''
}

fn tagged_writer(t string) string {
	return 'write_${t}_field'
}

fn scalar_reader(t string) string {
	return match t {
		'string' { 'read_string' }
		'bytes' { 'read_bytes' }
		'float' { 'read_float' }
		'double' { 'read_double' }
		else { 'read_${t}' }
	}
}

fn packed_write_stmt(t string, v string) string {
	return match t {
		'int32' { 'e.write_varint(u64(i64(${v})))' }
		'int64' { 'e.write_varint(u64(${v}))' }
		'uint32' { 'e.write_varint(u64(${v}))' }
		'uint64' { 'e.write_varint(${v})' }
		'sint32' { 'e.write_varint(protobuf.zigzag_encode(i64(${v})))' }
		'sint64' { 'e.write_varint(protobuf.zigzag_encode(${v}))' }
		'bool' { 'e.write_varint(if ${v} { u64(1) } else { u64(0) })' }
		'fixed32' { 'e.write_fixed32(${v})' }
		'sfixed32' { 'e.write_fixed32(u32(${v}))' }
		'float' { 'e.write_f32(${v})' }
		'fixed64' { 'e.write_fixed64(${v})' }
		'sfixed64' { 'e.write_fixed64(u64(${v}))' }
		'double' { 'e.write_f64(${v})' }
		else { '' }
	}
}

// exact wire size of one tagged scalar field, mirroring the tagged writers
fn scalar_size_expr(t string, fnum int, v string) string {
	return match t {
		'int32' { 'protobuf.tag_len(${fnum}) + protobuf.varint_len(u64(i64(${v})))' }
		'int64' { 'protobuf.tag_len(${fnum}) + protobuf.varint_len(u64(${v}))' }
		'uint32' { 'protobuf.tag_len(${fnum}) + protobuf.varint_len(u64(${v}))' }
		'uint64' { 'protobuf.tag_len(${fnum}) + protobuf.varint_len(${v})' }
		'sint32' { 'protobuf.tag_len(${fnum}) + protobuf.varint_len(protobuf.zigzag_encode(i64(${v})))' }
		'sint64' { 'protobuf.tag_len(${fnum}) + protobuf.varint_len(protobuf.zigzag_encode(${v}))' }
		'bool' { 'protobuf.tag_len(${fnum}) + 1' }
		'string' { 'protobuf.len_field_len(${fnum}, ${v}.len)' }
		'bytes' { 'protobuf.len_field_len(${fnum}, ${v}.len)' }
		'float', 'fixed32', 'sfixed32' { 'protobuf.tag_len(${fnum}) + 4' }
		'double', 'fixed64', 'sfixed64' { 'protobuf.tag_len(${fnum}) + 8' }
		else { '' }
	}
}

// size of one untagged packed element for varint-class types; fixed-width
// types are handled arithmetically via packed_elem_width
fn packed_elem_size_expr(t string, v string) string {
	return match t {
		'int32' { 'protobuf.varint_len(u64(i64(${v})))' }
		'int64' { 'protobuf.varint_len(u64(${v}))' }
		'uint32' { 'protobuf.varint_len(u64(${v}))' }
		'uint64' { 'protobuf.varint_len(${v})' }
		'sint32' { 'protobuf.varint_len(protobuf.zigzag_encode(i64(${v})))' }
		'sint64' { 'protobuf.varint_len(protobuf.zigzag_encode(${v}))' }
		else { '' }
	}
}

// bytes per packed element when constant, 0 for varint-class types
fn packed_elem_width(t string) int {
	return match t {
		'bool' { 1 }
		'float', 'fixed32', 'sfixed32' { 4 }
		'double', 'fixed64', 'sfixed64' { 8 }
		else { 0 }
	}
}

fn zero_literal(t string) string {
	return match t {
		'bool' { 'false' }
		'string' { "''" }
		'bytes' { '[]u8{}' }
		'float' { 'f32(0)' }
		'double' { 'f64(0)' }
		'int32', 'sint32', 'sfixed32' { '0' }
		'int64', 'sint64', 'sfixed64' { 'i64(0)' }
		'uint32', 'fixed32' { 'u32(0)' }
		'uint64', 'fixed64' { 'u64(0)' }
		else { '' }
	}
}

// one serialized map entry: key field 1 + value field 2, both always
// written (protoc does the same, even for defaults)
fn map_entry_size_expr(fld Field, info FieldInfo) string {
	key := scalar_size_expr(fld.key_typ, 1, 'k')
	val := match info.kind {
		.scalar { scalar_size_expr(fld.typ, 2, 'v') }
		.enum_ { 'protobuf.tag_len(2) + protobuf.varint_len(u64(i64(int(v))))' }
		.message { 'protobuf.len_field_len(2, v.encoded_size())' }
	}
	return '${key} + ${val}'
}

fn zero_check(t string, expr string) string {
	return match t {
		'bool' { expr }
		'string' { "${expr} != ''" }
		'bytes' { '${expr}.len > 0' }
		else { '${expr} != 0' }
	}
}

pub fn generate(f File, opts GenOpts) !string {
	mut g := Gen{
		file: f
	}
	for m in f.messages {
		g.register_message([], m)
	}
	for e in f.enums {
		g.register_enum([], e)
	}
	g.check_recursion()!
	mut b := strings.new_builder(8192)
	b.writeln('// Code generated by protobuf.gen. DO NOT EDIT.')
	b.writeln('module ${opts.module_name}')
	if f.messages.len > 0 {
		b.writeln('')
		b.writeln('import protobuf')
	}
	for e in f.enums {
		g.emit_enum(mut b, [], e)!
	}
	for m in f.messages {
		g.emit_enums_in(mut b, [], m)!
	}
	for m in f.messages {
		g.emit_message(mut b, [], m)!
	}
	return b.str()
}

fn qualify(path []string, name string) string {
	if path.len == 0 {
		return name
	}
	return path.join('.') + '.' + name
}

fn v_type_name(path []string, name string) string {
	if path.len == 0 {
		return name
	}
	return path.join('_') + '_' + name
}

fn (mut g Gen) register_message(path []string, m Message) {
	g.syms[qualify(path, m.name)] = Sym{
		vname:   v_type_name(path, m.name)
		is_enum: false
	}
	mut sub := path.clone()
	sub << m.name
	for c in m.messages {
		g.register_message(sub, c)
	}
	for e in m.enums {
		g.register_enum(sub, e)
	}
}

fn (mut g Gen) register_enum(path []string, e Enum) {
	g.syms[qualify(path, e.name)] = Sym{
		vname:   v_type_name(path, e.name)
		is_enum: true
	}
}

// proto name resolution: innermost enclosing scope outward, then
// package-qualified and leading-dot absolute forms
fn (g &Gen) resolve(scope []string, typ_ string) ?Sym {
	mut typ := typ_
	if typ.starts_with('.') {
		typ = typ[1..]
		if g.file.package != '' && typ.starts_with(g.file.package + '.') {
			typ = typ[g.file.package.len + 1..]
		}
		return g.syms[typ] or { return none }
	}
	for i := scope.len; i >= 0; i-- {
		key := if i == 0 { typ } else { scope[..i].join('.') + '.' + typ }
		if key in g.syms {
			return g.syms[key]
		}
	}
	if g.file.package != '' && typ.starts_with(g.file.package + '.') {
		stripped := typ[g.file.package.len + 1..]
		if stripped in g.syms {
			return g.syms[stripped]
		}
	}
	return none
}

fn (g &Gen) field_info(scope []string, msg_name string, fld Field) !FieldInfo {
	st := v_scalar_type(fld.typ)
	if st != '' {
		return FieldInfo{
			kind:  .scalar
			vtype: st
		}
	}
	sym := g.resolve(scope, fld.typ) or {
		return error('message ${msg_name}: unknown type `${fld.typ}` for field ${fld.name}')
	}
	return FieldInfo{
		kind:  if sym.is_enum { FieldKind.enum_ } else { FieldKind.message }
		vtype: sym.vname
		sym:   sym
	}
}

// a cycle through singular message fields would make the V struct
// infinitely sized (?T stores inline); repeated fields break cycles
fn (g &Gen) check_recursion() ! {
	mut state := map[string]int{} // 0 unvisited, 1 in-progress, 2 done
	for m in g.file.messages {
		g.dfs([], m, mut state)!
	}
}

fn (g &Gen) dfs(path []string, m Message, mut state map[string]int) ! {
	full := qualify(path, m.name)
	if state[full] == 2 {
		return
	}
	if state[full] == 1 {
		return error('recursive message type ${full} through singular fields is not supported (make the field repeated)')
	}
	state[full] = 1
	mut scope := path.clone()
	scope << m.name
	for fld in m.fields {
		// repeated and map fields are reference-backed containers in V, so
		// they break recursion cycles
		if fld.label == .repeated || fld.is_map {
			continue
		}
		if v_scalar_type(fld.typ) != '' {
			continue
		}
		sym := g.resolve(scope, fld.typ) or { continue }
		if sym.is_enum {
			continue
		}
		target := g.find_message(sym.vname) or { continue }
		g.dfs(target.path, target.msg, mut state)!
	}
	state[full] = 2
	for c in m.messages {
		g.dfs(scope, c, mut state)!
	}
}

struct Found {
	path []string
	msg  Message
}

fn (g &Gen) find_message(vname string) ?Found {
	return find_in(g.file.messages, [], vname)
}

fn find_in(msgs []Message, path []string, vname string) ?Found {
	for m in msgs {
		if v_type_name(path, m.name) == vname {
			return Found{
				path: path
				msg:  m
			}
		}
		mut sub := path.clone()
		sub << m.name
		if f := find_in(m.messages, sub, vname) {
			return f
		}
	}
	return none
}

fn (mut g Gen) emit_enums_in(mut b strings.Builder, path []string, m Message) ! {
	mut sub := path.clone()
	sub << m.name
	for e in m.enums {
		g.emit_enum(mut b, sub, e)!
	}
	for c in m.messages {
		g.emit_enums_in(mut b, sub, c)!
	}
}

fn (mut g Gen) emit_enum(mut b strings.Builder, path []string, e Enum) ! {
	mut seen := map[int]bool{}
	for val in e.values {
		if val.number in seen {
			return error('enum ${e.name}: aliased values (allow_alias) are not supported')
		}
		seen[val.number] = true
	}
	b.writeln('')
	b.writeln('pub enum ${v_type_name(path, e.name)} {')
	for val in e.values {
		b.writeln('\t${sanitize(val.name.to_lower())} = ${val.number}')
	}
	b.writeln('}')
}

fn (mut g Gen) emit_message(mut b strings.Builder, path []string, m Message) ! {
	vname := v_type_name(path, m.name)
	mut scope := path.clone()
	scope << m.name

	b.writeln('')
	if m.fields.len == 0 {
		b.writeln('pub struct ${vname} {}')
	} else {
		b.writeln('pub struct ${vname} {')
		b.writeln('pub mut:')
		for fld in m.fields {
			info := g.field_info(scope, vname, fld)!
			mut t := info.vtype
			if fld.is_map {
				t = 'map[${v_scalar_type(fld.key_typ)}]${t}'
			} else if fld.label == .repeated {
				t = '[]${t}'
			} else if fld.label == .optional || info.kind == .message {
				t = '?${t}'
			}
			b.writeln('\t${sanitize(fld.name)} ${t}')
		}
		b.writeln('}')
	}

	mut fields := m.fields.clone()
	fields.sort(a.number < b.number)

	b.writeln('')
	b.writeln('pub fn (m &${vname}) encoded_size() int {')
	if fields.len == 0 {
		b.writeln('\treturn 0')
	} else {
		b.writeln('\tmut n := 0')
		for fld in fields {
			g.emit_size_field(mut b, scope, vname, fld)!
		}
		b.writeln('\treturn n')
	}
	b.writeln('}')

	b.writeln('')
	b.writeln('pub fn (m &${vname}) encode_to(mut e protobuf.Encoder) {')
	for fld in fields {
		g.emit_encode_field(mut b, scope, vname, fld)!
	}
	b.writeln('}')

	b.writeln('')
	b.writeln('pub fn (m &${vname}) encode() []u8 {')
	b.writeln('\tmut e := protobuf.Encoder{')
	b.writeln('\t\tbuf: []u8{cap: m.encoded_size()}')
	b.writeln('\t}')
	b.writeln('\tm.encode_to(mut e)')
	b.writeln('\treturn e.buf')
	b.writeln('}')

	b.writeln('')
	b.writeln('pub fn ${vname}.decode(buf []u8) !${vname} {')
	b.writeln('\tmut m := ${vname}{}')
	b.writeln('\tmut d := protobuf.Decoder{')
	b.writeln('\t\tbuf: buf')
	b.writeln('\t}')
	b.writeln('\tfor d.more() {')
	b.writeln('\t\tfield, wt := d.read_tag()!')
	b.writeln('\t\tmatch field {')
	for fld in fields {
		g.emit_decode_field(mut b, scope, vname, fld)!
	}
	b.writeln('\t\t\telse {')
	b.writeln('\t\t\t\td.skip(wt)!')
	b.writeln('\t\t\t}')
	b.writeln('\t\t}')
	b.writeln('\t}')
	b.writeln('\treturn m')
	b.writeln('}')

	for c in m.messages {
		g.emit_message(mut b, scope, c)!
	}
}

fn (mut g Gen) emit_encode_field(mut b strings.Builder, scope []string, vname string, fld Field) ! {
	info := g.field_info(scope, vname, fld)!
	name := sanitize(fld.name)
	n := fld.number
	if fld.is_map {
		val_write := match info.kind {
			.scalar { 'e.${tagged_writer(fld.typ)}(2, v)' }
			.enum_ { 'e.write_int32_field(2, int(v))' }
			.message { 'e.write_tag(2, .len_delim)\n\t\t\te.write_varint(u64(v.encoded_size()))\n\t\t\tv.encode_to(mut e)' }
		}
		b.writeln('\tif m.${name}.len > 0 {')
		b.writeln('\t\tmut ${name}_keys := m.${name}.keys()')
		b.writeln('\t\t${name}_keys.sort()')
		b.writeln('\t\tfor k in ${name}_keys {')
		b.writeln('\t\t\tv := m.${name}[k]')
		b.writeln('\t\t\te.write_tag(${n}, .len_delim)')
		b.writeln('\t\t\te.write_varint(u64(${map_entry_size_expr(fld, info)}))')
		b.writeln('\t\t\te.${tagged_writer(fld.key_typ)}(1, k)')
		b.writeln('\t\t\t${val_write}')
		b.writeln('\t\t}')
		b.writeln('\t}')
		return
	}
	if fld.label == .repeated {
		if info.kind == .message {
			b.writeln('\tfor v in m.${name} {')
			b.writeln('\t\te.write_tag(${n}, .len_delim)')
			b.writeln('\t\te.write_varint(u64(v.encoded_size()))')
			b.writeln('\t\tv.encode_to(mut e)')
			b.writeln('\t}')
			return
		}
		packed := if fld.has_packed { fld.packed } else { true }
		if info.kind == .enum_ {
			if packed {
				b.writeln('\tif m.${name}.len > 0 {')
				b.writeln('\t\tmut p := 0')
				b.writeln('\t\tfor v in m.${name} {')
				b.writeln('\t\t\tp += protobuf.varint_len(u64(i64(int(v))))')
				b.writeln('\t\t}')
				b.writeln('\t\te.write_tag(${n}, .len_delim)')
				b.writeln('\t\te.write_varint(u64(p))')
				b.writeln('\t\tfor v in m.${name} {')
				b.writeln('\t\t\te.write_varint(u64(i64(int(v))))')
				b.writeln('\t\t}')
				b.writeln('\t}')
			} else {
				b.writeln('\tfor v in m.${name} {')
				b.writeln('\t\te.write_int32_field(${n}, int(v))')
				b.writeln('\t}')
			}
			return
		}
		// scalar
		if is_packable(fld.typ) && packed {
			w := packed_elem_width(fld.typ)
			b.writeln('\tif m.${name}.len > 0 {')
			if w > 0 {
				mult := if w == 1 { 'm.${name}.len' } else { 'm.${name}.len * ${w}' }
				b.writeln('\t\te.write_tag(${n}, .len_delim)')
				b.writeln('\t\te.write_varint(u64(${mult}))')
			} else {
				b.writeln('\t\tmut p := 0')
				b.writeln('\t\tfor v in m.${name} {')
				b.writeln('\t\t\tp += ${packed_elem_size_expr(fld.typ, 'v')}')
				b.writeln('\t\t}')
				b.writeln('\t\te.write_tag(${n}, .len_delim)')
				b.writeln('\t\te.write_varint(u64(p))')
			}
			b.writeln('\t\tfor v in m.${name} {')
			b.writeln('\t\t\t${packed_write_stmt(fld.typ, 'v')}')
			b.writeln('\t\t}')
			b.writeln('\t}')
		} else {
			b.writeln('\tfor v in m.${name} {')
			b.writeln('\t\te.${tagged_writer(fld.typ)}(${n}, v)')
			b.writeln('\t}')
		}
		return
	}
	match info.kind {
		.message {
			b.writeln('\tif ${name} := m.${name} {')
			b.writeln('\t\te.write_tag(${n}, .len_delim)')
			b.writeln('\t\te.write_varint(u64(${name}.encoded_size()))')
			b.writeln('\t\t${name}.encode_to(mut e)')
			b.writeln('\t}')
		}
		.enum_ {
			if fld.label == .optional {
				b.writeln('\tif ${name} := m.${name} {')
				b.writeln('\t\te.write_int32_field(${n}, int(${name}))')
				b.writeln('\t}')
			} else {
				b.writeln('\tif int(m.${name}) != 0 {')
				b.writeln('\t\te.write_int32_field(${n}, int(m.${name}))')
				b.writeln('\t}')
			}
		}
		.scalar {
			if fld.label == .optional {
				b.writeln('\tif ${name} := m.${name} {')
				b.writeln('\t\te.${tagged_writer(fld.typ)}(${n}, ${name})')
				b.writeln('\t}')
			} else {
				b.writeln('\tif ${zero_check(fld.typ, 'm.${name}')} {')
				b.writeln('\t\te.${tagged_writer(fld.typ)}(${n}, m.${name})')
				b.writeln('\t}')
			}
		}
	}
}

// mirrors emit_encode_field exactly — every condition here must match the
// write path or the presized buffer will be wrong
fn (mut g Gen) emit_size_field(mut b strings.Builder, scope []string, vname string, fld Field) ! {
	info := g.field_info(scope, vname, fld)!
	name := sanitize(fld.name)
	n := fld.number
	if fld.is_map {
		// fixed-width scalar values never reference v in the size expr
		vvar := if info.kind == .scalar && packed_elem_width(fld.typ) > 0 { '_' } else { 'v' }
		b.writeln('\tfor k, ${vvar} in m.${name} {')
		b.writeln('\t\tn += protobuf.len_field_len(${n}, ${map_entry_size_expr(fld, info)})')
		b.writeln('\t}')
		return
	}
	if fld.label == .repeated {
		if info.kind == .message {
			b.writeln('\tfor v in m.${name} {')
			b.writeln('\t\tn += protobuf.len_field_len(${n}, v.encoded_size())')
			b.writeln('\t}')
			return
		}
		packed := if fld.has_packed { fld.packed } else { true }
		if info.kind == .enum_ {
			if packed {
				b.writeln('\tif m.${name}.len > 0 {')
				b.writeln('\t\tmut p := 0')
				b.writeln('\t\tfor v in m.${name} {')
				b.writeln('\t\t\tp += protobuf.varint_len(u64(i64(int(v))))')
				b.writeln('\t\t}')
				b.writeln('\t\tn += protobuf.len_field_len(${n}, p)')
				b.writeln('\t}')
			} else {
				b.writeln('\tfor v in m.${name} {')
				b.writeln('\t\tn += protobuf.tag_len(${n}) + protobuf.varint_len(u64(i64(int(v))))')
				b.writeln('\t}')
			}
			return
		}
		if is_packable(fld.typ) && packed {
			w := packed_elem_width(fld.typ)
			if w > 0 {
				mult := if w == 1 { 'm.${name}.len' } else { 'm.${name}.len * ${w}' }
				b.writeln('\tif m.${name}.len > 0 {')
				b.writeln('\t\tn += protobuf.len_field_len(${n}, ${mult})')
				b.writeln('\t}')
			} else {
				b.writeln('\tif m.${name}.len > 0 {')
				b.writeln('\t\tmut p := 0')
				b.writeln('\t\tfor v in m.${name} {')
				b.writeln('\t\t\tp += ${packed_elem_size_expr(fld.typ, 'v')}')
				b.writeln('\t\t}')
				b.writeln('\t\tn += protobuf.len_field_len(${n}, p)')
				b.writeln('\t}')
			}
		} else {
			b.writeln('\tfor v in m.${name} {')
			b.writeln('\t\tn += ${scalar_size_expr(fld.typ, n, 'v')}')
			b.writeln('\t}')
		}
		return
	}
	match info.kind {
		.message {
			b.writeln('\tif ${name} := m.${name} {')
			b.writeln('\t\tn += protobuf.len_field_len(${n}, ${name}.encoded_size())')
			b.writeln('\t}')
		}
		.enum_ {
			if fld.label == .optional {
				b.writeln('\tif ${name} := m.${name} {')
				b.writeln('\t\tn += protobuf.tag_len(${n}) + protobuf.varint_len(u64(i64(int(${name}))))')
				b.writeln('\t}')
			} else {
				b.writeln('\tif int(m.${name}) != 0 {')
				b.writeln('\t\tn += protobuf.tag_len(${n}) + protobuf.varint_len(u64(i64(int(m.${name}))))')
				b.writeln('\t}')
			}
		}
		.scalar {
			if fld.label == .optional {
				b.writeln('\tif ${name} := m.${name} {')
				b.writeln('\t\tn += ${scalar_size_expr(fld.typ, n, name)}')
				b.writeln('\t}')
			} else {
				b.writeln('\tif ${zero_check(fld.typ, 'm.${name}')} {')
				b.writeln('\t\tn += ${scalar_size_expr(fld.typ, n, 'm.${name}')}')
				b.writeln('\t}')
			}
		}
	}
}

fn (mut g Gen) emit_decode_field(mut b strings.Builder, scope []string, vname string, fld Field) ! {
	info := g.field_info(scope, vname, fld)!
	name := sanitize(fld.name)
	n := fld.number
	if fld.is_map {
		val_zero := match info.kind {
			.scalar { zero_literal(fld.typ) }
			.enum_ { 'unsafe { ${info.vtype}(0) }' }
			.message { '${info.vtype}{}' }
		}
		val_read := match info.kind {
			.scalar { 'sub.${scalar_reader(fld.typ)}()!' }
			.enum_ { 'unsafe { ${info.vtype}(sub.read_int32()!) }' }
			.message { '${info.vtype}.decode(sub.read_bytes()!)!' }
		}
		// missing key or value fields fall back to zero values; last entry
		// wins on duplicate keys, both per the proto3 spec
		b.writeln('\t\t\t${n} {')
		b.writeln('\t\t\t\tmut sub := protobuf.Decoder{')
		b.writeln('\t\t\t\t\tbuf: d.read_bytes()!')
		b.writeln('\t\t\t\t}')
		b.writeln('\t\t\t\tmut mk := ${zero_literal(fld.key_typ)}')
		b.writeln('\t\t\t\tmut mv := ${val_zero}')
		b.writeln('\t\t\t\tfor sub.more() {')
		b.writeln('\t\t\t\t\tmf, mw := sub.read_tag()!')
		b.writeln('\t\t\t\t\tmatch mf {')
		b.writeln('\t\t\t\t\t\t1 { mk = sub.${scalar_reader(fld.key_typ)}()! }')
		b.writeln('\t\t\t\t\t\t2 { mv = ${val_read} }')
		b.writeln('\t\t\t\t\t\telse { sub.skip(mw)! }')
		b.writeln('\t\t\t\t\t}')
		b.writeln('\t\t\t\t}')
		b.writeln('\t\t\t\tm.${name}[mk] = mv')
		b.writeln('\t\t\t}')
		return
	}
	if fld.label == .repeated {
		if info.kind == .message {
			b.writeln('\t\t\t${n} {')
			b.writeln('\t\t\t\tm.${name} << ${info.vtype}.decode(d.read_bytes()!)!')
			b.writeln('\t\t\t}')
			return
		}
		elem_d := if info.kind == .enum_ {
			'unsafe { ${info.vtype}(d.read_int32()!) }'
		} else {
			'd.${scalar_reader(fld.typ)}()!'
		}
		if is_packable(fld.typ) || info.kind == .enum_ {
			// proto3 parsers accept packed and expanded encodings
			elem_sub := if info.kind == .enum_ {
				'unsafe { ${info.vtype}(sub.read_int32()!) }'
			} else {
				'sub.${scalar_reader(fld.typ)}()!'
			}
			b.writeln('\t\t\t${n} {')
			b.writeln('\t\t\t\tif wt == .len_delim {')
			b.writeln('\t\t\t\t\tmut sub := protobuf.Decoder{')
			b.writeln('\t\t\t\t\t\tbuf: d.read_bytes()!')
			b.writeln('\t\t\t\t\t}')
			b.writeln('\t\t\t\t\tfor sub.more() {')
			b.writeln('\t\t\t\t\t\tm.${name} << ${elem_sub}')
			b.writeln('\t\t\t\t\t}')
			b.writeln('\t\t\t\t} else {')
			b.writeln('\t\t\t\t\tm.${name} << ${elem_d}')
			b.writeln('\t\t\t\t}')
			b.writeln('\t\t\t}')
		} else {
			b.writeln('\t\t\t${n} {')
			b.writeln('\t\t\t\tm.${name} << ${elem_d}')
			b.writeln('\t\t\t}')
		}
		return
	}
	b.writeln('\t\t\t${n} {')
	match info.kind {
		.message {
			b.writeln('\t\t\t\tm.${name} = ${info.vtype}.decode(d.read_bytes()!)!')
		}
		.enum_ {
			b.writeln('\t\t\t\tm.${name} = unsafe { ${info.vtype}(d.read_int32()!) }')
		}
		.scalar {
			b.writeln('\t\t\t\tm.${name} = d.${scalar_reader(fld.typ)}()!')
		}
	}
	b.writeln('\t\t\t}')
}
