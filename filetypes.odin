package http

import "core:encoding/csv"
import "core:strings"

file_type_map: map[string]string = nil

build_file_type_map :: proc(allocator := context.allocator) -> map[string]string {
	file_contents := get_filetypes_csv(allocator)
	defer delete(file_contents, allocator)

	r: csv.Reader
	r.trim_leading_space = true
	r.reuse_record = true
	r.reuse_record_buffer = true

	csv.reader_init_with_string(&r, string(file_contents), allocator)
	defer csv.reader_destroy(&r)

	file_type_map := make(map[string]string, allocator)

	for record in csv.iterator_next(&r) {
		file_type_map[strings.clone(record[0])] = strings.clone(record[1])
	}

	log(.BASIC, "Loaded", len(file_type_map), "known MIME types")

	return file_type_map
}

get_filetype :: proc(extension: string) -> string {
	return file_type_map[extension] or_else "application/octet-stream"
}
