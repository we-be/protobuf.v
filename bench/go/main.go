// Benchmark harness — mirrors ../v/main.v exactly: same rng, seed, data
// construction order, and timing methodology.
package main

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	benchpb "example.com/pbbench/bench"
)

const seed = uint64(42)

var sizes = []int{1, 100, 10000}

type rng struct{ state uint64 }

func (r *rng) next() uint64 {
	r.state += 0x9e3779b97f4a7c15
	z := r.state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

func buildBook(n int) *benchpb.AddressBook {
	r := &rng{state: seed}
	book := &benchpb.AddressBook{People: make([]*benchpb.Person, 0, n)}
	for i := 0; i < n; i++ {
		pad := int(r.next() % 24)
		id := int32(r.next() & 0xffffffff)
		active := (r.next() & 1) == 1
		score := float64(r.next()%100000) / 100.0
		lastSeen := r.next()
		p := &benchpb.Person{
			Name:     "person-" + strconv.Itoa(i) + "-" + strings.Repeat("x", pad),
			Id:       id,
			Email:    "person" + strconv.Itoa(i) + "@example.com",
			Active:   active,
			Score:    score,
			LastSeen: lastSeen,
		}
		nphones := int(r.next() % 3)
		for j := 0; j < nphones; j++ {
			num := "555-" + strconv.FormatUint(r.next()%10000, 10)
			typ := benchpb.PhoneType(int32(r.next() % 4))
			p.Phones = append(p.Phones, &benchpb.PhoneNumber{Number: num, Type: typ})
		}
		ntags := int(r.next() % 5)
		for j := 0; j < ntags; j++ {
			p.Tags = append(p.Tags, int64(r.next()%100000)-50000)
		}
		nmeta := int(r.next() % 4)
		for j := 0; j < nmeta; j++ {
			mk := "k" + strconv.FormatUint(r.next()%1000, 10)
			mv := "v" + strconv.FormatUint(r.next()%1000, 10)
			if p.Metadata == nil {
				p.Metadata = map[string]string{}
			}
			p.Metadata[mk] = mv
		}
		ncnt := int(r.next() % 4)
		for j := 0; j < ncnt; j++ {
			ck := int32(r.next() % 1000)
			cv := int64(r.next()%100000) - 50000
			if p.Counters == nil {
				p.Counters = map[int32]int64{}
			}
			p.Counters[ck] = cv
		}
		if (r.next() & 1) == 1 {
			ss := int64(r.next() % 4000000000)
			nn := int32(r.next() % 1000000000)
			p.SeenAt = &timestamppb.Timestamp{Seconds: ss, Nanos: nn}
		}
		switch r.next() % 3 {
		case 0:
			p.Contact = &benchpb.Person_Handle{Handle: "h" + strconv.FormatUint(r.next()%1000, 10)}
		case 1:
			p.Contact = &benchpb.Person_Ext{Ext: int64(r.next() % 1000000)}
		}
		book.People = append(book.People, p)
	}
	return book
}

func measure(run func(iters int) int64) (int, float64) {
	iters := 1
	t := run(iters)
	for t < 100_000_000 && iters < 1_000_000_000 {
		iters *= 10
		t = run(iters)
	}
	fi := int(int64(iters) * 1_000_000_000 / t)
	if fi < 1 {
		fi = 1
	}
	tf := run(fi)
	return fi, float64(tf) / float64(fi)
}

func bench() {
	for _, n := range sizes {
		book := buildBook(n)
		data, err := proto.Marshal(book)
		if err != nil {
			panic(err)
		}

		encIters, encNs := measure(func(iters int) int64 {
			start := time.Now()
			sink := 0
			for i := 0; i < iters; i++ {
				b, err := proto.Marshal(book)
				if err != nil {
					panic(err)
				}
				sink += len(b)
			}
			ns := time.Since(start).Nanoseconds()
			if sink == -1 {
				fmt.Println("impossible")
			}
			return ns
		})
		fmt.Printf("go,encode,%d,%d,%d,%.1f,%.1f\n", n, len(data), encIters, encNs,
			float64(len(data))/encNs*1000.0)

		decIters, decNs := measure(func(iters int) int64 {
			start := time.Now()
			sink := 0
			for i := 0; i < iters; i++ {
				var b benchpb.AddressBook
				if err := proto.Unmarshal(data, &b); err != nil {
					panic(err)
				}
				sink += len(b.People)
			}
			ns := time.Since(start).Nanoseconds()
			if sink == -1 {
				fmt.Println("impossible")
			}
			return ns
		})
		fmt.Printf("go,decode,%d,%d,%d,%.1f,%.1f\n", n, len(data), decIters, decNs,
			float64(len(data))/decNs*1000.0)
	}
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 || args[0] == "bench" {
		bench()
		return
	}
	switch args[0] {
	case "dump":
		n, _ := strconv.Atoi(args[2])
		data, err := proto.MarshalOptions{Deterministic: true}.Marshal(buildBook(n))
		if err != nil {
			panic(err)
		}
		if err := os.WriteFile(args[1], data, 0o644); err != nil {
			panic(err)
		}
		fmt.Printf("wrote %d bytes (%d people)\n", len(data), n)
	case "cross":
		data, err := os.ReadFile(args[1])
		if err != nil {
			panic(err)
		}
		var book benchpb.AddressBook
		if err := proto.Unmarshal(data, &book); err != nil {
			fmt.Fprintf(os.Stderr, "DECODE FAILED: %v\n", err)
			os.Exit(1)
		}
		out, err := proto.MarshalOptions{Deterministic: true}.Marshal(&book)
		if err != nil {
			panic(err)
		}
		if bytes.Equal(out, data) {
			fmt.Printf("IDENTICAL %d bytes, %d people\n", len(data), len(book.People))
		} else {
			fmt.Fprintf(os.Stderr, "MISMATCH: in %d bytes, out %d bytes\n", len(data), len(out))
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: bench | dump <file> <n> | cross <file>")
		os.Exit(1)
	}
}
