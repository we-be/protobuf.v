// Address book CLI storing contacts as a proto3 AddressBook binary —
// the same file protoc and every other protobuf implementation can read.
//
//   v run . add "Ada Lovelace" --email ada@analytical.uk --mobile +44-555-0100
//   v run . list
//   protoc --decode=tutorial.AddressBook addressbook.proto < addressbook.bin
module main

import os
import protobuf

enum PhoneType {
	unspecified = 0
	mobile      = 1
	home        = 2
	work        = 3
}

fn phone_type_from(v int) PhoneType {
	return match v {
		1 { PhoneType.mobile }
		2 { PhoneType.home }
		3 { PhoneType.work }
		else { PhoneType.unspecified }
	}
}

struct PhoneNumber {
mut:
	number string
	typ    PhoneType
}

struct Person {
mut:
	name   string
	id     int
	email  string
	phones []PhoneNumber
}

struct AddressBook {
mut:
	people []Person
}

fn (p PhoneNumber) encode() []u8 {
	mut e := protobuf.Encoder{}
	if p.number != '' {
		e.write_string_field(1, p.number)
	}
	if p.typ != .unspecified {
		e.write_int32_field(2, int(p.typ))
	}
	return e.buf
}

fn PhoneNumber.decode(buf []u8) !PhoneNumber {
	mut p := PhoneNumber{}
	mut d := protobuf.Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 { p.number = d.read_string()! }
			2 { p.typ = phone_type_from(d.read_int32()!) }
			else { d.skip(wt)! }
		}
	}
	return p
}

fn (p Person) encode() []u8 {
	mut e := protobuf.Encoder{}
	if p.name != '' {
		e.write_string_field(1, p.name)
	}
	if p.id != 0 {
		e.write_int32_field(2, p.id)
	}
	if p.email != '' {
		e.write_string_field(3, p.email)
	}
	for ph in p.phones {
		e.write_message_field(4, ph.encode())
	}
	return e.buf
}

fn Person.decode(buf []u8) !Person {
	mut p := Person{}
	mut d := protobuf.Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 { p.name = d.read_string()! }
			2 { p.id = d.read_int32()! }
			3 { p.email = d.read_string()! }
			4 { p.phones << PhoneNumber.decode(d.read_bytes()!)! }
			else { d.skip(wt)! }
		}
	}
	return p
}

fn (b AddressBook) encode() []u8 {
	mut e := protobuf.Encoder{}
	for p in b.people {
		e.write_message_field(1, p.encode())
	}
	return e.buf
}

fn AddressBook.decode(buf []u8) !AddressBook {
	mut b := AddressBook{}
	mut d := protobuf.Decoder{
		buf: buf
	}
	for d.more() {
		field, wt := d.read_tag()!
		match field {
			1 { b.people << Person.decode(d.read_bytes()!)! }
			else { d.skip(wt)! }
		}
	}
	return b
}

fn load(path string) !AddressBook {
	if !os.exists(path) {
		return AddressBook{}
	}
	return AddressBook.decode(os.read_bytes(path)!)!
}

fn usage() {
	eprintln('usage: addressbook [--db file] add <name> [--id N] [--email E] [--mobile P] [--home P] [--work P]')
	eprintln('       addressbook [--db file] list')
	exit(1)
}

fn flag_val(args []string, i int) string {
	if i + 1 >= args.len {
		usage()
	}
	return args[i + 1]
}

fn main() {
	mut args := os.args[1..].clone()
	mut db := 'addressbook.bin'
	for i, arg in args {
		if arg == '--db' {
			db = flag_val(args, i)
			args.delete(i)
			args.delete(i)
			break
		}
	}
	if args.len == 0 {
		usage()
	}
	mut book := load(db) or {
		eprintln('cannot read ${db}: ${err}')
		exit(1)
	}
	match args[0] {
		'add' {
			if args.len < 2 {
				usage()
			}
			mut p := Person{
				name: args[1]
			}
			mut i := 2
			for i < args.len {
				match args[i] {
					'--id' { p.id = flag_val(args, i).int() }
					'--email' { p.email = flag_val(args, i) }
					'--mobile' { p.phones << PhoneNumber{flag_val(args, i), .mobile} }
					'--home' { p.phones << PhoneNumber{flag_val(args, i), .home} }
					'--work' { p.phones << PhoneNumber{flag_val(args, i), .work} }
					else { usage() }
				}
				i += 2
			}
			if p.id == 0 {
				mut max := 0
				for q in book.people {
					if q.id > max {
						max = q.id
					}
				}
				p.id = max + 1
			}
			book.people << p
			os.write_file_array(db, book.encode()) or {
				eprintln('cannot write ${db}: ${err}')
				exit(1)
			}
			println('added #${p.id} ${p.name} (${os.file_size(db)} bytes total)')
		}
		'list' {
			if book.people.len == 0 {
				println('address book is empty')
				return
			}
			for p in book.people {
				email := if p.email != '' { ' <${p.email}>' } else { '' }
				println('#${p.id}  ${p.name}${email}')
				for ph in p.phones {
					println('     ${ph.typ}: ${ph.number}')
				}
			}
		}
		else {
			usage()
		}
	}
}
