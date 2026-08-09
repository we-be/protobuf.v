module protobuf

// Wire types per the protobuf encoding spec.
// Groups (3/4) are deprecated proto2-only constructs and are rejected.
pub enum WireType {
	varint    = 0
	fixed64   = 1
	len_delim = 2
	fixed32   = 5
}

@[inline]
fn wire_type_from(v u64) !WireType {
	match v {
		0 { return .varint }
		1 { return .fixed64 }
		2 { return .len_delim }
		5 { return .fixed32 }
		3, 4 { return error('deprecated group wire type ${v}') }
		else { return error('invalid wire type ${v}') }
	}
}

// zigzag maps signed ints to unsigned so small negatives stay small varints.
// One 64-bit pair covers sint32 too: sign-extend in, truncate out.
pub fn zigzag_encode(n i64) u64 {
	return (u64(n) << 1) ^ u64(n >> 63)
}

pub fn zigzag_decode(v u64) i64 {
	return i64(v >> 1) ^ -i64(v & 1)
}
