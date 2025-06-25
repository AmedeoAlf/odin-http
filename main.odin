package http

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:text/regex"
import "core:thread"

DEFAULT_LISTEN :: "0.0.0.0:3500"
MAX_INCIDENTS :: 10

EXIT :: enum int {
  No_endpoint,
  Busy_port,
  Emfile,
}
exit :: #force_inline proc(reason: EXIT) {
  os.exit(int(reason))
}

stream_file :: proc(socket: net.TCP_Socket, file: os.Handle) {
  buf: [4096]byte

  read, read_err := os.read(file, buf[:])

  for read_err == nil && read > 0 {
    written, send_err := net.send(socket, buf[:read])
    if send_err != net.TCP_Send_Error.Connection_Closed && send_err != nil {
      fmt.println(send_err, "in send()")
    }
    read, read_err = os.read(file, buf[:])
  }

  if read_err != nil {
    fmt.println(read_err, "in read()")
  }
}

send_response :: proc(filename, mime_str: string, socket: net.TCP_Socket) {
  file, err := os.open(filename)
  defer os.close(file)
  switch err {
  case nil:
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    fmt.sbprintf(
      &builder,
      "HTTP/1.1 200 OK\r\nContent-type: %s\r\n\r\n",
      mime_str,
    )
    net.send(socket, builder.buf[:])

    stream_file(socket, file)

  case os.Platform_Error.EMFILE:
    fmt.eprintln("Too many files opened, what am I supposed to do?")
    exit(.Emfile)

  case os.General_Error.Not_Exist, os.Platform_Error.ENOENT:
    net.send(
      socket,
      transmute([]u8)string(
        "HTTP/1.1 404 Not Found\r\nContent-type: text/plain\r\n\r\n404 Not Found\r\n",
      ),
    )
    return

  case:
    fmt.println(err)
  }
}

get_filetype :: proc(extension: string) -> string {
  switch extension {
  case ".html":
    return "text/html"
  case ".jpg":
    return "image/jpeg"
  case ".png":
    return "image/png"
  case ".css":
    return "text/css"
  case ".txt":
    return "text/plain"
  case:
    return "application/octet-stream"
  }
}

parse_request :: proc(
  req: []byte,
) -> (
  filename: string,
  ext: string,
  ok := false,
) {
  http_regex, err := regex.create("^GET /([^ ]*) HTTP/1")
  defer regex.destroy(http_regex)
  if err != nil {
    fmt.eprintln("Regex error", err)
    return
  }

  match, match_ok := regex.match(http_regex, string(req))
  defer regex.destroy(match)

  if !match_ok {
    lines := strings.split_lines(string(req))
    fmt.eprintln("[INVALID] Got ", lines[0])

    for i in 1 ..< len(lines) {
      if len(lines[i - 1]) == 0 {
        fmt.println(
          "Hopefully that's the payload:",
          strings.join(lines[i:], "\n"),
        )
        break
      }
    }

    return
  }

  fmt.println("[REQUEST]", match.groups[0])
  filename = net.percent_decode(match.groups[1]) or_return
  if filename == "" {
    delete(filename)
    filename = strings.clone("index.html")
  }

  ext = strings.trim_left_proc(
    filename,
    proc(r: rune) -> bool {return r != '.'},
  )

  return filename, ext, true
}

handle_client :: proc(client: net.TCP_Socket) {
  buf: [4096]byte
  bytes_read, err := net.recv(client, buf[:])

  if err != nil {
    // Just client stopping the connection
    if err != net.TCP_Recv_Error.Connection_Closed do fmt.eprintln(err, "in recv()")
    return
  }

  filename, file_ext, ok := parse_request(buf[:bytes_read])
  defer delete(filename)
  if !ok do return

  send_response(filename, get_filetype(file_ext), client)

  net.close(client)
}

get_requested_endpoint :: proc() -> net.Endpoint {
  endpoint_str := DEFAULT_LISTEN if len(os.args) < 2 else os.args[1]

  endpoint, ok := net.parse_endpoint(endpoint_str)
  if !ok {
    fmt.eprintln(
      endpoint_str,
      "is not a valid endpoint (leave blank for",
      DEFAULT_LISTEN,
      "),",
    )
    exit(.No_endpoint)
  }

  return endpoint
}

main :: proc() {
  endpoint := get_requested_endpoint()

  sock, err := net.listen_tcp(endpoint)
  if err != nil {
    fmt.eprintln("Can't listen TCP on", net.to_string(endpoint), "error", err)
    exit(.Busy_port)
  }

  actual_addr, _ := net.bound_endpoint(sock)
  fmt.println(
    "Serving on http://",
    net.to_string(actual_addr),
    " (you can specify an alternative address as first argument)",
    sep = "",
  )

  incidents := 0
  for {
    client, addr, err := net.accept_tcp(sock)

    if err != nil {
      fmt.eprintln(
        err,
        "in accept_tcp, client",
        client,
        "addr",
        net.to_string(addr),
      )
      incidents += 1
      if incidents >= MAX_INCIDENTS do return
      continue
    }

    t := thread.create_and_start_with_poly_data(
      client,
      handle_client,
      self_cleanup = true,
    )
  }
  fmt.eprintln("Got", MAX_INCIDENTS, "incidents, stopping")
}
