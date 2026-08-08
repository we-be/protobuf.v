// Minimal repro for the macos-arm64 i64-literal truncation seen in CI:
// `assert <result-unwrap> == <bare big negative literal>` reported the
// literal itself as a 32-bit-truncated value. Control cases included.

fn get() !i64 {
	return i64(-123456789012345)
}

fn get_plain() i64 {
	return i64(-123456789012345)
}

// exact failing shape: result unwrap compared against a bare literal
fn test_unwrap_eq_bare_literal() ! {
	assert get()! == -123456789012345
}

// control: plain call, bare literal — passed in the original run
fn test_plain_eq_bare_literal() {
	assert get_plain() == -123456789012345
}

// control: both sides explicitly typed
fn test_unwrap_eq_cast_literal() ! {
	assert get()! == i64(-123456789012345)
}
