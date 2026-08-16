<div align="center">
<h1>ghc-ios</h1>
<p><strong>A GHC 9.8 cross-compiler for aarch64-apple-ios.</strong></p>
<p>Five patches, one libffi fix, and a CI bootstrap that turn the stock GHC source tarball into an App-Store-compatible Haskell toolchain on a standard macOS runner - with the complete failure-by-failure build log.</p>

[![CI](https://github.com/Novavero-AI/ghc-ios/actions/workflows/cross-compiler.yml/badge.svg)](https://github.com/Novavero-AI/ghc-ios/actions/workflows/cross-compiler.yml)
![GHC](https://img.shields.io/badge/GHC-9.8-purple)
![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)

</div>

---

Nobody had documented a working GHC 9.8 iOS cross-compiler built from scratch. This repo is that documentation in executable form: dispatch the workflow and it takes GHC 9.8.4 from source tarball to a packaged `aarch64-apple-ios-ghc` that compiles Haskell to native ARM64 static libraries.

It powers [nova-kit](https://novavero.ai), our pure-Haskell iOS framework. Full write-up: [Haskell on your iPhone](https://novavero.ai/blog/haskell-on-your-iphone). Every failure on the way, with commit hashes: [`cross-compiler/iteration-log.md`](cross-compiler/iteration-log.md).

The work here predates this repo: it was done in nova-kit's private tree over the winter of 2025-2026, reaching the first green build (v37) in March 2026, and was extracted here for release. Log entries v38 onward document keeping that build green against newer Xcode runner images.

## Contents

```
.github/workflows/cross-compiler.yml   bootstrap: source -> patched -> built -> packaged artifact
cross-compiler/patches/                5 unified diffs, applied to ghc-9.8.4-src via patch -p1
cross-compiler/iteration-log.md        every failure and fix, v1 onward
cross-compiler/host-fix-rts-darwin.sh  host-side fix for GHCup's darwin GHC 9.8
```

## The fixes

| # | Problem | Fix | Where |
|---|---------|-----|-------|
| 1 | Hadrian doesn't treat iOS as an Apple platform (GNU ld flags, wrong rpaths) | `isOsxTarget` includes `"ios"` | `patches/001` |
| 2 | Cabal names iOS shared libs `.so` | `dllExtension`: `IOS -> "dylib"` | `patches/002` |
| 3 | `mach_vm.h` is `#error` on iOS; the usual `TARGET_OS_IPHONE` guard fails silently without its header | guard on `__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__` | `patches/003` |
| 4 | Hadrian compiles against the boot GHC's Cabal, so fix 2 never takes effect | build Hadrian against in-tree Cabal | `patches/004` |
| 5 | `posix_spawn` `addchdir_np` is unavailable on iOS | conditional guard | `patches/005` |
| 6 | Apple's assembler rejects arithmetic in libffi's CFI directives; Hadrian re-extracts the vendored tarball over source patches | Homebrew LLVM clang + repack the tarball with `gcc_cv_as_cfi_pseudo_op=no` | workflow step |
| 7 | GHCup's host darwin GHC 9.8 ships a redundant `-Wl,-U` flag (warns on Xcode 15+) | idempotent `rts-*.conf` edit | `host-fix-rts-darwin.sh` |

Build configuration that matters: `--flavour=quick+native_bignum` (no GMP on iOS), `--flags=-libm --flags=-libdl` (both live inside `libSystem`), `-D_DARWIN_C_SOURCE -Ddarwin_HOST_OS` (iOS is Darwin, but GHC doesn't say so for cross targets), and a versioned deployment target (`--target=arm64-apple-ios15.0`) in the stage-1 C flags, without which newer clang rejects the thread-local storage the threaded RTS needs. Hadrian does not persist CLI settings between invocations: the install step needs the same flags and flavour as the build step, plus `SDKROOT` and a pre-seeded `CXX_STD_LIB_LIBS=c++` for the binary-dist's host configure - current Apple SDKs ship no separate linkable libc++abi, and the C++ probe has no plain-`c++` fallback.

## Building it

Prebuilt: [Release v42](https://github.com/Novavero-AI/ghc-ios/releases/tag/v42) is the packaged toolchain from the green from-scratch run - download the tarball and unpack it to `~/ghc-ios`, or anywhere `$GHC_IOS` points.

From scratch: fork or clone, then manually dispatch **Build GHC Cross Compiler (iOS)** under Actions. The workflow downloads `ghc-9.8.4-src`, patches it, builds with Hadrian on `macos-latest` (roughly an hour end to end), verifies, and uploads the toolchain as an artifact. Unpack to `~/ghc-ios` or set `$GHC_IOS`. (The repo checkout and the installed toolchain are different things that share a default name - if you cloned this repo to `~/ghc-ios` itself, unpack the toolchain elsewhere and point `$GHC_IOS` at it.)

To use the toolchain you also need Xcode with the iOS SDK, Homebrew LLVM (`brew install llvm`), and, if your host GHC comes from GHCup, one run of `./cross-compiler/host-fix-rts-darwin.sh` after each `ghcup install ghc`.

## Scope

This is the compiler-side story. Running the GHC RTS well on a device needs three link-time overrides in the app itself: a no-op `mprotectForLinker` (iOS W^X), a memory-pressure-aware `osReserveHeapMemory` (GHC asks for 256 GB of address space; iOS grants about 1 GB), and `os_log` routing for RTS diagnostics. Those are covered in the write-up and ship as part of nova-kit's platform shell.

## Prior art

The original `ghc-ios` scripts (GHC 7.x era) proved this was possible before going quiet. reflex-platform shipped iOS cross-compilation for years, pinned to GHC 8.10, and its maintainers [describe that support as bitrotted](https://github.com/obsidiansystems/obelisk/pull/1139#issuecomment-4845448746) today. A [2022 guide on GHC's wiki](https://gitlab.haskell.org/ghc/ghc/-/wikis/Brief-Guide-for-Compiling-GHC-to-iOS) built a GHC 9.2.1 cross-compiler and ran it on a jailbroken iPhone: impressive, single-shot, and never carried forward. The `mac2ios` approach retags macOS Mach-O output as iOS instead of cross-compiling at all. This repo differs by being versioned, CI-reproducible on a stock runner, App-Store-compatible (no jailbreak entitlements), and documented failure by failure.

## Upstreaming

Several of these patches are one-line guards that belong in GHC proper, and upstreaming is in progress. If you work on GHC or Hadrian and have opinions about iOS as a target, open an issue.

## License

BSD-3-Clause. The patches are diffs against GHC, Cabal, and process sources, which are BSD-licensed by their respective authors.

---

<p align="center"><sub>BSD-3-Clause - <a href="https://github.com/Novavero-AI">Novavero AI Inc.</a></sub></p>
