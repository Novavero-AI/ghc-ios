# GHC iOS Cross-Compiler - Iteration Log

## Context
Target: Build GHC 9.14.1 cross-compiler for `aarch64-apple-ios` on macOS (GitHub Actions).
Output: A working `aarch64-apple-ios-ghc` that compiles Haskell to native ARM64 iOS binaries.
CI: `.github/workflows/cross-compiler.yml` (manual dispatch, `macos-latest`)
Timeline: v1-v37 over the winter of 2025-2026 (first green 2026-03-07), host-GHC fixes April 2026, v38-v42 August 2026 against newer Xcode images, port to 9.14.1 (Phase 9, first green 2026-08-21).

Phases 1-8 built and maintained the toolchain on GHC 9.8.4; Phase 9 ports it to
9.14.1, the first LTS line, and the analysis behind that port has its own
document, [`porting-9.14.md`](porting-9.14.md). Earlier entries describe the
9.8.4 build and are kept as history: where a 9.8.4-era statement no longer holds
for 9.14, the port document says so rather than the entry being rewritten. A
statement that was never true is a different case and is corrected in place,
marked as a correction - see v42.

No prior GHC iOS cross-compiler published its failures. This log is that
record: the original bootstrap iterations (v1-v37), then the maintenance
entries that keep the build green on newer Xcode images (v38+). v1-v37
were run out of nova-kit's private tree, where this work originally
lived; from v38 onward every run is in
this repo's public Actions history, and the whole thing is reproducible
by dispatching the workflow. Release tags continue this numbering, but
only compiler-build failures get entries - releases v43 and v44 have no
matching entries; their story is in the release notes and commit
history, which is why the 9.14 port's first dispatch is v45.

---

## Key Decisions

Current as of the 9.14.1 port. Superseded 9.8.4-era decisions are marked; the
reasoning that retired them is in [`porting-9.14.md`](porting-9.14.md).

| Decision | Why |
|----------|-----|
| Apple clang via `xcrun` | The build compiler is now the same one the shipped `ios-cc` wrapper invokes at runtime. Supersedes the 9.8.4 choice of Homebrew LLVM, which existed only because Apple's assembler rejected libffi 3.4.6's aarch64 CFI. |
| `+native_bignum` flavour | GMP is not available on iOS. Pure Haskell bignum backend, zero external deps. |
| `--flags=-libm --flags=-libdl` | On iOS, `libm` and `libdl` are part of `libSystem` - no standalone libraries exist. GHC's `rts.cabal` uses flag conditionals for these. |
| `-D_DARWIN_C_SOURCE` | iOS needs this for POSIX extensions like `pthread_setname_np`. |
| `-Ddarwin_HOST_OS` | The RTS gates its Mach code paths on this macro. 9.14 generates `ghcplatform.h` from `rts/configure`'s own `--host` triple rather than the top-level configure's `TargetOS`, so whether it defines `ios_HOST_OS` or `darwin_HOST_OS` depends on which triple Cabal hands it. Forcing the define is correct under either answer and costs nothing. |
| Target C flags in `CONF_CC_OPTS_STAGE2` | 9.14 describes the stage-1 (target) toolchain in `hadrian/cfg/default.target`, generated from the STAGE2 variables. `CONF_CC_OPTS_STAGE1` is accepted by the shell and then ignored. |
| No libffi tarball repack (9.14+) | libffi 3.5.2 moved `.cfi_startproc` after the global label, which is what actually broke on Mach-O. Supersedes the 9.8.4 repack with `gcc_cv_as_cfi_pseudo_op=no`. |
| `__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__` for iOS detection | Clang built-in when `-target arm64-apple-ios` is set. No `#include` needed. `TARGET_OS_IPHONE` requires `<TargetConditionals.h>` - doesn't work in sed patches. |

---

## Iteration Log

### Phase 1 - Build System Setup (v1-v8)

Getting the basic cross-compiler pipeline working: source download, boot GHC,
alex/happy, configure flags, CC/CXX wrapper scripts.

**v1** - alex/happy install path conflicts. Fix: install outside repo dir.

**v2** - Wrong working dirs, missing SDK flags. Fix: proper paths, `--target=aarch64-apple-ios`.

**v3** - SDL2 not found (the early combined CI also built the framework's since-removed desktop SDL2 shell - never a GHC dependency), `./boot` fails on pre-booted tarball. Fix: install SDL2, skip boot.

**v4** - Obsolete `--with-clang` flag rejected. Fix: use `CC=` instead.

**v5** - Configure misparses inline CC flags. Fix: wrapper script that embeds `-target` and `-isysroot`.

**v6** - Missing CXX wrapper, heredoc whitespace, isysroot not passed. Fix: add CXX wrapper, fix heredoc.

**v7** - `perf-cross` flavour doesn't exist in GHC 9.8. Fix: use `quick` flavour.

**v8** - LD path not set (the old combined CI also shuffled framework modules here - not GHC work). Fix: add LD path.

---

### Phase 2 - RTS Library Fixes (v9-v13)

GHC's RTS links against `libm`, `libdl`, and GMP. None exist as standalone
libraries on iOS.

**v9** - RTS link fails: `-lm not found`. Attempt: pass iOS SDK lib path.
Result: **Failed** - `libm.tbd` exists but isn't a real archive on iOS.

**v10** - Attempt: create stub `.a` archives for libm/libdl.
Result: **Failed** - Hadrian special-cases RTS configure, ignores `--extra-lib-dirs`.

**v11** - Attempt: sed patch `rts.cabal.in` to remove libm/libdl.
Result: **Failed** - fragile, breaks on rebuild.

**v12** - `--flags=-libm --flags=-libdl` via Hadrian's cabal configure opts.
Result: **Passed RTS link!** New error: `__GNU_MP_VERSION not defined` (GMP).

**v13** - `+native_bignum` flavour (pure Haskell bignum, no GMP dependency).
Result: **Passed bignum!** New error: libffi aarch64 assembly.

---

### Phase 3 - libffi Assembly (v14-v21)

libffi's `aarch64/sysv.S` uses CFI directives with arithmetic expressions.
Apple's Xcode clang rejects these. Required switching to Homebrew LLVM clang
and then patching the libffi configure to disable CFI entirely.

**v14** - Attempt: use upstream system libffi instead of bundled.
Result: **Failed** - version/ABI mismatch.

**v15** - Switch to Homebrew LLVM clang (not Apple Xcode clang).
Result: **Partial** - assembly parses, but libffi configure still enables broken CFI.

**v16** - Attempt: patch `aarch64/sysv.S` source directly.
Result: **Failed** - Hadrian re-extracts from tarball, overwrites patches.

**v17** - Attempt: disable CFI at build level.
Result: **Failed** - wrong approach, configure re-enables.

**v18** - Attempt: find `fficonfig.h` in build subdir.
Result: **Failed** - wrong path.

**v19** - Attempt: pass iOS libffi to Stage 1 only.
Result: **Failed** - Stage 0/1 conflict.

**v20** - Attempt: restore macOS libffi for Stage 0.
Result: **Failed** - still conflicts.

**v21** - Drop `--with-system-libffi`, let Hadrian build native for both stages.
Result: **Failed** - bundled libffi configure still enables CFI.

---

### Phase 4 - libffi Tarball Patching (v22-v26)

Key insight: Hadrian extracts from `libffi-tarballs/libffi-3.4.6.tar.gz` on
every build attempt. Must patch the tarball itself.

**v22** - Patch bundled libffi configure in extracted source, two-pass fallback.
Result: **Failed** - Hadrian overwrites with fresh tarball extract.

**v23** - **Patch the tarball directly.** Extract -> sed -> repackage.
Target: `HAVE_AS_CFI_PSEUDO_OP`.
Result: **Failed** - that is the C `#define` configure emits, not the cache variable the test consults.

**v24** - Try `libffi_cv_as_cfi_pseudo_op` (autoconf convention).
Result: **Failed** - still wrong variable name.

**v25** - Debug: grep the actual configure script for the CFI variable.
Result: Found it - `gcc_cv_as_cfi_pseudo_op` (libffi uses GCC-style naming).

**v26** - `gcc_cv_as_cfi_pseudo_op=no` in patched tarball.
Result: **Passed libffi!** New error: `pthread_setname_np` undeclared.

---

### Phase 5 - Darwin/iOS Platform Detection (v27-v31)

iOS is Darwin but GHC doesn't know that for cross targets. RTS code paths
need Darwin-specific defines and headers, but some Darwin APIs (`mach_vm.h`)
are blocked on iOS.

**v27** - `pthread_setname_np` undeclared. Fix: `-D_DARWIN_C_SOURCE` in `CONF_CC_OPTS_STAGE1`.
Result: **Passed pthread!** New error: RTS missing darwin code paths entirely.

**v28** - RTS compiled without any Darwin code paths. Fix: `-Ddarwin_HOST_OS`.
Result: **Passed most of RTS!** New error: `mach_vm.h` has `#error` on line 1 for iOS.

**v29** - `ReportMemoryMap.c` includes `mach_vm.h` which is blocked on iOS.
Attempt: guard with `!TARGET_OS_IPHONE`.
Result: **Failed** - `TARGET_OS_IPHONE` needs `#include <TargetConditionals.h>`.
Without the include, preprocessor treats it as `0`, so `!0 = 1`, guard passes,
darwin mach_vm block still compiles.

**v30** - Use `!defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)` instead.
Clang built-in when targeting iOS - no includes needed.
Result: **Failed** - sed matched `#if` (line 17) but missed `#elif` (line 75). The verify grep was also still checking the old macro name.

**v31** - Patch BOTH darwin_HOST_OS guards in ReportMemoryMap.c (`#if` on line 17 and `#elif` on line 75). Fix verify to check for new macro and require 2 matches.
Result: **Passed ReportMemoryMap.c!** All RTS C files compiled. New error: **linker** - `ld: unknown options: -zorigin`.

---

### Phase 6 - Hadrian Build System (v32-v37)

RTS compilation complete. Now fixing Hadrian's build system which doesn't
recognize iOS as an Apple platform.

**v32** - `ld: unknown options: -zorigin`. GNU ld flag for RPATH `$ORIGIN` resolution - Apple's ld doesn't support `-z` flags. Root cause: Hadrian's `isOsxTarget` only matches `"darwin"`, not `"ios"`. iOS target registers as non-Apple, gets Linux linker flags.
Fix: patch `isOsxTarget = anyTargetOs ["darwin", "ios"]` in `hadrian/src/Oracles/Setting.hs`. Also fixes `@loader_path` (macOS rpath) and `-framework` flags for iOS.
Result: **Passed linker flags!** `@loader_path` now used correctly. New error: `ld: library 'ffi' not found`.

**v33** - `ld: library 'ffi' not found`. Hadrian builds libffi to `_build/stage1/libffi/build/inst/` and copies headers to `_build/stage1/rts/build/include/`, but does NOT copy the library. RTS link has `-L_build/stage1/rts/build -lffi` - wrong path.
Fix: add `stage1.rts.ghc.link.opts += -optl-L_build/stage1/libffi/build/inst/lib` to Hadrian build args.
Result: **Passed libffi link!** All RTS libraries built (static + dynamic). New error: `copyFile: does not exist` - `.so` vs `.dylib` mismatch.

**v34** - `libHSrts-1.0.2-ghc9.8.4.so: copyFile: does not exist`. Hadrian builds `.dylib` (correct for Apple) but Cabal's `Copy package` step looks for `.so`. Root cause: `dllExtension` in `Distribution.Simple.BuildPaths` only matches `OSX -> "dylib"` - `IOS` falls through to `_ -> "so"`.
Fix: patch Cabal's `BuildPaths.hs` in GHC source tree to add `IOS -> "dylib"`.
Result: **Still `.so`!** Patch applied to in-tree Cabal, but Hadrian uses the **boot GHC's Cabal** (unpatched). `hadrian/cabal.project` has `packages: ./` - only includes itself.

**v35** - Same `.so` error. Root cause deeper: Hadrian is compiled with the boot GHC's Cabal, not the in-tree one. Our patch to `libraries/Cabal/` only affects Stage 0/1 libraries.
Fix: patch `hadrian/cabal.project` to include in-tree Cabal packages + `allow-newer`, so Hadrian compiles against patched `dllExtension`. Also: `posix_spawn_file_actions_addchdir_np` unavailable on iOS (Apple marks it `__attribute__((unavailable))`). Fix: patch 005 guards the `#elif` with `!defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)`.
Also: replaced all sed-based patches with proper unified diff `.patch` files in `cross-compiler/patches/`. Applied via `patch -p1`.
Result: **Build with Hadrian PASSED! (36 min)** Install step failed: `Missing (or bad) C libraries: m, dl`.

**v36** - Install step fails: `Missing (or bad) C libraries: m, dl`. Hadrian doesn't persist CLI settings between invocations. The build step passed `--flags=-libm --flags=-libdl` but the install step didn't.
Fix: pass the same iOS flags (`--flags=-libm --flags=-libdl`, `-isysroot`, `-L` for libffi) to the install command.
Result: **Passed -lm/-ldl!** New error: `__GNU_MP_VERSION not defined` - install step also doesn't know about `+native_bignum` flavour.

**v37** - Install step compiles `gmp_wrappers.c` which requires GMP headers. Hadrian doesn't persist the flavour between invocations - without `+native_bignum`, it falls back to GMP bignum.
Fix: pass `--flavour=quick+native_bignum` to the install command.
Result: **GREEN. ALL STEPS PASSED.** Build (36 min) + Install (25 min) + Verify + Package + Upload. `aarch64-apple-ios-ghc --version` works. Artifact uploaded.

---

### Phase 7 - Host GHC Quirks (post-bootstrap, April 2026)

Discovered during a downstream `cabal build` of a consumer app. Every host link on macOS emits:

    ld: warning: -U option is redundant when using -undefined dynamic_lookup

**Root cause:** GHC's `rts/rts.cabal.in` has an `if os(darwin)` block that adds `-Wl,-U,___darwin_check_fd_set_overflow` immediately followed by `-Wl,-undefined,dynamic_lookup`. The per-symbol `-U` is redundant - the next flag already permits any undefined symbol. Apple's newer `ld64` (Xcode 15+) noticed and started warning. Fixed upstream in GHC 9.10, still present in 9.8.x.

**Why CI doesn't see this in artifacts:** the iOS cross compiler's rts conf at `~/ghc-ios/lib/aarch64-apple-ios-ghc-9.8.4/lib/package.conf.d/rts-1.0.2.conf` is verified clean - none of the darwin block is present. Cabal evaluates `os(darwin)` against the **target** OS, not the host, so when configured for `aarch64-apple-ios` it sees `os(ios)` and omits the entire darwin section at build time. Only the host GHCup-installed darwin GHC ships the redundant flag.

**Why nova-kit's own iOS link path doesn't trip it either:** `nova-kit build ios` produces `libHaskellApp.a` via `aarch64-apple-ios-ghc -staticlib` (no link step) and then links the binary via `xcrun clang` directly from `cli/NovaKit/CLI/Build.hs:linkBinary`. The iOS GHC's rts conf is never consulted during the link.

**Fix:** `cross-compiler/host-fix-rts-darwin.sh` - idempotent host-side post-install script. Removes the redundant flag from the GHCup-installed `rts-*.conf` and runs `ghc-pkg --global recache`. Re-run after every `ghcup install ghc`. Lives at the cross-compiler root rather than inside `patches/` because the two have different lifecycles: source-tree `.patch` files are applied during cross-compiler bootstrap in CI, while this script runs locally on each developer machine after a fresh GHCup install.

---

### Phase 8 - Public repo bootstrap (v38-v42, August 2026)

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
probes still failed. The cause was never established.

This entry originally blamed a missing libc++abi in the Xcode 26
macOS SDK. That is wrong, and the correction belongs here rather
than buried in a later phase: MacOSX26.5.sdk ships
`usr/lib/libc++abi.tbd`, and the probe's FIRST candidate
(`c++ c++abi`) links cleanly against it, as does
`c++ c++abi pthread`. Only `c++ cxxrt` fails, and cxxrt is a
FreeBSD library that was never expected on Darwin. So the probe had
a working candidate available and still failed, for a reason this
log does not know. The one gap in the check: it was run against
Xcode 26.5 locally, while the failing runs used the runner's
Xcode 26.6, whose macOS SDK sits behind an unversioned symlink.

Fix: pre-seed the probe's documented escape hatch instead of fighting
it - export CXX_STD_LIB_LIBS="c++" (with empty LIB_DIRS and
DYN_LIB_DIRS), which fp_find_cxx_std_lib.m4 honors by skipping
detection entirely. Plain c++ is a truthful answer on Darwin:
linking `-lc++` alone succeeds, verified directly. SDKROOT stays for
the other host probes. Cache key bumped v41 -> v42.

This entry also used to call the probe's missing plain-c++ candidate
a GHC bug and queue it for upstreaming. That does not follow: the
candidate list already contains a combination that links, so a
missing fallback is not what failed here. Nothing about this probe
goes upstream until the actual failure is understood.

Result: **GREEN. ALL STEPS PASSED.** Run 31944695895 on commit
04b24cd: configure, full Hadrian build, install, portability patch,
verify (the installed compiler reports "version 9.8.4", "Target
platform: aarch64-apple-ios"), package, upload. The first green build
on an Xcode 26 image - five iterations after the runner image drift
began (v38 TLS floor, v39 posix_spawn branch, v40 bindist toolchain,
v41 disproved sysroot theory, v42 pre-seeded C++ std lib). Toolchain
published as Release v42.

---

### Phase 9 - Port to GHC 9.14.1 (August 2026)

GHC 9.14 is the first LTS line, and every flag and patch was re-derived
against a pristine 9.14.1 tree before the workflow was touched. That
analysis is long and is its own document:
[`porting-9.14.md`](porting-9.14.md). It is a port analysis rather than
a build log, which is why it does not live here.

What it concluded, in short: patches 5 -> 2 (001, 002 and 004 retired,
numbers not reused), the libffi tarball repack retired because 3.5.2
fixed the Mach-O CFI construct that actually broke 3.4.6, Homebrew LLVM
dropped with it, `CONF_CC_OPTS_STAGE1` replaced by STAGE2 because 9.14
substitutes nothing into the former, boot GHC 9.12.2, and
`host-fix-rts-darwin.sh` deleted because the redundant `-Wl,-U` was
removed upstream in 9.12.1.

Three defects were found by reading source before any 9.14 build ran,
and all three would have failed a run or shipped a broken artifact:
the versionless LLVM triple that silently selects clang's iOS 7 default,
the `docs` phony that `binary-dist-dir` needs unconditionally, and the
`bin/` wrappers that have carried the build-machine prefix since v42.
All three are written up in the companion document.

**v45** - Two dead runs before green, both at the RTS `cabal-configure`:

    clang: error: cannot specify -o when generating multiple output files
    clang: warning: no such sysroot directory: '--target=arm64-apple-ios15.0'
    `ios-cc' failed in phase `C Compiler'. (Exit code: 1)

The target description was never at fault - `default.target` held a
well-formed flag list and every generated `settings` was correct. The
corruption is specific to the RTS, which is `build-type: Configure`:
hadrian flattens the stage-1 cc flags into one
`--configure-option=CFLAGS=` string and includes the whole set TWICE.
`-isysroot` is the only two-token flag in it, so the duplicated pair is
the one thing that can be separated from its argument; clang then read
`--target=` as the sysroot and treated the orphaned SDK path as a second
input file, producing both errors at once.

Both duplicated flags were redundant. The target is injected by
`FP_CC_SUPPORTS_TARGET` from `bootstrap_llvm_target`, and the sysroot is
passed by the `ios-cc` wrapper on every invocation. `CONF_CC_OPTS_STAGE2`
now carries only `-D_DARWIN_C_SOURCE -Ddarwin_HOST_OS`. Diagnosing it
took a run with `-V` plus dumps of `default.target`, every generated
`settings`, and the RTS `config.log`, because guessing costs 25 minutes
a try.

Result: **GREEN. ALL STEPS PASSED.** Run 32531829270 - configure, the
full Hadrian build, install, portability patch, verify, package, upload.
The installed compiler reports version 9.14.1 and
`("LLVM target","arm64-apple-ios15.0")`, and the smoke object is arm64
with `platform 2` and `minos 15.0`. First green GHC 9.14.1
cross-compiler for `aarch64-apple-ios`.

---

## Patches (2 total, `cross-compiler/patches/`)

| # | File | What |
|---|------|------|
| 003 | `rts/ReportMemoryMap.c` | Guard `mach_vm.h` includes for iOS |
| 005 | `libraries/process/.../posix_spawn.c` | Guard both `addchdir` branches for iOS |

Retired by the 9.14 port, numbers not reused:

| # | File | Why it is gone |
|---|------|----------------|
| 001 | `hadrian/src/Oracles/Setting.hs` | 9.14 hadrian reads the typed OS, which is already `OSDarwin` for iOS |
| 002 | `libraries/Cabal/.../BuildPaths.hs` | Cabal now classifies the target as `OSX`, so `dllExtension` returns `dylib` |
| 004 | `hadrian/cabal.project` | Only existed to make patch 002 reach hadrian |

Plus:
- No libffi tarball repack from 9.14 on - libffi 3.5.2 fixed the Mach-O CFI
  construct that broke 3.4.6.
- `cross-compiler/host-fix-rts-darwin.sh` was deleted by the 9.14 port; the
  underlying flag was removed upstream in GHC 9.12.1 (Phase 7 said 9.10;
  corrected in the port document).
