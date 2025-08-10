package http

import "core:fmt"
import "core:os"
import "core:strings"

filetypes_paths := [?]string {
	"filetypes.csv",
	"~/.local/share/odin-http/filetypes.csv",
	"/usr/share/odin-http/filetypes.csv",
}


get_filetypes_csv :: proc(allocator := context.allocator) -> string {
	home := os.get_env_alloc("HOME", allocator)
	for &str in filetypes_paths {
		if strings.starts_with(str, "~") {
			path, _ := strings.replace(str, "~", home, 1, allocator = allocator)
			str = path
		}
	}

	for path in filetypes_paths {
		file_contents, found := os.read_entire_file_from_filename(path, allocator)
		if found do return string(file_contents)
		else do delete(file_contents)
	}
	return ""
}
