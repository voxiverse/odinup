package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

// Windows-only pieces (the _windows file suffix keeps them out of other builds).

// ---------------------------------------------------------------------------
// Exe shims
// ---------------------------------------------------------------------------
//
// bin\odin.exe, bin\ols.exe, ... are copies of odinup.exe; a <name>.shim file
// beside each holds the real binary's path on its first line, then optional
// KEY=VALUE environment overrides for it. Real executables, unlike .bat
// shims, keep working when a batch file calls them without `call` (a .bat
// calling a .bat never returns), from PowerShell, and for editors that spawn
// ols over stdio.

SHIM_EXT :: ".shim"

// run_as_shim runs the target when this exe was launched under another name
// than odinup, returning its exit code. is_shim = false means we are odinup.
run_as_shim :: proc() -> (code: int, is_shim: bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return
	stem := filepath.stem(self)
	if strings.equal_fold(stem, "odinup") do return

	shim_file := pjoin({filepath.dir(self), strings.concatenate({stem, SHIM_EXT})})
	data, rerr := os.read_entire_file_from_path(shim_file, context.temp_allocator)
	if rerr != nil {
		log_err(fmt.tprintf("%s is an odinup shim but %s is missing — run `odinup install`", self, shim_file))
		return 1, true
	}
	lines := strings.split_lines(strings.trim_space(string(data)))
	target := strings.trim_space(lines[0])
	env: []string // nil: inherit ours
	if len(lines) > 1 {
		base, _ := os.environ(context.temp_allocator)
		env = merge_env(base, lines[1:])
	}

	// The child shares our console and gets Ctrl+C itself; the shim just
	// waits for it so the exit code comes through. (A handler, not
	// SetConsoleCtrlHandler(nil, TRUE): that flag would be inherited.)
	win.SetConsoleCtrlHandler(ignore_ctrl, true)
	// Std handles must be inheritable for the child to use them (ols speaks
	// LSP over stdin/stdout).
	for which in ([]win.DWORD{win.STD_INPUT_HANDLE, win.STD_OUTPUT_HANDLE, win.STD_ERROR_HANDLE}) {
		if h := win.GetStdHandle(which); h != nil && h != win.INVALID_HANDLE_VALUE {
			win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT)
		}
	}

	cmd := make([dynamic]string)
	append(&cmd, target)
	append(&cmd, ..os.args[1:])
	status := run_status(os.Process_Desc{command = cmd[:], env = env})
	return status < 0 ? 1 : status, true
}

ignore_ctrl :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	return true
}

install_exe_shim :: proc(name, target: string) -> bool {
	bd := bin_dir()
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		log_err(fmt.tprintf("cannot locate odinup.exe to create the %s shim: %v", name, err))
		return false
	}
	exe := pjoin({bd, exe_name(name)})
	if !same_contents(self, exe) {
		if cerr := os.copy_file(exe, self); cerr != nil {
			// Usually in use (an editor running ols). The old copy still works:
			// it reads the .shim written below on every launch.
			log_warn(fmt.tprintf("could not refresh %s (%v) — close programs using it and re-run", exe, cerr))
		}
	}
	os.remove(pjoin({bd, strings.concatenate({name, ".bat"})})) // .bat shim from older odinup

	// Odin finds a portable MSVC only through its environment variables.
	lines := make([dynamic]string)
	append(&lines, target)
	if name == "odin" do append(&lines, ..msvc_env())
	return write_file_atomic(pjoin({bd, strings.concatenate({name, SHIM_EXT})}), strings.join(lines[:], "\r\n"))
}

same_contents :: proc(a, b: string) -> bool {
	da, ea := os.read_entire_file_from_path(a, context.temp_allocator)
	db, eb := os.read_entire_file_from_path(b, context.temp_allocator)
	return ea == nil && eb == nil && string(da) == string(db)
}

// ---------------------------------------------------------------------------
// MSVC + cmd.exe
// ---------------------------------------------------------------------------

// Portable MSVC (install.ps1 downloads it when there's no Visual Studio):
// ~\.odinup\msvc, with env.txt holding the variables Odin locates it by and
// setup.bat setting up cl/link like vcvars64.bat. ODINUP_MSVC=vs ignores it.
msvc_dir :: proc() -> string { return pjoin({root_dir(), "msvc"}) }

msvc_env :: proc() -> []string {
	if mode, _ := os.lookup_env("ODINUP_MSVC", context.temp_allocator); mode == "vs" do return nil
	data, err := os.read_entire_file_from_path(pjoin({msvc_dir(), "env.txt"}), context.temp_allocator)
	if err != nil do return nil
	out := make([dynamic]string)
	for line in strings.split_lines(string(data)) {
		if l := strings.trim_space(line); strings.index_byte(l, '=') > 0 do append(&out, l)
	}
	return out[:]
}

// find_vcvars64 returns the script that puts cl/link on PATH: portable MSVC's
// setup.bat when installed, else vcvars64.bat of a Visual Studio found via
// vswhere (shipped with every VS install, any edition or year) or well-known paths.
find_vcvars64 :: proc() -> string {
	VCVARS :: "VC\\Auxiliary\\Build\\vcvars64.bat"
	if setup := pjoin({msvc_dir(), "setup.bat"}); len(msvc_env()) > 0 && os.exists(setup) do return setup

	pf86, _ := os.lookup_env("ProgramFiles(x86)", context.temp_allocator)
	pf, _ := os.lookup_env("ProgramFiles", context.temp_allocator)

	vswhere := pjoin({pf86, "Microsoft Visual Studio", "Installer", "vswhere.exe"})
	if os.exists(vswhere) {
		out, ok := capture({vswhere, "-latest", "-products", "*", "-requires",
			"Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"})
		if ok {
			for line in strings.split_lines(out) {
				install := strings.trim_space(line)
				if len(install) == 0 do continue
				if p := pjoin({install, VCVARS}); os.exists(p) do return p
			}
		}
	}
	for year in ([]string{"18", "2022"}) {
		for edition in ([]string{"BuildTools", "Community", "Professional", "Enterprise"}) {
			if p := pjoin({pf, "Microsoft Visual Studio", year, edition, VCVARS}); os.exists(p) do return p
		}
	}
	return ""
}

// run_cmd_script runs cmd.exe script lines via a temporary .bat. Passing them
// with `cmd /c "..."` doesn't work: process_start escapes embedded quotes as
// \" (the CRT convention), which cmd.exe doesn't understand.
run_cmd_script :: proc(script, cwd: string, env: []string = nil) -> bool {
	os.make_directory_all(state_dir())
	bat := pjoin({state_dir(), "run.bat"})
	if !write_file_atomic(bat, fmt.tprintf("@echo off\r\n%s\r\nexit /b %%ERRORLEVEL%%\r\n", script)) {
		return false
	}
	defer os.remove(bat)
	return run({"cmd.exe", "/d", "/c", bat}, cwd, env)
}

// ---------------------------------------------------------------------------
// Console QuickEdit
// ---------------------------------------------------------------------------
//
// With QuickEdit on (the default), clicking in a console window starts a
// selection that freezes the program's output until a key is pressed; during
// a long build that looks exactly like a hang. Builds turn it off and put the
// console back as it was afterwards.

ENABLE_EXTENDED_FLAGS :: 0x0080

Quick_Edit_Restore :: struct {
	mode:  win.DWORD,
	valid: bool,
}

quick_edit_off :: proc() -> (r: Quick_Edit_Restore) {
	h := win.GetStdHandle(win.STD_INPUT_HANDLE)
	if !win.GetConsoleMode(h, &r.mode) do return // not a console (redirected, CI)
	r.valid = bool(win.SetConsoleMode(h, (r.mode & ~win.DWORD(win.ENABLE_QUICK_EDIT_MODE)) | ENABLE_EXTENDED_FLAGS))
	return
}

quick_edit_restore :: proc(r: Quick_Edit_Restore) {
	if r.valid do win.SetConsoleMode(win.GetStdHandle(win.STD_INPUT_HANDLE), r.mode)
}
