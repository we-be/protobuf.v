module gen

// proto3 subset parser: syntax, package, message, enum, scalar/repeated
// fields, nested messages/enums, reserved/option skipping. Unsupported
// constructs (import, oneof, map, services, proto2-isms) error loudly
// rather than mis-parse.

pub struct File {
pub mut:
	package  string
	messages []Message
	enums    []Enum
}

pub struct Message {
pub mut:
	name     string
	fields   []Field
	messages []Message
	enums    []Enum
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
}

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

fn (mut p Parser) skip_to_semi() ! {
	for {
		t := p.next()
		if t.kind == .eof {
			return error('line ${t.line}: unexpected EOF, missing `;`')
		}
		if t.kind == .punct && t.lit == ';' {
			return
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
				return error('line ${t.line}: import is not supported yet')
			}
			'message' {
				f.messages << p.parse_message()!
			}
			'enum' {
				f.enums << p.parse_enum()!
			}
			'service' {
				return error('line ${t.line}: service definitions are not supported')
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
				return error('line ${t.line}: oneof is not supported yet')
			}
			'map' {
				return error('line ${t.line}: map fields are not supported yet')
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
	mut t := p.next()
	if t.lit == 'repeated' {
		fld.label = .repeated
		t = p.next()
	} else if t.lit == 'optional' {
		fld.label = .optional
		t = p.next()
	} else if t.lit == 'required' {
		return error('line ${t.line}: `required` is proto2-only')
	}
	if t.kind != .ident {
		return error('line ${t.line}: expected field type, got `${t.lit}`')
	}
	if t.lit == 'map' {
		return error('line ${t.line}: map fields are not supported yet')
	}
	fld.typ = t.lit
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
			key := p.expect_ident()!
			p.expect_punct('=')!
			val := p.next()
			if key.lit == 'packed' {
				fld.has_packed = true
				fld.packed = val.lit == 'true'
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
