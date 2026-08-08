// JSON oracle: protojson must accept every JSON file the V side emitted
// and decode it to the same message as the binary; then it emits its own
// JSON (.go.json) for the V side to parse back.
package main

import (
	"fmt"
	"os"
	"strconv"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	pb "example.com/jsoncheck/scalars"
)

func die(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}

func main() {
	dir := os.Args[1]
	count, _ := strconv.Atoi(os.Args[2])
	names := []string{"known"}
	for i := 0; i < count; i++ {
		names = append(names, "fuzz_"+strconv.Itoa(i))
	}
	for _, n := range names {
		bin, err := os.ReadFile(dir + "/" + n + ".bin")
		die(err)
		var want pb.Scalars
		die(proto.Unmarshal(bin, &want))
		vjson, err := os.ReadFile(dir + "/" + n + ".json")
		die(err)
		var got pb.Scalars
		if err := protojson.Unmarshal(vjson, &got); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL %s: protojson rejects V JSON: %v\n%s\n", n, err, vjson)
			os.Exit(1)
		}
		if !proto.Equal(&want, &got) {
			fmt.Fprintf(os.Stderr, "FAIL %s: V JSON decodes differently than binary\n", n)
			os.Exit(1)
		}
		gj, err := protojson.Marshal(&want)
		die(err)
		die(os.WriteFile(dir+"/"+n+".go.json", gj, 0o644))
	}
	fmt.Printf("jsoncheck OK: %d V JSON files accepted by protojson\n", len(names))
}
