package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// odinup — Odin-native toolchain manager (no Python anywhere).
//
//   odinup                     install pinned toolchain (or latest)
//   odinup install [--latest | --odin <tag>] [--file odinup.toml]
//   odinup check   [--file odinup.toml]
//   odinup pin <odin|tool> <value> [--file odinup.toml]
//   odinup update  [--file odinup.toml]
//
// Bootstrap path: install.sh / install.ps1 build Odin from source, then compile
// this file into ~/.odinup/bin/odinup with that fresh compiler.
//
// Everything is compared by commit, never by version string: `odin version`
// reports the commit month ("dev-2026-07"), not the tag ("dev-2026-07a").
// Pins resolve to commits in the local clones; the odin binary carries its own
// commit, tools get a stamp in ~/.odinup/state written after a successful build.

VERSION :: "1.0.0"

ODIN_REPO :: "https://github.com/odin-lang/Odin"
OLS_REPO  :: "https://github.com/DanielGavin/ols"

TOML_NAMES :: [3]string{"odinup.toml", ".odinup.toml", "toolchain.toml"}

// Directory names under ~/.odinup that a tool may not claim.
RESERVED_NAMES :: [4]string{"odin", "bin", "state", "src"}

Config :: struct {
	odin_version: string, // tag ("dev-2026-07", "dev-2026-07a"), branch or sha
	odin_git:     string, // optional override of ODIN_REPO
	tools:        [dynamic]Tool_Pin,
}

Tool_Pin :: struct {
	name:  string,
	git:   string,
	rev:   string, // tag, branch or sha; empty = tag matching the Odin pin, else default branch
	build: string, // optional shell command; empty = build.sh/build.bat, else `odin build .`
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

home_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		if v, ok := os.lookup_env("USERPROFILE", context.temp_allocator); ok do return v
	} else {
		if v, ok := os.lookup_env("HOME", context.temp_allocator); ok do return v
	}
	return "."
}

// pjoin joins path elements, discarding the allocator error (CLI tool: fatal on OOM anyway).
pjoin :: proc(args: []string) -> string {
	p, _ := filepath.join(args)
	return p
}

exe_name :: proc(name: string) -> string {
	when ODIN_OS == .Windows do return strings.concatenate({name, ".exe"})
	return name
}

root_dir  :: proc() -> string { return pjoin({home_dir(), ".odinup"}) }
odin_dir  :: proc() -> string { return pjoin({root_dir(), "odin"}) }
bin_dir   :: proc() -> string { return pjoin({root_dir(), "bin"}) }
state_dir :: proc() -> string { return pjoin({root_dir(), "state"}) }

tool_dir :: proc(name: string) -> string { return pjoin({root_dir(), name}) }

odin_exe_path :: proc() -> string { return pjoin({odin_dir(), exe_name("odin")}) }

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

// run executes a command inheriting our stdio (visible progress, prompts work),
// waits for completion and reports success by exit code. env = nil inherits ours.
run :: proc(cmd: []string, cwd := "", env: []string = nil) -> bool {
	desc := os.Process_Desc{command = cmd, env = env}
	if len(cwd) > 0 do desc.working_dir = cwd
	return run_status(desc) == 0
}

// run_status runs desc with our stdin/stdout/stderr and returns its exit code
// (-1 if it couldn't start or didn't exit normally).
run_status :: proc(desc: os.Process_Desc) -> int {
	desc := desc
	desc.stdin = os.stdin
	desc.stdout = os.stdout
	desc.stderr = os.stderr

	child, err := os.process_start(desc)
	if err != nil {
		fmt.eprintf("error: could not start '%s': %v\n", desc.command[0], err)
		return -1
	}
	state, werr := os.process_wait(child)
	if werr != nil || !state.exited {
		fmt.eprintf("error: '%s' did not exit cleanly\n", desc.command[0])
		return -1
	}
	return state.exit_code
}

// capture executes a command and returns its stdout as a string.
capture :: proc(cmd: []string, cwd := "") -> (output: string, ok: bool) {
	desc := os.Process_Desc{command = cmd}
	if len(cwd) > 0 do desc.working_dir = cwd

	state, stdout_data, _, err := os.process_exec(desc, context.temp_allocator)
	if err != nil {
		fmt.eprintf("error: could not start '%s': %v\n", cmd[0], err)
		return "", false
	}
	output = string(stdout_data)
	ok = state.exit_code == 0
	return
}

// tool_env is our environment with ~/.odinup/bin first on PATH: tool build
// scripts expect `odin` on PATH, and it may not be there yet on first install.
tool_env :: proc() -> []string {
	env, err := os.environ(context.temp_allocator)
	if err != nil do return nil
	sep := ":"
	when ODIN_OS == .Windows do sep = ";"

	out := make([dynamic]string)
	found := false
	for kv in env {
		eq := strings.index_byte(kv, '=')
		if eq > 0 && strings.equal_fold(kv[:eq], "PATH") {
			append(&out, strings.concatenate({kv[:eq+1], bin_dir(), sep, kv[eq+1:]}))
			found = true
		} else {
			append(&out, kv)
		}
	}
	if !found do append(&out, strings.concatenate({"PATH=", bin_dir()}))
	when ODIN_OS == .Windows {
		return merge_env(out[:], msvc_env())
	}
	return out[:]
}

// merge_env returns base (KEY=VALUE entries) with overrides applied: a key
// already present (case-insensitively, as on Windows) is replaced, others appended.
merge_env :: proc(base, overrides: []string) -> []string {
	out := make([dynamic]string)
	append(&out, ..base)
	for o in overrides {
		eq := strings.index_byte(o, '=')
		if eq <= 0 do continue
		replaced := false
		for &kv in out {
			if e := strings.index_byte(kv, '='); e == eq && strings.equal_fold(kv[:e], o[:eq]) {
				kv = o
				replaced = true
				break
			}
		}
		if !replaced do append(&out, o)
	}
	return out[:]
}

// write_file_atomic writes via a temp file + rename so an interrupted write
// never leaves a truncated odinup.toml or stamp behind.
write_file_atomic :: proc(path, content: string) -> bool {
	tmp := strings.concatenate({path, ".odinup-tmp"})
	if werr := os.write_entire_file_from_string(tmp, content); werr != nil {
		log_err(fmt.tprintf("could not write %s: %v", tmp, werr))
		return false
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		log_err(fmt.tprintf("could not replace %s: %v", path, rerr))
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Git helpers
// ---------------------------------------------------------------------------

git_out :: proc(repo: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string)
	append(&cmd, "git")
	append(&cmd, ..args)
	out, ok = capture(cmd[:], repo)
	return strings.trim_space(out), ok
}

// ensure_clone clones git_url into dest unless it is already a checkout.
// Fetching is separate so already-present pinned commits need no network.
ensure_clone :: proc(git_url, dest: string) -> bool {
	if os.exists(pjoin({dest, ".git"})) do return true
	if os.exists(dest) do os.remove_all(dest)
	os.make_directory_all(filepath.dir(dest))
	log_info(fmt.tprintf("Cloning %s ...", git_url))
	return run({"git", "clone", git_url, dest})
}

fetch :: proc(dest: string) -> bool {
	log_info(fmt.tprintf("Fetching updates for %s", filepath.base(dest)))
	return run({"git", "fetch", "--tags", "--force", "--prune", "origin"}, dest)
}

// rev_commit resolves a tag, branch or sha to a full commit sha using local refs
// only. Remote-tracking branches win so a stale local branch never does; an empty
// rev means the remote's default branch.
rev_commit :: proc(dest, rev: string) -> (sha: string, ok: bool) {
	cands := make([dynamic]string)
	if len(rev) == 0 {
		append(&cands, "origin/HEAD", "origin/main", "origin/master")
	} else {
		append(&cands, strings.concatenate({"origin/", rev}), rev)
	}
	for c in cands {
		// Not fmt: it reads `{` as a format directive.
		if sha, ok = git_out(dest, "rev-parse", "--verify", "--quiet", strings.concatenate({c, "^{commit}"})); ok {
			return
		}
	}
	return "", false
}

has_tag :: proc(dest, tag: string) -> bool {
	_, ok := git_out(dest, "rev-parse", "--verify", "--quiet", strings.concatenate({"refs/tags/", tag}))
	return ok
}

is_remote_branch :: proc(dest, rev: string) -> bool {
	_, ok := git_out(dest, "rev-parse", "--verify", "--quiet", strings.concatenate({"refs/remotes/origin/", rev}))
	return ok
}

// resolve_pin maps a pin to a commit, fetching only when needed: always for
// moving refs (branches, default branch), otherwise only when the pin is not
// present locally, so an installed pinned toolchain works offline.
resolve_pin :: proc(dest, rev: string) -> (sha: string, ok: bool) {
	moving := len(rev) == 0 || is_remote_branch(dest, rev)
	if !moving {
		if sha, ok = rev_commit(dest, rev); ok do return
	}
	if !fetch(dest) {
		log_warn("Fetch failed — falling back to local refs")
	}
	return rev_commit(dest, rev)
}

checkout_commit :: proc(dest, sha: string) -> bool {
	if head, ok := git_out(dest, "rev-parse", "HEAD"); ok && head == sha {
		return true
	}
	log_info(fmt.tprintf("Checking out %s in %s", sha[:12], filepath.base(dest)))
	return run({"git", "checkout", "--quiet", "--force", "--detach", sha}, dest)
}

// same_commit compares a full sha against a possibly abbreviated one.
same_commit :: proc(a, b: string) -> bool {
	if len(a) < 7 || len(b) < 7 do return false
	n := min(len(a), len(b))
	return strings.equal_fold(a[:n], b[:n])
}

is_dev_tag :: proc(s: string) -> bool {
	// ^dev-\d{4}-\d{2}[a-z]?$
	if !strings.has_prefix(s, "dev-") do return false
	rest := s[4:]
	if len(rest) != 7 && len(rest) != 8 do return false
	for i in 0..<7 {
		c := rest[i]
		if i == 4 {
			if c != '-' do return false
		} else if c < '0' || c > '9' {
			return false
		}
	}
	return len(rest) == 7 || ('a' <= rest[7] && rest[7] <= 'z')
}

// latest_dev_tag picks the newest dev tag from `git tag` output. Valid tags are
// fixed-width, so byte order is release order ("dev-2026-07" < "dev-2026-07a").
latest_dev_tag :: proc(tag_list: string) -> string {
	best := ""
	for line in strings.split_lines(tag_list) {
		t := strings.trim_space(line)
		if is_dev_tag(t) && t > best do best = t
	}
	return best
}

// ---------------------------------------------------------------------------
// Install state
// ---------------------------------------------------------------------------

// parse_odin_version splits `odin version` output
// ("/path/odin version dev-2026-10:84bc3fc21") into version and commit.
parse_odin_version :: proc(output: string) -> (version, commit: string) {
	line := strings.trim_space(output)
	if nl := strings.index_byte(line, '\n'); nl >= 0 do line = strings.trim_space(line[:nl])
	if i := strings.index(line, "version "); i >= 0 do line = line[i+len("version "):]
	if c := strings.index_byte(line, ':'); c >= 0 {
		return line[:c], strings.trim_space(line[c+1:])
	}
	return line, ""
}

// installed_odin reads the version and commit baked into ~/.odinup/odin's binary.
installed_odin :: proc() -> (version, commit: string, ok: bool) {
	exe := odin_exe_path()
	if !os.exists(exe) do return
	out, cok := capture({exe, "version"})
	if !cok do return
	version, commit = parse_odin_version(out)
	return version, commit, len(commit) > 0
}

// Stamp records what a tool was last built from, written only on success.
Stamp :: struct {
	commit: string,
	odin:   string, // commit of the compiler that built it
}

stamp_path :: proc(name: string) -> string {
	return pjoin({state_dir(), strings.concatenate({name, ".stamp"})})
}

read_stamp :: proc(name: string) -> (s: Stamp, ok: bool) {
	data, err := os.read_entire_file_from_path(stamp_path(name), context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data)) {
		if v, found := cut_prefix(line, "commit="); found do s.commit = strings.trim_space(v)
		if v, found := cut_prefix(line, "odin="); found do s.odin = strings.trim_space(v)
	}
	return s, len(s.commit) > 0
}

write_stamp :: proc(name: string, s: Stamp) -> bool {
	os.make_directory_all(state_dir())
	return write_file_atomic(stamp_path(name), fmt.tprintf("commit=%s\nodin=%s\n", s.commit, s.odin))
}

// ---------------------------------------------------------------------------
// Builds
// ---------------------------------------------------------------------------

build_odin :: proc(repo_dir: string) -> bool {
	log_info("Building Odin from source (takes a few minutes)...")
	when ODIN_OS == .Windows {
		vcvars := find_vcvars64()
		if len(vcvars) == 0 {
			log_err("MSVC not found — install Visual Studio Build Tools with the C++ workload (install.ps1 does this)")
			return false
		}
		return run_cmd_script(fmt.tprintf("call \"%s\" || exit /b 1\r\ncall build.bat release", vcvars), repo_dir)
	} else {
		return run({"make", "release-native"}, repo_dir)
	}
}

// build_tool builds with, in order: the toml `build` command, the repo's
// build.sh/build.bat, or `odin build .`. The result must be <repo>/<name>.
build_tool :: proc(tool: Tool_Pin, repo_dir: string) -> bool {
	env := tool_env()
	ok := false
	when ODIN_OS == .Windows {
		if len(tool.build) > 0 {
			ok = run_cmd_script(tool.build, repo_dir, env)
		} else if os.exists(pjoin({repo_dir, "build.bat"})) {
			ok = run_cmd_script("call build.bat", repo_dir, env)
		} else {
			ok = run({odin_exe_path(), "build", ".", "-o:speed", fmt.tprintf("-out:%s", exe_name(tool.name))}, repo_dir, env)
		}
	} else {
		script := pjoin({repo_dir, "build.sh"})
		if len(tool.build) > 0 {
			ok = run({"sh", "-c", tool.build}, repo_dir, env)
		} else if os.exists(script) {
			// Honour the shebang: ols's build.sh is bash, and sh is dash on Debian.
			shell := "sh"
			if data, err := os.read_entire_file_from_path(script, context.temp_allocator); err == nil {
				first := string(data)
				if nl := strings.index_byte(first, '\n'); nl >= 0 do first = first[:nl]
				if strings.has_prefix(first, "#!") && strings.contains(first, "bash") do shell = "bash"
			}
			ok = run({shell, "build.sh"}, repo_dir, env)
		} else {
			ok = run({odin_exe_path(), "build", ".", "-o:speed", fmt.tprintf("-out:%s", tool.name)}, repo_dir, env)
		}
	}
	if !ok do return false

	// ols's build script doesn't produce odinfmt; build it so both get shimmed.
	odinfmt_src := pjoin({repo_dir, "tools", "odinfmt", "main.odin"})
	if tool.name == "ols" && os.exists(odinfmt_src) {
		out := fmt.tprintf("-out:%s", pjoin({repo_dir, exe_name("odinfmt")}))
		if !run({odin_exe_path(), "build", odinfmt_src, "-file", "-collection:src=src", "-o:speed", out}, repo_dir, env) {
			log_warn("odinfmt build failed — ols itself is fine")
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// odinup.toml
// ---------------------------------------------------------------------------

find_odinup_toml :: proc(start: string) -> (path: string, ok: bool) {
	cur, cerr := filepath.abs(start)
	if cerr != nil do cur = start
	for _ in 0..<12 {
		for name in TOML_NAMES {
			p := pjoin({cur, name})
			if os.exists(p) do return p, true
		}
		parent := filepath.dir(cur)
		if parent == cur do break
		cur = parent
	}
	return "", false
}

valid_tool_name :: proc(name: string) -> bool {
	if len(name) == 0 do return false
	for r in RESERVED_NAMES {
		if name == r do return false
	}
	for c in transmute([]u8)name {
		if !(('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// parse_kv splits `key = value  # comment`, unquoting "..." / '...' values.
// A '#' inside quotes is part of the value.
parse_kv :: proc(line: string) -> (key, value: string, ok: bool) {
	eq := strings.index_byte(line, '=')
	if eq <= 0 do return
	key = strings.trim_space(line[:eq])
	rest := strings.trim_space(line[eq+1:])
	if len(rest) > 0 && (rest[0] == '"' || rest[0] == '\'') {
		close := strings.index_byte(rest[1:], rest[0])
		if close < 0 do return
		value = rest[1:1+close]
		after := strings.trim_space(rest[2+close:])
		return key, value, len(after) == 0 || after[0] == '#'
	}
	if ci := strings.index_byte(rest, '#'); ci >= 0 do rest = strings.trim_space(rest[:ci])
	return key, rest, len(key) > 0
}

cut_prefix :: proc(s, prefix: string) -> (rest: string, ok: bool) {
	if !strings.has_prefix(s, prefix) do return s, false
	return s[len(prefix):], true
}

is_section_header :: proc(line: string) -> (name: string, ok: bool) {
	if !strings.has_prefix(line, "[") || !strings.has_suffix(line, "]") do return
	return strings.trim_space(line[1:len(line)-1]), true
}

find_or_add_tool :: proc(cfg: ^Config, name: string) -> ^Tool_Pin {
	for &t in cfg.tools {
		if t.name == name do return &t
	}
	append(&cfg.tools, Tool_Pin{name = name})
	return &cfg.tools[len(cfg.tools)-1]
}

// parse_config is strict on purpose: an unknown key is almost always a typo
// (`ref =` for `rev =`), and silently ignoring it would build the wrong thing.
parse_config :: proc(text: string) -> (cfg: Config, errs: [dynamic]string) {
	section := ""
	for raw, i in strings.split_lines(text) {
		line := strings.trim_space(raw)
		if len(line) == 0 || line[0] == '#' do continue
		n := i + 1

		if name, is_header := is_section_header(line); is_header {
			section = name
			if name == "toolchain" do continue
			if tool, is_tool := cut_prefix(name, "tools."); is_tool {
				if valid_tool_name(tool) {
					find_or_add_tool(&cfg, tool)
				} else {
					append(&errs, fmt.tprintf("line %d: invalid tool name '%s' (use a-z 0-9 - _; not odin/bin/state/src)", n, tool))
					section = ""
				}
				continue
			}
			append(&errs, fmt.tprintf("line %d: unknown section [%s]", n, name))
			section = ""
			continue
		}

		key, value, ok := parse_kv(line)
		if !ok {
			append(&errs, fmt.tprintf("line %d: expected `key = \"value\"`", n))
			continue
		}
		if section == "toolchain" {
			switch key {
			case "odin": cfg.odin_version = value
			case "git":  cfg.odin_git = value
			case: append(&errs, fmt.tprintf("line %d: unknown key '%s' in [toolchain] (expected odin, git)", n, key))
			}
		} else if tool, is_tool := cut_prefix(section, "tools."); is_tool {
			t := find_or_add_tool(&cfg, tool)
			switch key {
			case "git":   t.git = value
			case "rev":   t.rev = value
			case "build": t.build = value
			case: append(&errs, fmt.tprintf("line %d: unknown key '%s' in [tools.%s] (expected git, rev, build)", n, key, tool))
			}
		} else if len(section) == 0 && len(errs) == 0 {
			append(&errs, fmt.tprintf("line %d: '%s' is outside any section", n, key))
		}
	}
	return
}

// rewrite_toml sets `odin = ...` under [toolchain] and/or `rev = ...` under
// [tools.<name>], preserving every other line, comment and the file's line
// ending. Missing keys are inserted under their header; missing sections are
// created. Pass "" to leave odin_version / tool_name untouched.
rewrite_toml :: proc(text, odin_version, tool_name, rev: string) -> string {
	eol := strings.contains(text, "\r\n") ? "\r\n" : "\n"
	tool_section := strings.concatenate({"tools.", tool_name})
	odin_line := fmt.tprintf("odin = \"%s\"", odin_version)
	rev_line := fmt.tprintf("rev = \"%s\"", rev)

	out := make([dynamic]string)
	section := ""
	toolchain_hdr, tool_hdr := -1, -1
	odin_done := len(odin_version) == 0
	rev_done := len(tool_name) == 0

	for line in strings.split_lines(text) {
		s := strings.trim_space(line)
		if name, ok := is_section_header(s); ok {
			section = name
			append(&out, line)
			if name == "toolchain" && toolchain_hdr < 0 do toolchain_hdr = len(out) - 1
			if name == tool_section && tool_hdr < 0 do tool_hdr = len(out) - 1
			continue
		}
		if key, _, ok := parse_kv(s); ok {
			if !odin_done && section == "toolchain" && key == "odin" {
				append(&out, odin_line)
				odin_done = true
				continue
			}
			if !rev_done && section == tool_section && key == "rev" {
				append(&out, rev_line)
				rev_done = true
				continue
			}
		}
		append(&out, line)
	}
	// split_lines yields a trailing "" for the final newline; drop blank tails
	// so repeated rewrites don't grow the file.
	for len(out) > 0 && len(strings.trim_space(out[len(out)-1])) == 0 do pop(&out)

	// Insert under existing headers, higher index first so the other stays valid.
	if !rev_done && tool_hdr >= 0 && tool_hdr > toolchain_hdr {
		inject_at(&out, tool_hdr + 1, rev_line)
		rev_done = true
	}
	if !odin_done && toolchain_hdr >= 0 {
		inject_at(&out, toolchain_hdr + 1, odin_line)
		odin_done = true
		if tool_hdr > toolchain_hdr do tool_hdr += 1
	}
	if !rev_done && tool_hdr >= 0 {
		inject_at(&out, tool_hdr + 1, rev_line)
		rev_done = true
	}
	if !odin_done {
		inject_at(&out, 0, "[toolchain]", odin_line, "")
	}
	if !rev_done {
		if len(out) > 0 do append(&out, "")
		append(&out, fmt.tprintf("[%s]", tool_section))
		if tool_name == "ols" do append(&out, fmt.tprintf("git = \"%s\"", OLS_REPO))
		append(&out, rev_line)
	}
	return strings.concatenate({strings.join(out[:], eol), eol})
}

Config_Status :: enum { Missing, Loaded, Invalid }

// open_config loads --file, or the nearest odinup.toml walking up from cwd.
open_config :: proc(file_arg: string) -> (cfg: Config, path: string, status: Config_Status) {
	path = file_arg
	if len(path) == 0 {
		found: bool
		if path, found = find_odinup_toml("."); !found do return cfg, "", .Missing
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		log_err(fmt.tprintf("cannot read %s: %v", path, err))
		return cfg, path, .Invalid
	}
	errs: [dynamic]string
	cfg, errs = parse_config(string(data))
	for e in errs do log_err(fmt.tprintf("%s: %s", path, e))
	return cfg, path, len(errs) == 0 ? .Loaded : .Invalid
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

// odin_override (--odin) replaces the config's Odin pin; the bootstrap scripts
// use it to hand over the tag they just built.
do_install :: proc(latest: bool, file_arg: string, odin_override := "") -> int {
	cfg, path, status := open_config(file_arg)
	switch status {
	case .Invalid: return 1
	case .Loaded:  log_info(fmt.tprintf("Using config: %s", path))
	case .Missing: if len(odin_override) == 0 && !latest do log_info("No odinup.toml found — using latest Odin")
	}

	// ---- Odin
	dir := odin_dir()
	odin_git := len(cfg.odin_git) > 0 ? cfg.odin_git : ODIN_REPO
	if !ensure_clone(odin_git, dir) do return 1

	target := latest ? "" : cfg.odin_version
	if len(odin_override) > 0 do target = odin_override
	if len(target) == 0 {
		if !fetch(dir) do log_warn("Fetch failed — latest tag may be stale")
		out, _ := git_out(dir, "tag", "-l", "dev-*")
		if target = latest_dev_tag(out); len(target) == 0 {
			log_err("could not resolve latest dev-* tag")
			return 1
		}
		log_info(fmt.tprintf("Using latest Odin tag: %s", target))
	}
	sha, ok := resolve_pin(dir, target)
	if !ok {
		log_err(fmt.tprintf("Odin pin '%s' not found in %s", target, odin_git))
		return 1
	}
	// The core library is read from this tree, so it must match the binary
	// even when no rebuild is needed.
	if !checkout_commit(dir, sha) do return 1
	if _, built, found := installed_odin(); found && same_commit(sha, built) {
		log_ok(fmt.tprintf("Odin %s already built (%s)", target, built))
	} else {
		if !build_odin(dir) {
			log_err("building Odin failed")
			return 1
		}
		_, built, found = installed_odin()
		if !found || !same_commit(sha, built) {
			log_err(fmt.tprintf("built odin reports commit '%s', expected %s", built, sha[:12]))
			return 1
		}
		log_ok(fmt.tprintf("Odin %s built (%s)", target, built))
	}
	install_shim("odin", odin_exe_path())

	// ---- Tools: keep going past a failure, but fail the command.
	result := 0
	for tool in cfg.tools {
		if !install_tool(tool, target, sha, latest) do result = 1
	}

	ensure_path()
	return result
}

// tool_rev picks what to build: the pin, else a tag matching the Odin tag (ols
// tags in lockstep with Odin; its default branch tracks unreleased Odin and may
// not build with a release), else the default branch.
tool_rev :: proc(dest, pinned, odin_tag: string) -> string {
	if len(pinned) > 0 do return pinned
	if is_dev_tag(odin_tag) && has_tag(dest, odin_tag) do return odin_tag
	return ""
}

install_tool :: proc(tool: Tool_Pin, odin_tag, odin_sha: string, latest: bool) -> bool {
	git_url := tool.git
	if len(git_url) == 0 && tool.name == "ols" do git_url = OLS_REPO
	if len(git_url) == 0 {
		log_err(fmt.tprintf("tool '%s' has no git URL", tool.name))
		return false
	}
	dest := tool_dir(tool.name)
	if !ensure_clone(git_url, dest) do return false

	pinned := latest ? "" : tool.rev
	if len(pinned) == 0 && is_dev_tag(odin_tag) && !has_tag(dest, odin_tag) {
		fetch(dest) // the matching tag may just not be fetched yet
	}
	rev := tool_rev(dest, pinned, odin_tag)
	sha, ok := resolve_pin(dest, rev)
	if !ok {
		log_err(fmt.tprintf("tool '%s': pin '%s' not found in %s", tool.name, rev, git_url))
		return false
	}

	bin := pjoin({dest, exe_name(tool.name)})
	if st, sok := read_stamp(tool.name); sok && st.commit == sha && same_commit(odin_sha, st.odin) && os.exists(bin) {
		log_ok(fmt.tprintf("Tool '%s' already built (%s)", tool.name, sha[:12]))
	} else {
		if !checkout_commit(dest, sha) do return false
		log_info(fmt.tprintf("Building %s ...", tool.name))
		if !build_tool(tool, dest) || !os.exists(bin) {
			log_err(fmt.tprintf("building tool '%s' failed (expected %s)", tool.name, bin))
			return false
		}
		if !write_stamp(tool.name, Stamp{commit = sha, odin = odin_sha}) do return false
		log_ok(fmt.tprintf("Tool '%s' built (%s)", tool.name, sha[:12]))
	}

	install_shim(tool.name, bin)
	if extra := pjoin({dest, exe_name("odinfmt")}); tool.name == "ols" && os.exists(extra) {
		install_shim("odinfmt", extra)
	}
	return true
}

install_shim :: proc(name, target: string) -> bool {
	bd := bin_dir()
	os.make_directory_all(bd)
	when ODIN_OS == .Windows {
		return install_exe_shim(name, target)
	} else {
		shim := pjoin({bd, name})
		if !write_file_atomic(shim, fmt.tprintf("#!/bin/sh\nexec \"%s\" \"$@\"\n", target)) {
			return false
		}
		return run({"chmod", "755", shim})
	}
}

// ensure_path adds the bin dir to existing shell rc files (Unix only; the
// Windows bootstrap sets the User PATH in the registry).
ensure_path :: proc() {
	when ODIN_OS != .Windows {
		bd := bin_dir()
		rcs := [3]string{".bashrc", ".profile", ".zshrc"}
		for name in rcs {
			rc := pjoin({home_dir(), name})
			data, err := os.read_entire_file_from_path(rc, context.temp_allocator)
			if err != nil do continue // rc file doesn't exist
			existing := string(data)
			if strings.contains(existing, bd) do continue
			content := fmt.tprintf("%s\n# Added by odinup\nexport PATH=\"%s:$PATH\"\n", strings.trim_right(existing, "\n"), bd)
			if write_file_atomic(rc, content) {
				log_ok(fmt.tprintf("Added %s to PATH in %s", bd, rc))
			}
		}
	}
}

// do_check is read-only and offline: it resolves pins against local clones and
// compares commits. Exit 1 means `odinup install` would change something.
do_check :: proc(file_arg: string) -> int {
	cfg, path, status := open_config(file_arg)
	switch status {
	case .Invalid: return 1
	case .Missing:
		log_warn("No odinup.toml found — nothing to check")
		return 0
	case .Loaded:
	}

	result := 0
	fail :: proc(result: ^int, msg: string) {
		log_err(msg)
		result^ = 1
	}

	version, built, odin_ok := installed_odin()
	if len(cfg.odin_version) == 0 {
		log_warn("No Odin pin in toml")
	} else if !odin_ok {
		fail(&result, "Odin not installed — run `odinup install`")
	} else if want, ok := rev_commit(odin_dir(), cfg.odin_version); !ok {
		fail(&result, fmt.tprintf("Odin pin '%s' not fetched yet — run `odinup install`", cfg.odin_version))
	} else if !same_commit(want, built) {
		fail(&result, fmt.tprintf("Odin mismatch: pinned %s (%s), installed %s:%s — run `odinup install`", cfg.odin_version, want[:12], version, built))
	} else if head, _ := git_out(odin_dir(), "rev-parse", "HEAD"); !same_commit(head, built) {
		fail(&result, fmt.tprintf("Odin core library tree is at %s but the binary is %s — run `odinup install`", head[:min(12, len(head))], built))
	} else {
		log_ok(fmt.tprintf("Odin matches pin %s (%s:%s)", cfg.odin_version, version, built))
	}

	for tool in cfg.tools {
		dest := tool_dir(tool.name)
		st, has_stamp := read_stamp(tool.name)
		if !has_stamp || !os.exists(pjoin({dest, exe_name(tool.name)})) {
			fail(&result, fmt.tprintf("Tool '%s' not installed — run `odinup install`", tool.name))
			continue
		}
		rev := tool_rev(dest, tool.rev, cfg.odin_version)
		if len(rev) > 0 {
			want, ok := rev_commit(dest, rev)
			if !ok {
				fail(&result, fmt.tprintf("Tool '%s' pin '%s' not fetched yet — run `odinup install`", tool.name, rev))
				continue
			}
			if want != st.commit {
				fail(&result, fmt.tprintf("Tool '%s' mismatch: pinned %s (%s), built %s — run `odinup install`", tool.name, rev, want[:12], st.commit[:12]))
				continue
			}
		}
		if odin_ok && !same_commit(built, st.odin) {
			fail(&result, fmt.tprintf("Tool '%s' was built with a different Odin — run `odinup install`", tool.name))
			continue
		}
		log_ok(fmt.tprintf("Tool '%s' matches pin %s (%s)", tool.name, len(rev) > 0 ? rev : "<default branch>", st.commit[:12]))
	}
	log_info(fmt.tprintf("Checked against %s", path))
	return result
}

do_pin :: proc(target, value, file_arg: string) -> int {
	cfg, path, status := open_config(file_arg)
	switch status {
	case .Invalid: return 1
	case .Missing:
		path = len(file_arg) > 0 ? file_arg : "odinup.toml"
		log_info(fmt.tprintf("Creating %s", path))
	case .Loaded:
	}

	text := ""
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
		text = string(data)
	}
	if target == "odin" {
		if !is_dev_tag(value) {
			log_warn(fmt.tprintf("'%s' is not an Odin dev tag (dev-YYYY-MM[a]); treating it as a branch or sha", value))
		}
		if !write_file_atomic(path, rewrite_toml(text, value, "", "")) do return 1
		log_ok(fmt.tprintf("Pinned odin %s in %s", value, path))
		return 0
	}

	known := target == "ols"
	for t in cfg.tools do known ||= t.name == target
	if !known || !valid_tool_name(target) {
		log_err(fmt.tprintf("unknown tool '%s' — add a [tools.%s] section with `git = \"...\"` first", target, target))
		return 1
	}
	if !write_file_atomic(path, rewrite_toml(text, "", target, value)) do return 1
	log_ok(fmt.tprintf("Pinned %s rev %s in %s", target, value, path))
	return 0
}

// do_update bumps Odin to the newest dev tag and each tool to the tag matching
// it (else its default branch), pinning tools by sha so a moved tag can't
// change what gets built. It only edits the toml; `install` builds.
do_update :: proc(file_arg: string) -> int {
	cfg, path, status := open_config(file_arg)
	switch status {
	case .Invalid: return 1
	case .Missing:
		path = len(file_arg) > 0 ? file_arg : "odinup.toml"
		log_info(fmt.tprintf("Creating %s", path))
	case .Loaded:
	}

	dir := odin_dir()
	if !ensure_clone(len(cfg.odin_git) > 0 ? cfg.odin_git : ODIN_REPO, dir) do return 1
	if !fetch(dir) {
		log_err("could not fetch Odin — update needs network access")
		return 1
	}
	out, _ := git_out(dir, "tag", "-l", "dev-*")
	tag := latest_dev_tag(out)
	if len(tag) == 0 {
		log_err("could not resolve latest dev-* tag")
		return 1
	}

	text := ""
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
		text = string(data)
	}
	text = rewrite_toml(text, tag, "", "")
	log_ok(fmt.tprintf("odin -> %s", tag))

	result := 0
	for tool in cfg.tools {
		git_url := tool.git
		if len(git_url) == 0 && tool.name == "ols" do git_url = OLS_REPO
		dest := tool_dir(tool.name)
		if len(git_url) == 0 || !ensure_clone(git_url, dest) || !fetch(dest) {
			log_err(fmt.tprintf("could not fetch tool '%s' — pin left unchanged", tool.name))
			result = 1
			continue
		}
		rev := tool_rev(dest, "", tag)
		sha, ok := rev_commit(dest, rev)
		if !ok {
			log_err(fmt.tprintf("could not resolve '%s' for tool '%s'", rev, tool.name))
			result = 1
			continue
		}
		text = rewrite_toml(text, "", tool.name, sha[:12])
		log_ok(fmt.tprintf("%s -> %s (%s)", tool.name, sha[:12], len(rev) > 0 ? rev : "default branch"))
	}

	if !write_file_atomic(path, text) do return 1
	log_info(fmt.tprintf("Updated %s — run `odinup install` to build", path))
	return result
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

log_info :: proc(m: string) { fmt.printfln("==> %s", m) }
log_ok :: proc(m: string)   { fmt.printfln("  [OK] %s", m) }
log_warn :: proc(m: string) { fmt.printfln("  [WARN] %s", m) }
log_err :: proc(m: string)  { fmt.eprintfln("error: %s", m) }

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

print_usage :: proc() {
	fmt.printfln("odinup %s — Odin toolchain manager", VERSION)
	fmt.println("Usage:")
	fmt.println("  odinup install [--latest | --odin <tag>] [--file odinup.toml]")
	fmt.println("  odinup check   [--file odinup.toml]")
	fmt.println("  odinup pin <odin|tool> <value> [--file odinup.toml]")
	fmt.println("  odinup update  [--file odinup.toml]")
	fmt.println("  odinup version")
	fmt.println("")
	fmt.println("Config discovery walks up from cwd looking for:")
	fmt.println("  odinup.toml | .odinup.toml | toolchain.toml")
}

main :: proc() {
	// odinup is a short-lived CLI: allocate everything from the temp arena and
	// release it once at exit. os.exit bypasses defers, hence the wrapper.
	context.allocator = context.temp_allocator
	when ODIN_OS == .Windows {
		// Copies of this exe serve as the odin.exe / ols.exe shims.
		if code, is_shim := run_as_shim(); is_shim do os.exit(code)
	}
	code := real_main()
	free_all(context.temp_allocator)
	os.exit(code)
}

Args :: struct {
	latest:     bool,
	file:       string,
	odin:       string,
	positional: [dynamic]string,
}

// parse_args rejects unknown flags so a typo (`--lastest`) fails loudly
// instead of silently doing the default thing.
parse_args :: proc(args: []string, is_install: bool) -> (a: Args, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case arg == "--latest" && is_install:
			a.latest = true
		case arg == "--file" || arg == "-f" || (arg == "--odin" && is_install):
			if i + 1 >= len(args) {
				log_err(fmt.tprintf("%s needs a value", arg))
				return a, false
			}
			i += 1
			if arg == "--odin" do a.odin = args[i]
			else do a.file = args[i]
		case strings.has_prefix(arg, "--file="):
			a.file = arg[len("--file="):]
		case strings.has_prefix(arg, "--odin=") && is_install:
			a.odin = arg[len("--odin="):]
		case strings.has_prefix(arg, "-"):
			log_err(fmt.tprintf("unknown option '%s'", arg))
			return a, false
		case:
			append(&a.positional, arg)
		}
	}
	return a, true
}

real_main :: proc() -> int {
	args := os.args
	if len(args) < 2 {
		return do_install(false, "")
	}

	cmd := args[1]
	switch cmd {
	case "install", "check", "pin", "update":
	case "version", "--version", "-V":
		fmt.printfln("odinup %s", VERSION)
		return 0
	case "help", "--help", "-h":
		print_usage()
		return 0
	case:
		log_err(fmt.tprintf("unknown command '%s'", cmd))
		print_usage()
		return 1
	}

	a, ok := parse_args(args[2:], cmd == "install")
	if !ok do return 1
	if a.latest && len(a.odin) > 0 {
		log_err("--latest and --odin are mutually exclusive")
		return 1
	}
	want_positional := cmd == "pin" ? 2 : 0
	if len(a.positional) != want_positional {
		if cmd == "pin" {
			log_err("usage: odinup pin <odin|tool-name> <value>")
		} else {
			log_err(fmt.tprintf("unexpected argument '%s'", a.positional[0]))
		}
		return 1
	}

	switch cmd {
	case "install": return do_install(a.latest, a.file, a.odin)
	case "check":   return do_check(a.file)
	case "pin":     return do_pin(a.positional[0], a.positional[1], a.file)
	case "update":  return do_update(a.file)
	}
	return 1
}
