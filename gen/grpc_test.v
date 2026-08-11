module gen

// structure-only: compiling these stubs needs the grpc module, which the
// protobuf repo's CI does not carry; behavior tests live in the grpc repo
fn test_grpc_stub_structure() ! {
	f := parse('syntax = "proto3";
package kv;
service KV {
	rpc Get (GetRequest) returns (GetResponse);
	rpc WatchAll (GetRequest) returns (stream GetResponse);
	rpc PutAll (stream GetRequest) returns (GetResponse);
	rpc Chat (stream GetRequest) returns (stream GetResponse);
}
message GetRequest { string key = 1; }
message GetResponse { bytes value = 1; }')!
	code := generate_grpc(f, GenOpts{ module_name: 'kvpb' })!
	assert code.contains('module kvpb')
	assert code.contains('import grpc')
	assert code.contains('pub struct KVClient {')
	// unary
	assert code.contains('pub fn (mut x KVClient) get(req GetRequest, opts ...grpc.CallOption) !grpc.Reply[GetResponse] {')
	assert code.contains("x.c.unary('/kv.KV/Get', req.encode(), ...opts)")
	// server-streaming: one request, the response stream buffered into a list
	assert code.contains('pub fn (mut x KVClient) watch_all(req GetRequest, opts ...grpc.CallOption) !grpc.Reply[[]GetResponse] {')
	assert code.contains("x.c.server_stream('/kv.KV/WatchAll', req.encode(), ...opts)")
	// client-streaming: the request stream buffered into a list, one response
	assert code.contains('pub fn (mut x KVClient) put_all(reqs []GetRequest, opts ...grpc.CallOption) !grpc.Reply[GetResponse] {')
	assert code.contains("x.c.client_stream('/kv.KV/PutAll', bodies, ...opts)")
	// bidirectional streaming stays skipped
	assert code.contains('// rpc Chat skipped: bidirectional streaming is not supported yet')
	assert !code.contains('chat(')
	// handler interface: unary + both streaming signatures
	assert code.contains('pub interface KVHandler {')
	assert code.contains('\tget(mut ctx grpc.ServerContext, req GetRequest) !GetResponse')
	assert code.contains('\twatch_all(mut ctx grpc.ServerContext, req GetRequest) ![]GetResponse')
	assert code.contains('\tput_all(mut ctx grpc.ServerContext, reqs []GetRequest) !GetResponse')
	assert code.contains('pub struct KVService {')
	// Connect dispatch: unary only (streaming paths fall through to found=false)
	assert code.contains('pub fn (mut s KVService) call(path string, codec grpc.Codec, body []u8, mut ctx grpc.ServerContext) !([]u8, bool) {')
	assert code.contains("'/kv.KV/Get' {")
	assert code.contains('s.h.get(mut ctx, req)!')
	// native gRPC dispatch: unary + buffered streaming, message-list in/out
	assert code.contains('pub fn (mut s KVService) grpc_call(path string, reqs [][]u8, mut ctx grpc.ServerContext) !([][]u8, bool) {')
	assert code.contains("'/kv.KV/WatchAll' {")
	assert code.contains("'/kv.KV/PutAll' {")
	// without -json the JSON codec is refused at runtime
	assert code.contains('JSON codec unavailable')
	jcode := generate_grpc_set(FileSet{ root: f, files: [f] }, GenOpts{
		module_name: 'kvpb'
		json:        true
	})!
	assert jcode.contains('GetRequest.from_json(body.bytestr())!')
	assert jcode.contains('resp.json()!.bytes()')
}

fn test_grpc_no_package_path() ! {
	f :=
		parse('syntax = "proto3"; service S { rpc Do (M) returns (M); } message M { int32 x = 1; }')!
	code := generate_grpc(f, GenOpts{})!
	assert code.contains("x.c.unary('/S/Do', req.encode(), ...opts)")
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
