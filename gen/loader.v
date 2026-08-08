module gen

import os

// Transitive .proto loader: parses the root file and everything it
// imports, deduplicating shared imports and rejecting cycles. An import
// path resolves against LoadOpts.paths in order, then the root file's own
// directory, then the embedded well-known types.

pub struct LoadOpts {
pub:
	paths []string // -I search paths, tried in order
}

pub struct FileSet {
pub mut:
	root  File // == files[0]
	files []File
}

struct Loader {
	opts     LoadOpts
	root_dir string
mut:
	files []File
	state map[string]int // canonical path or wkt key: 1 loading, 2 done
}

pub fn load(root_path string, opts LoadOpts) !FileSet {
	if !os.exists(root_path) {
		return error('cannot read ${root_path}')
	}
	canon := os.real_path(root_path)
	mut l := Loader{
		opts:     opts
		root_dir: os.dir(canon)
	}
	l.load_file(canon, root_path)!
	return FileSet{
		root:  l.files[0]
		files: l.files
	}
}

fn (mut l Loader) load_file(canon string, display string) ! {
	if l.state[canon] == 2 {
		return
	}
	if l.state[canon] == 1 {
		return error('import cycle involving ${display}')
	}
	l.state[canon] = 1
	src := os.read_file(canon) or { return error('cannot read ${display}: ${err.msg()}') }
	f := parse(src) or { return error('${display}: ${err.msg()}') }
	l.files << f
	for imp in f.imports {
		l.load_import(imp)!
	}
	l.state[canon] = 2
}

fn (mut l Loader) load_import(imp string) ! {
	mut dirs := l.opts.paths.clone()
	dirs << l.root_dir
	for dir in dirs {
		p := os.join_path(dir, imp)
		if os.exists(p) {
			l.load_file(os.real_path(p), imp)!
			return
		}
	}
	if imp in wkt_sources {
		key := 'wkt:${imp}'
		if l.state[key] == 2 {
			return
		}
		// the embedded sources import nothing, so no cycle bookkeeping
		f := parse(wkt_sources[imp]) or { return error('${imp}: ${err.msg()}') }
		l.files << f
		l.state[key] = 2
		return
	}
	return error('import `${imp}` not found in search paths or embedded well-known types')
}
