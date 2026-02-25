// Build your own top. See https://codingchallenges.fyi/challenges/challenge-top

package cctop

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

// Terminal window size struct for ioctl
Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

// Memory unit modes
Mem_Unit :: enum {
	KiB,
	MiB,
	GiB,
	Auto,
}

// CPU stat snapshot from /proc/stat
CPU_Stats :: struct {
	user:    u64,
	nice:    u64,
	system:  u64,
	idle:    u64,
	iowait:  u64,
	irq:     u64,
	softirq: u64,
	steal:   u64,
}

// Per-process info
Process_Info :: struct {
	pid:         int,
	comm:        string,
	state:       u8,
	utime:       u64,
	stime:       u64,
	num_threads: int,
	rss_pages:   i64,
	cpu_percent: f64,
	mem_kb:      i64,
	cmdline:     string,
}

// Previous CPU times for delta calculation (per-process)
Prev_Proc_CPU :: struct {
	utime: u64,
	stime: u64,
}

// Global state
orig_termios: posix.termios
term_rows: int = 24
term_cols: int = 80
mem_unit: Mem_Unit = .Auto
prev_cpu: CPU_Stats
prev_proc_cpu: map[int]Prev_Proc_CPU
prev_total_cpu_time: u64

// Output buffer to reduce write calls
output_buf: [dynamic]u8

buf_write :: proc(s: string) {
	append(&output_buf, s)
}

buf_flush :: proc() {
	if len(output_buf) > 0 {
		linux.write(linux.STDOUT_FILENO, output_buf[:])
		clear(&output_buf)
	}
}

// Enter terminal raw mode
enter_raw_mode :: proc() {
	posix.tcgetattr(posix.FD(0), &orig_termios)
	raw := orig_termios
	raw.c_lflag &= ~posix.CLocal_Flags{.ICANON, .ECHO, .ISIG, .IEXTEN}
	raw.c_iflag &= ~posix.CInput_Flags{.IXON, .ICRNL, .BRKINT, .INPCK, .ISTRIP}
	raw.c_oflag &= ~posix.COutput_Flags{.OPOST}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &raw)
}

// Restore terminal
restore_terminal :: proc() {
	posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &orig_termios)
	buf_write("\x1b[?25h\x1b[0m")
	buf_flush()
}

// Get terminal size
get_terminal_size :: proc() {
	ws: Winsize
	linux.ioctl(linux.STDOUT_FILENO, linux.TIOCGWINSZ, uintptr(&ws))
	if ws.ws_row > 0 {
		term_rows = int(ws.ws_row)
	}
	if ws.ws_col > 0 {
		term_cols = int(ws.ws_col)
	}
}

// Read a file from /proc as string (uses temp allocator)
read_proc_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// Parse /proc/stat first line for CPU stats
parse_cpu_stats :: proc() -> (CPU_Stats, bool) {
	content, ok := read_proc_file("/proc/stat")
	if !ok {
		return {}, false
	}

	first_line: string
	nl := strings.index_byte(content, '\n')
	if nl >= 0 {
		first_line = content[:nl]
	} else {
		first_line = content
	}

	fields_str := strings.trim_left(first_line[3:], " ")
	fields := strings.split(fields_str, " ", context.temp_allocator)

	if len(fields) < 8 {
		return {}, false
	}

	stats: CPU_Stats
	stats.user, _ = strconv.parse_u64_of_base(fields[0], 10)
	stats.nice, _ = strconv.parse_u64_of_base(fields[1], 10)
	stats.system, _ = strconv.parse_u64_of_base(fields[2], 10)
	stats.idle, _ = strconv.parse_u64_of_base(fields[3], 10)
	stats.iowait, _ = strconv.parse_u64_of_base(fields[4], 10)
	stats.irq, _ = strconv.parse_u64_of_base(fields[5], 10)
	stats.softirq, _ = strconv.parse_u64_of_base(fields[6], 10)
	stats.steal, _ = strconv.parse_u64_of_base(fields[7], 10)

	return stats, true
}

cpu_total :: proc(s: CPU_Stats) -> u64 {
	return s.user + s.nice + s.system + s.idle + s.iowait + s.irq + s.softirq + s.steal
}

// Parse /proc/meminfo
Mem_Info :: struct {
	total:     u64,
	free:      u64,
	available: u64,
	buffers:   u64,
	cached:    u64,
}

parse_meminfo :: proc() -> (Mem_Info, bool) {
	content, ok := read_proc_file("/proc/meminfo")
	if !ok {
		return {}, false
	}

	info: Mem_Info
	for line in strings.split_lines_iterator(&content) {
		if strings.has_prefix(line, "MemTotal:") {
			info.total = parse_meminfo_value(line)
		} else if strings.has_prefix(line, "MemFree:") {
			info.free = parse_meminfo_value(line)
		} else if strings.has_prefix(line, "MemAvailable:") {
			info.available = parse_meminfo_value(line)
		} else if strings.has_prefix(line, "Buffers:") {
			info.buffers = parse_meminfo_value(line)
		} else if strings.has_prefix(line, "Cached:") && !strings.has_prefix(line, "CachedSwap") {
			info.cached = parse_meminfo_value(line)
		}
	}
	return info, true
}

parse_meminfo_value :: proc(line: string) -> u64 {
	colon := strings.index_byte(line, ':')
	if colon < 0 {
		return 0
	}
	val_str := strings.trim_space(line[colon + 1:])
	val_str = strings.trim_right(val_str, " kB")
	val_str = strings.trim_space(val_str)
	v, _ := strconv.parse_u64_of_base(val_str, 10)
	return v
}

// Parse /proc/loadavg
parse_loadavg :: proc() -> (f64, f64, f64, bool) {
	content, ok := read_proc_file("/proc/loadavg")
	if !ok {
		return 0, 0, 0, false
	}

	fields := strings.split(strings.trim_space(content), " ", context.temp_allocator)
	if len(fields) < 3 {
		return 0, 0, 0, false
	}

	l1, _ := strconv.parse_f64(fields[0])
	l5, _ := strconv.parse_f64(fields[1])
	l15, _ := strconv.parse_f64(fields[2])
	return l1, l5, l15, true
}

// Format memory value according to current unit mode
format_mem :: proc(kb: u64, buf: []u8) -> string {
	switch mem_unit {
	case .KiB:
		return fmt.bprintf(buf, "%d KiB", kb)
	case .MiB:
		return fmt.bprintf(buf, "%.1f MiB", f64(kb) / 1024.0)
	case .GiB:
		return fmt.bprintf(buf, "%.2f GiB", f64(kb) / 1048576.0)
	case .Auto:
		if kb >= 1048576 {
			return fmt.bprintf(buf, "%.2f GiB", f64(kb) / 1048576.0)
		} else if kb >= 1024 {
			return fmt.bprintf(buf, "%.1f MiB", f64(kb) / 1024.0)
		} else {
			return fmt.bprintf(buf, "%d KiB", kb)
		}
	}
	return ""
}

// Parse /proc/<pid>/stat for process info
parse_proc_stat :: proc(pid: int) -> (Process_Info, bool) {
	path_buf: [64]u8
	path := fmt.bprintf(path_buf[:], "/proc/%d/stat", pid)
	content, ok := read_proc_file(path)
	if !ok {
		return {}, false
	}

	info: Process_Info
	info.pid = pid

	lparen := strings.index_byte(content, '(')
	rparen := strings.last_index_byte(content, ')')
	if lparen < 0 || rparen < 0 || rparen <= lparen {
		return {}, false
	}

	info.comm = content[lparen + 1:rparen]

	rest := content[rparen + 2:]
	fields := strings.split(rest, " ", context.temp_allocator)
	if len(fields) < 22 {
		return {}, false
	}

	if len(fields[0]) > 0 {
		info.state = fields[0][0]
	}

	info.utime, _ = strconv.parse_u64_of_base(fields[11], 10)
	info.stime, _ = strconv.parse_u64_of_base(fields[12], 10)
	info.num_threads, _ = strconv.parse_int(fields[17])

	rss, _ := strconv.parse_i64(fields[21])
	info.rss_pages = rss
	info.mem_kb = rss * 4

	return info, true
}

// Parse /proc/<pid>/cmdline
parse_cmdline :: proc(pid: int) -> string {
	path_buf: [64]u8
	path := fmt.bprintf(path_buf[:], "/proc/%d/cmdline", pid)
	content, ok := read_proc_file(path)
	if !ok || len(content) == 0 {
		return ""
	}

	result := strings.clone(content, context.temp_allocator)
	result_bytes := transmute([]u8)result
	for &b in result_bytes {
		if b == 0 {
			b = ' '
		}
	}
	return strings.trim_space(result)
}

// Check if a string is all digits (a PID directory)
is_pid_dir :: proc(name: string) -> (int, bool) {
	if len(name) == 0 {
		return 0, false
	}
	for c in name {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	pid, parse_ok := strconv.parse_int(name)
	return pid, parse_ok
}

// Scan all processes from /proc
scan_processes :: proc() -> [dynamic]Process_Info {
	processes: [dynamic]Process_Info
	processes.allocator = context.temp_allocator

	f, err := os.open("/proc")
	if err != nil {
		return processes
	}
	defer os.close(f)

	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		pid, is_pid := is_pid_dir(info.name)
		if !is_pid {
			continue
		}

		proc_info, ok := parse_proc_stat(pid)
		if !ok {
			continue
		}

		cmdline := parse_cmdline(pid)
		if len(cmdline) > 0 {
			proc_info.cmdline = cmdline
		} else {
			proc_info.cmdline = proc_info.comm
		}

		total_time := proc_info.utime + proc_info.stime
		if prev, has_prev := prev_proc_cpu[pid]; has_prev {
			prev_total := prev.utime + prev.stime
			delta_proc := total_time - prev_total
			if prev_total_cpu_time > 0 {
				proc_info.cpu_percent = f64(delta_proc) / f64(prev_total_cpu_time) * 100.0
			}
		}

		prev_proc_cpu[pid] = Prev_Proc_CPU{proc_info.utime, proc_info.stime}

		append(&processes, proc_info)
	}

	return processes
}

// Format CPU time (utime + stime in jiffies) as HH:MM:SS
format_cpu_time :: proc(utime, stime: u64, buf: []u8) -> string {
	total_seconds := (utime + stime) / 100
	hours := total_seconds / 3600
	mins := (total_seconds % 3600) / 60
	secs := total_seconds % 60
	return fmt.bprintf(buf, "%d:%02d:%02d", hours, mins, secs) // zero-padding is intentional here
}

// State character to readable string
state_str :: proc(state: u8) -> string {
	switch state {
	case 'R':
		return "running"
	case 'S':
		return "sleeping"
	case 'D':
		return "disk slp"
	case 'Z':
		return "zombie"
	case 'T':
		return "stopped"
	case 't':
		return "tracing"
	case 'X', 'x':
		return "dead"
	case 'K':
		return "wakekill"
	case 'W':
		return "waking"
	case 'P':
		return "parked"
	case 'I':
		return "idle"
	case:
		return "?"
	}
}

// Draw the display
draw_display :: proc(cpu: CPU_Stats, first_frame: bool) {
	get_terminal_size()

	buf_write("\x1b[2J\x1b[H")
	buf_write("\x1b[?25l")

	line_buf: [512]u8
	mem_buf1: [64]u8
	mem_buf2: [64]u8
	time_buf: [32]u8

	now := time.now()
	dt, _ := time.time_to_datetime(now)

	header_time := fmt.bprintf(time_buf[:], "%02d:%02d:%02d", dt.hour, dt.minute, dt.second)
	header_left := "cctop"
	pad := term_cols - len(header_left) - len(header_time)
	if pad < 1 {
		pad = 1
	}

	buf_write("\x1b[1;37;44m")
	buf_write(header_left)
	for _ in 0 ..< pad {
		buf_write(" ")
	}
	buf_write(header_time)
	buf_write("\x1b[0m\r\n")

	if !first_frame {
		d_user := cpu.user - prev_cpu.user + (cpu.nice - prev_cpu.nice)
		d_sys := cpu.system - prev_cpu.system + (cpu.irq - prev_cpu.irq) + (cpu.softirq - prev_cpu.softirq)
		d_idle := cpu.idle - prev_cpu.idle + (cpu.iowait - prev_cpu.iowait)
		d_steal := cpu.steal - prev_cpu.steal
		d_total := d_user + d_sys + d_idle + d_steal

		if d_total > 0 {
			user_pct := f64(d_user) / f64(d_total) * 100.0
			sys_pct := f64(d_sys) / f64(d_total) * 100.0
			idle_pct := f64(d_idle) / f64(d_total) * 100.0

			prev_total_cpu_time = d_total

			l1, l5, l15, _ := parse_loadavg()
			line := fmt.bprintf(
				line_buf[:],
				"Load Avg: %.2f, %.2f, %.2f   CPU: %.1f%% user, %.1f%% sys, %.1f%% idle",
				l1,
				l5,
				l15,
				user_pct,
				sys_pct,
				idle_pct,
			)
			buf_write(line)
		}
	} else {
		l1, l5, l15, _ := parse_loadavg()
		line := fmt.bprintf(line_buf[:], "Load Avg: %.2f, %.2f, %.2f   CPU: (calculating...)", l1, l5, l15)
		buf_write(line)
	}
	buf_write("\r\n")

	mem, mem_ok := parse_meminfo()
	if mem_ok {
		used := mem.total - mem.free - mem.buffers - mem.cached
		used_str := format_mem(used, mem_buf1[:])
		free_str := format_mem(mem.free + mem.buffers + mem.cached, mem_buf2[:])
		line := fmt.bprintf(
			line_buf[:],
			"PhysMem: %s used, %s free (of %s)",
			used_str,
			free_str,
			format_mem(mem.total, time_buf[:]),
		)
		buf_write(line)
	}
	buf_write("\r\n")

	unit_name: string
	switch mem_unit {
	case .KiB:
		unit_name = "KiB"
	case .MiB:
		unit_name = "MiB"
	case .GiB:
		unit_name = "GiB"
	case .Auto:
		unit_name = "auto"
	}
	indicator := fmt.bprintf(line_buf[:], "Memory units: %s (press 'e' to cycle)   Press 'q' to quit", unit_name)
	buf_write("\x1b[90m")
	buf_write(indicator)
	buf_write("\x1b[0m\r\n")

	buf_write("\r\n")

	hdr := fmt.bprintf(
		line_buf[:],
		"\x1b[7m% -7s % -20s % 6s % 10s % 4s % 10s % -10s\x1b[0m",
		"PID",
		"COMMAND",
		"%CPU",
		"TIME",
		"#TH",
		"MEM",
		"STATE",
	)
	buf_write(hdr)
	buf_write("\r\n")

	if !first_frame {
		processes := scan_processes()

		slice.sort_by(processes[:], proc(a, b: Process_Info) -> bool {
			return a.cpu_percent > b.cpu_percent
		})

		max_procs := term_rows - 7
		if max_procs < 1 {
			max_procs = 1
		}

		count := min(len(processes), max_procs)
		for i in 0 ..< count {
			p := processes[i]

			cmd_display := p.cmdline
			max_cmd_len := 20
			if len(cmd_display) > max_cmd_len {
				cmd_display = cmd_display[:max_cmd_len]
			}

			cpu_time := format_cpu_time(p.utime, p.stime, time_buf[:])
			mem_str := format_mem(u64(p.mem_kb), mem_buf1[:])

			line := fmt.bprintf(
				line_buf[:],
				"% -7d % -20s % 6.1f % 10s % 4d % 10s % -10s",
				p.pid,
				cmd_display,
				p.cpu_percent,
				cpu_time,
				p.num_threads,
				mem_str,
				state_str(p.state),
			)
			buf_write(line)
			buf_write("\r\n")
		}
	}

	buf_flush()
}

// Check for keypress (non-blocking)
check_input :: proc() -> (u8, bool) {
	pfds := [1]linux.Poll_Fd {
		{
			fd     = linux.STDIN_FILENO,
			events = {.IN},
		},
	}
	n, _ := linux.poll(pfds[:], 0)
	if n > 0 && .IN in pfds[0].revents {
		buf: [1]u8
		bytes_read, _ := linux.read(linux.STDIN_FILENO, buf[:])
		if bytes_read > 0 {
			return buf[0], true
		}
	}
	return 0, false
}

main :: proc() {
	enter_raw_mode()
	defer restore_terminal()

	output_buf = make([dynamic]u8, 0, 8192)
	defer delete(output_buf)

	prev_proc_cpu = make(map[int]Prev_Proc_CPU)
	defer delete(prev_proc_cpu)

	cpu, cpu_ok := parse_cpu_stats()
	if !cpu_ok {
		restore_terminal()
		fmt.eprintln("Error: Cannot read /proc/stat")
		return
	}
	prev_cpu = cpu

	draw_display(cpu, true)

	for {
		for _ in 0 ..< 20 {
			time.sleep(50 * time.Millisecond)

			key, has_key := check_input()
			if has_key {
				switch key {
				case 'q', 'Q':
					return
				case 'e', 'E':
					switch mem_unit {
					case .KiB:
						mem_unit = .MiB
					case .MiB:
						mem_unit = .GiB
					case .GiB:
						mem_unit = .Auto
					case .Auto:
						mem_unit = .KiB
					}
				}
			}
		}

		free_all(context.temp_allocator)

		cpu, cpu_ok = parse_cpu_stats()
		if !cpu_ok {
			continue
		}

		draw_display(cpu, false)
		prev_cpu = cpu
	}
}
