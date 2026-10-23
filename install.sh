#!/bin/sh
# odinup bootstrap - Odin from source on a fresh Linux/macOS/WSL machine.
#
#   curl -sSfL https://raw.githubusercontent.com/voxiverse/odinup/main/install.sh | sh
#
# What it does:
#   1. Installs git, git-lfs, make and clang if missing (asks for sudo only then).
#   2. Clones Odin into ~/.odinup/odin and builds the pinned or latest dev-* tag,
#      first installing an LLVM version that tag supports if there isn't one.
#   3. Builds the odinup manager with that compiler, then hands over to
#      `odinup install`, which writes the shims in ~/.odinup/bin and adds that
#      directory to PATH in your shell rc files.
#
# Environment:
#   ODINUP_ODIN_VERSION=dev-2026-07   build this Odin tag instead of the latest
#   ODINUP_REPO / ODINUP_REF          where to get odinup's source (default: GitHub, main)
#
# Safe to re-run: finished steps are skipped.

set -eu

DEST_DIR="${HOME}/.odinup"
ODIN_DIR="$DEST_DIR/odin"
BIN_DIR="$DEST_DIR/bin"
ODIN_REPO="https://github.com/odin-lang/Odin"
ODINUP_REPO="${ODINUP_REPO:-https://github.com/voxiverse/odinup}"
ODINUP_REF="${ODINUP_REF:-main}"

# LLVM majors Odin builds against, newest first. Replaced by the
# SUPPORTED_LLVM_VERSIONS of the Odin version being built once it's cloned.
LLVM_VERSIONS="22 21 20 19 18 17"

if [ -t 1 ]; then
    log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
    ok()   { printf "\033[1;32m  [OK]\033[0m %s\n" "$*"; }
    warn() { printf "\033[1;33m  [WARN]\033[0m %s\n" "$*"; }
    die()  { printf "\033[1;31merror:\033[0m %s\n" "$*" >&2; exit 1; }
else
    log()  { printf "==> %s\n" "$*"; }
    ok()   { printf "  [OK] %s\n" "$*"; }
    warn() { printf "  [WARN] %s\n" "$*"; }
    die()  { printf "error: %s\n" "$*" >&2; exit 1; }
fi

have() { command -v "$1" >/dev/null 2>&1; }

OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Linux|Darwin) ;;
    *) die "Unsupported OS '$OS_NAME' - on Windows use install.ps1 (or this script inside WSL)." ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if have sudo; then SUDO="sudo"
    elif have doas; then SUDO="doas"
    fi
fi

as_root() {
    if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
        die "Need root to install packages, but neither sudo nor doas is available. Install manually: $*"
    fi
    $SUDO "$@"
}

# ------------------------------------------------------------- prerequisites

# POSIX sh has no local variables: helpers below use _-prefixed names so they
# don't clobber their callers' loop variables.

# llvm_usable succeeds if $1 is an llvm-config for a supported LLVM whose
# development headers are installed (distros often split them off: having
# llvm-config-18 doesn't mean llvm-18-dev is there).
llvm_usable() {
    have "$1" || return 1
    _major="$("$1" --version 2>/dev/null | cut -d. -f1)"
    case " $LLVM_VERSIONS " in *" $_major "*) ;; *) return 1 ;; esac
    [ -f "$("$1" --includedir 2>/dev/null)/llvm-c/Core.h" ]
}

# find_llvm_config prints a usable llvm-config, newest LLVM first, searching
# where distros put versioned installs and Homebrew its kegs.
find_llvm_config() {
    for _v in $LLVM_VERSIONS; do
        for _c in "llvm-config-$_v" "llvm-config$_v" "/usr/lib/llvm-$_v/bin/llvm-config" "/usr/lib/llvm$_v/bin/llvm-config"; do
            if llvm_usable "$_c"; then echo "$_c"; return 0; fi
        done
        if have brew; then
            _c="$(brew --prefix "llvm@$_v" 2>/dev/null)/bin/llvm-config"
            if llvm_usable "$_c"; then echo "$_c"; return 0; fi
        fi
    done
    for _c in llvm-config "$( (have brew && brew --prefix llvm) 2>/dev/null)/bin/llvm-config"; do
        if llvm_usable "$_c"; then echo "$_c"; return 0; fi
    done
    return 1
}

# pkg_install installs packages with the system package manager.
pkg_install() {
    if have apt-get; then as_root apt-get install -y "$@"
    elif have dnf; then as_root dnf install -y "$@"
    elif have yum; then as_root yum install -y "$@"
    elif have pacman; then as_root pacman -S --needed --noconfirm "$@"
    elif have zypper; then as_root zypper --non-interactive install "$@"
    elif have apk; then as_root apk add --no-progress "$@"
    elif have brew; then brew install "$@"
    else return 1
    fi
}

# Odin's compiler is built with clang++ and Odin links programs with clang,
# so clang is required (g++ is not enough).
ensure_base_tools() {
    if have git && have make && have clang && have clang++; then
        ok "git, make, clang present"
        return
    fi
    log "Installing git, make and clang..."
    case "$OS_NAME" in
        Darwin)
            if ! xcode-select -p >/dev/null 2>&1; then
                xcode-select --install || true
                die "Finish the Xcode Command Line Tools install (a dialog opened), then re-run this installer."
            fi ;;
        *)
            if have apt-get; then
                as_root apt-get update -y
                pkg_install ca-certificates git make clang build-essential
            elif have pacman; then
                as_root pacman -Sy --noconfirm
                pkg_install git make clang base-devel
            elif have apk; then
                pkg_install git make clang build-base
            elif have dnf || have yum || have zypper; then
                pkg_install git make clang gcc-c++
            else
                die "No supported package manager found. Install git, make and clang, then re-run."
            fi ;;
    esac
    for T in git make clang clang++; do
        have "$T" || die "$T is still missing after installing prerequisites."
    done
    ok "git, make, clang installed"
}

# ensure_git_lfs installs Git LFS if missing: Odin keeps some vendor
# libraries (Box2D's, Box3D's) in LFS. Best effort: without it only those
# packages are missing, so odinup warns and carries on.
ensure_git_lfs() {
    if git lfs version >/dev/null 2>&1; then
        ok "git-lfs present"
        return
    fi
    log "Installing git-lfs (Odin keeps some vendor libraries in Git LFS)..."
    if [ "$OS_NAME" = Darwin ] && ! have brew; then
        warn "git-lfs is missing and Homebrew is not installed: vendor:box2d/box3d will lack their libraries (install git-lfs and re-run)"
        return
    fi
    if pkg_install git-lfs && git lfs version >/dev/null 2>&1; then
        ok "git-lfs installed"
    else
        warn "could not install git-lfs: vendor:box2d/box3d will lack their libraries (install git-lfs and re-run)"
    fi
}

# NO_LFS: clone and check out LFS files as pointers whether or not git-lfs is
# installed; `odinup install` then fetches the real files (git lfs pull).
NO_LFS="-c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false"

# ensure_llvm installs an LLVM in Odin's supported range: the distro's default
# when it fits, else a versioned package (rolling distros can be ahead of
# Odin, older LTS releases behind), else apt.llvm.org on Debian/Ubuntu.
ensure_llvm() {
    if C="$(find_llvm_config)"; then
        ok "LLVM: $C ($("$C" --version))"
        return
    fi
    log "Installing LLVM (Odin $ODIN_TAG supports: $LLVM_VERSIONS)..."
    if have apt-get; then
        pkg_install llvm-dev || true
        for V in $LLVM_VERSIONS; do
            find_llvm_config >/dev/null && break
            pkg_install "llvm-$V-dev" 2>/dev/null || true
        done
        if ! find_llvm_config >/dev/null; then
            log "No suitable LLVM in the distro repositories - using apt.llvm.org"
            pkg_install curl lsb-release wget software-properties-common gnupg
            curl -sSfL https://apt.llvm.org/llvm.sh -o /tmp/odinup-llvm.sh
            for V in $LLVM_VERSIONS; do
                if as_root bash /tmp/odinup-llvm.sh "$V" && pkg_install "llvm-$V-dev"; then break; fi
            done
            rm -f /tmp/odinup-llvm.sh
        fi
    else
        if have dnf || have yum || have zypper; then DEFAULT=llvm-devel; FMT="llvm%s-devel"
        elif have pacman; then DEFAULT=llvm; FMT="llvm%s"
        elif have apk; then DEFAULT=llvm-dev; FMT="llvm%s-dev"
        elif have brew; then DEFAULT=llvm; FMT="llvm@%s"
        else die "Install LLVM (one of: $LLVM_VERSIONS) with llvm-config, then re-run."
        fi
        pkg_install "$DEFAULT" || true
        for V in $LLVM_VERSIONS; do
            find_llvm_config >/dev/null && break
            # shellcheck disable=SC2059 # FMT is a package-name pattern
            pkg_install "$(printf "$FMT" "$V")" 2>/dev/null || true
        done
    fi
    C="$(find_llvm_config)" || die "Could not install LLVM $LLVM_VERSIONS. Install one (with llvm-config) and re-run, or set LLVM_CONFIG."
    ok "LLVM: $C ($("$C" --version))"
}

# -------------------------------------------------------------------- Odin

latest_odin_tag() {
    git -C "$ODIN_DIR" tag -l 'dev-*' | grep -E '^dev-[0-9]{4}-[0-9]{2}[a-z]?$' | LC_ALL=C sort | tail -n 1
}

build_odin() {
    if [ -d "$ODIN_DIR/.git" ]; then
        log "Fetching Odin updates"
        git -C "$ODIN_DIR" fetch --tags --force --prune origin || warn "fetch failed - using local tags"
    else
        rm -rf "$ODIN_DIR"
        mkdir -p "$DEST_DIR"
        log "Cloning Odin..."
        # shellcheck disable=SC2086 # NO_LFS is several arguments
        git $NO_LFS clone "$ODIN_REPO" "$ODIN_DIR"
    fi

    ODIN_TAG="${ODINUP_ODIN_VERSION:-}"
    if [ -z "$ODIN_TAG" ]; then
        ODIN_TAG="$(latest_odin_tag)"
        [ -n "$ODIN_TAG" ] || die "Could not find any dev-* tag in $ODIN_DIR."
    fi
    log "Odin $ODIN_TAG"

    WANT="$(git -C "$ODIN_DIR" rev-parse --verify --quiet "$ODIN_TAG^{commit}")" || die "Odin tag '$ODIN_TAG' not found."
    # shellcheck disable=SC2086
    git -C "$ODIN_DIR" $NO_LFS checkout --quiet --force --detach "$WANT"

    # Skip the multi-minute build when this commit is already built.
    if [ -x "$ODIN_DIR/odin" ]; then
        HAVE="$("$ODIN_DIR/odin" version 2>/dev/null | sed -n 's/.*:\([0-9a-f]*\).*/\1/p')"
        case "$WANT" in
            "$HAVE"*) if [ -n "$HAVE" ]; then ok "Odin $ODIN_TAG already built"; return; fi ;;
        esac
    fi

    # The supported LLVM range is the one of the Odin version being built.
    V="$(sed -n 's/^SUPPORTED_LLVM_VERSIONS="\(.*\)"/\1/p' "$ODIN_DIR/build_odin.sh" 2>/dev/null)"
    if [ -n "$V" ]; then LLVM_VERSIONS="$V"; fi
    if [ -z "${LLVM_CONFIG:-}" ]; then
        ensure_llvm
        LLVM_CONFIG="$(find_llvm_config)"
    fi
    export LLVM_CONFIG

    log "Building Odin from source - this takes a few minutes..."
    (cd "$ODIN_DIR" && make release-native) || die "Building Odin failed (see output above)."
    [ -x "$ODIN_DIR/odin" ] || die "Odin build finished but $ODIN_DIR/odin is missing."
    ok "Built $("$ODIN_DIR/odin" version)"
}

# ------------------------------------------------------------------ odinup

# odinup_source prints a directory containing odinup's src/: this checkout when
# run from one, else a clone of ODINUP_REPO at ODINUP_REF.
odinup_source() {
    case "$0" in
        */install.sh|install.sh)
            D="$(cd "$(dirname "$0")" && pwd)"
            if [ -f "$D/src/main.odin" ]; then echo "$D"; return; fi ;;
    esac
    D="$DEST_DIR/src"
    if [ -d "$D/.git" ]; then
        git -C "$D" fetch --quiet --tags --force origin >&2 || warn "could not update $D" >&2
    else
        rm -rf "$D"
        git clone --quiet "$ODINUP_REPO" "$D" >&2 || die "Could not clone $ODINUP_REPO"
    fi
    git -C "$D" checkout --quiet --force "origin/$ODINUP_REF" 2>/dev/null \
        || git -C "$D" checkout --quiet --force "$ODINUP_REF" \
        || die "odinup ref '$ODINUP_REF' not found in $ODINUP_REPO"
    echo "$D"
}

build_odinup() {
    SRC="$(odinup_source)"
    log "Building odinup from $SRC"
    mkdir -p "$BIN_DIR"
    (cd "$SRC" && "$ODIN_DIR/odin" build src -o:speed "-out:$BIN_DIR/odinup") || die "Building odinup failed."
    ok "Built $("$BIN_DIR/odinup" version)"
}

# -------------------------------------------------------------------- main

main() {
    log "odinup bootstrap ($OS_NAME/$(uname -m))"
    ensure_base_tools
    ensure_git_lfs
    build_odin
    build_odinup

    # Hand over: odinup writes the shims and PATH entries (no rebuild - the
    # commit is already built). Run from ~/.odinup so a project's odinup.toml
    # in the current directory doesn't change what gets installed.
    (cd "$DEST_DIR" && "$BIN_DIR/odinup" install --odin "$ODIN_TAG") || die "odinup install failed."

    echo
    ok "Odin is installed."
    # shellcheck disable=SC2016 # print $PATH literally
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) printf '\n  Open a new terminal (or run: export PATH="%s:$PATH")\n' "$BIN_DIR" ;;
    esac
    printf '\n  Then, in a project with an odinup.toml:  odinup install\n\n'
}

main "$@"
