module gen

// proto3 subset parser: syntax, package, message, enum, scalar/repeated/map
// fields, oneof, service/rpc, nested messages/enums, reserved/option
// skipping. Unsupported constructs (import, proto2-isms) error loudly
// rather than mis-parse.

pub struct File {
pub mut:
	package  string
	imports  []string // import paths as written; `public` folds into these
	messages []Message
	enums    []Enum
	services []Service
}

pub struct Service {
pub mut:
	name    string
	methods []Method
}

pub struct Method {
pub mut:
	name             string
	input            string // request type as written
	output           string // response type as written
	client_streaming bool
	server_streaming bool
}

pub struct Message {
pub mut:
	name     string
	fields   []Field
	messages []Message
	enums    []Enum
	oneofs   []Oneof
}

// arms live in Message.fields (tagged with Field.oneof) so numbering and
// wire-order sorting see them; this records the grouping
pub struct Oneof {
pub mut:
	name string
	arms []string // arm field names, declaration order
}

pub struct Enum {
pub mut:
	name   string
	values []EnumValue
}

pub struct EnumValue {
pub mut:
	name   string
	number int
}

pub enum Label {
	plain
	repeated
	optional
}

pub struct Field {
pub mut:
	label      Label
	typ        string // proto type as written: scalar name or (qualified) message/enum
	name       string
	number     int
	has_packed bool // explicit [packed=...] option present
	packed     bool
	is_map     bool
	key_typ    string // map key type; typ holds the value type
	oneof      string // enclosing oneof name, empty for regular fields
	json_name  string // explicit [json_name = "..."] override; empty = derive lowerCamel
	deprecated bool   // [deprecated = true]
}

// integral and string types; proto3 also allows bool, but V maps cannot
// key on bool, so it is rejected at parse
const map_key_types = ['int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64', 'fixed32', 'fixed64',
	'sfixed32', 'sfixed64', 'string']

enum TokenKind {
	ident
	str
	num
	punct
	eof
}

struct Token {
	kind TokenKind
	lit  string
	line int
}

fn is_ident_start(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

// dots stay inside ident tokens so qualified names arrive whole
fn is_ident_char(c u8) bool {
	return is_ident_start(c) || (c >= `0` && c <= `9`) || c == `.`
}

fn tokenize(src string) ![]Token {
	mut toks := []Token{}
	mut i := 0
	mut line := 1
	for i < src.len {
		c := src[i]
		if c == `\n` {
			line++
			i++
			continue
		}
		if c == ` ` || c == `\t` || c == `\r` {
			i++
			continue
		}
		if c == `/` && i + 1 < src.len && src[i + 1] == `/` {
			for i < src.len && src[i] != `\n` {
				i++
			}
			continue
		}
		if c == `/` && i + 1 < src.len && src[i + 1] == `*` {
			i += 2
			for i + 1 < src.len && !(src[i] == `*` && src[i + 1] == `/`) {
				if src[i] == `\n` {
					line++
				}
				i++
			}
			if i + 1 >= src.len {
				return error('line ${line}: unterminated block comment')
			}
			i += 2
			continue
		}
		if c == `"` || c == `'` {
			quote := c
			i++
			start := i
			for i < src.len && src[i] != quote {
				if src[i] == `\\` {
					i++
				}
				i++
			}
			if i >= src.len {
				return error('line ${line}: unterminated string')
			}
			toks << Token{.str, src[start..i], line}
			i++
			continue
		}
		if c >= `0` && c <= `9` {
			start := i
			for i < src.len && ((src[i] >= `0` && src[i] <= `9`) || src[i] == `.`
				|| src[i] == `x` || (src[i] >= `a` && src[i] <= `f`)
				|| (src[i] >= `A` && src[i] <= `F`)) {
				i++
			}
			toks << Token{.num, src[start..i], line}
			continue
		}
		if is_ident_start(c) {
			start := i
			for i < src.len && is_ident_char(src[i]) {
				i++
			}
			toks << Token{.ident, src[start..i], line}
			continue
		}
		toks << Token{.punct, c.ascii_str(), line}
		i++
	}
	toks << Token{.eof, '', line}
	return toks
}

struct Parser {
	toks []Token
mut:
	pos int
}

fn (p &Parser) peek() Token {
	return p.toks[p.pos]
}

fn (mut p Parser) next() Token {
	t := p.toks[p.pos]
	if t.kind != .eof {
		p.pos++
	}
	return t
}

fn (mut p Parser) expect_punct(s string) ! {
	t := p.next()
	if t.kind != .punct || t.lit != s {
		return error('line ${t.line}: expected `${s}`, got `${t.lit}`')
	}
}

fn (mut p Parser) expect_ident() !Token {
	t := p.next()
	if t.kind != .ident {
		return error('line ${t.line}: expected identifier, got `${t.lit}`')
	}
	return t
}

// skip to the terminating `;`, honoring aggregate `{...}` option values
// (which can themselves contain `;`); used for option/reserved statements
fn (mut p Parser) skip_to_semi() ! {
	mut depth := 0
	for {
		t := p.next()
		if t.kind == .eof {
			return error('line ${t.line}: unexpected EOF, missing `;`')
		}
		if t.kind == .punct {
			match t.lit {
				'{' {
					depth++
				}
				'}' {
					if depth > 0 { depth-- }
				}
				';' {
					if depth == 0 { return }
				}
				else {}
			}
		}
	}
}

// a (possibly fully-qualified) type name: an optional leading `.` for an
// absolute reference, then dot-joined identifiers. The tokenizer keeps
// dots inside a single ident, but a leading dot or a dot after whitespace
// (a name split across lines) arrives as its own punct — stitch them back.
fn (mut p Parser) parse_type_name() !string {
	mut name := ''
	if p.peek().kind == .punct && p.peek().lit == '.' {
		p.next()
		name = '.'
	}
	name += p.expect_ident()!.lit
	for p.peek().kind == .punct && p.peek().lit == '.' {
		p.next()
		name += '.' + p.expect_ident()!.lit
	}
	return name
}

// consume one option value: an aggregate `{...}` or a scalar token
// (with an optional leading `-` for negative numbers)
fn (mut p Parser) skip_option_value() ! {
	if p.peek().kind == .punct && p.peek().lit == '{' {
		p.skip_braces()!
		return
	}
	if p.peek().kind == .punct && p.peek().lit == '-' {
		p.next()
	}
	p.next()
}

// consume a balanced { ... } starting at the current `{`
fn (mut p Parser) skip_braces() ! {
	p.expect_punct('{')!
	mut depth := 1
	for depth > 0 {
		t := p.next()
		if t.kind == .eof {
			return error('line ${t.line}: unterminated `{` in option value')
		}
		if t.kind == .punct && t.lit == '{' {
			depth++
		} else if t.kind == .punct && t.lit == '}' {
			depth--
		}
	}
}

pub fn parse(src string) !File {
	toks := tokenize(src)!
	mut p := Parser{
		toks: toks
	}
	mut f := File{}
	t0 := p.peek()
	if t0.kind == .ident && t0.lit == 'syntax' {
		p.next()
		p.expect_punct('=')!
		s := p.next()
		if s.kind != .str || s.lit != 'proto3' {
			return error('line ${s.line}: only proto3 is supported')
		}
		p.expect_punct(';')!
	} else if t0.kind == .ident && t0.lit == 'edition' {
		return error('proto editions are not supported; this library targets proto3')
	} else {
		return error('missing `syntax = "proto3";` declaration')
	}
	for {
		t := p.peek()
		if t.kind == .eof {
			break
		}
		if t.kind == .punct && t.lit == ';' {
			p.next()
			continue
		}
		if t.kind != .ident {
			return error('line ${t.line}: unexpected `${t.lit}`')
		}
		match t.lit {
			'package' {
				p.next()
				f.package = p.expect_ident()!.lit
				p.expect_punct(';')!
			}
			'option' {
				p.next()
				p.skip_to_semi()!
			}
			'import' {
				p.next()
				mut s := p.next()
				if s.kind == .ident && s.lit == 'public' {
					// visibility is resolved transitively here, so public
					// imports need no special handling
					s = p.next()
				} else if s.kind == .ident && s.lit == 'weak' {
					return error('line ${s.line}: `import weak` is not supported')
				}
				if s.kind != .str {
					return error('line ${s.line}: expected import path string, got `${s.lit}`')
				}
				f.imports << s.lit
				p.expect_punct(';')!
			}
			'message' {
				f.messages << p.parse_message()!
			}
			'enum' {
				f.enums << p.parse_enum()!
			}
			'service' {
				f.services << p.parse_service()!
			}
			else {
				return error('line ${t.line}: unexpected `${t.lit}`')
			}
		}
	}
	return f
}

fn (mut p Parser) parse_message() !Message {
	p.next() // `message`
	mut m := Message{
		name: p.expect_ident()!.lit
	}
	p.expect_punct('{')!
	for {
		t := p.peek()
		if t.kind == .punct && t.lit == '}' {
			p.next()
			break
		}
		if t.kind == .eof {
			return error('line ${t.line}: unexpected EOF in message ${m.name}')
		}
		if t.kind == .punct && t.lit == ';' {
			p.next()
			continue
		}
		// a field whose type is an absolute reference starts with `.`
		if t.kind == .punct && t.lit == '.' {
			m.fields << p.parse_field()!
			continue
		}
		if t.kind != .ident {
			return error('line ${t.line}: unexpected `${t.lit}` in message ${m.name}')
		}
		match t.lit {
			'message' {
				m.messages << p.parse_message()!
			}
			'enum' {
				m.enums << p.parse_enum()!
			}
			'option', 'reserved' {
				p.next()
				p.skip_to_semi()!
			}
			'oneof' {
				p.next()
				mut o := Oneof{
					name: p.expect_ident()!.lit
				}
				p.expect_punct('{')!
				for {
					t2 := p.peek()
					if t2.kind == .punct && t2.lit == '}' {
						p.next()
						break
					}
					if t2.kind == .eof {
						return error('line ${t2.line}: unexpected EOF in oneof ${o.name}')
					}
					if t2.kind == .punct && t2.lit == ';' {
						p.next()
						continue
					}
					if t2.kind == .ident && t2.lit == 'option' {
						p.next()
						p.skip_to_semi()!
						continue
					}
					mut fld := p.parse_field()!
					if fld.label != .plain {
						return error('message ${m.name}: oneof ${o.name} arms cannot be repeated or optional')
					}
					if fld.is_map {
						return error('message ${m.name}: oneof ${o.name} arms cannot be maps')
					}
					fld.oneof = o.name
					o.arms << fld.name
					m.fields << fld
				}
				if o.arms.len == 0 {
					return error('message ${m.name}: oneof ${o.name} has no fields')
				}
				m.oneofs << o
			}
			'extensions', 'extend', 'group' {
				return error('line ${t.line}: `${t.lit}` is proto2-only and not supported')
			}
			else {
				m.fields << p.parse_field()!
			}
		}
	}
	mut seen := map[int]bool{}
	for fl in m.fields {
		if fl.number in seen {
			return error('message ${m.name}: duplicate field number ${fl.number}')
		}
		seen[fl.number] = true
	}
	return m
}

fn (mut p Parser) parse_field() !Field {
	mut fld := Field{}
	lead := p.peek()
	if lead.kind == .ident && lead.lit == 'repeated' {
		fld.label = .repeated
		p.next()
	} else if lead.kind == .ident && lead.lit == 'optional' {
		fld.label = .optional
		p.next()
	} else if lead.kind == .ident && lead.lit == 'required' {
		return error('line ${lead.line}: `required` is proto2-only')
	}
	if p.peek().kind == .ident && p.peek().lit == 'map' {
		mt := p.next()
		if fld.label != .plain {
			return error('line ${mt.line}: map fields cannot be repeated or optional')
		}
		p.expect_punct('<')!
		kt := p.expect_ident()!
		if kt.lit == 'bool' {
			return error('line ${kt.line}: map<bool, ...> is not supported (V maps cannot key on bool)')
		}
		if kt.lit !in map_key_types {
			return error('line ${kt.line}: invalid map key type `${kt.lit}`')
		}
		p.expect_punct(',')!
		if p.peek().kind == .ident && p.peek().lit == 'map' {
			return error('line ${p.peek().line}: map values cannot be maps')
		}
		fld.typ = p.parse_type_name()!
		p.expect_punct('>')!
		fld.is_map = true
		fld.key_typ = kt.lit
	} else {
		fld.typ = p.parse_type_name()!
	}
	fld.name = p.expect_ident()!.lit
	p.expect_punct('=')!
	num := p.next()
	if num.kind != .num {
		return error('line ${num.line}: expected field number, got `${num.lit}`')
	}
	fld.number = num.lit.int()
	if fld.number < 1 || fld.number > 536870911 {
		return error('line ${num.line}: field number ${fld.number} out of range')
	}
	mut t2 := p.next()
	if t2.kind == .punct && t2.lit == '[' {
		for {
			pk := p.peek()
			if pk.kind == .punct && pk.lit == '(' {
				// custom/extension option `(pkg.name)` optionally `.field` —
				// pervasive in real protos (google.api.field_behavior, ...).
				// We don't use it, just parse past name and value.
				p.next() // (
				for {
					tk := p.next()
					if tk.kind == .eof {
						return error('line ${tk.line}: unterminated `(` in field option')
					}
					if tk.kind == .punct && tk.lit == ')' {
						break
					}
				}
				for p.peek().kind == .punct && p.peek().lit == '.' {
					p.next()
					p.expect_ident()!
				}
				p.expect_punct('=')!
				p.skip_option_value()!
			} else {
				key := p.expect_ident()!
				p.expect_punct('=')!
				if p.peek().kind == .punct && p.peek().lit == '{' {
					p.skip_braces()! // aggregate value on a known option name — skip
				} else {
					val := p.next()
					match key.lit {
						'packed' {
							fld.has_packed = true
							fld.packed = val.lit == 'true'
						}
						'json_name' {
							if val.kind != .str {
								return error('line ${val.line}: json_name must be a string')
							}
							fld.json_name = val.lit
						}
						'deprecated' {
							fld.deprecated = val.lit == 'true'
						}
						else {} // other standard options ignored, like protoc
					}
				}
			}
			sep := p.next()
			if sep.kind == .punct && sep.lit == ']' {
				break
			}
			if !(sep.kind == .punct && sep.lit == ',') {
				return error('line ${sep.line}: expected `,` or `]` in field options')
			}
		}
		t2 = p.next()
	}
	if !(t2.kind == .punct && t2.lit == ';') {
		return error('line ${t2.line}: expected `;` after field ${fld.name}')
	}
	return fld
}

fn (mut p Parser) parse_service() !Service {
	p.next() // `service`
	mut s := Service{
		name: p.expect_ident()!.lit
	}
	p.expect_punct('{')!
	for {
		t := p.peek()
		if t.kind == .punct && t.lit == '}' {
			p.next()
			break
		}
		if t.kind == .eof {
			return error('line ${t.line}: unexpected EOF in service ${s.name}')
		}
		if t.kind == .punct && t.lit == ';' {
			p.next()
			continue
		}
		if t.kind == .ident && t.lit == 'option' {
			p.next()
			p.skip_to_semi()!
			continue
		}
		if !(t.kind == .ident && t.lit == 'rpc') {
			return error('line ${t.line}: unexpected `${t.lit}` in service ${s.name}')
		}
		p.next()
		mut m := Method{
			name: p.expect_ident()!.lit
		}
		p.expect_punct('(')!
		if p.peek().kind == .ident && p.peek().lit == 'stream' {
			m.client_streaming = true
			p.next()
		}
		m.input = p.parse_type_name()!
		p.expect_punct(')')!
		ret := p.expect_ident()!
		if ret.lit != 'returns' {
			return error('line ${ret.line}: expected `returns`, got `${ret.lit}`')
		}
		p.expect_punct('(')!
		if p.peek().kind == .ident && p.peek().lit == 'stream' {
			m.server_streaming = true
			p.next()
		}
		m.output = p.parse_type_name()!
		p.expect_punct(')')!
		t2 := p.next()
		if t2.kind == .punct && t2.lit == '{' {
			// method options body — skip balanced braces
			mut depth := 1
			for depth > 0 {
				t3 := p.next()
				if t3.kind == .eof {
					return error('line ${t3.line}: unexpected EOF in rpc ${m.name}')
				}
				if t3.kind == .punct && t3.lit == '{' {
					depth++
				}
				if t3.kind == .punct && t3.lit == '}' {
					depth--
				}
			}
		} else if !(t2.kind == .punct && t2.lit == ';') {
			return error('line ${t2.line}: expected `;` or `{` after rpc ${m.name}')
		}
		s.methods << m
	}
	return s
}

fn (mut p Parser) parse_enum() !Enum {
	p.next() // `enum`
	mut e := Enum{
		name: p.expect_ident()!.lit
	}
	p.expect_punct('{')!
	for {
		t := p.peek()
		if t.kind == .punct && t.lit == '}' {
			p.next()
			break
		}
		if t.kind == .eof {
			return error('line ${t.line}: unexpected EOF in enum ${e.name}')
		}
		if t.kind == .punct && t.lit == ';' {
			p.next()
			continue
		}
		if t.kind != .ident {
			return error('line ${t.line}: unexpected `${t.lit}` in enum ${e.name}')
		}
		if t.lit == 'option' || t.lit == 'reserved' {
			p.next()
			p.skip_to_semi()!
			continue
		}
		name := p.next().lit
		p.expect_punct('=')!
		mut sign := 1
		mut numt := p.next()
		if numt.kind == .punct && numt.lit == '-' {
			sign = -1
			numt = p.next()
		}
		if numt.kind != .num {
			return error('line ${numt.line}: expected number for enum value ${name}')
		}
		e.values << EnumValue{
			name:   name
			number: sign * numt.lit.int()
		}
		mut t2 := p.next()
		if t2.kind == .punct && t2.lit == '[' {
			for {
				tt := p.next()
				if tt.kind == .eof {
					return error('line ${tt.line}: unterminated enum value options')
				}
				if tt.kind == .punct && tt.lit == ']' {
					break
				}
			}
			t2 = p.next()
		}
		if !(t2.kind == .punct && t2.lit == ';') {
			return error('line ${t2.line}: expected `;` after enum value ${name}')
		}
	}
	if e.values.len == 0 {
		return error('enum ${e.name} has no values')
	}
	if e.values[0].number != 0 {
		return error('enum ${e.name}: proto3 requires the first value to be 0')
	}
	return e
}
