package main

import "core:strings"
import "core:testing"

// Pure-logic tests: `odin test src`. Nothing here touches git, the network or ~/.odinup.

@(test)
test_is_dev_tag :: proc(t: ^testing.T) {
	testing.expect(t, is_dev_tag("dev-2026-07"))
	testing.expect(t, is_dev_tag("dev-2026-07a"))
	testing.expect(t, !is_dev_tag("dev-2026-7"))
	testing.expect(t, !is_dev_tag("dev-2026-07A"))
	testing.expect(t, !is_dev_tag("dev-2026-07ab"))
	testing.expect(t, !is_dev_tag("dev-2026_07"))
	testing.expect(t, !is_dev_tag("nightly"))
	testing.expect(t, !is_dev_tag(""))
}

@(test)
test_latest_dev_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// The letter release must beat its base month (the old key ignored it).
	testing.expect_value(t, latest_dev_tag("dev-2026-06\ndev-2026-07\ndev-2026-07a\n"), "dev-2026-07a")
	testing.expect_value(t, latest_dev_tag("dev-2026-07a\ndev-2026-08\n"), "dev-2026-08")
	testing.expect_value(t, latest_dev_tag("dev-2025-12\ndev-2026-01\n"), "dev-2026-01")
	testing.expect_value(t, latest_dev_tag("nightly\ndev-2026-99-rc\ndev-2026-02\n"), "dev-2026-02")
	testing.expect_value(t, latest_dev_tag(""), "")
}

@(test)
test_parse_odin_version :: proc(t: ^testing.T) {
	v, c := parse_odin_version("/home/x/.odinup/odin/odin version dev-2026-10:84bc3fc21\n")
	testing.expect_value(t, v, "dev-2026-10")
	testing.expect_value(t, c, "84bc3fc21")

	v, c = parse_odin_version("odin.exe version dev-2026-07:abcdef012\r\n")
	testing.expect_value(t, v, "dev-2026-07")
	testing.expect_value(t, c, "abcdef012")

	// Built without git: no commit, so callers must treat it as unknown.
	v, c = parse_odin_version("odin version dev-2026-07\n")
	testing.expect_value(t, v, "dev-2026-07")
	testing.expect_value(t, c, "")
}

@(test)
test_same_commit :: proc(t: ^testing.T) {
	full := "84bc3fc21aa0e0b6e3f7f8c9d0e1f2a3b4c5d6e7"
	testing.expect(t, same_commit(full, "84bc3fc21"))
	testing.expect(t, same_commit("84BC3FC21", full))
	testing.expect(t, !same_commit(full, "84bc3fc22"))
	testing.expect(t, !same_commit(full, ""))
	testing.expect(t, !same_commit(full, "84bc3")) // too short to trust
}

@(test)
test_valid_tool_name :: proc(t: ^testing.T) {
	testing.expect(t, valid_tool_name("ols"))
	testing.expect(t, valid_tool_name("my-tool_2"))
	for bad in ([]string{"", "bin", "odin", "state", "src", "..", "a/b", "Ols", "x y"}) {
		testing.expectf(t, !valid_tool_name(bad), "%q should be rejected", bad)
	}
}

@(test)
test_parse_kv :: proc(t: ^testing.T) {
	k, v, ok := parse_kv(`rev = "abc" # pinned`)
	testing.expect(t, ok && k == "rev" && v == "abc")

	k, v, ok = parse_kv(`git = "https://host/x#frag"`)
	testing.expect(t, ok && v == "https://host/x#frag")

	k, v, ok = parse_kv(`rev = ''`)
	testing.expect(t, ok && v == "")

	k, v, ok = parse_kv(`odin = dev-2026-07 # bare`)
	testing.expect(t, ok && v == "dev-2026-07")

	_, _, ok = parse_kv(`rev = "unterminated`)
	testing.expect(t, !ok)
	_, _, ok = parse_kv(`rev = "a" trailing`)
	testing.expect(t, !ok)
	_, _, ok = parse_kv(`= "x"`)
	testing.expect(t, !ok)
}

@(test)
test_parse_config :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "# c\r\n[toolchain]\r\nodin = \"dev-2026-07a\"\r\n\r\n[tools.ols]\r\ngit = \"https://github.com/DanielGavin/ols\"\r\nrev = \"\"\r\nbuild = \"make\"\r\n"
	cfg, errs := parse_config(text)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, cfg.odin_version, "dev-2026-07a")
	testing.expect_value(t, len(cfg.tools), 1)
	testing.expect_value(t, cfg.tools[0].name, "ols")
	testing.expect_value(t, cfg.tools[0].rev, "")
	testing.expect_value(t, cfg.tools[0].build, "make")
	testing.expect(t, !cfg.tools[0].dev)

	dev, dev_errs := parse_config("[toolchain]\nodin = \"dev-2026-10\"\n[tools.ols]\ndev = true\n")
	testing.expect_value(t, len(dev_errs), 0)
	testing.expect(t, len(dev.tools) == 1 && dev.tools[0].dev)
}

@(test)
test_parse_config_rejects_mistakes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cases := []string{
		"[tools.ols]\nref = \"abc\"\n",       // typo'd key
		"[toolchain]\nodin_version = \"x\"\n", // wrong key
		"[tools.bin]\ngit = \"x\"\n",          // would clobber ~/.odinup/bin
		"[tools.../x]\ngit = \"x\"\n",         // path escape
		"[odin]\nversion = \"x\"\n",           // unknown section
		"odin = \"x\"\n",                      // outside a section
		"[toolchain]\nodin \"x\"\n",           // not key = value
		"[tools.ols]\ndev = yes\n",              // dev is true or false
	}
	for text in cases {
		_, errs := parse_config(text)
		testing.expectf(t, len(errs) > 0, "expected an error for %q", text)
	}
}

@(test)
test_rewrite_toml_preserves_crlf_and_comments :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "# header\r\n[toolchain]\r\n# keep me\r\nodin = \"dev-2026-08\"\r\n\r\n[tools.ols]\r\ngit = \"g\"\r\nrev = \"old\" # c\r\n"
	got := rewrite_toml(text, "dev-2026-10", "", "")
	got = rewrite_toml(got, "", "ols", "new")
	want := "# header\r\n[toolchain]\r\n# keep me\r\nodin = \"dev-2026-10\"\r\n\r\n[tools.ols]\r\ngit = \"g\"\r\nrev = \"new\"\r\n"
	testing.expect_value(t, got, want)
}

@(test)
test_rewrite_toml_is_idempotent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	text := "[toolchain]\nodin = \"dev-2026-10\"\n\n[tools.ols]\nrev = \"abc\"\n"
	once := rewrite_toml(text, "dev-2026-10", "ols", "abc")
	twice := rewrite_toml(once, "dev-2026-10", "ols", "abc")
	testing.expect_value(t, once, text)
	testing.expect_value(t, twice, text)
}

@(test)
test_rewrite_toml_inserts_missing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// [tools.ols] exists without rev, and sits before [toolchain] which lacks odin.
	text := "[tools.ols]\ngit = \"g\"\n\n[toolchain]\n"
	got := rewrite_toml(text, "dev-2026-10", "ols", "abc")
	testing.expect_value(t, got, "[tools.ols]\nrev = \"abc\"\ngit = \"g\"\n\n[toolchain]\nodin = \"dev-2026-10\"\n")

	// Empty file: both sections created; result parses back cleanly.
	got = rewrite_toml("", "dev-2026-10", "ols", "abc")
	cfg, errs := parse_config(got)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, cfg.odin_version, "dev-2026-10")
	testing.expect(t, len(cfg.tools) == 1 && cfg.tools[0].rev == "abc" && cfg.tools[0].git == OLS_REPO)
	testing.expect(t, !strings.contains(got, "\r"))
}

@(test)
test_parse_args :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a, ok := parse_args({"--latest", "--file", "x.toml"}, true)
	testing.expect(t, ok && a.latest && a.file == "x.toml")

	a, ok = parse_args({"--file=y.toml", "ols", "abc"}, false)
	testing.expect(t, ok && a.file == "y.toml" && len(a.positional) == 2)

	_, ok = parse_args({"--lastest"}, true)
	testing.expect(t, !ok)
	_, ok = parse_args({"--latest"}, false) // only install takes it
	testing.expect(t, !ok)
	_, ok = parse_args({"--file"}, false)
	testing.expect(t, !ok)
}

@(test)
test_merge_env :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	got := merge_env({"Path=C:\\x", "A=1", "=C:=C:\\"}, {"PATH=C:\\y", "B=2", "bad", "=x"})
	testing.expect_value(t, len(got), 4)
	testing.expect_value(t, got[0], "PATH=C:\\y") // replaced, case-insensitively
	testing.expect_value(t, got[1], "A=1")
	testing.expect_value(t, got[2], "=C:=C:\\")  // Windows drive entries pass through
	testing.expect_value(t, got[3], "B=2")
}
