// Benchmark harness — mirrored exactly by ../go/main.go so results compare
// across implementations, not methodologies. Same rng, seed, data, timing.
module main

import os
import time

const seed = u64(42)
const sizes = [1, 100, 10000]

// splitmix64 — trivially portable across languages
struct Rng {
mut:
	state u64
}

fn (mut r Rng) next() u64 {
	r.state += u64(0x9e3779b97f4a7c15)
	mut z := r.state
	z = (z ^ (z >> 30)) * u64(0xbf58476d1ce4e5b9)
	z = (z ^ (z >> 27)) * u64(0x94d049bb133111eb)
	return z ^ (z >> 31)
}

fn build_book(n int) AddressBook {
	mut r := Rng{
		state: seed
	}
	mut people := []Person{cap: n}
	for i in 0 .. n {
		pad := int(r.next() % 24)
		id := int(r.next() & 0xffffffff)
		active := (r.next() & 1) == 1
		score := f64(r.next() % 100000) / 100.0
		last_seen := r.next()
		mut p := Person{
			name:      'person-${i}-' + 'x'.repeat(pad)
			id:        id
			email:     'person${i}@example.com'
			active:    active
			score:     score
			last_seen: last_seen
		}
		nphones := int(r.next() % 3)
		for _ in 0 .. nphones {
			num := '555-' + (r.next() % 10000).str()
			typ := unsafe { PhoneType(int(r.next() % 4)) }
			p.phones << PhoneNumber{
				number: num
				type_:  typ
			}
		}
		ntags := int(r.next() % 5)
		for _ in 0 .. ntags {
			p.tags << i64(r.next() % 100000) - 50000
		}
		people << p
	}
	return AddressBook{
		people: people
	}
}

// grow iterations until the run is long enough to trust, then scale to ~1s
fn measure(run fn (iters int) i64) (int, f64) {
	mut iters := 1
	mut t := run(iters)
	for t < 100_000_000 && iters < 1_000_000_000 {
		iters *= 10
		t = run(iters)
	}
	mut fi := int(i64(iters) * 1_000_000_000 / t)
	if fi < 1 {
		fi = 1
	}
	tf := run(fi)
	return fi, f64(tf) / f64(fi)
}

fn bench() {
	for n in sizes {
		book := build_book(n)
		data := book.encode()

		enc_iters, enc_ns := measure(fn [book] (iters int) i64 {
			sw := time.new_stopwatch()
			mut sink := 0
			for _ in 0 .. iters {
				b := book.encode()
				sink += b.len
			}
			ns := sw.elapsed().nanoseconds()
			if sink == -1 {
				println('impossible')
			}
			return ns
		})
		enc_mbs := f64(data.len) / enc_ns * 1000.0
		println('v,encode,${n},${data.len},${enc_iters},${enc_ns:.1f},${enc_mbs:.1f}')

		dec_iters, dec_ns := measure(fn [data] (iters int) i64 {
			sw := time.new_stopwatch()
			mut sink := 0
			for _ in 0 .. iters {
				b := AddressBook.decode(data) or { panic(err) }
				sink += b.people.len
			}
			ns := sw.elapsed().nanoseconds()
			if sink == -1 {
				println('impossible')
			}
			return ns
		})
		dec_mbs := f64(data.len) / dec_ns * 1000.0
		println('v,decode,${n},${data.len},${dec_iters},${dec_ns:.1f},${dec_mbs:.1f}')
	}
}

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] == 'bench' {
		bench()
		return
	}
	match args[0] {
		'dump' {
			n := args[2].int()
			data := build_book(n).encode()
			os.write_file_array(args[1], data) or { panic(err) }
			println('wrote ${data.len} bytes (${n} people)')
		}
		'probe' {
			n := args[1].int()
			book := build_book(n)
			mut sw := time.new_stopwatch()
			mut total := 0
			for x in book.people {
				total += x.encode().len
			}
			println('people only:  ${sw.elapsed().microseconds()}us total=${total}')
			sw.restart()
			data := book.encode()
			println('full book:    ${sw.elapsed().microseconds()}us len=${data.len}')
		}
		'cross' {
			data := os.read_bytes(args[1]) or { panic(err) }
			book := AddressBook.decode(data) or {
				eprintln('DECODE FAILED: ${err}')
				exit(1)
			}
			out := book.encode()
			if out == data {
				println('IDENTICAL ${data.len} bytes, ${book.people.len} people')
			} else {
				eprintln('MISMATCH: in ${data.len} bytes, out ${out.len} bytes')
				exit(1)
			}
		}
		else {
			eprintln('usage: bench | dump <file> <n> | cross <file>')
			exit(1)
		}
	}
}
