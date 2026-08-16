#!/usr/bin/env bash
#
# Patches the host (GHCup-installed) GHC's RTS package config to remove
# the redundant '-Wl,-U,___darwin_check_fd_set_overflow' linker flag that
# triggers a warning under newer Apple linkers (Xcode 15+, ld64 1015+).
#
# Why this exists
# ---------------
# GHC's rts package (rts-*.conf) contains a darwin-specific block in its
# 'ld-options' field that looks like this:
#
#     "-Wl,-search_paths_first" "-Wl,-U,___darwin_check_fd_set_overflow"
#     "-Wl,-undefined,dynamic_lookup"
#
# The per-symbol '-Wl,-U,___darwin_check_fd_set_overflow' was added years
# ago to allow the FD_SET / FD_CLR / FD_ZERO bounds-checking symbol to be
# absent on older macOS versions. The next line, '-Wl,-undefined,dynamic_lookup',
# already says "any undefined symbol is allowed", so the per-symbol -U is
# completely redundant.
#
# Newer Apple ld (Xcode 15+) noticed the redundancy and now emits:
#
#     ld: warning: -U option is redundant when using -undefined dynamic_lookup
#
# on every link of every Haskell executable on macOS. The warning is harmless
# but it shows up in every nova-kit downstream build (every 'cabal build' of
# every consumer app), which makes the SDK look broken when it isn't.
#
# This is a known upstream issue. It was fixed in GHC 9.10 by removing the
# flag from rts/rts.cabal.in, but GHC 9.8.x - which is what the iOS cross
# compiler is built from - still ships it.
#
# Two patches needed in total
# ---------------------------
# 1. THIS SCRIPT - patches the GHCup-installed *host* GHC's rts conf, since
#    that is what runs 'cabal build' for every downstream nova-kit app on
#    the developer's machine. Idempotent: safe to re-run after every
#    'ghcup install ghc'.
#
# 2. cross-compiler/patches/006-* - TODO when we have a verifiable patch
#    against rts/rts.cabal.in in the GHC 9.8.4 source tarball. This would
#    fix the iOS cross-compiler's RTS conf at source-tree level so the
#    cross-compiler bootstrap in CI also avoids the warning. Not critical:
#    the iOS link goes through nova-kit's own build pipeline, which uses
#    its own clang invocations and never reads this conf.
#
# Usage
# -----
#   ./cross-compiler/host-fix-rts-darwin.sh
#
# Re-run after every 'ghcup install ghc' or any time the host GHC is
# reinstalled. The script is idempotent: if the redundant flag is already
# absent, it exits cleanly with "already patched".

set -euo pipefail

# Locate the host GHC's rts conf via 'ghc-pkg field rts ld-options'.
# This is more robust than hard-coding the GHCup path because it works
# whether the host GHC came from GHCup, a Nix install, a Homebrew install,
# or a from-source build.
GHC_PKG="${GHC_PKG:-ghc-pkg}"
if ! command -v "$GHC_PKG" >/dev/null 2>&1; then
    echo "ERROR: $GHC_PKG not found in PATH" >&2
    echo "       Install GHC via ghcup, or set GHC_PKG to a valid binary." >&2
    exit 1
fi

# Find the global package db directory. 'ghc-pkg list --simple-output rts'
# prints the rts package id; we then derive the conf file from the global
# package db location reported by 'ghc-pkg --version' + the standard layout.
GHC_LIB_DIR="$($GHC_PKG --global list 2>/dev/null | head -1 | sed 's/:$//')"
if [ -z "$GHC_LIB_DIR" ] || [ ! -d "$GHC_LIB_DIR" ]; then
    echo "ERROR: could not locate global package db from $GHC_PKG" >&2
    exit 1
fi

RTS_CONF="$(find "$GHC_LIB_DIR" -maxdepth 1 -name 'rts-*.conf' | head -1)"
if [ -z "$RTS_CONF" ] || [ ! -f "$RTS_CONF" ]; then
    echo "ERROR: rts-*.conf not found under $GHC_LIB_DIR" >&2
    exit 1
fi

echo "Host GHC rts conf: $RTS_CONF"

# Idempotency check: bail early if the flag is already gone.
if ! grep -q '"-Wl,-U,___darwin_check_fd_set_overflow"' "$RTS_CONF"; then
    echo "  already patched (no redundant -U flag present)"
    exit 0
fi

# In-place edit. The flag appears exactly once and on the same line as
# '-Wl,-search_paths_first', so we strip it with sed leaving the line's
# leading whitespace intact.
sed -i '' 's| "-Wl,-U,___darwin_check_fd_set_overflow"||' "$RTS_CONF"

# Verify the edit took.
if grep -q '"-Wl,-U,___darwin_check_fd_set_overflow"' "$RTS_CONF"; then
    echo "ERROR: sed edit did not remove the flag - conf format may have changed" >&2
    exit 1
fi
echo "  removed redundant -Wl,-U,___darwin_check_fd_set_overflow"

# Re-cache the package db so GHC sees the new conf. Without this, GHC
# still reads the binary 'package.cache' which has the old flag baked in.
"$GHC_PKG" --global recache
echo "  recached global package db"

echo "Done. Test with: cd <any nova-kit app> && cabal clean && cabal build"
