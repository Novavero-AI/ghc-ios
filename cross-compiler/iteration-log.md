# GHC iOS Cross-Compiler - Iteration Log

## Context
Target: Build GHC 9.8.4 cross-compiler for `aarch64-apple-ios` on macOS (GitHub Actions).
Output: A working `aarch64-apple-ios-ghc` that compiles Haskell to native ARM64 iOS binaries.
CI: `.github/workflows/cross-compiler.yml` (manual dispatch, `macos-latest`)
Timeline: v1-v37 over the winter of 2025-2026 (first green 2026-03-07), host-GHC fixes April 2026, v38+ August 2026 against newer Xcode images.

Nobody had documented a working GHC 9.8 iOS cross-compiler build from scratch.
This log records every failure and fix: the original bootstrap iterations
(v1-v37), then the maintenance entries that keep the build green on newer
Xcode images (v38+). Commit hashes in v1-v37 reference nova-kit's private
tree, where this work originally lived.

---

## Key Decisions

| Decision | Why |
|----------|-----|
| Homebrew LLVM clang (not Xcode clang) | Apple's integrated assembler rejects arithmetic in CFI directives (`cfi_adjust_cfa_offset (8*2 + ...)`) that libffi's aarch64 assembly requires. Upstream LLVM handles these correctly. |
| `+native_bignum` flavour | GMP is not available on iOS. Pure Haskell bignum backend, zero external deps. |
| `--flags=-libm --flags=-libdl` | On iOS, `libm` and `libdl` are part of `libSystem` - no standalone libraries exist. GHC's `rts.cabal.in` uses flag conditionals for these. |
| `-D_DARWIN_C_SOURCE` | iOS needs this for POSIX extensions like `pthread_setname_np`. |
| `-Ddarwin_HOST_OS` | iOS is Darwin but GHC doesn't define this automatically for cross targets. RTS code paths depend on it for Mach APIs, signal handling, etc. |
| Patch libffi tarball (not source) | Hadrian re-extracts from `libffi-tarballs/libffi-3.4.6.tar.gz` on every build attempt, overwriting any source patches. Must patch the tarball itself. |
| `__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__` for iOS detection | Clang built-in when `-target arm64-apple-ios` is set. No `#include` needed. `TARGET_OS_IPHONE` requires `<TargetConditionals.h>` - doesn't work in sed patches. |

---

## Iteration Log

### Phase 1 - Build System Setup (v1-v8)

Getting the basic cross-compiler pipeline working: source download, boot GHC,
alex/happy, configure flags, CC/CXX wrapper scripts.

**v1** `7bc2d6a` - alex/happy install path conflicts. Fix: install outside repo dir.

**v2** `924019b` - Wrong working dirs, missing SDK flags. Fix: proper paths, `--target=aarch64-apple-ios`.

**v3** `5759760` - SDL2 not found (the early combined CI also built the framework's since-removed desktop SDL2 shell - never a GHC dependency), `./boot` fails on pre-booted tarball. Fix: install SDL2, skip boot.

**v4** `b73c014` - Obsolete `--with-clang` flag rejected. Fix: use `CC=` instead.

**v5** `0de7b24` - Configure misparses inline CC flags. Fix: wrapper script that embeds `-target` and `-isysroot`.

**v6** `9741c6d` - Missing CXX wrapper, heredoc whitespace, isysroot not passed. Fix: add CXX wrapper, fix heredoc.

**v7** `baa3bb5` - `perf-cross` flavour doesn't exist in GHC 9.8. Fix: use `quick` flavour.

**v8** `4c53e9e` - LD path not set, UI toolkit module structure. Fix: add LD path.

---

### Phase 2 - RTS Library Fixes (v9-v13)

GHC's RTS links against `libm`, `libdl`, and GMP. None exist as standalone
libraries on iOS.

**v9** `6e9276a` - RTS link fails: `-lm not found`. Attempt: pass iOS SDK lib path.
Result: **Failed** - `libm.tbd` exists but isn't a real archive on iOS.

**v10** `f29957e` - Attempt: create stub `.a` archives for libm/libdl.
Result: **Failed** - Hadrian special-cases RTS configure, ignores `--extra-lib-dirs`.

**v11** `d77582b` - Attempt: sed patch `rts.cabal.in` to remove libm/libdl.
Result: **Failed** - fragile, breaks on rebuild.

**v12** `db54366` - `--flags=-libm --flags=-libdl` via Hadrian's cabal configure opts.
Result: **Passed RTS link!** New error: `__GNU_MP_VERSION not defined` (GMP).

**v13** `494c3db` - `+native_bignum` flavour (pure Haskell bignum, no GMP dependency).
Result: **Passed bignum!** New error: libffi aarch64 assembly.

---

### Phase 3 - libffi Assembly (v14-v21)

libffi's `aarch64/sysv.S` uses CFI directives with arithmetic expressions.
Apple's Xcode clang rejects these. Required switching to Homebrew LLVM clang
and then patching the libffi configure to disable CFI entirely.

**v14** `2f22b3c` - Attempt: use upstream system libffi instead of bundled.
Result: **Failed** - version/ABI mismatch.

**v15** `f143082` - Switch to Homebrew LLVM clang (not Apple Xcode clang).
Result: **Partial** - assembly parses, but libffi configure still enables broken CFI.

**v16** `bb36193` - Attempt: patch `aarch64/sysv.S` source directly.
Result: **Failed** - Hadrian re-extracts from tarball, overwrites patches.

**v17** `5a4236c` - Attempt: disable CFI at build level.
Result: **Failed** - wrong approach, configure re-enables.

**v18** `d7b5da6` - Attempt: find `fficonfig.h` in build subdir.
Result: **Failed** - wrong path.

**v19** `da7b4d4` - Attempt: pass iOS libffi to Stage 1 only.
Result: **Failed** - Stage 0/1 conflict.

**v20** `ca08993` - Attempt: restore macOS libffi for Stage 0.
Result: **Failed** - still conflicts.

**v21** `ae782fb` - Drop `--with-system-libffi`, let Hadrian build native for both stages.
Result: **Failed** - bundled libffi configure still enables CFI.

---

### Phase 4 - libffi Tarball Patching (v22-v26)

Key insight: Hadrian extracts from `libffi-tarballs/libffi-3.4.6.tar.gz` on
every build attempt. Must patch the tarball itself.

**v22** `7f4f393` - Patch bundled libffi configure in extracted source, two-pass fallback.
Result: **Failed** - Hadrian overwrites with fresh tarball extract.

**v23** `a6c9853` - **Patch the tarball directly.** Extract -> sed -> repackage.
Target: `libffi_cv_as_cfi_pseudo_op`.
Result: **Failed** - wrong autoconf cache variable name.

**v24** `e42d460` - Try `libffi_cv_as_cfi_pseudo_op` (autoconf convention).
Result: **Failed** - still wrong variable name.

**v25** `d5815f1` - Debug: grep the actual configure script for the CFI variable.
Result: Found it - `gcc_cv_as_cfi_pseudo_op` (libffi uses GCC-style naming).

**v26** `e4fc950` - `gcc_cv_as_cfi_pseudo_op=no` in patched tarball.
Result: **Passed libffi!** New error: `pthread_setname_np` undeclared.

---

### Phase 5 - Darwin/iOS Platform Detection (v27-v30)

iOS is Darwin but GHC doesn't know that for cross targets. RTS code paths
need Darwin-specific defines and headers, but some Darwin APIs (`mach_vm.h`)
are blocked on iOS.

**v27** `8c7a498` - `pthread_setname_np` undeclared. Fix: `-D_DARWIN_C_SOURCE` in `CONF_CC_OPTS_STAGE1`.
Result: **Passed pthread!** New error: RTS missing darwin code paths entirely.

**v28** `b918934` - RTS compiled without any Darwin code paths. Fix: `-Ddarwin_HOST_OS`.
Result: **Passed most of RTS!** New error: `mach_vm.h` has `#error` on line 1 for iOS.

**v29** `45d240e` - `ReportMemoryMap.c` includes `mach_vm.h` which is blocked on iOS.
Attempt: guard with `!TARGET_OS_IPHONE`.
Result: **Failed** - `TARGET_OS_IPHONE` needs `#include <TargetConditionals.h>`.
Without the include, preprocessor treats it as `0`, so `!0 = 1`, guard passes,
darwin mach_vm block still compiles.

**v30** `f1fb607` - Use `!defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)` instead.
Clang built-in when targeting iOS - no includes needed.
Result: **Failed** - sed matched `#if` (line 17) but missed `#elif` (line 75). Also verify grep was checking old macro name.

**v31** `32dab87` - Patch BOTH darwin_HOST_OS guards in ReportMemoryMap.c (`#if` on line 17 and `#elif` on line 75). Fix verify to check for new macro and require 2 matches.
Result: **Passed ReportMemoryMap.c!** All RTS C files compiled. New error: **linker** - `ld: unknown options: -zorigin`.

---

### Phase 6 - Hadrian Build System (v32-v37)

RTS compilation complete. Now fixing Hadrian's build system which doesn't
recognize iOS as an Apple platform.

**v32** `4f88bf0` - `ld: unknown options: -zorigin`. GNU ld flag for RPATH `$ORIGIN` resolution - Apple's ld doesn't support `-z` flags. Root cause: Hadrian's `isOsxTarget` only matches `"darwin"`, not `"ios"`. iOS target registers as non-Apple, gets Linux linker flags.
Fix: patch `isOsxTarget = anyTargetOs ["darwin", "ios"]` in `hadrian/src/Oracles/Setting.hs`. Also fixes `@loader_path` (macOS rpath) and `-framework` flags for iOS.
Result: **Passed linker flags!** `@loader_path` now used correctly. New error: `ld: library 'ffi' not found`.

**v33** - `ld: library 'ffi' not found`. Hadrian builds libffi to `_build/stage1/libffi/build/inst/` and copies headers to `_build/stage1/rts/build/include/`, but does NOT copy the library. RTS link has `-L_build/stage1/rts/build -lffi` - wrong path.
Fix: add `stage1.rts.ghc.link.opts += -optl-L_build/stage1/libffi/build/inst/lib` to Hadrian build args.
Result: **Passed libffi link!** All RTS libraries built (static + dynamic). New error: `copyFile: does not exist` - `.so` vs `.dylib` mismatch.

**v34** - `libHSrts-1.0.2-ghc9.8.4.so: copyFile: does not exist`. Hadrian builds `.dylib` (correct for Apple) but Cabal's `Copy package` step looks for `.so`. Root cause: `dllExtension` in `Distribution.Simple.BuildPaths` only matches `OSX -> "dylib"` - `IOS` falls through to `_ -> "so"`.
Fix: patch Cabal's `BuildPaths.hs` in GHC source tree to add `IOS -> "dylib"`.
Result: **Still `.so`!** Patch applied to in-tree Cabal, but Hadrian uses the **boot GHC's Cabal** (unpatched). `hadrian/cabal.project` has `packages: ./` - only includes itself.

**v35** `a2d2d7c` - Same `.so` error. Root cause deeper: Hadrian is compiled with the boot GHC's Cabal, not the in-tree one. Our patch to `libraries/Cabal/` only affects Stage 0/1 libraries.
Fix: patch `hadrian/cabal.project` to include in-tree Cabal packages + `allow-newer`, so Hadrian compiles against patched `dllExtension`. Also: `posix_spawn_file_actions_addchdir_np` unavailable on iOS (Apple marks it `__attribute__((unavailable))`). Fix: patch 005 guards the `#elif` with `!defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)`.
Also: replaced all sed-based patches with proper unified diff `.patch` files in `cross-compiler/patches/`. Applied via `patch -p1`.
Result: **Build with Hadrian PASSED! (36 min)** Install step failed: `Missing (or bad) C libraries: m, dl`.

**v36** `84e7e43` - Install step fails: `Missing (or bad) C libraries: m, dl`. Hadrian doesn't persist CLI settings between invocations. The build step passed `--flags=-libm --flags=-libdl` but the install step didn't.
Fix: pass the same iOS flags (`--flags=-libm --flags=-libdl`, `-isysroot`, `-L` for libffi) to the install command.
Result: **Passed -lm/-ldl!** New error: `__GNU_MP_VERSION not defined` - install step also doesn't know about `+native_bignum` flavour.

**v37** `1028c15` - Install step compiles `gmp_wrappers.c` which requires GMP headers. Hadrian doesn't persist the flavour between invocations - without `+native_bignum`, it falls back to GMP bignum.
Fix: pass `--flavour=quick+native_bignum` to the install command.
Result: **GREEN. ALL STEPS PASSED.** Build (36 min) + Install (25 min) + Verify + Package + Upload. `aarch64-apple-ios-ghc --version` works. Artifact uploaded.

---

### Phase 7 - Shell Rename (parallel with CI)

**`7437fb2`** - Renamed entire shell layer from `np_` (nova-plat) to `nk_` (nova-kit).
Files renamed: `np_shell.h/c` -> `nk_shell.h/c`, `np_shell_ios.m` -> `nk_shell_ios.m`, `np_shell_android.c` -> `nk_shell_android.c`.
All prefixes updated: `NP_` -> `NK_`, `NPEvent` -> `NKEvent`, `np_` -> `nk_`, iOS classes `NPView/NPViewController/NPAppDelegate` -> `NKView/NKViewController/NKAppDelegate`.
Haskell FFI: `c_np_*` -> `c_nk_*`, event constants `np*` -> `nk*`. Cabal c-sources path updated.

---

### Phase 8 - Host GHC Quirks (post-bootstrap, April 2026)

Discovered during a downstream `cabal build` of a consumer app. Every host link on macOS emits:

    ld: warning: -U option is redundant when using -undefined dynamic_lookup

**Root cause:** GHC's `rts/rts.cabal.in` has an `if os(darwin)` block that adds `-Wl,-U,___darwin_check_fd_set_overflow` immediately followed by `-Wl,-undefined,dynamic_lookup`. The per-symbol `-U` is redundant - the next flag already permits any undefined symbol. Apple's newer `ld64` (Xcode 15+) noticed and started warning. Fixed upstream in GHC 9.10, still present in 9.8.x.

**Why CI doesn't see this in artifacts:** the iOS cross compiler's rts conf at `~/ghc-ios/lib/aarch64-apple-ios-ghc-9.8.4/lib/package.conf.d/rts-1.0.2.conf` is verified clean - none of the darwin block is present. Cabal evaluates `os(darwin)` against the **target** OS, not the host, so when configured for `aarch64-apple-ios` it sees `os(ios)` and omits the entire darwin section at build time. Only the host GHCup-installed darwin GHC ships the redundant flag.

**Why nova-kit's own iOS link path doesn't trip it either:** `nova-kit build ios` produces `libHaskellApp.a` via `aarch64-apple-ios-ghc -staticlib` (no link step) and then links the binary via `xcrun clang` directly from `cli/NovaKit/CLI/Build.hs:linkBinary`. The iOS GHC's rts conf is never consulted during the link.

**Fix:** `cross-compiler/host-fix-rts-darwin.sh` - idempotent host-side post-install script. Removes the redundant flag from the GHCup-installed `rts-*.conf` and runs `ghc-pkg --global recache`. Re-run after every `ghcup install ghc`. Lives at the cross-compiler root rather than inside `patches/` because the two have different lifecycles: source-tree `.patch` files are applied during cross-compiler bootstrap in CI, while this script runs locally on each developer machine after a fresh GHCup install.

---

### Phase 9 - Public repo bootstrap (v38-v40, August 2026)

**v38** - First run in the public ghc-ios repo, on a newer runner image
(Xcode 26.6 / iOS SDK 26.5) than the original green run. Failed in
`rts/sm/GCTDecl.h`: `thread-local storage is not supported for the current
target` on `extern __thread gc_thread* gct;`.

Root cause: GHC's configure derives an unversioned `--target=arm64-apple-ios`
from the platform triple and prepends it to the stage-1 C flags, where it
overrides the versioned `-target arm64-apple-ios15.0` inside the ios-cc
wrapper (clang: last target flag wins). With no deployment version, newer
clang assumes an ancient iOS floor where TLS is unsupported, and the
threaded RTS uses `__thread`. Older toolchains happened to tolerate it;
Xcode 26-era LLVM does not.

Fix: put `--target=arm64-apple-ios15.0` inside `CONF_CC_OPTS_STAGE1`, which
lands after the derived flag and wins. Deployment target is now pinned in
both the wrapper and the configure flags, which it always should have been.

**v39** - Past the TLS error; new failure in `libraries/process`:
`posix_spawn_file_actions_addchdir` (no `_np`) "explicitly marked
unavailable" on iOS. The Xcode 26 SDK now declares the standardized
non-`_np` variant, autoconf detects it (its probe supplies its own
prototype, bypassing the availability attribute), and the first branch
of the `#if` chain - which patch 005 never guarded, because the
function didn't exist on older SDKs - gets taken on iOS. Same failure
family as v31/v35: the chain had two branches, the patch guarded one.

Fix: regenerate patch 005 to guard BOTH `addchdir` branches with
`!defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)`; iOS now
falls through to `not_supported`, which is honest - iOS cannot spawn
arbitrary processes regardless. Cache key bumped v38 -> v39.

**v40** - v38+v39 both held: configure, the full Hadrian build, and
bindist assembly all passed for the first time on the Xcode 26 image.
New failure in the install step: the binary-dist configure died with
"Failed to find C++ standard library" - all three libc++ linkage probes
(`c++ c++abi`, `c++ c++abi pthread`, `c++ cxxrt`) failed.

Root cause: the source-tree configure is given CC=/tmp/ios-cc and
CXX=/tmp/ios-cxx explicitly, and its identical probe SUCCEEDED thirty
minutes earlier in the same run. But hadrian's install rule invokes the
binary-dist's own configure, which re-detects its toolchain from the
environment rather than inheriting the source tree's arguments. It
picked up bare Homebrew clang++ (llvm 22, first on PATH from the deps
step) with no -isysroot, which cannot link -lc++/-lc++abi on this
image, and the probe list has no plain-`c++` fallback. Older runner
images tolerated the sysroot-less link; the llvm 22 / Xcode 26
combination does not.

Fix: export CC/CXX/LD/AR/RANLIB/STRIP - the same iOS toolchain the
source configure was given - in the install step, so the bindist
configure probes the target toolchain instead of whatever is on PATH.
Two guards added while here: dump the bindist config.log when install
fails (this failure was undiagnosable from step output alone), and
assert no /tmp wrapper path survives into the shipped settings file.
Cache key bumped v39 -> v40.

**v41** - v40's C++ probe failure is gone, but the toolchain export
broke autoconf cross-detection: the bindist configure receives no
explicit --host (config.log: host_alias=''), so with CC=/tmp/ios-cc it
compiled its test program for arm64-ios and tried to RUN it on the
macOS host - "configure: error: cannot run C compiled programs"
(exit 77) at "checking whether we are cross compiling". The config.log
dump added in v40 turned this diagnosis into one grep instead of a
guess.

Fix: revert the toolchain exports. The bindist configure is a HOST
configure and always was (v37 ran it that way, green); the only thing
the Xcode 26 image broke is that bare Homebrew clang++ (llvm 22) has
no default sysroot, so its C++ std lib probe cannot link
-lc++/-lc++abi. Export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
so the host toolchain finds the macOS SDK - the v37-green
configuration, adapted to the new image. Cache key bumped v40 -> v41.

**v42** - v41 disproved its own hypothesis: with the toolchain exports
reverted and SDKROOT pointing at the macOS SDK, all three C++ std lib
probes still failed. The probe section of config.log was cut off by
the tail -150 dump (fixed this iteration: the dump now greps the
probe region directly), but the evidence pattern identifies the
cause: every candidate in the probe list (c++ c++abi / c++ c++abi
pthread / c++ cxxrt) requires a linkable libc++abi, the Xcode 26
macOS SDK no longer ships one, and the list has no plain-c++
fallback - so the probe cannot succeed on this image with any host
compiler. The iOS SDK still carries libc++abi, which is why the
source-tree configure's identical probe passes minutes earlier in
the same run.

Fix: pre-seed the probe's documented escape hatch instead of fighting
it - export CXX_STD_LIB_LIBS="c++" (with empty LIB_DIRS and
DYN_LIB_DIRS), which fp_find_cxx_std_lib.m4 honors by skipping
detection entirely. Plain c++ is the truthful answer on modern
Darwin, where the ABI library is bundled into libc++. SDKROOT stays
for the other host probes. Cache key bumped v41 -> v42. The probe's
missing plain-c++ candidate is a GHC bug against current Apple SDKs
(it will bite plain macOS builds on Xcode 26 too) and joins the
upstreaming queue alongside the patches.

Result: **GREEN. ALL STEPS PASSED.** Run 31944695895 on commit
04b24cd: configure, full Hadrian build, install, portability patch,
verify (the installed compiler reports "version 9.8.4", "Target
platform: aarch64-apple-ios"), package, upload. The first green build
on an Xcode 26 image - five iterations after the runner image drift
began (v38 TLS floor, v39 posix_spawn branch, v40 bindist toolchain,
v41 disproved sysroot theory, v42 pre-seeded C++ std lib). Toolchain
published as Release v42.
---

## Patches (5 total, `cross-compiler/patches/`)

| # | File | What |
|---|------|------|
| 001 | `hadrian/src/Oracles/Setting.hs` | `isOsxTarget` includes `"ios"` - Apple linker flags |
| 002 | `libraries/Cabal/.../BuildPaths.hs` | `dllExtension`: `IOS -> "dylib"` |
| 003 | `rts/ReportMemoryMap.c` | Guard `mach_vm.h` includes for iOS |
| 004 | `hadrian/cabal.project` | Use in-tree Cabal so Hadrian gets patch 002 |
| 005 | `libraries/process/.../posix_spawn.c` | Guard `addchdir_np` for iOS |

Plus:
- libffi tarball repackage (script, not patch file) - `gcc_cv_as_cfi_pseudo_op=no`.
- `cross-compiler/host-fix-rts-darwin.sh` - host-side post-install fix (see Phase 8).

## Current Workflow Steps

1. Cache check (keyed `ghc-9.8.4-aarch64-apple-ios-v<n>`, bumped whenever a patch or build flag changes)
2. Install boot GHC 9.8, cabal, alex, happy
3. Install build deps (automake, autoconf, libtool, Homebrew LLVM)
4. Download GHC 9.8.4 source tarball
5. Create `ios-cc` / `ios-cxx` wrappers (Homebrew LLVM clang + `-target arm64-apple-ios -isysroot $IOS_SDK`)
6. **Patch libffi tarball** - extract, force `gcc_cv_as_cfi_pseudo_op=no` in configure, repackage
7. **Apply patches** (`cross-compiler/patches/001-005`) - Hadrian, Cabal, RTS, process fixes via `patch -p1`
8. Configure: `--target=aarch64-apple-ios`, Homebrew LLVM tools, `-D_DARWIN_C_SOURCE -Ddarwin_HOST_OS`
9. Build: `hadrian/build -j --flavour=quick+native_bignum` with `--flags=-libm --flags=-libdl` and `-L` for libffi
10. Install: same Hadrian flags as build (Hadrian doesn't persist CLI settings), with SDKROOT and the pre-seeded CXX_STD_LIB_* answers exported for the bindist's host configure (v41/v42)
11. Verify -> package -> upload artifact

## What's After Green

1. Link Haskell + C shell -> `.ipa` -> pixels on device
2. Upstream patches to gitlab.haskell.org/ghc/ghc
3. Cache stage 0 bootstrap separately (or use nova-cache on OCI)
