// A solution for https://codingchallenges.fyi/challenges/challenge-text-editor/
// I'm a big fan of the program "micro" so I opted to model my solution like micro
// features mouse support and a side panel (vscode/subl style)
// copy paste features appear to be broken currently


package termpad

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

// ── Mouse Constants ───────────────────────────────────────────────────────────

MOUSE_LEFT_CLICK   :: 2000
MOUSE_LEFT_RELEASE :: 2001
MOUSE_LEFT_DRAG    :: 2002
MOUSE_SCROLL_UP    :: 2003
MOUSE_SCROLL_DOWN  :: 2004
MOUSE_DOUBLE_CLICK :: 2005
MOUSE_TRIPLE_CLICK :: 2006

// ── Mouse Globals ─────────────────────────────────────────────────────────────

g_mouse_x:  int
g_mouse_y:  int
g_mouse_cb: int

// Click timing for double/triple click detection
g_last_click_x: int
g_last_click_y: int
g_click_count:  int    // 1=single, 2=double, 3=triple
g_last_click_time: i64 // nanoseconds from clock_gettime

// ── Types ──────────────────────────────────────────────────────────────────────

Mode :: enum {
	NORMAL,
	INSERT,
	COMMAND,
}

Focus :: enum {
	EDITOR,
	PANEL,
}

Language :: enum {
	UNKNOWN,
	ODIN,
	CHUCK,
}

File_Entry :: struct {
	name:     string,
	path:     string,
	is_dir:   bool,
	expanded: bool,
	depth:    int,
	children: [dynamic]^File_Entry,
	loaded:   bool, // whether children have been read from disk
}

File_Panel :: struct {
	root:       ^File_Entry,
	root_path:  string,
	visible:    bool,
	width:      int,
	scroll_off: int,
	cursor:     int,
	entries:    [dynamic]^File_Entry, // flattened visible entries
}

Win_Size :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

Editor :: struct {
	cx, cy:         int, // cursor position in the file
	row_off:        int, // vertical scroll offset
	col_off:        int, // horizontal scroll offset
	screen_rows:    int,
	screen_cols:    int,
	mode:           Mode,
	lines:          [dynamic]string,
	filename:       string,
	status_msg:     string,
	dirty:          bool,
	command_buf:    strings.Builder,
	orig_termios:   posix.termios,
	quit:           bool,
	sel_active:     bool,
	sel_start_x:    int,
	sel_start_y:    int,
	sel_end_x:      int,
	sel_end_y:      int,
	mouse_down:     bool,
	clipboard:      string,
	quit_count:     int, // for Ctrl+Q force-quit confirmation
	panel:          File_Panel,
	focus:          Focus,
	total_cols:     int, // full terminal width before panel offset
	ac_suggestion:  string, // the full suggested word (empty = no suggestion)
	ac_prefix_len:  int,    // length of the prefix the user typed
	language:       Language,
}

// ── Terminal ───────────────────────────────────────────────────────────────────

enable_raw_mode :: proc(e: ^Editor) -> bool {
	fd := posix.FD(posix.STDIN_FILENO)
	if posix.tcgetattr(fd, &e.orig_termios) != .OK {
		return false
	}

	raw := e.orig_termios
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_cflag |= {.CS8}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 1

	if posix.tcsetattr(fd, .TCSAFLUSH, &raw) != .OK {
		return false
	}
	return true
}

disable_raw_mode :: proc(e: ^Editor) {
	posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSAFLUSH, &e.orig_termios)
}

get_window_size :: proc(e: ^Editor) -> bool {
	ws: Win_Size
	_ = linux.ioctl(linux.Fd(1), linux.TIOCGWINSZ, uintptr(&ws))
	// On error, ioctl returns a large value (wrapping -1)
	if ws.ws_row == 0 || ws.ws_col == 0 {
		return false
	}
	e.screen_rows = int(ws.ws_row) - 2 // reserve 2 lines: status bar + message bar
	e.total_cols = int(ws.ws_col)
	if e.panel.visible {
		e.panel.width = e.total_cols / 4
		if e.panel.width < 15 { e.panel.width = 15 }
		e.screen_cols = e.total_cols - e.panel.width - 1 // -1 for separator
	} else {
		e.screen_cols = e.total_cols
	}
	return true
}

read_key :: proc() -> (key: int, ok: bool) {
	buf: [1]u8
	fd := linux.Fd(0)
	for {
		n, _ := linux.read(fd, buf[:])
		if n == 1 {
			// Check for escape sequence
			if buf[0] == 0x1b {
				seq: [2]u8
				n1, _ := linux.read(fd, seq[0:1])
				if n1 != 1 { return 0x1b, true }
				n2, _ := linux.read(fd, seq[1:2])
				if n2 != 1 { return 0x1b, true }
				if seq[0] == '[' {
					if seq[1] == '<' {
						// SGR 1006 mouse: ESC [ < Cb ; Cx ; Cy M/m
						cb, cx_val, cy_val: int
						ch: [1]u8
						// Parse Cb
						for {
							rn, _ := linux.read(fd, ch[:])
							if rn != 1 { return 0x1b, true }
							if ch[0] == ';' { break }
							cb = cb * 10 + int(ch[0] - '0')
						}
						// Parse Cx
						for {
							rn, _ := linux.read(fd, ch[:])
							if rn != 1 { return 0x1b, true }
							if ch[0] == ';' { break }
							cx_val = cx_val * 10 + int(ch[0] - '0')
						}
						// Parse Cy, terminated by M or m
						terminator: u8
						for {
							rn, _ := linux.read(fd, ch[:])
							if rn != 1 { return 0x1b, true }
							if ch[0] == 'M' || ch[0] == 'm' {
								terminator = ch[0]
								break
							}
							cy_val = cy_val * 10 + int(ch[0] - '0')
						}
						g_mouse_x = cx_val
						g_mouse_y = cy_val
						g_mouse_cb = cb
						button := cb & 0x03
						is_motion := (cb & 32) != 0
						is_scroll := (cb & 64) != 0
						if is_scroll {
							if button == 0 { return MOUSE_SCROLL_UP, true }
							return MOUSE_SCROLL_DOWN, true
						}
						if terminator == 'm' {
							return MOUSE_LEFT_RELEASE, true
						}
						if is_motion {
							return MOUSE_LEFT_DRAG, true
						}
						// Detect double/triple clicks
						now := time.now()
						now_ns := time.time_to_unix_nano(now)
						elapsed_ms := (now_ns - g_last_click_time) / 1_000_000
						if elapsed_ms < 400 && cx_val == g_last_click_x && cy_val == g_last_click_y {
							g_click_count += 1
							if g_click_count > 3 { g_click_count = 3 }
						} else {
							g_click_count = 1
						}
						g_last_click_time = now_ns
						g_last_click_x = cx_val
						g_last_click_y = cy_val
						if g_click_count == 3 {
							return MOUSE_TRIPLE_CLICK, true
						}
						if g_click_count == 2 {
							return MOUSE_DOUBLE_CLICK, true
						}
						return MOUSE_LEFT_CLICK, true
					}
					switch seq[1] {
					case 'A': return 1000, true // UP
					case 'B': return 1001, true // DOWN
					case 'C': return 1002, true // RIGHT
					case 'D': return 1003, true // LEFT
					case 'H': return 1004, true // HOME
					case 'F': return 1005, true // END
					case '3':
						del: [1]u8
						linux.read(fd, del[:])
						if del[0] == '~' { return 1006, true } // DELETE
					}
				}
				return 0x1b, true
			}
			return int(buf[0]), true
		}
		if n == 0 {
			return 0, false // timeout, no key pressed
		}
		if n < 0 {
			return 0, false
		}
	}
}

// ── Language Detection ──────────────────────────────────────────────────────────

detect_language :: proc(filename: string) -> Language {
	ext := filepath.ext(filename)
	if ext == ".odin" { return .ODIN }
	if ext == ".ck" { return .CHUCK }
	return .UNKNOWN
}

// ── File I/O ───────────────────────────────────────────────────────────────────

editor_open :: proc(e: ^Editor, filename: string) {
	e.filename = filename
	e.language = detect_language(filename)
	data, err := os.read_entire_file(filename, context.allocator)
	if err != nil {
		// New file
		set_status(e, fmt.tprintf("New file: %s", filename))
		return
	}
	defer delete(data)

	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		append(&e.lines, strings.clone(line))
	}
	e.dirty = false
	set_status(e, fmt.tprintf("Opened %s (%d lines)", filename, len(e.lines)))
}

editor_save :: proc(e: ^Editor) {
	if e.filename == "" {
		set_status(e, "No filename")
		return
	}

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	for line, i in e.lines {
		strings.write_string(&sb, line)
		if i < len(e.lines) - 1 {
			strings.write_byte(&sb, '\n')
		}
	}
	// Add trailing newline if there are lines
	if len(e.lines) > 0 {
		strings.write_byte(&sb, '\n')
	}

	content := strings.to_string(sb)
	err := os.write_entire_file(e.filename, transmute([]u8)content)
	if err != nil {
		set_status(e, fmt.tprintf("Save error: %v", err))
		return
	}
	e.dirty = false
	set_status(e, fmt.tprintf("Saved %s (%d lines)", e.filename, len(e.lines)))
}

// ── File Panel ─────────────────────────────────────────────────────────────────

scan_directory :: proc(path: string, depth: int) -> ^File_Entry {
	entry := new(File_Entry)
	entry.name = strings.clone(filepath.base(path))
	entry.path = strings.clone(path)
	entry.is_dir = true
	entry.expanded = depth == 0 // auto-expand root
	entry.depth = depth
	entry.children = make([dynamic]^File_Entry)
	entry.loaded = false

	if depth == 0 {
		load_children(entry)
	}
	return entry
}

load_children :: proc(entry: ^File_Entry) {
	if entry.loaded { return }
	entry.loaded = true

	dh, err := os.open(entry.path)
	if err != nil { return }
	defer os.close(dh)

	fis, read_err := os.read_dir(dh, -1, context.allocator)
	if read_err != nil { return }
	defer delete(fis)

	// Separate dirs and files, sort each alphabetically
	dirs := make([dynamic]os.File_Info)
	files := make([dynamic]os.File_Info)
	defer delete(dirs)
	defer delete(files)

	for fi in fis {
		name := fi.name
		// Skip hidden files
		if len(name) > 0 && name[0] == '.' { continue }
		if fi.type == .Directory {
			append(&dirs, fi)
		} else {
			append(&files, fi)
		}
	}

	slice.sort_by(dirs[:], proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})
	slice.sort_by(files[:], proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	for fi in dirs {
		child := new(File_Entry)
		child.name = strings.clone(fi.name)
		child.path = strings.clone(fi.fullpath)
		child.is_dir = true
		child.depth = entry.depth + 1
		child.children = make([dynamic]^File_Entry)
		append(&entry.children, child)
	}
	for fi in files {
		child := new(File_Entry)
		child.name = strings.clone(fi.name)
		child.path = strings.clone(fi.fullpath)
		child.is_dir = false
		child.depth = entry.depth + 1
		append(&entry.children, child)
	}
}

flatten_entries :: proc(panel: ^File_Panel) {
	clear(&panel.entries)
	if panel.root == nil { return }
	flatten_recursive(panel, panel.root)
}

flatten_recursive :: proc(panel: ^File_Panel, entry: ^File_Entry) {
	// Skip root itself, show its children at depth 0
	if entry == panel.root {
		if entry.expanded {
			for child in entry.children {
				flatten_recursive(panel, child)
			}
		}
		return
	}
	append(&panel.entries, entry)
	if entry.is_dir && entry.expanded {
		for child in entry.children {
			flatten_recursive(panel, child)
		}
	}
}

panel_open_file :: proc(e: ^Editor, path: string) {
	// Clear existing buffer
	for &line in e.lines {
		delete(line)
	}
	clear(&e.lines)
	e.cx = 0
	e.cy = 0
	e.row_off = 0
	e.col_off = 0
	e.sel_active = false
	e.dirty = false

	editor_open(e, path)

	if len(e.lines) == 0 {
		append(&e.lines, strings.clone(""))
	}

	e.focus = .EDITOR
}

// ── Status ─────────────────────────────────────────────────────────────────────

set_status :: proc(e: ^Editor, msg: string) {
	e.status_msg = msg
}

// ── Cursor Movement ────────────────────────────────────────────────────────────

editor_move_cursor :: proc(e: ^Editor, key: int) {
	switch key {
	case 'h', 1003: // left
		if e.cx > 0 {
			e.cx -= 1
		} else if e.cy > 0 {
			e.cy -= 1
			e.cx = current_line_len(e)
		}
	case 'l', 1002: // right
		rlen := current_line_len(e)
		if e.cx < rlen {
			e.cx += 1
		} else if e.cy < len(e.lines) - 1 {
			e.cy += 1
			e.cx = 0
		}
	case 'k', 1000: // up
		if e.cy > 0 {
			e.cy -= 1
		}
	case 'j', 1001: // down
		if e.cy < len(e.lines) - 1 {
			e.cy += 1
		}
	}
	// Snap cx to end of line
	rlen := current_line_len(e)
	if e.cx > rlen {
		e.cx = rlen
	}
}

current_line_len :: proc(e: ^Editor) -> int {
	if e.cy < len(e.lines) {
		return len(e.lines[e.cy])
	}
	return 0
}

// ── Scrolling ──────────────────────────────────────────────────────────────────

editor_scroll :: proc(e: ^Editor) {
	if e.cy < e.row_off {
		e.row_off = e.cy
	}
	if e.cy >= e.row_off + e.screen_rows {
		e.row_off = e.cy - e.screen_rows + 1
	}
	if e.cx < e.col_off {
		e.col_off = e.cx
	}
	if e.cx >= e.col_off + e.screen_cols {
		e.col_off = e.cx - e.screen_cols + 1
	}
}

// ── Text Editing ───────────────────────────────────────────────────────────────

editor_insert_char :: proc(e: ^Editor, c: u8) {
	if e.cy >= len(e.lines) {
		// Pad with empty lines up to cursor
		for len(e.lines) <= e.cy {
			append(&e.lines, strings.clone(""))
		}
	}

	line := e.lines[e.cy]
	char_buf := [1]u8{c}
	new_line := strings.concatenate({line[:e.cx], string(char_buf[:]), line[e.cx:]})
	delete(e.lines[e.cy])
	e.lines[e.cy] = new_line
	e.cx += 1
	e.dirty = true
}

editor_insert_newline :: proc(e: ^Editor) {
	if e.cy >= len(e.lines) {
		append(&e.lines, strings.clone(""))
		e.cy += 1
		e.cx = 0
		e.dirty = true
		return
	}

	line := e.lines[e.cy]
	// Split line at cursor
	new_line := strings.clone(line[e.cx:])
	old_line := strings.clone(line[:e.cx])
	delete(e.lines[e.cy])
	e.lines[e.cy] = old_line

	// Insert new line after current
	inject_at(&e.lines, e.cy + 1, new_line)
	e.cy += 1
	e.cx = 0
	e.dirty = true
}

editor_delete_char :: proc(e: ^Editor) {
	if e.cy >= len(e.lines) { return }
	if e.cx == 0 && e.cy == 0 { return }

	if e.cx > 0 {
		line := e.lines[e.cy]
		new_line := strings.concatenate({line[:e.cx - 1], line[e.cx:]})
		delete(e.lines[e.cy])
		e.lines[e.cy] = new_line
		e.cx -= 1
	} else {
		// Join with previous line
		prev_len := len(e.lines[e.cy - 1])
		new_line := strings.concatenate({e.lines[e.cy - 1], e.lines[e.cy]})
		delete(e.lines[e.cy - 1])
		delete(e.lines[e.cy])
		e.lines[e.cy - 1] = new_line
		ordered_remove(&e.lines, e.cy)
		e.cy -= 1
		e.cx = prev_len
	}
	e.dirty = true
}

// ── Selection Helpers ──────────────────────────────────────────────────────────

Selection_Range :: struct {
	start_x, start_y, end_x, end_y: int,
}

selection_normalized :: proc(e: ^Editor) -> Selection_Range {
	sy := e.sel_start_y
	sx := e.sel_start_x
	ey := e.sel_end_y
	ex := e.sel_end_x
	if sy > ey || (sy == ey && sx > ex) {
		return {ex, ey, sx, sy}
	}
	return {sx, sy, ex, ey}
}

is_selected :: proc(e: ^Editor, x: int, y: int, sel: Selection_Range) -> bool {
	if !e.sel_active { return false }
	if y < sel.start_y || y > sel.end_y { return false }
	if y == sel.start_y && y == sel.end_y {
		return x >= sel.start_x && x < sel.end_x
	}
	if y == sel.start_y { return x >= sel.start_x }
	if y == sel.end_y { return x < sel.end_x }
	return true
}

// ── Word Boundary Helpers ──────────────────────────────────────────────────────

is_word_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

word_start_at :: proc(line: string, pos: int) -> int {
	if len(line) == 0 { return 0 }
	p := pos
	if p >= len(line) { p = len(line) - 1 }
	if p < 0 { p = 0 }
	for p > 0 && is_word_char(line[p - 1]) {
		p -= 1
	}
	return p
}

word_end_at :: proc(line: string, pos: int) -> int {
	if len(line) == 0 { return 0 }
	p := pos
	if p < 0 { p = 0 }
	for p < len(line) && is_word_char(line[p]) {
		p += 1
	}
	return p
}

// ── Autocomplete ───────────────────────────────────────────────────────────────

collect_words :: proc(e: ^Editor) -> [dynamic]string {
	words := make([dynamic]string)

	// Extract words from all lines
	for line in e.lines {
		i := 0
		for i < len(line) {
			if is_word_char(line[i]) {
				start := i
				for i < len(line) && is_word_char(line[i]) {
					i += 1
				}
				word := line[start:i]
				// Deduplicate with linear scan
				found := false
				for w in words {
					if w == word {
						found = true
						break
					}
				}
				if !found {
					append(&words, word)
				}
			} else {
				i += 1
			}
		}
	}

	// Add language keywords, types, builtins
	kw_list: []string
	ty_list: []string
	bl_list: []string
	switch e.language {
	case .ODIN:
		kw_list = ODIN_KEYWORDS[:]
		ty_list = ODIN_TYPES[:]
		bl_list = ODIN_BUILTINS[:]
	case .CHUCK:
		kw_list = CHUCK_KEYWORDS[:]
		ty_list = CHUCK_TYPES[:]
		bl_list = CHUCK_BUILTINS[:]
	case .UNKNOWN:
		// no language keywords
	}
	for kw in kw_list {
		found := false
		for w in words {
			if w == kw { found = true; break }
		}
		if !found { append(&words, kw) }
	}
	for t in ty_list {
		found := false
		for w in words {
			if w == t { found = true; break }
		}
		if !found { append(&words, t) }
	}
	for b in bl_list {
		found := false
		for w in words {
			if w == b { found = true; break }
		}
		if !found { append(&words, b) }
	}

	return words
}

update_autocomplete :: proc(e: ^Editor) {
	// Clear previous suggestion
	if e.ac_suggestion != "" {
		delete(e.ac_suggestion)
		e.ac_suggestion = ""
		e.ac_prefix_len = 0
	}

	if e.cy >= len(e.lines) { return }
	line := e.lines[e.cy]

	// Extract prefix: word characters ending at cursor
	if e.cx <= 0 || e.cx > len(line) { return }
	// Check that cursor is at the end of a word (char before cursor is word char)
	if !is_word_char(line[e.cx - 1]) { return }

	ws := word_start_at(line, e.cx)
	prefix := line[ws:e.cx]
	if len(prefix) < 2 { return }

	words := collect_words(e)
	defer delete(words)

	best: string
	for w in words {
		if len(w) <= len(prefix) { continue } // skip exact matches or shorter
		if len(w) < len(prefix) { continue }
		// Check prefix match
		if w[:len(prefix)] != prefix { continue }
		// Pick shorter match, or alphabetically first
		if best == "" || len(w) < len(best) || (len(w) == len(best) && w < best) {
			best = w
		}
	}

	if best != "" {
		e.ac_suggestion = strings.clone(best)
		e.ac_prefix_len = len(prefix)
	}
}

accept_autocomplete :: proc(e: ^Editor) {
	if e.ac_suggestion == "" { return }

	suffix := e.ac_suggestion[e.ac_prefix_len:]
	for i in 0 ..< len(suffix) {
		editor_insert_char(e, suffix[i])
	}

	delete(e.ac_suggestion)
	e.ac_suggestion = ""
	e.ac_prefix_len = 0
}

// ── Selection Operations ──────────────────────────────────────────────────────

get_selected_text :: proc(e: ^Editor) -> string {
	if !e.sel_active { return "" }
	sel := selection_normalized(e)
	sb := strings.builder_make()
	for y in sel.start_y ..= sel.end_y {
		if y >= len(e.lines) { break }
		line := e.lines[y]
		sx := y == sel.start_y ? sel.start_x : 0
		ex := y == sel.end_y ? sel.end_x : len(line)
		if sx > len(line) { sx = len(line) }
		if ex > len(line) { ex = len(line) }
		if sx < ex {
			strings.write_string(&sb, line[sx:ex])
		}
		if y < sel.end_y {
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

delete_selection :: proc(e: ^Editor) {
	if !e.sel_active { return }
	sel := selection_normalized(e)

	if sel.start_y == sel.end_y {
		// Single line deletion
		if sel.start_y < len(e.lines) {
			line := e.lines[sel.start_y]
			sx := min(sel.start_x, len(line))
			ex := min(sel.end_x, len(line))
			new_line := strings.concatenate({line[:sx], line[ex:]})
			delete(e.lines[sel.start_y])
			e.lines[sel.start_y] = new_line
		}
	} else {
		// Multi-line deletion
		if sel.start_y < len(e.lines) && sel.end_y < len(e.lines) {
			start_line := e.lines[sel.start_y]
			end_line := e.lines[sel.end_y]
			sx := min(sel.start_x, len(start_line))
			ex := min(sel.end_x, len(end_line))
			new_line := strings.concatenate({start_line[:sx], end_line[ex:]})

			// Remove lines from end_y down to start_y+1
			for i := sel.end_y; i > sel.start_y; i -= 1 {
				delete(e.lines[i])
				ordered_remove(&e.lines, i)
			}
			delete(e.lines[sel.start_y])
			e.lines[sel.start_y] = new_line
		}
	}

	e.cx = sel.start_x
	e.cy = sel.start_y
	e.sel_active = false
	e.dirty = true

	// Ensure at least one line
	if len(e.lines) == 0 {
		append(&e.lines, strings.clone(""))
		e.cx = 0
		e.cy = 0
	}
	// Snap cursor
	rlen := current_line_len(e)
	if e.cx > rlen { e.cx = rlen }
}

// ── Syntax Highlighting ───────────────────────────────────────────────────────

Hl_Kind :: enum u8 {
	NORMAL,
	KEYWORD,
	TYPE,
	BUILTIN,
	STRING,
	COMMENT,
	NUMBER,
	OPERATOR,
	DIRECTIVE,
	ATTRIBUTE,
}

// ANSI color codes for each highlight kind
hl_color :: proc(kind: Hl_Kind) -> string {
	switch kind {
	case .KEYWORD:   return "\x1b[33m"       // yellow
	case .TYPE:      return "\x1b[32m"       // green
	case .BUILTIN:   return "\x1b[36m"       // cyan
	case .STRING:    return "\x1b[36m"       // cyan
	case .COMMENT:   return "\x1b[90m"       // bright black (gray)
	case .NUMBER:    return "\x1b[35m"       // magenta
	case .OPERATOR:  return "\x1b[91m"       // bright red
	case .DIRECTIVE: return "\x1b[31m"       // red
	case .ATTRIBUTE: return "\x1b[34m"       // blue
	case .NORMAL:    return "\x1b[39m"       // default
	}
	return "\x1b[39m"
}

ODIN_KEYWORDS := [?]string{
	"if", "else", "when", "for", "in", "not_in",
	"switch", "case", "break", "continue", "fallthrough",
	"return", "proc", "struct", "union", "enum", "bit_set", "bit_field",
	"map", "dynamic", "defer", "using", "import", "package",
	"where", "distinct", "opaque", "foreign",
	"or_else", "or_return", "or_break", "or_continue",
	"context", "typeid", "any",
	"cast", "auto_cast", "transmute",
}

ODIN_TYPES := [?]string{
	"int", "uint", "i8", "i16", "i32", "i64", "i128",
	"u8", "u16", "u32", "u64", "u128",
	"f16", "f32", "f64",
	"complex32", "complex64", "complex128",
	"quaternion64", "quaternion128", "quaternion256",
	"bool", "b8", "b16", "b32", "b64",
	"string", "cstring", "rune",
	"rawptr", "uintptr",
	"byte",
	"typeid",
}

ODIN_BUILTINS := [?]string{
	"len", "cap", "size_of", "align_of", "offset_of", "type_of",
	"type_info_of",
	"append", "delete", "make", "new", "free",
	"copy", "close", "clear",
	"assert", "panic",
	"min", "max", "abs", "clamp",
	"true", "false", "nil",
	"inject_at", "ordered_remove", "unordered_remove",
}

CHUCK_KEYWORDS := [?]string{
	"if", "else", "while", "for", "do", "until", "repeat",
	"break", "continue", "return",
	"class", "extends", "public", "private", "static", "pure",
	"this", "super", "interface", "implements", "protected",
	"new", "function", "fun", "spork",
	"null", "NULL", "true", "false", "maybe",
	"const", "now", "me",
	"dac", "adc", "blackhole", "cherr", "chout",
	"Machine", "Math", "Std",
	"second", "ms", "minute", "hour", "day", "week", "samp",
}

CHUCK_TYPES := [?]string{
	"int", "float", "time", "dur", "void", "string",
	"complex", "polar", "vec3", "vec4",
	"Object", "Event", "UGen", "array",
}

CHUCK_BUILTINS := [?]string{
	"SinOsc", "SawOsc", "SqrOsc", "TriOsc", "Noise", "Impulse", "Step",
	"Gain", "Pan2", "SndBuf", "SndBuf2",
	"Envelope", "ADSR",
	"Delay", "DelayL", "DelayA", "Echo",
	"JCRev", "NRev", "PRCRev", "Chorus", "PitShift",
	"Blit", "BlitSaw", "BlitSquare",
	"WvIn", "WvOut", "LiSa",
	"Phasor", "PulseOsc",
	"Mandolin", "Moog", "Rhodey", "Wurley", "BeeThree", "Shakers", "StifKarp",
	"Dyno",
	"LPF", "HPF", "BPF", "BRF", "ResonZ", "BiQuad",
	"OnePole", "TwoPole", "OneZero", "TwoZero", "PoleZero",
	"FFT", "IFFT", "DCT", "IDCT", "Flip", "pilF", "UAnaBlob",
}

is_ident_char :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

match_word_list :: proc(line: string, pos: int, words: []string) -> (length: int, found: bool) {
	for w in words {
		wl := len(w)
		if pos + wl > len(line) { continue }
		if line[pos:pos + wl] == w {
			// Must not be followed by an ident char
			if pos + wl < len(line) && is_ident_char(line[pos + wl]) { continue }
			// Must not be preceded by an ident char
			if pos > 0 && is_ident_char(line[pos - 1]) { continue }
			return wl, true
		}
	}
	return 0, false
}

// Highlight a single line (Odin). in_block_comment is the state coming into this line.
// Returns the highlight array and whether we're still inside a block comment at line end.
highlight_line_odin :: proc(line: string, in_block_comment: bool) -> (hl: [dynamic]Hl_Kind, out_block_comment: bool) {
	hl = make([dynamic]Hl_Kind, len(line))
	in_block := in_block_comment
	i := 0

	for i < len(line) {
		// Block comment continuation/start
		if in_block {
			if i + 1 < len(line) && line[i] == '*' && line[i + 1] == '/' {
				hl[i] = .COMMENT
				hl[i + 1] = .COMMENT
				i += 2
				in_block = false
			} else {
				hl[i] = .COMMENT
				i += 1
			}
			continue
		}

		// Line comment
		if i + 1 < len(line) && line[i] == '/' && line[i + 1] == '/' {
			for j in i ..< len(line) {
				hl[j] = .COMMENT
			}
			return hl, false
		}

		// Block comment start
		if i + 1 < len(line) && line[i] == '/' && line[i + 1] == '*' {
			hl[i] = .COMMENT
			hl[i + 1] = .COMMENT
			i += 2
			in_block = true
			continue
		}

		// Directives: #keyword
		if line[i] == '#' {
			start := i
			i += 1
			for i < len(line) && is_ident_char(line[i]) {
				i += 1
			}
			for j in start ..< i {
				hl[j] = .DIRECTIVE
			}
			continue
		}

		// Attribute: @
		if line[i] == '@' {
			start := i
			i += 1
			// @(...)  or @word
			if i < len(line) && line[i] == '(' {
				for i < len(line) && line[i] != ')' {
					hl[i] = .ATTRIBUTE
					i += 1
				}
				if i < len(line) {
					hl[i] = .ATTRIBUTE
					i += 1
				}
			} else {
				for i < len(line) && is_ident_char(line[i]) {
					i += 1
				}
			}
			for j in start ..< i {
				hl[j] = .ATTRIBUTE
			}
			continue
		}

		// Strings (double-quoted)
		if line[i] == '"' {
			start := i
			hl[i] = .STRING
			i += 1
			for i < len(line) {
				if line[i] == '\\' && i + 1 < len(line) {
					hl[i] = .STRING
					hl[i + 1] = .STRING
					i += 2
					continue
				}
				hl[i] = .STRING
				if line[i] == '"' {
					i += 1
					break
				}
				i += 1
			}
			_ = start
			continue
		}

		// Raw strings (backtick)
		if line[i] == '`' {
			hl[i] = .STRING
			i += 1
			for i < len(line) && line[i] != '`' {
				hl[i] = .STRING
				i += 1
			}
			if i < len(line) {
				hl[i] = .STRING
				i += 1
			}
			continue
		}

		// Char literals
		if line[i] == '\'' {
			hl[i] = .STRING
			i += 1
			for i < len(line) {
				if line[i] == '\\' && i + 1 < len(line) {
					hl[i] = .STRING
					hl[i + 1] = .STRING
					i += 2
					continue
				}
				hl[i] = .STRING
				if line[i] == '\'' {
					i += 1
					break
				}
				i += 1
			}
			continue
		}

		// Numbers
		if (line[i] >= '0' && line[i] <= '9') ||
		   (line[i] == '.' && i + 1 < len(line) && line[i + 1] >= '0' && line[i + 1] <= '9') {
			// Don't highlight if preceded by ident char (part of identifier)
			if i > 0 && (is_ident_char(line[i - 1]) && line[i - 1] != '_') {
				hl[i] = .NORMAL
				i += 1
				continue
			}
			for i < len(line) && (line[i] >= '0' && line[i] <= '9' ||
			                      line[i] == '.' || line[i] == 'x' || line[i] == 'X' ||
			                      line[i] == 'o' || line[i] == 'b' || line[i] == '_' ||
			                      (line[i] >= 'a' && line[i] <= 'f') ||
			                      (line[i] >= 'A' && line[i] <= 'F') ||
			                      line[i] == 'e' || line[i] == 'E' ||
			                      line[i] == '+' || line[i] == '-') {
				hl[i] = .NUMBER
				i += 1
			}
			continue
		}

		// Identifiers / keywords / types / builtins
		if is_ident_char(line[i]) && !(line[i] >= '0' && line[i] <= '9') {
			start := i
			for i < len(line) && is_ident_char(line[i]) {
				i += 1
			}
			word := line[start:i]

			kind := Hl_Kind.NORMAL
			// Check keywords
			for kw in ODIN_KEYWORDS {
				if word == kw {
					kind = .KEYWORD
					break
				}
			}
			if kind == .NORMAL {
				for t in ODIN_TYPES {
					if word == t {
						kind = .TYPE
						break
					}
				}
			}
			if kind == .NORMAL {
				for b in ODIN_BUILTINS {
					if word == b {
						kind = .BUILTIN
						break
					}
				}
			}
			for j in start ..< i {
				hl[j] = kind
			}
			continue
		}

		// Operators
		switch line[i] {
		case '+', '-', '*', '/', '%', '&', '|', '^', '~', '!', '=', '<', '>', ':', ';', ',':
			hl[i] = .OPERATOR
		}

		i += 1
	}

	return hl, in_block
}

// Highlight a single line (ChucK).
highlight_line_chuck :: proc(line: string, in_block_comment: bool) -> (hl: [dynamic]Hl_Kind, out_block_comment: bool) {
	hl = make([dynamic]Hl_Kind, len(line))
	in_block := in_block_comment
	i := 0

	for i < len(line) {
		// Block comment continuation/start
		if in_block {
			if i + 1 < len(line) && line[i] == '*' && line[i + 1] == '/' {
				hl[i] = .COMMENT
				hl[i + 1] = .COMMENT
				i += 2
				in_block = false
			} else {
				hl[i] = .COMMENT
				i += 1
			}
			continue
		}

		// Line comment
		if i + 1 < len(line) && line[i] == '/' && line[i + 1] == '/' {
			for j in i ..< len(line) {
				hl[j] = .COMMENT
			}
			return hl, false
		}

		// Block comment start
		if i + 1 < len(line) && line[i] == '/' && line[i + 1] == '*' {
			hl[i] = .COMMENT
			hl[i + 1] = .COMMENT
			i += 2
			in_block = true
			continue
		}

		// Strings (double-quoted only)
		if line[i] == '"' {
			hl[i] = .STRING
			i += 1
			for i < len(line) {
				if line[i] == '\\' && i + 1 < len(line) {
					hl[i] = .STRING
					hl[i + 1] = .STRING
					i += 2
					continue
				}
				hl[i] = .STRING
				if line[i] == '"' {
					i += 1
					break
				}
				i += 1
			}
			continue
		}

		// ChucK operator => (chuck operator)
		if i + 1 < len(line) && line[i] == '=' && line[i + 1] == '>' {
			hl[i] = .OPERATOR
			hl[i + 1] = .OPERATOR
			i += 2
			continue
		}

		// <<< debug print delimiter
		if i + 2 < len(line) && line[i] == '<' && line[i + 1] == '<' && line[i + 2] == '<' {
			hl[i] = .OPERATOR
			hl[i + 1] = .OPERATOR
			hl[i + 2] = .OPERATOR
			i += 3
			continue
		}

		// >>> debug print delimiter
		if i + 2 < len(line) && line[i] == '>' && line[i + 1] == '>' && line[i + 2] == '>' {
			hl[i] = .OPERATOR
			hl[i + 1] = .OPERATOR
			hl[i + 2] = .OPERATOR
			i += 3
			continue
		}

		// Numbers
		if (line[i] >= '0' && line[i] <= '9') ||
		   (line[i] == '.' && i + 1 < len(line) && line[i + 1] >= '0' && line[i + 1] <= '9') {
			if i > 0 && (is_ident_char(line[i - 1]) && line[i - 1] != '_') {
				hl[i] = .NORMAL
				i += 1
				continue
			}
			for i < len(line) && (line[i] >= '0' && line[i] <= '9' ||
			                      line[i] == '.' || line[i] == 'x' || line[i] == 'X' ||
			                      line[i] == 'o' || line[i] == 'b' || line[i] == '_' ||
			                      (line[i] >= 'a' && line[i] <= 'f') ||
			                      (line[i] >= 'A' && line[i] <= 'F') ||
			                      line[i] == 'e' || line[i] == 'E' ||
			                      line[i] == '+' || line[i] == '-') {
				hl[i] = .NUMBER
				i += 1
			}
			continue
		}

		// Identifiers / keywords / types / builtins
		if is_ident_char(line[i]) && !(line[i] >= '0' && line[i] <= '9') {
			start := i
			for i < len(line) && is_ident_char(line[i]) {
				i += 1
			}
			word := line[start:i]

			kind := Hl_Kind.NORMAL
			for kw in CHUCK_KEYWORDS {
				if word == kw {
					kind = .KEYWORD
					break
				}
			}
			if kind == .NORMAL {
				for t in CHUCK_TYPES {
					if word == t {
						kind = .TYPE
						break
					}
				}
			}
			if kind == .NORMAL {
				for b in CHUCK_BUILTINS {
					if word == b {
						kind = .BUILTIN
						break
					}
				}
			}
			for j in start ..< i {
				hl[j] = kind
			}
			continue
		}

		// Operators
		switch line[i] {
		case '+', '-', '*', '/', '%', '&', '|', '^', '~', '!', '=', '<', '>', ':', ';', ',':
			hl[i] = .OPERATOR
		}

		i += 1
	}

	return hl, in_block
}

// Dispatch to the appropriate language highlighter.
highlight_line :: proc(line: string, in_block_comment: bool, lang: Language = .ODIN) -> (hl: [dynamic]Hl_Kind, out_block_comment: bool) {
	switch lang {
	case .CHUCK:
		return highlight_line_chuck(line, in_block_comment)
	case .ODIN:
		return highlight_line_odin(line, in_block_comment)
	case .UNKNOWN:
		// No highlighting — return all NORMAL
		hl = make([dynamic]Hl_Kind, len(line))
		return hl, in_block_comment
	}
	return highlight_line_odin(line, in_block_comment)
}

// ── Drawing ────────────────────────────────────────────────────────────────────

draw_panel_row :: proc(ab: ^strings.Builder, e: ^Editor, y: int) {
	panel := &e.panel
	entry_idx := y + panel.scroll_off
	if entry_idx < len(panel.entries) {
		entry := panel.entries[entry_idx]
		is_cursor := entry_idx == panel.cursor

		if is_cursor {
			strings.write_string(ab, "\x1b[7m") // inverted
		}

		// Indentation (2 spaces per depth, depth is relative to root children which are depth 1)
		indent := (entry.depth - 1) * 2
		for _ in 0 ..< indent {
			strings.write_byte(ab, ' ')
		}

		// Icon
		chars_written := indent
		if entry.is_dir {
			if entry.expanded {
				strings.write_string(ab, "\xe2\x96\xbe ") // ▾
				chars_written += 3 // 3 bytes for ▾ but 1 display col + space
			} else {
				strings.write_string(ab, "\xe2\x96\xb8 ") // ▸
				chars_written += 3
			}
		} else {
			strings.write_string(ab, "\xc2\xb7 ") // ·
			chars_written += 3
		}

		// Name - truncate to fit panel width
		// The icon takes ~2 display columns (icon + space)
		display_used := indent + 2
		avail := panel.width - display_used
		name := entry.name
		if avail > 0 {
			if len(name) > avail {
				name = name[:avail]
			}
			strings.write_string(ab, name)
			display_used += len(name)
		}

		// Pad to panel width
		for _ in display_used ..< panel.width {
			strings.write_byte(ab, ' ')
		}

		if is_cursor {
			strings.write_string(ab, "\x1b[m") // reset
		}
	} else {
		// Empty row in panel
		for _ in 0 ..< panel.width {
			strings.write_byte(ab, ' ')
		}
	}
}

editor_draw :: proc(e: ^Editor) {
	editor_scroll(e)

	ab := strings.builder_make()
	defer strings.builder_destroy(&ab)

	// Hide cursor + move to top-left
	strings.write_string(&ab, "\x1b[?25l")
	strings.write_string(&ab, "\x1b[H")

	// Pre-compute selection range
	sel := selection_normalized(e)

	panel_visible := e.panel.visible
	panel_w := panel_visible ? e.panel.width : 0
	editor_col_start := panel_visible ? panel_w + 1 : 0 // +1 for separator

	// Compute block comment state from the top of the file down to row_off
	block_comment_state := false
	for r in 0 ..< e.row_off {
		if r < len(e.lines) {
			hl_tmp, out_bc := highlight_line(e.lines[r], block_comment_state, e.language)
			delete(hl_tmp)
			block_comment_state = out_bc
		}
	}

	// Panel scroll clamping
	if panel_visible {
		panel := &e.panel
		if panel.cursor < panel.scroll_off {
			panel.scroll_off = panel.cursor
		}
		if panel.cursor >= panel.scroll_off + e.screen_rows {
			panel.scroll_off = panel.cursor - e.screen_rows + 1
		}
		if panel.scroll_off < 0 { panel.scroll_off = 0 }
	}

	// Draw rows
	for y in 0 ..< e.screen_rows {
		// Draw panel column if visible
		if panel_visible {
			draw_panel_row(&ab, e, y)
			// Separator
			strings.write_string(&ab, "\xe2\x94\x82") // │
		}

		file_row := y + e.row_off
		if file_row < len(e.lines) {
			line := e.lines[file_row]
			line_len := len(line)

			// Highlight the full line, then we slice into the visible portion
			hl, out_bc := highlight_line(line, block_comment_state, e.language)
			defer delete(hl)
			block_comment_state = out_bc

			if line_len > e.col_off {
				vis_start := e.col_off
				vis_end := min(line_len, e.col_off + e.screen_cols)

				prev_kind := Hl_Kind.NORMAL
				in_sel := false
				for ci in vis_start ..< vis_end {
					want_sel := e.sel_active && is_selected(e, ci, file_row, sel)

					if want_sel && !in_sel {
						strings.write_string(&ab, "\x1b[7m")
						in_sel = true
						prev_kind = .NORMAL // force re-emit color after selection
					} else if !want_sel && in_sel {
						strings.write_string(&ab, "\x1b[m")
						in_sel = false
						prev_kind = .NORMAL
					}

					kind := ci < len(hl) ? hl[ci] : Hl_Kind.NORMAL
					if kind != prev_kind && !in_sel {
						strings.write_string(&ab, hl_color(kind))
						prev_kind = kind
					}

					strings.write_byte(&ab, line[ci])
				}
				if in_sel {
					strings.write_string(&ab, "\x1b[m")
				} else if prev_kind != .NORMAL {
					strings.write_string(&ab, "\x1b[39m")
				}
			}

			// Ghost text for autocomplete on cursor line
			if file_row == e.cy && e.ac_suggestion != "" && e.mode == .INSERT {
				suffix := e.ac_suggestion[e.ac_prefix_len:]
				chars_on_screen := max(min(line_len, e.col_off + e.screen_cols) - e.col_off, 0)
				remaining := e.screen_cols - chars_on_screen
				ghost_len := min(len(suffix), remaining)
				if ghost_len > 0 {
					strings.write_string(&ab, "\x1b[90m")
					strings.write_string(&ab, suffix[:ghost_len])
					strings.write_string(&ab, "\x1b[39m")
				}
			}
		} else {
			if len(e.lines) == 0 && y == e.screen_rows / 3 {
				welcome := "byote -- a tiny text editor"
				if len(welcome) > e.screen_cols {
					welcome = welcome[:e.screen_cols]
				}
				padding := (e.screen_cols - len(welcome)) / 2
				if padding > 0 {
					strings.write_string(&ab, "~")
					for _ in 1 ..< padding {
						strings.write_byte(&ab, ' ')
					}
				}
				strings.write_string(&ab, welcome)
			} else {
				strings.write_string(&ab, "~")
			}
		}

		strings.write_string(&ab, "\x1b[K") // clear rest of line
		strings.write_string(&ab, "\r\n")
	}

	// Status bar (inverted colors) - spans full terminal width
	strings.write_string(&ab, "\x1b[7m")

	mode_str: string
	switch e.mode {
	case .NORMAL:  mode_str = "NORMAL"
	case .INSERT:  mode_str = "INSERT"
	case .COMMAND: mode_str = "COMMAND"
	}

	dirty_indicator := e.dirty ? " [+]" : ""
	fname := e.filename != "" ? e.filename : "[No Name]"
	left := fmt.tprintf(" %s %s%s", mode_str, fname, dirty_indicator)
	right := fmt.tprintf("%d/%d ", e.cy + 1, len(e.lines))

	status_width := e.total_cols
	if len(left) > status_width {
		left = left[:status_width]
	}
	strings.write_string(&ab, left)

	for i in len(left) ..< status_width {
		if status_width - i == len(right) {
			strings.write_string(&ab, right)
			break
		} else {
			strings.write_byte(&ab, ' ')
		}
	}

	strings.write_string(&ab, "\x1b[m") // reset
	strings.write_string(&ab, "\r\n")

	// Message bar / command line
	strings.write_string(&ab, "\x1b[K")
	if e.mode == .COMMAND {
		strings.write_string(&ab, ":")
		strings.write_string(&ab, strings.to_string(e.command_buf))
	} else if e.status_msg != "" {
		msg := e.status_msg
		if len(msg) > e.total_cols {
			msg = msg[:e.total_cols]
		}
		strings.write_string(&ab, msg)
	}

	// Position cursor
	if e.focus == .PANEL && panel_visible {
		// Cursor in panel area
		panel_cursor_row := e.panel.cursor - e.panel.scroll_off + 1
		cursor_pos := fmt.tprintf("\x1b[%d;%dH", panel_cursor_row, 1)
		strings.write_string(&ab, cursor_pos)
	} else {
		screen_cy := e.cy - e.row_off + 1
		screen_cx := e.cx - e.col_off + 1 + editor_col_start
		cursor_pos := fmt.tprintf("\x1b[%d;%dH", screen_cy, screen_cx)
		strings.write_string(&ab, cursor_pos)
	}

	// Show cursor
	strings.write_string(&ab, "\x1b[?25h")

	// Write everything at once
	output := strings.to_string(ab)
	linux.write(linux.Fd(1), transmute([]u8)output)
}

// ── Command Processing ─────────────────────────────────────────────────────────

process_command :: proc(e: ^Editor) {
	cmd := strings.to_string(e.command_buf)

	if cmd == "q" {
		if e.dirty {
			set_status(e, "Unsaved changes! Use :q! to force quit or :w to save")
		} else {
			e.quit = true
		}
	} else if cmd == "q!" {
		e.quit = true
	} else if cmd == "w" {
		editor_save(e)
	} else if cmd == "wq" {
		editor_save(e)
		e.quit = true
	} else {
		set_status(e, fmt.tprintf("Unknown command: %s", cmd))
	}

	strings.builder_reset(&e.command_buf)
	e.mode = .NORMAL
}

// ── Input Handling ─────────────────────────────────────────────────────────────

process_panel_action :: proc(e: ^Editor) {
	panel := &e.panel
	if panel.cursor < 0 || panel.cursor >= len(panel.entries) { return }
	entry := panel.entries[panel.cursor]

	if entry.is_dir {
		entry.expanded = !entry.expanded
		if entry.expanded && !entry.loaded {
			load_children(entry)
		}
		flatten_entries(panel)
		// Clamp cursor after flatten
		if panel.cursor >= len(panel.entries) {
			panel.cursor = max(len(panel.entries) - 1, 0)
		}
	} else {
		panel_open_file(e, entry.path)
	}
}

process_keypress :: proc(e: ^Editor) {
	key, ok := read_key()
	if !ok { return }

	// ── Ctrl+B toggle panel focus (works in all modes) ──
	if key == 2 && e.panel.visible { // Ctrl+B
		if e.focus == .PANEL {
			e.focus = .EDITOR
		} else {
			e.focus = .PANEL
		}
		return
	}

	// ── Mouse handling (works in all modes) ──
	is_mouse := false
	panel_col_end := e.panel.visible ? e.panel.width : 0

	switch key {
	case MOUSE_LEFT_CLICK:
		is_mouse = true
		screen_y := g_mouse_y - 1
		if screen_y >= e.screen_rows { break }
		mouse_col := g_mouse_x - 1 // 0-based

		// Check if click is in panel area
		if e.panel.visible && mouse_col < panel_col_end {
			e.focus = .PANEL
			entry_idx := screen_y + e.panel.scroll_off
			if entry_idx >= 0 && entry_idx < len(e.panel.entries) {
				e.panel.cursor = entry_idx
				process_panel_action(e)
			}
			break
		}

		// Click in editor area - adjust x for panel offset
		e.focus = .EDITOR
		editor_x := mouse_col - (e.panel.visible ? panel_col_end + 1 : 0)
		file_x := editor_x + e.col_off
		file_y := screen_y + e.row_off
		// Clamp to valid range
		if file_y < 0 { file_y = 0 }
		if file_y >= len(e.lines) { file_y = len(e.lines) - 1 }
		if file_y < 0 { file_y = 0 }
		e.cy = file_y
		if file_x < 0 { file_x = 0 }
		line_len := current_line_len(e)
		if file_x > line_len { file_x = line_len }
		e.cx = file_x
		e.mouse_down = true
		e.sel_active = false
		e.sel_start_x = e.cx
		e.sel_start_y = e.cy
		e.sel_end_x = e.cx
		e.sel_end_y = e.cy
		// Switch to INSERT mode on click (micro-like behavior)
		if e.mode == .NORMAL {
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		}
	case MOUSE_DOUBLE_CLICK:
		is_mouse = true
		screen_y := g_mouse_y - 1
		if screen_y >= e.screen_rows { break }
		mouse_col := g_mouse_x - 1
		if e.panel.visible && mouse_col < panel_col_end { break } // ignore in panel
		editor_x := mouse_col - (e.panel.visible ? panel_col_end + 1 : 0)
		file_x := editor_x + e.col_off
		file_y := screen_y + e.row_off
		if file_y < 0 { file_y = 0 }
		if file_y >= len(e.lines) { file_y = len(e.lines) - 1 }
		if file_y < 0 { file_y = 0 }
		e.cy = file_y
		line := e.cy < len(e.lines) ? e.lines[e.cy] : ""
		if file_x >= len(line) { file_x = max(len(line) - 1, 0) }
		ws := word_start_at(line, file_x)
		we := word_end_at(line, file_x)
		if ws == we {
			// Clicked on non-word char, select just that char
			we = min(ws + 1, len(line))
		}
		e.cx = ws
		e.sel_active = true
		e.sel_start_x = ws
		e.sel_start_y = e.cy
		e.sel_end_x = we
		e.sel_end_y = e.cy
		e.mouse_down = false
		if e.mode == .NORMAL {
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		}
	case MOUSE_TRIPLE_CLICK:
		is_mouse = true
		screen_y := g_mouse_y - 1
		if screen_y >= e.screen_rows { break }
		mouse_col := g_mouse_x - 1
		if e.panel.visible && mouse_col < panel_col_end { break }
		file_y := screen_y + e.row_off
		if file_y < 0 { file_y = 0 }
		if file_y >= len(e.lines) { file_y = len(e.lines) - 1 }
		if file_y < 0 { file_y = 0 }
		e.cy = file_y
		e.cx = 0
		line_len := e.cy < len(e.lines) ? len(e.lines[e.cy]) : 0
		e.sel_active = true
		e.sel_start_x = 0
		e.sel_start_y = e.cy
		e.sel_end_x = line_len
		e.sel_end_y = e.cy
		e.mouse_down = false
		if e.mode == .NORMAL {
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		}
	case MOUSE_LEFT_DRAG:
		is_mouse = true
		if e.mouse_down {
			screen_y := g_mouse_y - 1
			mouse_col := g_mouse_x - 1
			editor_x := mouse_col - (e.panel.visible ? panel_col_end + 1 : 0)
			file_x := editor_x + e.col_off
			file_y := screen_y + e.row_off
			// Clamp screen_y to text area (allow dragging to edges for auto-scroll feel)
			if screen_y >= e.screen_rows {
				file_y = e.row_off + e.screen_rows - 1
			}
			if file_y < 0 { file_y = 0 }
			if file_y >= len(e.lines) { file_y = len(e.lines) - 1 }
			if file_y < 0 { file_y = 0 }
			if file_x < 0 { file_x = 0 }
			line_len := 0
			if file_y < len(e.lines) { line_len = len(e.lines[file_y]) }
			if file_x > line_len { file_x = line_len }
			e.sel_end_x = file_x
			e.sel_end_y = file_y
			e.cx = file_x
			e.cy = file_y
			if e.sel_end_x != e.sel_start_x || e.sel_end_y != e.sel_start_y {
				e.sel_active = true
			}
		}
	case MOUSE_LEFT_RELEASE:
		is_mouse = true
		e.mouse_down = false
	case MOUSE_SCROLL_UP:
		is_mouse = true
		if e.focus == .PANEL && e.panel.visible {
			e.panel.scroll_off -= 3
			if e.panel.scroll_off < 0 { e.panel.scroll_off = 0 }
		} else {
			e.sel_active = false
			e.row_off -= 3
			if e.row_off < 0 { e.row_off = 0 }
			if e.cy >= e.row_off + e.screen_rows {
				e.cy = e.row_off + e.screen_rows - 1
			}
		}
	case MOUSE_SCROLL_DOWN:
		is_mouse = true
		if e.focus == .PANEL && e.panel.visible {
			max_off := len(e.panel.entries) - e.screen_rows
			if max_off < 0 { max_off = 0 }
			e.panel.scroll_off += 3
			if e.panel.scroll_off > max_off { e.panel.scroll_off = max_off }
		} else {
			e.sel_active = false
			max_off := len(e.lines) - e.screen_rows
			if max_off < 0 { max_off = 0 }
			e.row_off += 3
			if e.row_off > max_off { e.row_off = max_off }
			if e.cy < e.row_off {
				e.cy = e.row_off
			}
		}
	}
	if is_mouse { return }

	// ── Panel keyboard handling ──
	if e.focus == .PANEL && e.panel.visible {
		panel := &e.panel
		switch key {
		case 'k', 1000: // up
			if panel.cursor > 0 { panel.cursor -= 1 }
		case 'j', 1001: // down
			if panel.cursor < len(panel.entries) - 1 { panel.cursor += 1 }
		case 13, 1002: // Enter or Right arrow - expand/open
			process_panel_action(e)
		case 1003: // Left arrow - collapse or go to parent
			if panel.cursor >= 0 && panel.cursor < len(panel.entries) {
				entry := panel.entries[panel.cursor]
				if entry.is_dir && entry.expanded {
					entry.expanded = false
					flatten_entries(panel)
					if panel.cursor >= len(panel.entries) {
						panel.cursor = max(len(panel.entries) - 1, 0)
					}
				} else {
					// Move to parent directory entry
					if panel.cursor > 0 {
						target_depth := entry.depth - 1
						for i := panel.cursor - 1; i >= 0; i -= 1 {
							if panel.entries[i].is_dir && panel.entries[i].depth == target_depth {
								panel.cursor = i
								break
							}
						}
					}
				}
			}
		case 'q', 0x1b: // q or Escape - switch to editor
			e.focus = .EDITOR
		case 17: // Ctrl+Q - quit
			e.quit = true
		}
		return
	}

	// Reset quit confirmation on any non-Ctrl+Q key
	if key != 17 {
		e.quit_count = 0
	}

	switch e.mode {
	case .NORMAL:
		switch key {
		case 'h', 'j', 'k', 'l', 1000, 1001, 1002, 1003:
			e.sel_active = false
			editor_move_cursor(e, key)
		case 1004: // HOME
			e.sel_active = false
			e.cx = 0
		case 1005: // END
			e.sel_active = false
			e.cx = current_line_len(e)
		case 'i':
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		case 'a':
			if current_line_len(e) > 0 {
				e.cx += 1
			}
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		case 'o':
			// Open new line below
			if e.cy < len(e.lines) {
				inject_at(&e.lines, e.cy + 1, strings.clone(""))
			} else {
				append(&e.lines, strings.clone(""))
			}
			e.cy += 1
			e.cx = 0
			e.dirty = true
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		case 'O':
			// Open new line above
			inject_at(&e.lines, e.cy, strings.clone(""))
			e.cx = 0
			e.dirty = true
			e.mode = .INSERT
			set_status(e, "-- INSERT --")
		case 'x':
			// Delete char under cursor
			if e.cy < len(e.lines) && e.cx < len(e.lines[e.cy]) {
				line := e.lines[e.cy]
				new_line := strings.concatenate({line[:e.cx], line[e.cx + 1:]})
				delete(e.lines[e.cy])
				e.lines[e.cy] = new_line
				e.dirty = true
				if e.cx >= len(e.lines[e.cy]) && e.cx > 0 {
					e.cx -= 1
				}
			}
		case 'd':
			// dd to delete line - read next key
			key2, ok2 := read_key()
			if ok2 && key2 == 'd' && len(e.lines) > 0 {
				if e.cy < len(e.lines) {
					delete(e.lines[e.cy])
					ordered_remove(&e.lines, e.cy)
					if len(e.lines) == 0 {
						append(&e.lines, strings.clone(""))
					}
					if e.cy >= len(e.lines) {
						e.cy = len(e.lines) - 1
					}
					rlen := current_line_len(e)
					if e.cx > rlen {
						e.cx = rlen
					}
					e.dirty = true
				}
			}
		case 'G':
			// Go to last line
			if len(e.lines) > 0 {
				e.cy = len(e.lines) - 1
			}
		case 'g':
			key2, ok2 := read_key()
			if ok2 && key2 == 'g' {
				e.cy = 0
				e.cx = 0
			}
		case '0':
			e.cx = 0
		case '$':
			e.cx = current_line_len(e)
		case 17: // Ctrl+Q - quit
			if e.dirty {
				e.quit_count += 1
				if e.quit_count >= 2 {
					e.quit = true
				} else {
					set_status(e, "Unsaved changes! Press Ctrl+Q again to force quit")
				}
				return
			}
			e.quit = true
		case ':':
			e.mode = .COMMAND
			strings.builder_reset(&e.command_buf)
			set_status(e, "")
		}

	case .INSERT:
		switch key {
		case 0x1b: // Escape
			e.sel_active = false
			if e.ac_suggestion != "" {
				delete(e.ac_suggestion)
				e.ac_suggestion = ""
				e.ac_prefix_len = 0
			}
			if e.cx > 0 {
				e.cx -= 1
			}
			e.mode = .NORMAL
			set_status(e, "")
		case 3: // Ctrl+C - copy
			if e.sel_active {
				txt := get_selected_text(e)
				if e.clipboard != "" { delete(e.clipboard) }
				e.clipboard = strings.clone(txt)
				set_status(e, "Copied")
			}
		case 24: // Ctrl+X - cut
			if e.sel_active {
				txt := get_selected_text(e)
				if e.clipboard != "" { delete(e.clipboard) }
				e.clipboard = strings.clone(txt)
				delete_selection(e)
				set_status(e, "Cut")
				update_autocomplete(e)
			}
		case 22: // Ctrl+V - paste
			if e.sel_active {
				delete_selection(e)
			}
			if e.clipboard != "" {
				for ci in 0 ..< len(e.clipboard) {
					c := e.clipboard[ci]
					if c == '\n' {
						editor_insert_newline(e)
					} else {
						editor_insert_char(e, c)
					}
				}
				set_status(e, "Pasted")
			}
			update_autocomplete(e)
		case 1: // Ctrl+A - select all
			e.sel_active = true
			e.sel_start_x = 0
			e.sel_start_y = 0
			last_line := max(len(e.lines) - 1, 0)
			e.sel_end_y = last_line
			e.sel_end_x = last_line < len(e.lines) ? len(e.lines[last_line]) : 0
		case 17: // Ctrl+Q - quit
			if e.dirty {
				e.quit_count += 1
				if e.quit_count >= 2 {
					e.quit = true
				} else {
					set_status(e, "Unsaved changes! Press Ctrl+Q again to force quit")
				}
				return
			}
			e.quit = true
		case 19: // Ctrl+S - save
			editor_save(e)
		case 9: // Tab - accept suggestion or insert tab
			if e.ac_suggestion != "" {
				accept_autocomplete(e)
			} else {
				if e.sel_active { delete_selection(e) }
				editor_insert_char(e, '\t')
				update_autocomplete(e)
			}
		case 13: // Enter
			if e.ac_suggestion != "" {
				delete(e.ac_suggestion)
				e.ac_suggestion = ""
				e.ac_prefix_len = 0
			}
			if e.sel_active { delete_selection(e) }
			editor_insert_newline(e)
		case 127, 8: // Backspace, Ctrl-H
			if e.sel_active {
				delete_selection(e)
			} else {
				editor_delete_char(e)
			}
			update_autocomplete(e)
		case 1006: // DELETE key
			if e.sel_active {
				delete_selection(e)
			} else if e.cy < len(e.lines) && e.cx < len(e.lines[e.cy]) {
				line := e.lines[e.cy]
				new_line := strings.concatenate({line[:e.cx], line[e.cx + 1:]})
				delete(e.lines[e.cy])
				e.lines[e.cy] = new_line
				e.dirty = true
			}
			update_autocomplete(e)
		case 1002: // Right arrow
			if e.ac_suggestion != "" && e.cx >= current_line_len(e) {
				accept_autocomplete(e)
			} else {
				e.sel_active = false
				editor_move_cursor(e, key)
				update_autocomplete(e)
			}
		case 1005: // END
			if e.ac_suggestion != "" {
				accept_autocomplete(e)
			} else {
				e.sel_active = false
				e.cx = current_line_len(e)
			}
		case 1000, 1001, 1003: // Up, Down, Left arrow keys
			e.sel_active = false
			editor_move_cursor(e, key)
			update_autocomplete(e)
		case 1004: // HOME
			e.sel_active = false
			e.cx = 0
			update_autocomplete(e)
		case:
			if key >= 32 && key < 127 {
				if e.sel_active { delete_selection(e) }
				editor_insert_char(e, u8(key))
				update_autocomplete(e)
			}
		}

	case .COMMAND:
		switch key {
		case 0x1b: // Escape - cancel command
			strings.builder_reset(&e.command_buf)
			e.mode = .NORMAL
			set_status(e, "")
		case 13: // Enter - execute command
			process_command(e)
		case 127, 8: // Backspace
			s := strings.to_string(e.command_buf)
			if len(s) > 0 {
				strings.pop_byte(&e.command_buf)
			} else {
				e.mode = .NORMAL
				set_status(e, "")
			}
		case:
			if key >= 32 && key < 127 {
				strings.write_byte(&e.command_buf, u8(key))
			}
		}
	}
}

// ── Main ───────────────────────────────────────────────────────────────────────

main :: proc() {
	e: Editor
	e.lines = make([dynamic]string)
	e.command_buf = strings.builder_make()
	defer {
		// Disable mouse tracking
		linux.write(linux.Fd(1), transmute([]u8)string("\x1b[?1006l\x1b[?1002l\x1b[?1000l"))
		disable_raw_mode(&e)
		// Clear screen on exit
		linux.write(linux.Fd(1), transmute([]u8)string("\x1b[2J\x1b[H"))
		strings.builder_destroy(&e.command_buf)
		if e.ac_suggestion != "" { delete(e.ac_suggestion) }
		if e.clipboard != "" { delete(e.clipboard) }
		for &line in e.lines {
			delete(line)
		}
		delete(e.lines)
	}

	if !enable_raw_mode(&e) {
		fmt.eprintln("Failed to enable raw mode")
		return
	}

	// Enable mouse tracking (SGR 1006 extended mode)
	linux.write(linux.Fd(1), transmute([]u8)string("\x1b[?1000h\x1b[?1002h\x1b[?1006h"))

	if !get_window_size(&e) {
		fmt.eprintln("Failed to get window size")
		return
	}

	// Load file or directory from args
	args := os.args
	if len(args) > 1 {
		arg_path := args[1]
		// Check if it's a directory
		if os.is_directory(arg_path) {
			abs_path, abs_ok := filepath.abs(arg_path, context.allocator)
			if abs_ok == nil {
				e.panel.root = scan_directory(abs_path, 0)
				e.panel.root_path = strings.clone(abs_path)
			} else {
				e.panel.root = scan_directory(arg_path, 0)
				e.panel.root_path = strings.clone(arg_path)
			}
			e.panel.visible = true
			e.panel.entries = make([dynamic]^File_Entry)
			flatten_entries(&e.panel)
			e.focus = .PANEL
			// Recalculate cols with panel
			get_window_size(&e)
			set_status(&e, "byote: Use arrows to navigate, Enter to open")
		} else {
			editor_open(&e, arg_path)
		}
	} else {
		set_status(e = &e, msg = "byote: :q to quit | i for insert mode | :w to save")
	}

	// Ensure at least one line
	if len(e.lines) == 0 {
		append(&e.lines, strings.clone(""))
	}

	for !e.quit {
		get_window_size(&e) // refresh in case terminal resized
		editor_draw(&e)
		process_keypress(&e)
	}
}
