// macos-arm64: a bare (uncast) large negative integer literal compared
// against an i64 is silently truncated to 32 bits. V rejects the same
// literal outright when it is bound to a const or a variable, so the
// comparison context is the inconsistency.

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

// plain call, bare literal
fn test_plain_eq_bare_literal() {
	assert get_plain() == -123456789012345
}

// non-assert: does a plain if-comparison truncate the same way?
fn test_if_comparison() {
	mut hit := false
	if get_plain() == -123456789012345 {
		hit = true
	}
	assert hit, 'if-comparison against bare literal did not match'
}

// control: explicit cast on both sides — the workaround
fn test_unwrap_eq_cast_literal() ! {
	assert get()! == i64(-123456789012345)
}
