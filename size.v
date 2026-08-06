module protobuf

// Wire-size helpers for computing a message's exact encoded size before
// writing it, so encoding fills one right-sized buffer in a single pass
// with no per-submessage temporaries.

// varint_len returns the number of bytes write_varint emits for v.
pub fn varint_len(v u64) int {
	mut n := 1
	mut x := v >> 7
	for x != 0 {
		n++
		x >>= 7
	}
	return n
}

// tag_len returns the number of bytes write_tag emits for a field number.
pub fn tag_len(field u32) int {
	return varint_len(u64(field) << 3)
}

// len_field_len returns the full wire size of a len-delimited field:
// tag + length prefix + payload.
pub fn len_field_len(field u32, n int) int {
	return tag_len(field) + varint_len(u64(n)) + n
}
