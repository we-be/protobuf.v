#!/usr/bin/env bash
# Build both harnesses, prove cross-language byte compatibility, run the
# benchmark matrix, and write a markdown report (default: bench-results.md).
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-bench-results.md}"

v -prod -o v/pbbench-v v
(cd go && go build -o pbbench-go .)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# functionality: identical bytes from identical data, and each side must
# decode the other's output and re-encode it byte-identically
./v/pbbench-v dump "$tmp/v.bin" 1000 >/dev/null
./go/pbbench-go dump "$tmp/go.bin" 1000 >/dev/null
cmp "$tmp/v.bin" "$tmp/go.bin"
cross_go="$(./go/pbbench-go cross "$tmp/v.bin")"
cross_v="$(./v/pbbench-v cross "$tmp/go.bin")"

./v/pbbench-v bench >"$tmp/v.csv"
./go/pbbench-go bench >"$tmp/go.csv"

cpu="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1)"
[ -n "$cpu" ] || cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
[ -n "$cpu" ] || cpu="$(uname -m)"
gopb="$(sed -n 's|.*google.golang.org/protobuf \(v[0-9.]*\).*|\1|p' go/go.mod | head -1)"

{
	echo "# protobuf.v benchmark report"
	echo
	echo "- date: $(date -u +%Y-%m-%d) (UTC)"
	echo "- cpu: $cpu"
	echo "- v: $(v version), harness compiled with -prod"
	echo "- go: $(go version | awk '{print $3}'), google.golang.org/protobuf $gopb"
	echo
	echo "## Wire compatibility"
	echo
	echo "- V and Go encode 1000 identical messages to byte-identical output"
	echo "- Go decode of V bytes: $cross_go"
	echo "- V decode of Go bytes: $cross_v"
	echo
	echo "## Throughput"
	echo
	awk -F, '
		function label(b) {
			if (b >= 1000000) return sprintf("%.1f MB", b / 1000000)
			if (b >= 1000) return sprintf("%.1f KB", b / 1000)
			return sprintf("%d B", b)
		}
		FNR == NR {
			k = $2 "," $3
			vns[k] = $6; vmb[k] = $7; bytes[k] = $4; order[++n] = k
			next
		}
		{ k = $2 "," $3; gns[k] = $6; gmb[k] = $7 }
		END {
			print "| payload | op | V ns/op | V MB/s | Go ns/op | Go MB/s | V/Go time |"
			print "|---|---|---|---|---|---|---|"
			for (i = 1; i <= n; i++) {
				k = order[i]; split(k, a, ",")
				printf "| %s | %s | %.0f | %.1f | %.0f | %.1f | %.2f |\n", \
					label(bytes[k]), a[1], vns[k], vmb[k], gns[k], gmb[k], vns[k] / gns[k]
			}
		}
	' "$tmp/v.csv" "$tmp/go.csv"
	echo
	echo "V/Go time: 1.00 = parity, below 1 = V faster. Schema: bench.proto (people with"
	echo "nested phone messages, packed varint tags). Both harnesses build identical data"
	echo "(splitmix64, seed 42) and time identically (iterations scaled to ~1s per cell)."
} >"$out"

echo "wrote $out"

# regression gate: fail if a cell's V/Go time ratio exceeds its op's
# threshold (MAX_ENCODE_RATIO / MAX_DECODE_RATIO, or MAX_RATIO for both).
# Ratios are same-run, same-box comparisons, so machine noise largely
# cancels — a tripped gate means a real relative slowdown. Baselines are
# hardware-dependent: decode wins on desktop cores but trails Go on
# cloud-runner Xeons, so the two ops get separate thresholds.
enc_max="${MAX_ENCODE_RATIO:-${MAX_RATIO:-}}"
dec_max="${MAX_DECODE_RATIO:-${MAX_RATIO:-}}"
if [ -n "$enc_max" ] || [ -n "$dec_max" ]; then
  viol="$(awk -F, -v encmax="${enc_max:-9999}" -v decmax="${dec_max:-9999}" '
    FNR == NR { vns[$2 "," $3] = $6; next }
    {
      k = $2 "," $3
      r = vns[k] / $6
      max = ($2 == "encode") ? encmax : decmax
      if (r > max) printf "  %s n=%s: V/Go %.2f > %s\n", $2, $3, r, max
    }
  ' "$tmp/v.csv" "$tmp/go.csv")"
  if [ -n "$viol" ]; then
    echo "PERF GATE FAILED (encode<=${enc_max:-inf}, decode<=${dec_max:-inf}):"
    echo "$viol"
    exit 1
  fi
  echo "perf gate OK (encode<=${enc_max:-inf}, decode<=${dec_max:-inf})"
fi
