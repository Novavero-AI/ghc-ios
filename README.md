<div align="center">
<h1>ghc-ios</h1>
<p><strong>A GHC 9.14 cross-compiler for aarch64-apple-ios.</strong></p>
<p>Two patches and a CI bootstrap that turn the stock GHC source tarball into an App-Store-compatible Haskell toolchain on a standard macOS runner - with the complete failure-by-failure build log.</p>

[![CI](https://github.com/Novavero-AI/ghc-ios/actions/workflows/cross-compiler.yml/badge.svg)](https://github.com/Novavero-AI/ghc-ios/actions/workflows/cross-compiler.yml)
![GHC](https://img.shields.io/badge/GHC-9.14-purple)
[![Release](https://img.shields.io/github/v/release/Novavero-AI/ghc-ios)](https://github.com/Novavero-AI/ghc-ios/releases/latest)
![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)

</div>

---

Every prior GHC iOS cross-compiler was a one-shot - see [Prior art](#prior-art). None was reproducible from a stock runner, App-Store-compatible, and documented failure by failure. This one is all three, in executable form: dispatch the workflow and it takes GHC 9.14.1 from source tarball to a packaged `aarch64-apple-ios-ghc` that compiles Haskell to native ARM64 static libraries.

It powers [nova-kit](https://novavero.ai), our pure-Haskell iOS framework. Full write-up: [Haskell on your iPhone](https://novavero.ai/blog/haskell-on-your-iphone). Every failure on the way: [`cross-compiler/iteration-log.md`](cross-compiler/iteration-log.md).

The work here predates this repo: it was done in nova-kit's private tree over the winter of 2025-2026, reaching the first green build in March 2026 on GHC 9.8.4, and was extracted here for release. Phase 9 of the log ports it to 9.14.1, the first LTS line.

## Contents

```
.github/workflows/cross-compiler.yml   bootstrap: source -> patched -> built -> packaged artifact
cross-compiler/patches/                2 unified diffs, applied to ghc-9.14.1-src via patch -p1
cross-compiler/iteration-log.md        every failure and fix, v1 onward
cross-compiler/porting-9.14.md         the 9.14 port, derived from source before it ran
```

## The fixes

| # | Problem | Fix | Where |
|---|---------|-----|-------|
| 1 | `mach_vm.h` is `#error` on iOS (and the obvious `TARGET_OS_IPHONE` guard fails silently) | guard on `__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__` | `patches/003` |
| 2 | `posix_spawn`'s `addchdir` file actions are unavailable on iOS, but autoconf's link probe defines `HAVE_*` for both variants anyway | guard both branches | `patches/005` |
| 3 | iOS is Darwin, but GHC does not hand the RTS the Darwin defines it gates its Mach code on | `-Ddarwin_HOST_OS -D_DARWIN_C_SOURCE` plus a versioned `--target` in `CONF_CC_OPTS_STAGE2` | workflow step |
| 4 | GHC's C++ std lib probe has no plain-`c++` candidate, and current macOS SDKs ship no linkable `libc++abi` | pre-seed `CXX_STD_LIB_LIBS=c++` for the bindist configure | workflow step |
| 5 | The installed settings and wrappers carry build-machine paths, and 9.14's new CPP keys point at the host compiler | rewrite them to `$topdir`-relative `xcrun` wrappers | workflow step |

Three fixes that GHC 9.8 needed are gone in 9.14, retired rather than ported - Hadrian now recognizes the target as Apple on its own, Cabal computes `dylib` for it, and libffi 3.5.2 fixed the Mach-O CFI construct that broke 3.4.6. The reasoning is in the log's Phase 9.

## The build, in order

The workflow is the executable version of this recipe; to replicate it outside CI, follow the same order:

1. Install a boot GHC 9.12.2, cabal, automake/autoconf/libtool, and pinned `alex` + `happy`. 9.14 accepts a boot GHC as old as 9.6, but only 9.10.x and 9.12.x have shipped bootstrap plans, and 9.12.2 is the one that needs no Hackage rebuilds under Hadrian's pinned index-state.
2. Download `ghc-9.14.1-src` and verify its sha256 against the official `SHA256SUMS`.
3. Write `ios-cc`/`ios-cxx` wrappers: Apple clang via `xcrun`, with `-target arm64-apple-ios15.0 -isysroot <iOS SDK>` baked in.
4. Apply `cross-compiler/patches/003` and `005` with `patch -p1 --fuzz=0` and assert each landed.
5. Configure with `--target=aarch64-apple-ios`, the wrappers, and `-D_DARWIN_C_SOURCE -Ddarwin_HOST_OS --target=arm64-apple-ios15.0` in `CONF_CC_OPTS_STAGE2`. It must be STAGE2: 9.14 describes the stage-1 target toolchain in `hadrian/cfg/default.target`, which is generated from the STAGE2 variables, and `CONF_CC_OPTS_STAGE1` is accepted and then ignored. The versioned target has to come after the unversioned one configure prepends, or newer clang assumes an iOS floor with no thread-local storage and refuses the threaded RTS.
6. Build with Hadrian: `--flavour=quick+native_bignum` (no GMP on iOS), `--flags=-libm --flags=-libdl` (both live inside `libSystem`), and `-L` for the in-tree libffi.
7. Install with the same flavour and flags - Hadrian persists nothing between invocations - plus `SDKROOT` and a pre-seeded `CXX_STD_LIB_LIBS=c++` for the binary-dist's host configure.
8. Patch the install for portability (`xcrun`-based `ios-cc`, `$topdir`-relative settings), then verify: a smoke `-staticlib` compile through the shipped wrapper must produce an arm64 static library whose Mach-O load commands say iOS.

## Building it

Prebuilt: the [latest Release](https://github.com/Novavero-AI/ghc-ios/releases/latest) is the packaged toolchain, with the run that built it named in the notes - download the tarball and unpack it to `~/ghc-ios`, or anywhere `$GHC_IOS` points. Releases are per-version; the GHC 9.8.4 releases remain available and frozen.

From scratch: fork or clone, then manually dispatch **Build GHC Cross Compiler (iOS)** under Actions. The workflow downloads `ghc-9.14.1-src`, patches it, builds with Hadrian on `macos-latest` (roughly an hour end to end), verifies, and uploads the toolchain as an artifact (artifacts expire after 30 days; pass the optional `release_tag` dispatch input to also publish the result as a durable GitHub Release). Unpack to `~/ghc-ios` or set `$GHC_IOS`. (The repo checkout and the installed toolchain are different things that share a default name - if you cloned this repo to `~/ghc-ios` itself, unpack the toolchain elsewhere and point `$GHC_IOS` at it.)

To use the toolchain you need Xcode with the iOS SDK. Nothing else: as of the 9.14 port the build no longer depends on Homebrew LLVM, because the libffi problem that justified it was fixed upstream.

## Using it

```sh
~/ghc-ios/bin/aarch64-apple-ios-ghc --version                          # 9.14.1
~/ghc-ios/bin/aarch64-apple-ios-ghc -staticlib -no-hs-main -o libapp.a App.hs
```

The output is an ARM64 static library: the app embeds it, calls `hs_init`, and reaches Haskell through `foreign export`. `-staticlib -no-hs-main` is the invocation shape nova-kit's build pipeline uses on every build. The final app link also needs the three RTS symbol overrides described under Scope.

### One thing to know before you port a downstream build

GHC 9.14 reports this toolchain's target platform as **`aarch64-apple-darwin`**, not `aarch64-apple-ios`. That is correct, not a misconfiguration: GHC's configure has always folded `darwin|ios|watchos|tvos` into a single `OSDarwin` value, and 9.14 reconstructs the reported triple from that typed value instead of echoing the configure triple the way 9.8 did. The compiler still targets iOS - `LLVM target` is `arm64-apple-ios15.0`, and the objects it emits carry the iOS platform load command.

The consequence is downstream and silent. Cabal derives its target platform from `ghc --info`, so:

- `os(ios)` conditionals in `.cabal` files become **false**
- `os(darwin)` and `os(osx)` conditionals become **true**
- Cabal's `$abi` install directory changes from `aarch64-ios-ghc-<ver>` to `aarch64-osx-ghc-<ver>`

Nothing errors; you just get a differently-configured build. Grep your packages for `os(ios)` before moving them to this toolchain. The binary name and install layout are unchanged.

## Scope

This is the compiler-side story. Running the GHC RTS well on a device needs three link-time overrides in the app itself: a no-op `mprotectForLinker` (iOS W^X), a memory-pressure-aware `osReserveHeapMemory` (GHC asks for 1 TiB of address space by default; iOS grants about 1 GB), and `os_log` routing for RTS diagnostics. Those are covered in the write-up and ship as part of nova-kit's platform shell.

## Prior art

The original `ghc-ios` scripts (GHC 7.x era) proved this was possible before going quiet. reflex-platform shipped iOS cross-compilation for years, pinned to GHC 8.10; in the Obelisk v2 discussion that support is [described as bitrotted](https://github.com/obsidiansystems/obelisk/pull/1139#issuecomment-4845448746), with both successor approaches dropping it. A [2022 guide on GHC's wiki](https://gitlab.haskell.org/ghc/ghc/-/wikis/Brief-Guide-for-Compiling-GHC-to-iOS) built a GHC 9.2.1 cross-compiler and ran it on a jailbroken iPhone: impressive, single-shot, and never carried forward. The `mac2ios` approach retags macOS Mach-O output as iOS instead of cross-compiling at all. This repo differs by being versioned, CI-reproducible on a stock runner, App-Store-compatible (no jailbreak entitlements), and documented failure by failure.

## Upstreaming

Several of these fixes are one-line guards that belong in GHC proper. The clearest is in `GHC_CONVERT_OS`: it accepts a versioned `darwin*` - its own comment reads "e.g. aarch64-apple-darwin14" - but matches `ios|watchos|tvos` exactly, so `GHC_LLVM_TARGET` drops the Apple OS version. That is harmless on macOS, where clang defaults to the SDK's version, and on iOS it silently selects clang's versionless default of iOS 7, which has no native thread-local storage. It affects iOS, tvOS and watchOS alike. If you work on GHC or Hadrian and have opinions about iOS as a target, open an issue.

## License

BSD-3-Clause. The patches are diffs against GHC and process sources, which are BSD-licensed by their respective authors.

---

<p align="center"><sub>BSD-3-Clause - <a href="https://github.com/Novavero-AI">Novavero AI Inc.</a></sub></p>
