// vpbgen: generate V encode/decode code from a proto3 file.
//
//   v run cmd/vpbgen [-m module_name] [-o out_pb.v] schema.proto
//
// Writes to stdout when -o is omitted. Output is v fmt'd when possible.
module main

import os
import protobuf.gen

@[noreturn]
fn fail(msg string) {
	eprintln(msg)
	exit(1)
}

fn arg_val(args []string, i int) string {
	if i + 1 >= args.len {
		fail('missing value after ${args[i]}')
	}
	return args[i + 1]
}

fn main() {
	args := os.args[1..]
	mut mod := 'main'
	mut out := ''
	mut input := ''
	mut i := 0
	for i < args.len {
		match args[i] {
			'-m' {
				mod = arg_val(args, i)
				i += 2
			}
			'-o' {
				out = arg_val(args, i)
				i += 2
			}
			else {
				if input != '' {
					fail('usage: vpbgen [-m module] [-o out.v] file.proto')
				}
				input = args[i]
				i++
			}
		}
	}
	if input == '' {
		fail('usage: vpbgen [-m module] [-o out.v] file.proto')
	}
	src := os.read_file(input) or { fail('cannot read ${input}: ${err}') }
	f := gen.parse(src) or { fail('${input}: ${err.msg()}') }
	code := gen.generate(f, gen.GenOpts{ module_name: mod }) or { fail('${input}: ${err.msg()}') }
	if out == '' {
		print(code)
		return
	}
	os.write_file(out, code) or { fail('cannot write ${out}: ${err}') }
	vexe := os.getenv('VEXE')
	if vexe != '' {
		os.execute('${os.quoted_path(vexe)} fmt -w ${os.quoted_path(out)}')
	}
	println('generated ${out}')
}
