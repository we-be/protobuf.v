module gen

// structure-only: compiling these stubs needs the grpc module, which the
// protobuf repo's CI does not carry; behavior tests live in the grpc repo
fn test_grpc_stub_structure() ! {
	f := parse('syntax = "proto3";
package kv;
service KV {
	rpc Get (GetRequest) returns (GetResponse);
	rpc WatchAll (GetRequest) returns (stream GetResponse);
}
message GetRequest { string key = 1; }
message GetResponse { bytes value = 1; }')!
	code := generate_grpc(f, GenOpts{ module_name: 'kvpb' })!
	assert code.contains('module kvpb')
	assert code.contains('import grpc')
	assert code.contains('pub struct KVClient {')
	assert code.contains('pub fn (mut x KVClient) get(req GetRequest) !GetResponse {')
	assert code.contains("x.c.unary('/kv.KV/Get', req.encode())")
	assert code.contains('// rpc WatchAll skipped: server streaming is not supported yet')
	assert !code.contains('watch_all(')
	// Connect server glue: handler interface + dispatch struct, unary only
	assert code.contains('pub interface KVHandler {')
	assert code.contains('\tget(req GetRequest) !GetResponse')
	assert code.contains('pub struct KVService {')
	assert code.contains('pub fn (mut s KVService) call(path string, codec grpc.Codec, body []u8) !([]u8, bool) {')
	assert code.contains("'/kv.KV/Get' {")
	// without -json the JSON codec is refused at runtime
	assert code.contains('JSON codec unavailable')
	jcode := generate_grpc_set(FileSet{ root: f, files: [f] }, GenOpts{
		module_name: 'kvpb'
		json:        true
	})!
	assert jcode.contains('GetRequest.from_json(body.bytestr())!')
	assert jcode.contains('resp.json().bytes()')
}

fn test_grpc_no_package_path() ! {
	f :=
		parse('syntax = "proto3"; service S { rpc Do (M) returns (M); } message M { int32 x = 1; }')!
	code := generate_grpc(f, GenOpts{})!
	assert code.contains("x.c.unary('/S/Do', req.encode())")
}

fn test_grpc_requires_services() {
	f := parse('syntax = "proto3"; message M { int32 x = 1; }') or {
		assert false, err.msg()
		return
	}
	if _ := generate_grpc(f, GenOpts{}) {
		assert false, 'expected error for service-free file'
	}
}
