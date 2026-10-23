# odinup

Install the [Odin programming language](https://odin-lang.org/) from source on a fresh machine with one command, and pin the exact compiler (plus tools like [ols](https://github.com/DanielGavin/ols)) per project so everyone builds with the same commits.

**Linux · macOS · WSL**

```sh
curl -sSfL https://raw.githubusercontent.com/voxiverse/odinup/main/install.sh | sh
```

**Windows** (PowerShell, or `cmd` / Run dialog)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/voxiverse/odinup/main/install.ps1 | iex"
```

That's it. When it finishes, `odin` and `odinup` are on your PATH:

```sh
odin version
odin run my_project
```

## What the installer does

It starts from a bare machine, installs only what's missing, and is safe to re-run (finished steps are skipped).

| | Linux / macOS | Windows |
|---|---|---|
| Prerequisites | git, make, clang via your package manager (apt, dnf, pacman, zypper, apk, Homebrew/Xcode CLT) — asks for `sudo` only if something is missing | git: uses yours, else portable [MinGit](https://github.com/git-for-windows/git/releases) (no admin) |
| C/C++ toolchain | an LLVM version the Odin release supports (read from Odin's own `build_odin.sh`); falls back to versioned packages or [apt.llvm.org](https://apt.llvm.org) when the distro default is too old or too new | uses an installed Visual Studio with the C++ tools; otherwise downloads **just the MSVC compiler and Windows SDK** from Microsoft into `.odinup\msvc` — no Visual Studio installer, no admin, no UAC prompt (asks you to accept Microsoft's license first) |
| Odin | clones to `~/.odinup/odin`, builds the latest `dev-YYYY-MM` release | same, `%USERPROFILE%\.odinup\odin` |
| PATH | adds `~/.odinup/bin` to `.bashrc` / `.profile` / `.zshrc` (those that exist) | adds `%USERPROFILE%\.odinup\bin` to your user PATH |

Expect a few minutes for the Odin build itself, plus the MSVC download on a Windows machine without Visual Studio.

Environment variables for the installers:

| Variable | Effect |
|---|---|
| `ODINUP_ODIN_VERSION=dev-2026-07` | build this Odin release instead of the latest |
| `ODINUP_MSVC=portable` / `vs` | Windows: force portable MSVC / an installed Visual Studio |
| `ODINUP_ACCEPT_MSVC_LICENSE=1` | Windows: accept the MSVC license without the y/n prompt (CI, scripted setups) |
| `ODINUP_REPO`, `ODINUP_REF` | where to fetch odinup's own source (default: this repo, `main`) |

On Windows set them with `$env:NAME = "value"` before running the one-liner.

### Portable MSVC (Windows)

Odin needs Microsoft's linker, C runtime and Windows SDK libraries to link programs on Windows. Without Visual Studio, the installer fetches only those packages from the same Microsoft feed the Visual Studio installer uses (the approach of [mmozeiko's portable-msvc](https://gist.github.com/mmozeiko/7f3162ec2988e81e56d5c4e22cde9977)) and verifies their checksums. They're covered by the Visual Studio Build Tools license, which the installer shows and asks you to accept.

`odin` finds this toolchain by itself (the `odin.exe` launcher sets the variables it looks for). To compile C code with `cl`/`link` yourself, run `call %USERPROFILE%\.odinup\msvc\setup.bat` first — the portable equivalent of `vcvars64.bat`.

## Pinning a toolchain per project

Commit an `odinup.toml` at your project root:

```toml
[toolchain]
odin = "dev-2026-10"          # Odin tag, branch or commit

[tools.ols]
git = "https://github.com/DanielGavin/ols"
rev = ""                       # tag, branch or sha; empty = ols's tag matching the Odin release
```

Then anyone on the project runs:

```sh
odinup install      # build exactly what the toml pins (no-op if already built)
odinup check        # exit 1 if anything doesn't match; read-only, works offline
```

A project build script can make this automatic:

```sh
odinup check >/dev/null 2>&1 || odinup install
odin build src -out:my_game
```

### Commands

```
odinup install [--latest | --odin <tag>] [--file odinup.toml]
odinup check   [--file odinup.toml]
odinup pin <odin|tool> <value> [--file odinup.toml]
odinup update  [--file odinup.toml]     # bump to the newest Odin release + matching tools
odinup version
```

`odinup` finds the config by walking up from the current directory (`odinup.toml`, `.odinup.toml` or `toolchain.toml`).

### `odinup.toml` reference

| Key | Meaning |
|---|---|
| `[toolchain] odin` | Odin tag (`dev-2026-10`, `dev-2026-07a`), branch or commit |
| `[toolchain] git` | Odin repository (default `https://github.com/odin-lang/Odin`) |
| `[tools.<name>] git` | Tool repository (default for `ols`: DanielGavin/ols) |
| `[tools.<name>] rev` | Tag, branch or sha. Empty: the tool's tag equal to the Odin tag if it has one (ols tags in lockstep with Odin; its default branch tracks unreleased Odin and often won't build against a release), else its default branch |
| `[tools.<name>] build` | Build command, run in the tool's checkout with `~/.odinup/bin` on PATH. Default: `build.sh` / `build.bat`, else `odin build .`. Must produce `./<name>` |

The parser is strict on purpose: an unknown key (`ref =` instead of `rev =`) is an error rather than silently building the wrong thing.

## How it decides what's installed

Everything is compared by **commit**, never by version string (`odin version` reports the month, `dev-2026-07`, not the tag `dev-2026-07a`).

- **Odin:** the pin must match the commit compiled into the `odin` binary *and* the checked-out source tree (Odin reads its core library from there at compile time).
- **Tools:** `~/.odinup/state/<name>.stamp` records the commit built and the Odin that built it, written only after a successful build. A tool built with a different Odin counts as stale.

`install` only touches the network when a pin isn't available locally (or follows a branch), so an installed toolchain keeps working offline.

On Windows, `odin.exe` / `ols.exe` in `~\.odinup\bin` are small launchers (copies of `odinup.exe`) that run the real binaries. They're real executables rather than `.bat` files, so they work from batch scripts without `call`, from PowerShell, and for editors that start ols over stdio.

## Uninstall

Linux / macOS: `rm -rf ~/.odinup` and delete the `# Added by odinup` lines from your shell rc files.

Windows: delete `%USERPROFILE%\.odinup` (this includes portable MSVC) and remove its `bin` (and `git\cmd`, if present) entries from your user PATH (*Edit environment variables for your account*).

## Troubleshooting

- **`odin` not found right after installing (Windows):** terminals opened before the install keep the old PATH. Open a new one — for Windows Terminal, close all of its windows first.
- **LLVM errors on Linux:** set `LLVM_CONFIG=/path/to/llvm-config` (a supported version, with development headers) and re-run the installer.
- **Portable MSVC download failed or was interrupted:** re-run — finished downloads are reused and verified. If it reports a broken install, delete `%USERPROFILE%\.odinup\msvc` and re-run.
- Anything else: re-run the installer (it resumes), and [open an issue](https://github.com/voxiverse/odinup/issues) with its output.

## Development

```
install.sh / install.ps1    bootstrap: prerequisites -> build Odin -> build odinup -> `odinup install --odin <tag>`
src/main.odin               the manager (pure Odin, no dependencies)
src/main_windows.odin       Windows-only: exe shims, MSVC discovery (installed or portable)
src/main_test.odin          unit tests: odin test src
```

CI bootstraps from scratch on Ubuntu, macOS and Windows (with portable MSVC and with Visual Studio) the way users do, then compiles a program, installs ols from a project `odinup.toml`, and talks LSP to it through the shim.

## License

MIT — see [LICENSE](LICENSE).
