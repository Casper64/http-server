// TODO: decrease dependencies ...
import os
import time
import io
import net { TcpConn}
import net.http
import net.http.mime
import net.urllib
import vweb
import flag

const (
	folder_index_page = 'folder_index.html'

	headers_close     = http.new_custom_header_from_map({
		'Server':                           'V'
		http.CommonHeader.connection.str(): 'close'
	}) or { panic('should never fail') }
)

struct Resource {
pub:
	is_folder bool
	mimetype  string = 'text/plain'
	path      string
}

struct Context {
pub mut:
	done bool
	root string

	conn &TcpConn = unsafe { nil }
}

pub fn (ctx Context) get_resource_at(path string) ?Resource {
	mut resource_path := ctx.root + path
	// valdiate path
	if os.exists(resource_path) == false {
		return none
	}
	// `net.http.mime.get_mime_type` expects a file extension without "."
	ext := os.file_ext(resource_path).replace('.', '')

	return Resource{
		is_folder: os.is_dir(resource_path)
		mimetype: mime.get_mime_type(ext)
		path: resource_path
	}
}

pub fn (mut ctx Context) send_folder_index(path string) {
	// for variable usage see `folder_index.html`
	title := os.base(path).replace('\\', '/')

	base_path := ctx.root + path
	mut current_dir := base_path.replace(ctx.root, '')
	link_up := os.join_path(current_dir, '../')
	if current_dir.ends_with('/') == false {
		current_dir += '/'
	}

	// get all folders and files in the requested directory
	paths := os.ls(base_path) or {
		send_string(mut ctx.conn, vweb.http_500.bytestr()) or {}
		return
	}

	mut folders := []string{}
	mut files := []string{}
	for p in paths {
		if os.is_dir(os.join_path(base_path, p)) {
			folders << p
		} else {
			files << p
		}
	}

	html := $tmpl('folder_index.html')
	if ctx.send_response('text/html', html) == false {
		send_string(mut ctx.conn, vweb.http_500.bytestr()) or {}
	}
}

[manualfree]
pub fn (mut ctx Context) send_file(resource Resource) {
	data := os.read_file(resource.path) or {
		send_string(mut ctx.conn, vweb.http_500.bytestr()) or {}
		return
	}
	ctx.send_response(resource.mimetype, data)

	unsafe { data.free() }
}

pub fn (mut ctx Context) send_response(mimetype string, res string) bool {
	if ctx.done {
		return false
	}
	ctx.done = true

	// build header
	header := http.new_header_from_map({
		http.CommonHeader.content_type:   mimetype
		http.CommonHeader.content_length: res.len.str()
	})
	// build response
	mut resp := http.Response{
		header: header.join(headers_close)
		body: res
	}

	resp.set_version(.v1_1)
	resp.set_status(http.status_from_int(200))
	send_string(mut ctx.conn, resp.bytestr()) or { return false }
	// response succeeded
	return true
}

fn main() {
	// parse arguments
	mut fp := flag.new_flag_parser(os.args)
	fp.application('http-server')
	fp.version('v1.0.1')
	fp.description('A simple http server')
	fp.skip_executable()

	port := fp.int('port', `p`, 8080, 'The port number')
	cwd := fp.string('dir', `d`, os.getwd(), 'The root directory of the server')
	expose := fp.bool('expose', `e`, false, 'Expose the http server on your local network')
	fp.finalize() or {
		eprintln(err)
		println(fp.usage())
		return
	}

	println('Starting server in ${os.abs_path(cwd)}\n')
	// net.listen_tcp(.ip, ':$port') // uncomment this if you want to listen outside of localhost
	host := if expose { '' } else { 'localhost' }
	mut l := net.listen_tcp(.ip, '$host:$port') or {
		eprintln('starting server failed $err')
		return
	}
	println('Server listening at http://${l.addr()!}')

	// connection loop
	for {
		mut conn := l.accept() or {
			eprintln("can't accept connection $err")
			continue
		}

		mut context := &Context{
			root: cwd
			conn: conn
		}
		spawn handle_conn(mut conn, mut context)
	}
}

[manualfree]
fn handle_conn(mut conn TcpConn, mut ctx Context) {
	conn.set_read_timeout(30 * time.second)
	conn.set_write_timeout(30 * time.second)
	defer {
		conn.close() or {}
	}

	mut reader := io.new_buffered_reader(reader: conn)
	defer {
		unsafe {
			free(ctx)
			reader.free()
		}
	}

	req := http.parse_request(mut reader) or {
		eprintln('parsing http request failed! $err')
		return
	}
	url := urllib.parse(req.url) or {
		eprintln('parsing url failed! $err')
		return
	}

	// don't allow navigating up the tree folder
	if url.path.contains('../') || url.path.contains(r'..\') {
		eprintln('malicious path $url.path')
		conn.write(vweb.http_400.bytes()) or {}
		return
	}
	resource := ctx.get_resource_at(url.path) or {
		eprintln('path not found! $url.path')
		// TODO: make own http page
		conn.write(vweb.http_404.bytes()) or {}
		return
	}

	if resource.is_folder {
		ctx.send_folder_index(url.path)
	} else {
		ctx.send_file(resource)
	}
}

fn send_string(mut conn TcpConn, s string) ! {
	conn.write(s.bytes())!
}
