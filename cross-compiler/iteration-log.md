# GHC iOS Cross-Compiler - Iteration Log

## Context
Target: Build GHC 9.14.1 cross-compiler for `aarch64-apple-ios` on macOS (GitHub Actions).
Output: A working `aarch64-apple-ios-ghc` that compiles Haskell to native ARM64 iOS binaries.
CI: `.github/workflows/cross-compiler.yml` (manual dispatch, `macos-latest`)
Timeline: v1-v37 over the winter of 2025-2026 (first green 2026-03-07), host-GHC fixes April 2026, v38-v42 August 2026 against newer Xcode images, port to 9.14.1 (Phase 9) August 2026.

Phases 1-8 built and maintained the toolchain on GHC 9.8.4. Phase 9 ports it to
9.14.1, the first LTS line. Everything before Phase 9 describes the 9.8.4 build
and is kept verbatim as history: where a 9.8.4-era statement no longer holds for
9.14, Phase 9 says so rather than editing the original entry.

Nobody had documented a working GHC 9.8 iOS cross-compiler build from scratch.
This log records every failure and fix: the original bootstrap iterations
(v1-v37), then the maintenance entries that keep the build green on newer
Xcode images (v38+). Commit hashes in v1-v37 reference nova-kit's private
tree, where this work originally lived; from v38 onward every run is in
this repo's public Actions history, and the whole thing is reproducible
by dispatching the workflow. Release tags continue this numbering, but
only compiler-build failures get entries - releases v43 and v44 have no
matching entries; their story is in the release notes and commit
history, which is why the 9.14 port's first dispatch is v45.

---

## Key Decisions

Current as of the 9.14.1 port. Superseded 9.8.4-era decisions are marked; the
reasoning that retired them is in Phase 9.

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

**v1** `7bc2d6a` - alex/happy install path conflicts. Fix: install outside repo dir.

**v2** `924019b` - Wrong working dirs, missing SDK flags. Fix: proper paths, `--target=aarch64-apple-ios`.

**v3** `5759760` - SDL2 not found (the early combined CI also built the framework's since-removed desktop SDL2 shell - never a GHC dependency), `./boot` fails on pre-booted tarball. Fix: install SDL2, skip boot.

**v4** `b73c014` - Obsolete `--with-clang` flag rejected. Fix: use `CC=` instead.

**v5** `0de7b24` - Configure misparses inline CC flags. Fix: wrapper script that embeds `-target` and `-isysroot`.

**v6** `9741c6d` - Missing CXX wrapper, heredoc whitespace, isysroot not passed. Fix: add CXX wrapper, fix heredoc.

**v7** `baa3bb5` - `perf-cross` flavour doesn't exist in GHC 9.8. Fix: use `quick` flavour.

**v8** `4c53e9e` - LD path not set (the old combined CI also shuffled framework modules here - not GHC work). Fix: add LD path.

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
Target: `HAVE_AS_CFI_PSEUDO_OP`.
Result: **Failed** - that is the C `#define` configure emits, not the cache variable the test consults.

**v24** `e42d460` - Try `libffi_cv_as_cfi_pseudo_op` (autoconf convention).
Result: **Failed** - still wrong variable name.

**v25** `d5815f1` - Debug: grep the actual configure script for the CFI variable.
Result: Found it - `gcc_cv_as_cfi_pseudo_op` (libffi uses GCC-style naming).

**v26** `e4fc950` - `gcc_cv_as_cfi_pseudo_op=no` in patched tarball.
Result: **Passed libffi!** New error: `pthread_setname_np` undeclared.

---

### Phase 5 - Darwin/iOS Platform Detection (v27-v31)

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
Result: **Failed** - sed matched `#if` (line 17) but missed `#elif` (line 75). The verify grep was also still checking the old macro name.

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

### Phase 9 - Port to GHC 9.14.1 (August 2026)

GHC 9.14 is the first LTS line, with point releases expected through roughly
summer 2028; 9.12 was skipped entirely. Issue #4 tracks the port. 9.14.1 is
pinned because 9.14.2 was still at rc1 when this landed.

Every flag and patch was re-checked against a pristine 9.14.1 tree before the
workflow was touched. Findings below are from source unless marked otherwise;
v45 is the first dispatch and has not run.

#### iOS is now typed as Darwin

GHC has always kept two representations of the target OS: a loose string from
`m4/ghc_convert_os.m4`, which still maps `ios|watchos|tvos` to `"ios"`, and a
typed `OS` ADT value from `checkOS` in `m4/fptools_set_haskell_platform_vars.m4`,
which folds `darwin|ios|watchos|tvos` into `OSDarwin`. There is no iOS
constructor in the ADT and there never was.

In 9.8.4 hadrian read the STRING, which is the entire reason patch 001 existed:
`isOsxTarget = anyTargetOs ["darwin"]` did not match `"ios"`, iOS registered as
non-Apple, and the RTS link died on `ld: unknown options: -zorigin` (v32). In
9.14 hadrian reads the TYPED value out of `hadrian/cfg/default.target`, so
`isOsxTarget = anyTargetOs [OSDarwin]` is already True for `aarch64-apple-ios`
with no patch. Patch 001 is not merely unnecessary, it is inexpressible: the
function no longer takes strings.

The collapse is NOT total, and the split matters:

- Shell/CPP side still says iOS at the top level. `GHC_CONVERT_OS` yields
  `TargetOS=ios`, and `--target=aarch64-apple-ios` still names the install
  prefix and the binary. The RTS's own platform macros are a separate question:
  9.14 moved `ghcplatform.h` generation into `rts/configure`, which derives
  `HostOS` from the `--host` triple Cabal passes it (`rts/configure.ac:77-78`,
  `rts/ghcplatform.h.top.in`). Cabal takes that triple from `ghc --info`, which
  now reports `-darwin`, so `darwin_HOST_OS` is the likely define where 9.8.4
  produced `ios_HOST_OS`. UNVERIFIED - it needs a run to settle. The workflow
  keeps forcing `-Ddarwin_HOST_OS` because that is the correct answer under
  either resolution. Patch 003 is unaffected either way: its guard fires on the
  clang builtin, not on the platform macro.
- Haskell side says Darwin. `targetPlatformTriple` RECONSTRUCTS the triple from
  the typed value (`utils/ghc-toolchain/src/GHC/Toolchain/Target.hs:88`), so the
  reported platform string becomes `aarch64-apple-darwin`.

The reported triple reaches the installed artifact by a longer route than
expected: hadrian generates `mk/project.mk` from `targetPlatformTriple`
(`Rules/Generate.hs:399-411`), the bindist Makefile rebuilds `lib/settings` at
install time from that (`hadrian/bindist/Makefile:120`), and GHC reports it as
`Target platform`. The old verify assertion greps for `aarch64-apple-ios` and
would fail on a perfectly correct build.

What does NOT change: `TargetPlatformFull` is `target_alias`, the literal
uncanonicalized `--target` string (`configure.ac:402-408`), and that is what
`crossPrefix` uses. The binary is still `aarch64-apple-ios-ghc` and the install
layout is still `lib/aarch64-apple-ios-ghc-<version>/lib`.

Downstream consequence: Cabal derives its target platform from `ghc --info`.
9.8.4 parsed `aarch64-apple-ios` to `IOS`; 9.14 parses `aarch64-apple-darwin` to
`OSX`. In any consumer package `os(ios)` becomes false, `os(darwin)` and
`os(osx)` become true, and Cabal's `$abi` install directory changes from
`aarch64-ios-ghc-<ver>` to `aarch64-osx-ghc-<ver>`. Nothing errors.

It also flips `rts.cabal`'s `if os(osx)` block ON for this target, which Phase 7
explicitly records as being OFF on 9.8.4. In 9.14 that block is only
`-Wl,-search_paths_first`, so the effect is benign - but the invariant Phase 7
states no longer holds.

#### Patches: 5 -> 2

- **001 retired.** See above.
- **002 and 004 retired.** The v34/v35 `.so` vs `.dylib` failure happened because
  Cabal classified the target as `IOS` and `dllExtension` fell through to `"so"`.
  With the target now classified `OSX`, `dllExtension` returns `"dylib"`, which
  matches what hadrian builds. The machinery is all still present - Cabal still
  has an `IOS` constructor, `dllExtension` still has no `IOS` case, hadrian still
  installs through Cabal's Copy step - the failure is simply no longer reached.
  Derived, not observed. If wrong, the failure is loud and specific
  (`libHSrts-1.0.3-ghc9.14.1.so: copyFile: does not exist` during
  `Copy package 'rts'`) and both patches come straight back.
- **003 and 005 unchanged, byte-for-byte.** Regenerating them against pristine
  9.14.1 produces files identical to the ones already in the repo; hunk headers
  do not even move across three majors. Both apply at `--fuzz=0`. Both were
  re-verified as still necessary by compiling minimal reproductions against the
  iPhoneOS 26.5 SDK: unpatched, `mach/mach_vm.h:1: #error mach_vm.h unsupported`
  and `posix_spawn_file_actions_addchdir_np is unavailable: not available on iOS`.

Numbers are not renumbered: the log cross-references patches by number
throughout, and closing the gaps would invalidate every one of those
references.

The patch-005 assertion was tightened from the `_NP` branch alone to requiring
both branches. v39 established that current SDKs declare the standardized
non-`_np` variant too, and that autoconf's link probe defines `HAVE_*` for both
because it supplies its own prototype and bypasses the availability attribute -
so the FIRST branch is the one that fires. The old assertion checked the branch
that no longer matters.

#### libffi: the workaround is retired, and the recorded root cause was wrong

9.14 vendors libffi 3.5.2 (9.8.4 had 3.4.6). The tarball repack step is deleted:
3.5.2's `src/aarch64/sysv.S` builds clean for `arm64-apple-ios` with CFI
ENABLED under both Apple clang 21 and Homebrew LLVM 22, verified by configuring
and building the library the way hadrian does.

Phases 3 and 4 attribute the original breakage to arithmetic CFI expressions
and to trailing semicolons from macro expansion. That diagnosis does not
reproduce on today's toolchains: both constructs assemble fine in isolation on
both compilers, and the arithmetic expressions are still present in 3.5.2. The
construct that actually fails is `.cfi_startproc` emitted BEFORE the global
function label on Mach-O; 3.5.2 moved it after `CNAME(...)` at three sites, and
applying only that move to 3.4.6 makes it assemble with the semicolons and the
arithmetic left untouched. 3.4.6 fails identically on BOTH compilers, which also
undercuts the "Apple's assembler rejects it, upstream LLVM handles it" framing
in v15 and in the README.

Two consequences. Homebrew LLVM loses its only justification and is dropped:
the wrappers now use Apple clang via `xcrun`, which makes the build compiler the
same one the shipped `ios-cc` wrapper invokes. And libffi now emits real
unwind data (`__eh_frame`, `__compact_unwind`) into the RTS on this target for
the first time, which is a behaviour change rather than just a removed
workaround.

A related 9.14 change resolves itself for the same reason as 002/004:
`Rules/Rts.hs` dropped its `not . wayUnit Dynamic` filter and now wants a libffi
library file for every way, and libtool refuses to build any shared library for
`--host=aarch64-apple-ios`. But hadrian now passes libffi the reconstructed
`aarch64-apple-darwin` triple, so libtool does build the dylib and the
requirement is satisfied.

#### CONF_CC_OPTS_STAGE1 is dead, and fails silently

`CONF_CC_OPTS_STAGE1` and `CONF_GCC_LINKER_OPTS_STAGE1` are no longer
substituted by any config template and hadrian never reads them. In 9.14 the
stage-1 (target) toolchain is described by `hadrian/cfg/default.target`, which
configure generates from `CONF_CC_OPTS_STAGE2` / `CONF_GCC_LINKER_OPTS_STAGE2`.
Passing the 9.8 values would be accepted by the shell and discarded, taking the
iOS target, sysroot and both Darwin defines with them.

The v38 mechanism itself is unchanged: configure still prepends its own derived,
unversioned `--target=arm64-apple-ios`, so the versioned override still has to
land after it. It just has to live in the STAGE2 variable now. The configure
step asserts `arm64-apple-ios15.0` actually reached `default.target` rather than
trusting that an unrecognized variable was honoured.

`ghc-toolchain` exists in 9.14 but `--enable-ghc-toolchain` defaults to NO and
it runs only as a non-fatal validation diff, so configure remains authoritative.

#### Bootstrap and toolchain pins

- **Boot GHC 9.8 -> 9.12.2.** configure accepts 9.6 or newer, but hadrian ships
  bootstrap plans only for 9.10.x and 9.12.x, and under `hadrian/cabal.project`'s
  pinned index-state (2025-01-27) a 9.10 boot compiler forces cabal to rebuild
  directory, process, file-io and Cabal from Hackage. A `ghc --numeric-version`
  assertion was added because configure resolves its boot compiler through
  `WithGhc` while `hadrian/build-cabal` independently takes `GHC` off PATH; if
  those disagree the build configures against one stage0 and compiles against
  another.
- **happy 2.2 -> 2.1.7.** configure requires `>= 2.0.2 && < 2.2`. A release
  tarball ships pre-generated parsers so the check never runs, but an
  out-of-bounds pin is not worth carrying. alex 3.5.4.2 is unchanged and in
  bounds.
- **Homebrew LLVM dropped.** See libffi above. Two latent defects went with it:
  `--with-llc=` and `--with-opt=` were never configure options in 9.8.4 OR
  9.14.1 - they are `LLC`/`OPT` precious variables, and autoconf was warning
  "unrecognized options" and ignoring them all along. And `llvm@22` sat outside
  the accepted LLVM range in both releases (`[11,16)` in 9.8.4, `[13,21)` in
  9.14.1), so `llc`/`opt` were rejected regardless; the pin only ever supplied
  clang.

#### Install and packaging

- The C++ std lib probe workaround from v42 STAYS. `fp_find_cxx_std_lib.m4` in
  9.14.1 still tries only `c++ c++abi`, `c++ c++abi pthread` and `c++ cxxrt`,
  with no plain-`c++` fallback, and current macOS SDKs still ship no linkable
  libc++abi. The `CXX_STD_LIB_LIBS` escape hatch still short-circuits detection.
- The v41 rule still applies: the bindist configure is a HOST configure and must
  not be handed the cross toolchain. A related constraint, stated correctly here
  after an earlier draft got it backwards: `MOVE_TO_FLAGS` exists to undo
  autoconf 2.70+ emitting `CC="clang -std=gnu11"`, so `CC` must be a single path
  with no embedded arguments. That is why the iOS flags live in a wrapper script
  rather than being packed into `CC`.
- **The portability step needed repair, not a version bump.** The wrapper
  directory moved: 9.8 wrote into `$topdir/bin`, but hadrian no longer produces
  a `lib/bin` at all and 9.14's settings refer to `$topdir/../bin` (the sibling
  directory that already holds the real binaries). The old step would have died
  on a missing directory. `ld command` and `ld flags` were removed from settings
  entirely - GHC computes `ld_prog` from `cc_prog` regardless - so that sed and
  the `ios-ld` wrapper were dead weight and are gone. Three new keys appear that
  the bindist configure fills with the HOST compiler: `CPP command`,
  `C-- CPP command` and `JavaScript CPP command`. The first two are now
  rewritten; left alone they ship a cross-compiler that preprocesses with macOS
  headers. `JavaScript CPP command` is left alone deliberately - it is only
  consulted by the JS backend.
- Each settings key is now asserted individually. The 9.8 verification used one
  `grep -E` with alternatives, which exits 0 when any single alternative matches
  and would therefore hide a key that vanished in a future GHC.
- The verify gate no longer proves iOS-ness via the platform triple, since that
  now says `darwin`. It asserts the exact new triple (so a future change is
  loud), asserts `LLVM target` is `arm64-apple-ios15.0` (see the deployment
  target section below), and checks the smoke object's Mach-O load commands
  directly: `platform 2` present, `platform 1` absent, `minos 15.0` set. That is a stronger check than the string it replaces - it proves the
  shipped wrapper produced iOS objects rather than that a settings field says so.

#### host-fix-rts-darwin.sh retired, with a correction

The script is deleted. 9.14.1's `rts/rts.cabal` darwin block is only
`-Wl,-search_paths_first`; `fd_set_overflow` appears nowhere in the tree, and
9.14 additionally removed `-Wl,-undefined,dynamic_lookup` from the RTS conf
(#26166, replaced by the `RtsToHsIface` indirection). Against any 9.12+ host the
script would report "already patched" and do nothing.

Correction: the script header and Phase 7 both state the flag was fixed upstream
in GHC 9.10. That is wrong. It ships in 9.10.1, 9.10.2 and 9.10.3, and was
removed in 9.12.1. Phase 7 is left as written - it is dated history - so the
correct version lives here. Anyone still running a host GHC older than 9.12 can
take the script from the 9.8.4-era tags.

One standing gap, pre-existing rather than new: GHC's two Apple-linker-warning
suppressors (`-Wl,-no_warn_duplicate_libraries`, `-Wl,-no_fixup_chains`) are
gated on `case $target in *-darwin)`, which `aarch64-apple-ios` does not match,
so the cross-compiler's linker opts get neither. Phase 7 records that nova-kit's
device link bypasses the cross GHC's link path entirely, which would hide it.
Whether it produces real noise downstream is unverified.

#### The versionless LLVM triple, and clang's iOS 7 default

Found before v45 ran, by tracing the flag path through the bindist rather
than by a build failure.

`installTo` (`hadrian/src/Rules/BinaryDist.hs`) runs the bindist's own
configure with nothing but `--prefix`. That configure calls
`FP_CC_SUPPORTS_TARGET`, which probes the host cc with
`--target=$LlvmTarget` and, on success, PREPENDS `--target=$LlvmTarget` to
`CONF_CC_OPTS_STAGE2` and `CONF_GCC_LINKER_OPTS_STAGE2`. `FP_SETTINGS`
copies those verbatim into `SettingsCCompilerFlags` and
`SettingsCCompilerLinkFlags`, and `hadrian/bindist/Makefile` writes them
into the installed `settings`. The probe succeeds on Xcode 26.5.

`LlvmTarget` is versionless: `GHC_LLVM_TARGET` assembles
`$cpu-$vendor-$os`, and the OS half comes from `GHC_CONVERT_OS`, which
folds `ios` to a bare `ios`. GHC passes `C compiler flags` AFTER the
wrapper's own `-target arm64-apple-ios15.0`, and clang honours the LAST
`-target`, so the shipped compiler would have built everything at clang's
versionless default of iOS 7.0. Measured directly on Xcode 26.5:

    -target arm64-apple-ios15.0                           ->  LC_BUILD_VERSION, platform 2, minos 15.0
    -target arm64-apple-ios15.0 --target=arm64-apple-ios  ->  LC_VERSION_MIN_IPHONEOS, version 7.0

There is no native thread-local storage at that floor, so this is v38's
failure class resurfacing in the SHIPPED toolchain rather than in the
build. The verify gate greps for `platform 2`, which an iOS 7 object does
not carry at all, so the run would have died at its very last step
reporting "smoke object is not an iOS build" - true, and pointing nowhere
near the cause.

The effect is new in 9.14. The installed 9.8.4 artifact carries
`C compiler flags = -Qunused-arguments`, with no `--target` at all.

Fixed at the origin. `bootstrap_llvm_target` is READ by
`GHC_LLVM_TARGET_SET_VAR` and ASSIGNED by nothing anywhere in the tree, so
configure now sets it and every consumer is correct by construction:
`default.target`, the bindist configure's injected `--target`, and the
settings file. It does not regress the `llvm-targets` lookup - that table
is keyed on `aarch64-apple-ios` while this value has always been
`arm64-apple-ios`, so the lookup missed already and `-fllvm` was never
viable on this target.

Three guards on top, because an origin fix that silently stops working is
the exact failure this entry exists to prevent:

- the configure step asserts the versioned triple reached `tgtLlvmTarget`
  in `default.target`, so a regression costs two minutes rather than the
  whole run;
- the packaging step normalises any `--target=arm64-apple-ios*` in the
  three settings flags keys to the versioned form, and refuses to ship a
  versionless one;
- the verify gate asserts `minos` on the smoke object, not just its
  platform. That is the assertion that would have caught this.

The wrapper keeps its own copy of the versioned target rather than being
thinned to a bare `xcrun` call: `Haskell CPP command`, `CPP command` and
`C-- CPP command` all point at `ios-cc` and their flags keys carry no
target of their own, so a thin wrapper would have preprocessed at clang's
default triple.

The floor itself is now a single `IOS_MIN` job variable that every
consumer derives `arm64-apple-ios${IOS_MIN}` from. It had been spelled as
a literal in nine places, which is how a floor bump silently half-lands.
nova-kit mirrors the same name in its `ci.yml`.

The real fix belongs upstream and is tracked in #3. `GHC_CONVERT_OS`
already accepts a versioned `darwin*` - its own comment reads "e.g.
aarch64-apple-darwin14" - but matches `ios|watchos|tvos` exactly, and
`GHC_LLVM_TARGET` then drops the Apple OS version. That is harmless on
macOS, where clang defaults to the SDK's version, and silently selects
iOS 7 on iOS, tvOS and watchOS. GHC has no concept of an Apple deployment
target anywhere in the tree, so the upstream change is a new option rather
than a repair. A local patch 006 introducing one was considered and
rejected: the release tarball ships a pre-generated `configure` (autoconf
2.71) with these macros already inlined at five sites, so patching the m4
is inert without regenerating it, and Homebrew's autoconf is 2.72.
Upstream regenerates `configure` as part of its build, so the option is
clean there and messy here.

#### Docs are mandatory for `install` in 9.14, and would have killed the run

Found by the pre-dispatch audit, not by a build. This one is a regression
between 9.8.4 and 9.14.1 and is invisible to every previous green run.

`hadrian/build install` runs `phony "install"`, which needs
`binary-dist-dir`. In 9.14 that rule builds its target list as
`lib_exe_targets ++ doc_target ++ other_targets` with
`doc_target = ["docs"]` UNCONDITIONALLY
(`hadrian/src/Rules/BinaryDist.hs:162,165,168`). The `CrossCompiling` flag
read three lines above it gates only `iserv_targets`, not docs. The
default doc set is `Set.fromList [minBound..maxBound]`
(`hadrian/src/CommandLine.hs:58`) over
`Haddocks | SphinxHTML | SphinxPDFs | SphinxMan | SphinxInfo`, and `quick`
does not override `ghcDocs`. `sphinx-build`, `xelatex`, `makeindex` and
`makeinfo` are NOT in `Builder.hs`'s `isOptional` list (only Objdump,
Happy, Alex, Ranlib and JsCpp are), so an unset tool is a hard
`Non optional builder "..." is not specified` error rather than a skip.
configure's `BUILD_SPHINX_HTML/PDF/INFO` are never plumbed into
`hadrian/cfg/system.config.in`, so there is no graceful degradation path.

A stock `macos-latest` image ships no Sphinx and no TeX Live, so the
Install step would have aborted after the whole ~45 minute build, before
`installTo` ever ran the bindist configure - which also means the step's
`find _build/bindist -name config.log` diagnostic would have printed
nothing, and the cache Save step that sits after Install would have been
skipped. Every retry pays the full build again.

9.8.4's `binary-dist-dir` rule had no doc target at all; its body was
`need (lib_targets ++ map snd (bin_targets ++ iserv_targets))`. The
corroboration is in the shipped artifact: `~/ghc-ios/share/doc/ghc-9.8.4/`
is empty, there is no `ghc.1`, and every package doc dir contains only
LICENSE. No green 9.8.4 run ever built a doc target, so the workflow's
history says nothing about whether this image can.

Fixed by passing `--docs=none` to BOTH hadrian invocations
(`readDocsArg "none"` sets the target set to empty, so
`Rules/Documentation.hs` needs nothing and the `docs` phony is a satisfied
no-op). It is only load-bearing on `install` - the plain build's
`topLevelTargets` has no doc target - but hadrian persists nothing between
invocations, so the two commands have to agree or install re-plans with a
different target set.

#### The C++ command was left pointing at the host

Same audit. The portability step rewrote `C compiler command` and the
three CPP commands but not `C++ compiler command`, which the bindist
configure fills with the host `g++`. On its own that was survivable
because 9.8.4 shipped the same way. It stops being survivable once the
deployment-target fix above forces `C++ compiler flags` to
`--target=arm64-apple-ios15.0`: the settings then name a macOS compiler
and an iOS target in the same breath, so any package with `cxx-sources`
or `objcxx-sources` compiles iOS-targeted objects against macOS SDK
headers. clang treats a sysroot mismatch as a warning, not an error, so
it would have been silent.

The artifact now ships an `ios-cxx` wrapper next to `ios-cc` and points
the key at it. Scope was never nova-kit's own shell - the C, assembler,
Obj-C and link paths all route through `pgm_c` and were already
redirected - but the toolchain is published, and shipping a
self-contradictory settings file is not something to leave for a consumer
to discover.

#### Open risks going into v45

- 002/004 being droppable is a source derivation across m4, hadrian, the
  settings file and Cabal. One wrong link flips it. Loud failure, patches ready.
- The bindist configure now runs `bin/ghc-toolchain-bin`, which hadrian does not
  appear to build for a cross bindist. Its exit status looks discarded by
  design, but this is unproven and is the most likely new Install-step failure.
- `FP_PROG_CC_LINKER_TARGET` and `CHECK_MERGE_OBJECTS` are new hard-failure
  surfaces in the 9.14 configure, each with `AC_MSG_ERROR` paths that 9.8.4 had
  no equivalent of.
- The threaded RTS now uses `extern __thread` unconditionally on Darwin, having
  dropped the `pthread_getspecific` fallback. Expected to be fine on iOS 15 with
  native TLS, but it is a behaviour change on this target.

---

## Patches (2 total, `cross-compiler/patches/`)

| # | File | What |
|---|------|------|
| 003 | `rts/ReportMemoryMap.c` | Guard `mach_vm.h` includes for iOS |
| 005 | `libraries/process/.../posix_spawn.c` | Guard both `addchdir` branches for iOS |

Retired by the 9.14 port (Phase 9), numbers not reused:

| # | File | Why it is gone |
|---|------|----------------|
| 001 | `hadrian/src/Oracles/Setting.hs` | 9.14 hadrian reads the typed OS, which is already `OSDarwin` for iOS |
| 002 | `libraries/Cabal/.../BuildPaths.hs` | Cabal now classifies the target as `OSX`, so `dllExtension` returns `dylib` |
| 004 | `hadrian/cabal.project` | Only existed to make patch 002 reach hadrian |

Plus:
- No libffi tarball repack from 9.14 on - libffi 3.5.2 fixed the Mach-O CFI
  construct that broke 3.4.6 (Phase 9).
- `cross-compiler/host-fix-rts-darwin.sh` was deleted by the 9.14 port; the
  underlying flag was removed upstream in GHC 9.12.1 (Phase 7, corrected in
  Phase 9).
