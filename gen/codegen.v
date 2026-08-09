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
// - a oneof becomes ?SumType over one wrapper struct per arm (arms can
//   share an underlying type, so bare unions won't do); arms have explicit
//   presence — a set arm encodes even at its zero value, like protoc
// - unknown fields are preserved: every struct carries pb_unknown []u8
//   (raw wire bytes, arrival order) re-emitted after known fields, so a
//   decode/encode roundtrip through an older schema loses nothing. Note
//   V's == therefore treats unknowns as part of the value
// - recursion through singular message fields is rejected (a ?T field
//   stores its value inline in V, so the type would be infinitely sized)

pub struct GenOpts {
pub:
	module_name string = 'main'
	json        bool // also emit canonical-JSON (protojson) methods
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
mut:
	files        []File
	root_pkg     string
	json         bool
	syms         map[string]Sym    // fully-qualified proto name -> V symbol
	locs         map[string]MsgLoc // vname -> definition site, for the recursion walk
	cur_pkg      []string          // package segments of the file being emitted
	cur_file_pkg string
	boxed        map[string]bool   // "msg.full#fieldnum" -> field boxed as ?&T to break a recursion cycle
}

// where a message lives, so cross-file recursion walks resolve in the
// right package scope
struct MsgLoc {
	pkg     []string
	pkg_str string
	path    []string
	msg     Message
}

fn pkg_segments(pkg string) []string {
	if pkg == '' {
		return []
	}
	return pkg.split('.')
}

const v_keywords = ['as', 'asm', 'assert', 'atomic', 'break', 'const', 'continue', 'defer', 'dump',
	'else', 'enum', 'false', 'fn', 'for', 'go', 'goto', 'if', 'implements', 'import', 'in',
	'interface', 'is', 'isreftype', 'lock', 'match', 'module', 'mut', 'none', 'or', 'pub', 'return',
	'rlock', 'select', 'shared', 'sizeof', 'spawn', 'static', 'struct', 'true', 'type', 'typeof',
	'union', 'unsafe', 'volatile']

// V struct field names must be lowercase (V rejects uppercase in field names),
// so identifiers are lowercased. JSON names derive from the original proto name
// separately, and the wire uses field numbers, so this is purely the in-memory
// identifier. Keyword clashes get a trailing underscore.
fn sanitize(name string) string {
	mut low := name.to_lower()
	// V rejects field names that start with `_`
	for low.starts_with('_') {
		low = low[1..]
	}
	if low == '' {
		low = 'field'
	}
	if low in v_keywords {
		return low + '_'
	}
	return low
}

// proto snake_case to a V type-name suffix: text_msg -> TextMsg
fn camel(name string) string {
	mut out := ''
	for part in name.split('_') {
		if part == '' {
			continue
		}
		out += part[..1].to_upper() + part[1..]
	}
	return out
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

// V map container key type. proto bool cannot key a V map, so bool keys are
// stored as int (0=false, 1=true); every other key maps to its V scalar type.
// The wire and JSON forms stay true to `bool` — only the in-memory key differs.
fn map_key_v_type(key_typ string) string {
	return if key_typ == 'bool' { 'int' } else { v_scalar_type(key_typ) }
}

// encode expr for map-entry key (field 1); `k` is the V key value.
fn map_key_write(key_typ string) string {
	return if key_typ == 'bool' {
		'e.write_bool_field(1, k != 0)'
	} else {
		'e.${tagged_writer(key_typ)}(1, k)'
	}
}

// decode expr yielding the V key value from map-entry field 1.
fn map_key_read(key_typ string) string {
	return if key_typ == 'bool' {
		'if sub.read_bool()! { 1 } else { 0 }'
	} else {
		'sub.${scalar_reader(key_typ)}()!'
	}
}

// zero value for the V key type.
fn map_key_zero(key_typ string) string {
	return if key_typ == 'bool' { '0' } else { zero_literal(key_typ) }
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
	return generate_set(FileSet{ root: f, files: [f] }, opts)
}

pub fn generate_set(fs FileSet, opts GenOpts) !string {
	mut g := Gen{
		files:    fs.files
		root_pkg: fs.root.package
		json:     opts.json
	}
	for f in fs.files {
		g.register_file(f)!
	}
	g.check_recursion()!
	// services emit nothing here (stub codegen is transport-level work),
	// but their types must still resolve so typos fail at generate time
	for f in fs.files {
		g.set_cur(f)
		for svc in f.services {
			for mth in svc.methods {
				for t in [mth.input, mth.output] {
					sym := g.resolve_in_pkg([], t) or {
						return error('service ${svc.name}: unknown type `${t}` for rpc ${mth.name}')
					}
					if sym.is_enum {
						return error('service ${svc.name}: rpc ${mth.name} type `${t}` must be a message')
					}
				}
			}
		}
	}
	mut b := strings.new_builder(8192)
	b.writeln('// Code generated by protobuf.gen. DO NOT EDIT.')
	b.writeln('module ${opts.module_name}')
	if fs.files.any(it.messages.len > 0) {
		b.writeln('')
		if g.json {
			b.writeln('import json2')
		}
		b.writeln('import protobuf')
		// the time mappings emitted with the well-known types need it
		if 'google.protobuf.Timestamp' in g.syms || 'google.protobuf.Duration' in g.syms {
			b.writeln('import time')
		}
	}
	for f in fs.files {
		g.set_cur(f)
		for e in f.enums {
			g.emit_enum(mut b, [], e)!
		}
		for m in f.messages {
			g.emit_enums_in(mut b, [], m)!
		}
	}
	for f in fs.files {
		g.set_cur(f)
		for m in f.messages {
			g.emit_message(mut b, [], m)!
		}
	}
	// whole-fileset Any JSON resolver: dispatches type_url -> concrete
	// type for canonical @type expansion. No runtime registry needed —
	// every packable type is in this fileset, so a match covers them all.
	if g.json {
		if _ := g.any_vname() {
			g.emit_any_json_resolver(mut b)
		}
	}
	return b.str()
}

// pb_any_to_json / pb_any_from_json: the generated Any resolver, one match
// arm per message in the fileset. `wrapped` = value-wrapped WKT form.
fn (mut g Gen) emit_any_json_resolver(mut b strings.Builder) {
	b.writeln('')
	b.writeln('fn pb_any_to_json(pb_name string, pb_value []u8) !(json2.Any, bool) {')
	b.writeln('\tmatch pb_name {')
	for vname, loc in g.locs {
		full := g.loc_full_name(loc)
		wrapped := loc.pkg_str == 'google.protobuf' && wkt_value_wrapped(loc.msg.name)
		b.writeln("\t\t'${full}' {")
		b.writeln('\t\t\treturn ${vname}.decode(pb_value)!.json_value(), ${wrapped}')
		b.writeln('\t\t}')
	}
	b.writeln("\t\telse { return error('protojson: unresolvable Any type `\${pb_name}`') }")
	b.writeln('\t}')
	b.writeln('}')
	b.writeln('')
	b.writeln('fn pb_any_from_json(pb_name string, pb_obj map[string]json2.Any) ![]u8 {')
	b.writeln('\tmatch pb_name {')
	for vname, loc in g.locs {
		full := g.loc_full_name(loc)
		wrapped := loc.pkg_str == 'google.protobuf' && wkt_value_wrapped(loc.msg.name)
		b.writeln("\t\t'${full}' {")
		if wrapped {
			b.writeln("\t\t\tpb_v := pb_obj['value'] or { return error('protojson: Any of ${full} missing \"value\"') }")
			b.writeln('\t\t\treturn ${vname}.from_json_value(pb_v)!.encode()')
		} else {
			b.writeln('\t\t\tmut pb_inner := pb_obj.clone()')
			b.writeln("\t\t\tpb_inner.delete('@type')")
			b.writeln('\t\t\treturn ${vname}.from_json_value(json2.Any(pb_inner))!.encode()')
		}
		b.writeln('\t\t}')
	}
	b.writeln("\t\telse { return error('protojson: unresolvable Any type `\${pb_name}`') }")
	b.writeln('\t}')
	b.writeln('}')
}

fn (g &Gen) loc_full_name(loc MsgLoc) string {
	mut parts := []string{}
	if loc.pkg_str != '' {
		parts << loc.pkg_str
	}
	parts << loc.path
	parts << loc.msg.name
	return parts.join('.')
}

fn (mut g Gen) set_cur(f File) {
	g.cur_pkg = pkg_segments(f.package)
	g.cur_file_pkg = f.package
}

// V type name for a definition: root-package types keep bare flattened
// names; foreign packages get a CamelCased package prefix so two packages
// can define the same message name
fn (g &Gen) vname_for(pkg string, path []string, name string) string {
	base := v_type_name(path, name)
	if pkg == g.root_pkg {
		return base
	}
	prefix := pkg.split('.').map(camel(it)).join('')
	return '${prefix}_${base}'
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

fn (mut g Gen) register_file(f File) ! {
	pkg := pkg_segments(f.package)
	for m in f.messages {
		g.register_message(pkg, f.package, [], m)!
	}
	for e in f.enums {
		g.register_enum(pkg, f.package, [], e)!
	}
}

fn (mut g Gen) register_message(pkg []string, pkg_str string, path []string, m Message) ! {
	mut full := pkg.clone()
	full << path
	key := qualify(full, m.name)
	if key in g.syms {
		return error('duplicate type ${key} across files')
	}
	vname := g.vname_for(pkg_str, path, m.name)
	g.syms[key] = Sym{
		vname:   vname
		is_enum: false
	}
	g.locs[vname] = MsgLoc{
		pkg:     pkg
		pkg_str: pkg_str
		path:    path
		msg:     m
	}
	mut sub := path.clone()
	sub << m.name
	for c in m.messages {
		g.register_message(pkg, pkg_str, sub, c)!
	}
	for e in m.enums {
		g.register_enum(pkg, pkg_str, sub, e)!
	}
}

fn (mut g Gen) register_enum(pkg []string, pkg_str string, path []string, e Enum) ! {
	mut full := pkg.clone()
	full << path
	key := qualify(full, e.name)
	if key in g.syms {
		return error('duplicate type ${key} across files')
	}
	g.syms[key] = Sym{
		vname:   g.vname_for(pkg_str, path, e.name)
		is_enum: true
	}
}

// proto name resolution: innermost enclosing scope outward through the
// package levels to the root, which also matches fully-qualified
// references to other packages
fn (g &Gen) resolve(scope []string, typ_ string) ?Sym {
	mut typ := typ_
	if typ.starts_with('.') {
		return g.syms[typ[1..]] or { return none }
	}
	for i := scope.len; i >= 0; i-- {
		key := if i == 0 { typ } else { scope[..i].join('.') + '.' + typ }
		if key in g.syms {
			return g.syms[key]
		}
	}
	return none
}

// resolve from a message scope inside the current file: the package
// segments are the outermost scope levels
fn (g &Gen) resolve_in_pkg(scope []string, typ string) ?Sym {
	mut full := g.cur_pkg.clone()
	full << scope
	return g.resolve(full, typ)
}

fn (g &Gen) field_info(scope []string, msg_name string, fld Field) !FieldInfo {
	st := v_scalar_type(fld.typ)
	if st != '' {
		return FieldInfo{
			kind:  .scalar
			vtype: st
		}
	}
	sym := g.resolve_in_pkg(scope, fld.typ) or {
		return error('message ${msg_name}: unknown type `${fld.typ}` for field ${fld.name}')
	}
	return FieldInfo{
		kind:  if sym.is_enum { FieldKind.enum_ } else { FieldKind.message }
		vtype: sym.vname
		sym:   sym
	}
}

// A cycle through singular message fields would make the V struct infinitely
// sized (?T stores inline), so we DFS the type graph and mark the back-edge
// field that closes each cycle for ?&T boxing (an optional heap pointer, the
// only recursive struct shape V allows). repeated/map/oneof fields are already
// heap-backed and break cycles on their own, so they are never boxed.
fn (mut g Gen) check_recursion() ! {
	mut state := map[string]int{} // 0 unvisited, 1 in-progress, 2 done
	for f in g.files {
		pkg := pkg_segments(f.package)
		for m in f.messages {
			g.dfs(pkg, [], m, mut state)!
		}
	}
}

fn (mut g Gen) dfs(pkg []string, path []string, m Message, mut state map[string]int) ! {
	mut fullpath := pkg.clone()
	fullpath << path
	full := qualify(fullpath, m.name)
	if state[full] != 0 {
		// already done, or on the stack (reached via an already-boxed back-edge)
		return
	}
	state[full] = 1
	mut scope := path.clone()
	scope << m.name
	mut rscope := pkg.clone()
	rscope << scope
	for fld in m.fields {
		if fld.label == .repeated || fld.is_map || fld.oneof != '' {
			continue
		}
		if v_scalar_type(fld.typ) != '' {
			continue
		}
		sym := g.resolve(rscope, fld.typ) or { continue }
		if sym.is_enum {
			continue
		}
		loc := g.locs[sym.vname] or { continue }
		mut tp := loc.pkg.clone()
		tp << loc.path
		target_full := qualify(tp, loc.msg.name)
		if state[target_full] == 1 {
			// back-edge into an in-progress type: box this field to break the cycle
			g.boxed['${full}#${fld.number}'] = true
			continue
		}
		g.dfs(loc.pkg, loc.path, loc.msg, mut state)!
	}
	state[full] = 2
	for c in m.messages {
		g.dfs(pkg, scope, c, mut state)!
	}
}

// is this singular message field marked for ?&T boxing to break a recursion cycle?
fn (g &Gen) is_boxed(scope []string, fnum int) bool {
	if g.boxed.len == 0 {
		return false
	}
	mut fp := g.cur_pkg.clone()
	fp << scope
	return '${fp.join('.')}#${fnum}' in g.boxed
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
			if !e.allow_alias {
				return error('enum ${e.name}: aliased values require `option allow_alias = true`')
			}
			continue
		}
		seen[val.number] = true
	}
	b.writeln('')
	b.writeln('pub enum ${g.vname_for(g.cur_file_pkg, path, e.name)} {')
	// aliases share a number; V enums need distinct values, so keep the first
	// name per number (the canonical one protojson emits) and drop the rest
	mut emitted := map[int]bool{}
	for val in e.values {
		if val.number in emitted {
			continue
		}
		emitted[val.number] = true
		b.writeln('\t${sanitize(val.name.to_lower())} = ${val.number}')
	}
	b.writeln('}')
	if g.json {
		g.emit_enum_json(mut b, g.vname_for(g.cur_file_pkg, path, e.name), e)
	}
}

fn (mut g Gen) emit_message(mut b strings.Builder, path []string, m Message) ! {
	vname := g.vname_for(g.cur_file_pkg, path, m.name)
	mut scope := path.clone()
	scope << m.name

	for o in m.oneofs {
		mut arm_types := []string{}
		for fld in m.fields {
			if fld.oneof != o.name {
				continue
			}
			info := g.field_info(scope, vname, fld)!
			at := '${vname}_${camel(fld.name)}'
			arm_types << at
			b.writeln('')
			b.writeln('pub struct ${at} {')
			b.writeln('pub mut:')
			b.writeln('\tvalue ${info.vtype}')
			b.writeln('}')
		}
		b.writeln('')
		b.writeln('pub type ${vname}_${camel(o.name)} = ' + arm_types.join(' | '))
	}

	for fld in m.fields {
		if sanitize(fld.name) == 'pb_unknown' || sanitize(fld.oneof) == 'pb_unknown' {
			return error('message ${m.name}: field name `pb_unknown` is reserved for unknown-field preservation')
		}
	}
	b.writeln('')
	b.writeln('pub struct ${vname} {')
	b.writeln('pub mut:')
	mut seen_oneofs := map[string]bool{}
	for fld in m.fields {
		if fld.oneof != '' {
			if fld.oneof in seen_oneofs {
				continue
			}
			seen_oneofs[fld.oneof] = true
			b.writeln('\t${sanitize(fld.oneof)} ?${vname}_${camel(fld.oneof)}')
			continue
		}
		info := g.field_info(scope, vname, fld)!
		mut t := info.vtype
		if fld.is_map {
			t = 'map[${map_key_v_type(fld.key_typ)}]${t}'
		} else if fld.label == .repeated {
			t = '[]${t}'
		} else if fld.label == .optional || info.kind == .message {
			if info.kind == .message && g.is_boxed(scope, fld.number) {
				t = '?&${t}' // recursive field: optional heap pointer
			} else {
				t = '?${t}'
			}
		}
		// [deprecated = true] → V's field attribute (warns cross-module)
		attr := if fld.deprecated { ' @[deprecated]' } else { '' }
		b.writeln('\t${sanitize(fld.name)} ${t}${attr}')
	}
	b.writeln('\tpb_unknown []u8 // unrecognized fields, re-emitted on encode')
	b.writeln('}')

	// recursive messages hold ?&T fields, which V's autogenerated == compares
	// by pointer; emit value equality via the canonical (deterministic) encoding
	mut has_boxed := false
	for fld in m.fields {
		if g.is_boxed(scope, fld.number) {
			has_boxed = true
			break
		}
	}
	if has_boxed {
		b.writeln('')
		b.writeln('pub fn (a ${vname}) == (b ${vname}) bool {')
		b.writeln('\treturn a.encode() == b.encode()')
		b.writeln('}')
	}

	mut fields := m.fields.clone()
	fields.sort(a.number < b.number)

	b.writeln('')
	b.writeln('pub fn (m &${vname}) encoded_size() int {')
	if fields.len == 0 {
		b.writeln('\treturn m.pb_unknown.len')
	} else {
		b.writeln('\tmut n := 0')
		for fld in fields {
			g.emit_size_field(mut b, scope, vname, fld)!
		}
		b.writeln('\treturn n + m.pb_unknown.len')
	}
	b.writeln('}')

	b.writeln('')
	b.writeln('pub fn (m &${vname}) encode_to(mut e protobuf.Encoder) {')
	for fld in fields {
		g.emit_encode_field(mut b, scope, vname, fld)!
	}
	b.writeln('\te.write_raw(m.pb_unknown)')
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
	if fields.len == 0 {
		b.writeln('\t\ttag_start := d.pos')
		b.writeln('\t\t_, wt := d.read_tag()!')
		b.writeln('\t\td.skip(wt)!')
		b.writeln('\t\tm.pb_unknown << d.buf[tag_start..d.pos]')
	} else {
		b.writeln('\t\ttag_start := d.pos')
		b.writeln('\t\tfield, wt := d.read_tag()!')
		b.writeln('\t\tmatch field {')
		for fld in fields {
			g.emit_decode_field(mut b, scope, vname, fld)!
		}
		b.writeln('\t\t\telse {')
		b.writeln('\t\t\t\td.skip(wt)!')
		b.writeln('\t\t\t\tm.pb_unknown << d.buf[tag_start..d.pos]')
		b.writeln('\t\t\t}')
		b.writeln('\t\t}')
	}
	b.writeln('\t}')
	b.writeln('\treturn m')
	b.writeln('}')

	if g.cur_file_pkg == 'google.protobuf' && path.len == 0 {
		g.emit_wkt_mappings(mut b, vname, m.name)
	}
	// google.protobuf.Any pack/unpack, only when Any is in the fileset
	if any_v := g.any_vname() {
		g.emit_any_helpers(mut b, vname, g.proto_full_name(path, m.name), any_v)
	}
	if g.json {
		g.emit_json_methods(mut b, vname, scope, path, m)!
	}

	for c in m.messages {
		g.emit_message(mut b, scope, c)!
	}
}

// the V type name of google.protobuf.Any if the fileset defines it
fn (g &Gen) any_vname() ?string {
	sym := g.syms['google.protobuf.Any'] or { return none }
	return sym.vname
}

// dotted proto full name (package + nesting + name), for Any type_urls
fn (g &Gen) proto_full_name(path []string, name string) string {
	mut parts := []string{}
	if g.cur_file_pkg != '' {
		parts << g.cur_file_pkg
	}
	parts << path
	parts << name
	return parts.join('.')
}

// to_any packs the message; <T>.from_any unpacks (verifying the type name).
// Caller names the target type — no runtime registry needed.
fn (mut g Gen) emit_any_helpers(mut b strings.Builder, vname string, full_name string, any_v string) {
	b.writeln('')
	b.writeln('pub fn (m &${vname}) to_any() ${any_v} {')
	b.writeln('\treturn ${any_v}{')
	b.writeln("\t\ttype_url: 'type.googleapis.com/${full_name}'")
	b.writeln('\t\tvalue:    m.encode()')
	b.writeln('\t}')
	b.writeln('}')
	b.writeln('')
	b.writeln('pub fn ${vname}.from_any(a ${any_v}) !${vname} {')
	b.writeln("\tgot := a.type_url.all_after_last('/')")
	b.writeln("\tif got != '${full_name}' {")
	b.writeln("\t\treturn error('protobuf: Any holds `\${got}`, not `${full_name}`')")
	b.writeln('\t}')
	b.writeln('\treturn ${vname}.decode(a.value)!')
	b.writeln('}')
}

// idiomatic V conversions on the well-known types, detected by
// fully-qualified name like protoc does
fn (mut g Gen) emit_wkt_mappings(mut b strings.Builder, vname string, name string) {
	match name {
		'Timestamp' {
			b.writeln('')
			b.writeln('// as_time converts to time.Time (UTC); out-of-spec nanos are clamped')
			b.writeln('pub fn (m &${vname}) as_time() time.Time {')
			b.writeln('\tmut n := m.nanos')
			b.writeln('\tif n < 0 {')
			b.writeln('\t\tn = 0')
			b.writeln('\t} else if n > 999_999_999 {')
			b.writeln('\t\tn = 999_999_999')
			b.writeln('\t}')
			b.writeln('\treturn time.unix_nanosecond(m.seconds, n)')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_time(t time.Time) ${vname} {')
			b.writeln('\treturn ${vname}{')
			b.writeln('\t\tseconds: t.unix()')
			b.writeln('\t\tnanos:   t.nanosecond')
			b.writeln('\t}')
			b.writeln('}')
		}
		'Duration' {
			b.writeln('')
			b.writeln('// as_duration saturates at the i64-nanosecond range (~±292 years),')
			b.writeln('// like protobuf-go — proto durations span ±10000 years')
			b.writeln('pub fn (m &${vname}) as_duration() time.Duration {')
			b.writeln('\tif m.seconds >= 9223372037 {')
			b.writeln('\t\treturn time.Duration(i64(9223372036854775807))')
			b.writeln('\t}')
			b.writeln('\tif m.seconds <= -9223372037 {')
			b.writeln('\t\treturn time.Duration(i64(-9223372036854775807) - 1)')
			b.writeln('\t}')
			b.writeln('\tsecs_ns := m.seconds * 1_000_000_000')
			b.writeln('\tif secs_ns > 0 && i64(m.nanos) > 9223372036854775807 - secs_ns {')
			b.writeln('\t\treturn time.Duration(i64(9223372036854775807))')
			b.writeln('\t}')
			b.writeln('\tif secs_ns < 0 && i64(m.nanos) < (i64(-9223372036854775807) - 1) - secs_ns {')
			b.writeln('\t\treturn time.Duration(i64(-9223372036854775807) - 1)')
			b.writeln('\t}')
			b.writeln('\treturn time.Duration(secs_ns + i64(m.nanos))')
			b.writeln('}')
			b.writeln('')
			b.writeln('pub fn ${vname}.from_duration(d time.Duration) ${vname} {')
			b.writeln('\treturn ${vname}{')
			b.writeln('\t\tseconds: i64(d) / 1_000_000_000')
			b.writeln('\t\tnanos:   int(i64(d) % 1_000_000_000)')
			b.writeln('\t}')
			b.writeln('}')
		}
		'Any' {
			b.writeln('')
			b.writeln('// the packed message type name (the type_url after the last /)')
			b.writeln('pub fn (m &${vname}) type_name() string {')
			b.writeln("\treturn m.type_url.all_after_last('/')")
			b.writeln('}')
		}
		else {}
	}
}

fn (mut g Gen) emit_encode_field(mut b strings.Builder, scope []string, vname string, fld Field) ! {
	info := g.field_info(scope, vname, fld)!
	name := sanitize(fld.name)
	n := fld.number
	if fld.oneof != '' {
		arm_write := match info.kind {
			.scalar { 'e.${tagged_writer(fld.typ)}(${n}, ov.value)' }
			.enum_ { 'e.write_int32_field(${n}, int(ov.value))' }
			.message { 'e.write_tag(${n}, .len_delim)\n\t\t\te.write_varint(u64(ov.value.encoded_size()))\n\t\t\tov.value.encode_to(mut e)' }
		}
		b.writeln('\tif ov := m.${sanitize(fld.oneof)} {')
		b.writeln('\t\tif ov is ${vname}_${camel(fld.name)} {')
		b.writeln('\t\t\t${arm_write}')
		b.writeln('\t\t}')
		b.writeln('\t}')
		return
	}
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
		b.writeln('\t\t\t${map_key_write(fld.key_typ)}')
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
	if fld.oneof != '' {
		arm_size := match info.kind {
			.scalar { scalar_size_expr(fld.typ, n, 'ov.value') }
			.enum_ { 'protobuf.tag_len(${n}) + protobuf.varint_len(u64(i64(int(ov.value))))' }
			.message { 'protobuf.len_field_len(${n}, ov.value.encoded_size())' }
		}
		b.writeln('\tif ov := m.${sanitize(fld.oneof)} {')
		b.writeln('\t\tif ov is ${vname}_${camel(fld.name)} {')
		b.writeln('\t\t\tn += ${arm_size}')
		b.writeln('\t\t}')
		b.writeln('\t}')
		return
	}
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
			// unpacked: fixed-width scalars never reference v in the size expr
			vvar := if packed_elem_width(fld.typ) > 0 { '_' } else { 'v' }
			b.writeln('\tfor ${vvar} in m.${name} {')
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
	if fld.oneof != '' {
		arm_read := match info.kind {
			.scalar { 'd.${scalar_reader(fld.typ)}()!' }
			.enum_ { 'unsafe { ${info.vtype}(d.read_int32()!) }' }
			.message { '${info.vtype}.decode(d.read_view()!)!' }
		}
		b.writeln('\t\t\t${n} {')
		b.writeln('\t\t\t\tm.${sanitize(fld.oneof)} = ${vname}_${camel(fld.name)}{')
		b.writeln('\t\t\t\t\tvalue: ${arm_read}')
		b.writeln('\t\t\t\t}')
		b.writeln('\t\t\t}')
		return
	}
	if fld.is_map {
		val_zero := match info.kind {
			.scalar { zero_literal(fld.typ) }
			.enum_ { 'unsafe { ${info.vtype}(0) }' }
			.message { '${info.vtype}{}' }
		}
		val_read := match info.kind {
			.scalar { 'sub.${scalar_reader(fld.typ)}()!' }
			.enum_ { 'unsafe { ${info.vtype}(sub.read_int32()!) }' }
			.message { '${info.vtype}.decode(sub.read_view()!)!' }
		}
		// missing key or value fields fall back to zero values; last entry
		// wins on duplicate keys, both per the proto3 spec
		b.writeln('\t\t\t${n} {')
		b.writeln('\t\t\t\tmut sub := protobuf.Decoder{')
		b.writeln('\t\t\t\t\tbuf: d.read_view()!')
		b.writeln('\t\t\t\t}')
		b.writeln('\t\t\t\tmut mk := ${map_key_zero(fld.key_typ)}')
		b.writeln('\t\t\t\tmut mv := ${val_zero}')
		b.writeln('\t\t\t\tfor sub.more() {')
		b.writeln('\t\t\t\t\tmf, mw := sub.read_tag()!')
		b.writeln('\t\t\t\t\tmatch mf {')
		b.writeln('\t\t\t\t\t\t1 { mk = ${map_key_read(fld.key_typ)} }')
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
			b.writeln('\t\t\t\tm.${name} << ${info.vtype}.decode(d.read_view()!)!')
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
			b.writeln('\t\t\t\t\t\tbuf: d.read_view()!')
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
			if g.is_boxed(scope, fld.number) {
				b.writeln('\t\t\t\tbox_${name} := ${info.vtype}.decode(d.read_view()!)!')
				b.writeln('\t\t\t\tm.${name} = &box_${name}')
			} else {
				b.writeln('\t\t\t\tm.${name} = ${info.vtype}.decode(d.read_view()!)!')
			}
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
