package http

import "core:encoding/csv"
import "core:flags"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:thread"

DEFAULT_INTERFACE :: net.IP4_Address{0, 0, 0, 0}
DEFAULT_PORT :: 3500
MAX_INCIDENTS :: 10

EXIT :: enum int {
	No_endpoint = 1,
	Busy_port   = 2,
	Emfile      = 3,
}
exit :: #force_inline proc(reason: EXIT) {
	os.exit(int(reason))
}

Arguments :: struct {
	ip:           string `usage:"The ip of the interface to listen on."`,
	port:         int `usage:"The port to listen on.`,
	default_file: string `args:"pos=0" usage:"The file to serve instead of index.html"`,
	verbose:      bool `usage:"Logs all traffic"`,
}
arguments: Arguments

LOG_TYPE :: enum {
	DEBUG,
	BASIC,
	ERROR,
	FATAL,
}

log :: #force_inline proc($type: LOG_TYPE, args: ..any) {
	when type == .FATAL || type == .ERROR {
		fmt.eprintln(..args)
	} else when type == .BASIC {
		fmt.println(..args)
	} else when type == .DEBUG {
		if arguments.verbose do fmt.println(..args)
	}
}

stream_file :: proc(socket: net.TCP_Socket, file: os.Handle, limit := -1) {
	buf: [4096]byte

	read, read_err := os.read(file, buf[:])
	total_read := read

	for read_err == nil && read > 0 {
		send_err: net.Network_Error
		if limit == -1 || total_read < limit {
			_, send_err = net.send(socket, buf[:read])
		} else {
			_, send_err = net.send(socket, buf[:read + limit - total_read])
			break
		}
		if send_err != net.TCP_Send_Error.Connection_Closed && send_err != nil {
			log(.ERROR, send_err, "in send()")
		}
		read, read_err = os.read(file, buf[:])
		total_read += read
	}

	if read_err != nil {
		log(.ERROR, read_err, "in read()")
	}
}

trim_for_print :: proc(str: string, length := 1000) -> (trimmed: string, maybe_dots: string) {
	if len(str) < length do return str, ""
	return str[:length], "..."
}

send_file_header :: proc(request: Request, file: os.Handle, socket: net.TCP_Socket) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	file_size, err2 := os.file_size(file)

	if (request.start == 0) {
		fmt.sbprintf(&builder, "HTTP/1.1 200 OK\r\n")
		if err2 == nil do fmt.sbprintf(&builder, "Content-length: %d\r\n", file_size)
	} else {
		end := request.end if request.end != 0 else int(file_size)
		fmt.sbprintf(&builder, "HTTP/1.1 206 Partial\r\n")
		fmt.sbprintf(&builder, "Content-range: bytes %d-%d/%d\r\n", request.start, end, file_size)
		fmt.sbprintf(&builder, "Content-length: %d\r\n", end - request.start)
	}
	fmt.sbprintf(&builder, "Content-type: %s\r\n", get_filetype(filepath.ext(request.file)[1:]))
	fmt.sbprintf(&builder, "Accept-ranges: bytes\r\n")
	fmt.sbprintf(&builder, "\r\n")

	net.send(socket, builder.buf[:])

	log(.DEBUG, "Sent header:")
	log(.DEBUG, trim_for_print(string(builder.buf[:])))
}

send_response :: proc(request: Request, socket: net.TCP_Socket) {
	file, err := os.open(request.file)
	defer os.close(file)
	switch err {
	case nil:
		send_file_header(request, file, socket)
		os.seek(file, i64(request.start), os.SEEK_SET)

		if request.end != 0 do stream_file(socket, file, request.end - request.start)
		else do stream_file(socket, file)

	case os.Platform_Error.EMFILE:
		log(.FATAL, "Too many files opened, what am I supposed to do?")
		exit(.Emfile)

	case os.General_Error.Not_Exist, os.Platform_Error.ENOENT:
		log(.DEBUG, "Sent header 404 Not Found")
		net.send(
			socket,
			transmute([]u8)string(
				"HTTP/1.1 404 Not Found\r\nContent-type: text/plain\r\n\r\n404 Not Found\r\n",
			),
		)
		return

	case:
		log(.ERROR, "Unhandled error", err)
	}
}

Request :: struct {
	file:       string,
	start, end: int,
}

parse_request :: proc(req: []byte) -> (parsed: Request, ok := false) {
	http_regex, err := regex.create("^GET /([^ ]*) HTTP/1")
	defer regex.destroy(http_regex)
	if err != nil {
		log(.ERROR, "Regex error", err)
		return
	}

	match, match_ok := regex.match(http_regex, string(req))
	defer regex.destroy(match)

	lines := strings.split_lines(string(req))
	defer delete(lines)

	if !match_ok {
		log(.ERROR, "[INVALID] Got ", lines[0])

		for i in 1 ..< len(lines) {
			if len(lines[i - 1]) == 0 {
				log(.BASIC, "Hopefully that's the payload:", strings.join(lines[i:], "\n"))
				break
			}
		}

		return
	}


	for line in lines {
		RANGE_TEXT :: "Range: bytes="
		if strings.starts_with(line, RANGE_TEXT) {
			start_end := line[len(RANGE_TEXT):] // ex. "100-1024"
			separator_position := strings.index_byte(start_end, '-')
			parsed.start = strconv.atoi(start_end[:separator_position])
			parsed.end = strconv.atoi(start_end[separator_position + 1:])
		}
	}

	fmt.println("[REQUEST]", match.groups[0])
	parsed.file = net.percent_decode(match.groups[1]) or_return
	if parsed.file == "" do parsed.file = strings.clone(arguments.default_file)

	return parsed, true
}

handle_client :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	buf: [4096]byte
	bytes_read, err := net.recv(client, buf[:])

	if err != nil {
		// Just client stopping the connection
		if err != net.TCP_Recv_Error.Connection_Closed do log(.ERROR, err, "in recv()")
		return
	}

	log(.DEBUG, "[Got request] (", bytes_read, "bytes)")
	log(.DEBUG, trim_for_print(string(buf[:])))

	request, ok := parse_request(buf[:bytes_read])
	if !ok do return

	send_response(request, client)
}

get_requested_endpoint :: proc() -> net.Endpoint {
	using net
	return Endpoint {
		parse_ip4_address(arguments.ip) or_else DEFAULT_INTERFACE,
		arguments.port if arguments.port != 0 else DEFAULT_PORT,
	}
}


main :: proc() {
	flags.parse_or_exit(&arguments, os.args, .Unix)
	if arguments.default_file == "" do arguments.default_file = "index.html"

	file_type_map = build_file_type_map()

	endpoint := get_requested_endpoint()

	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintln("Can't listen TCP on", net.to_string(endpoint), "error", err)
		exit(.Busy_port)
	}

	actual_addr, _ := net.bound_endpoint(sock)
	fmt.println("Serving on http://", net.to_string(actual_addr), sep = "")

	incidents := 0
	for {
		client, addr, err := net.accept_tcp(sock)

		if err != nil {
			fmt.eprintln(err, "in accept_tcp, client", client, "addr", net.to_string(addr))
			incidents += 1
			if incidents >= MAX_INCIDENTS do break
			continue
		}

		t := thread.create_and_start_with_poly_data(client, handle_client, self_cleanup = true)
	}
	fmt.eprintln("Got", MAX_INCIDENTS, "incidents, stopping")
}
