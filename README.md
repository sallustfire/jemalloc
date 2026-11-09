# Bazel build of jemalloc

This is a minimal fork of [jemalloc](https://github.com/jemalloc/jemalloc) to maintain a set of overlay files for 
building jemalloc with [Bazel](https://bazel.build/). 

The upstream jemalloc build performs a number of feature detection steps in the configure script. All of which need to be
statically declared via platform and compiler constraints. Some of these have been made configurable under
//settings, but the list is not exhaustive. An attempt has been made to default to logical values assuming the most
common configurations. But these assumptions cannot satisfy all cases in the wild and may break on some systems. 
Contributors are encouraged to open MRs to add more configuration options to //settings/platform.

## Usage

See the [examples/BUILD.bazel](examples/BUILD.bazel) file for examples of how to consume `@jemalloc`.

## Notes

- **//settings/flags:jemalloc_prefix (--with-jemalloc-prefix):** As in the make build, this defaults to "je_" on macOS
 and Windows and to no prefix elsewhere. On macOS jemalloc is designed to replace malloc by overlaying the default
 malloc zone rather than by exporting malloc, free and so on; see Known Issues for why this build does not do so yet. A
 prefix renames the public API, malloc_conf, /etc/malloc.conf and MALLOC_CONF as INSTALL.md's --with-jemalloc-prefix
 describes. To call the API by its je_* names (je_mallctl, je_mallocx, ...) under any prefix, define
 JEMALLOC_NO_DEMANGLE before including jemalloc/jemalloc.h. Set the flag, or jemalloc()'s jemalloc_prefix, to choose a
 prefix explicitly. The flag defaults to "__auto__", which only jemalloc's own transition resolves, so a select() on the
 flag outside it sees "__auto__", and the flag provides no $(JEMALLOC_PREFIX). Set the prefix explicitly where a
 consumer needs to know it.
- **//settings/platform:lg_vaddr:** Defaults to the hard-coded cross compilation value of 57 from the configure script.
 If targeting a 32-bit platform, this should be explicitly set.
- **glibc:** Assumes a modern version. If jemalloc is compiled to be the default allocator on linux, it assumes glibc
 and some publicly exposed symbols can be wrapped: __malloc_hook, __realloc_hook, __free_hook, __memalign_hook.
 However, they are deprecated since glibc 2.34. The jemalloc source likely needs to be updated to reflect this.

Platform configurations that have defaults that are applied via transition.
- //settings/flags:enable_zone_allocator
- //settings/flags:jemalloc_prefix
- //settings/platform:glibc_overrides_support
- //settings/platform:lg_page
- //settings/platform:memalign_support
- //settings/platform:malloc_size_support
- //settings/platform:usable_size_const
- //settings/platform:valloc_support

## Fidelity with upstream

The upstream build generates several headers with shell, awk and sed scripts, run by configure and make on the host.
Here Bazel generates them from Starlark rules and a small C++ tool, so a module that depends on `@jemalloc` needs only
its C and C++ toolchain: no host shell, awk or sed. private_namespace.h comes from running the toolchain's `nm`, which
the tool can only do on POSIX hosts for now (see Windows under Known Issues).

The upstream scripts are kept, not replaced. Each generated header has a `fidelity_test` in
[tools/fidelity](tools/fidelity) that runs the unmodified upstream script, as configure.ac invokes it, on the
same inputs and with the same settings, and fails if the outputs differ. The scripts run with hermetic gawk, grep, sed
and coreutils, which are dev dependencies: they are fetched for this repository's tests and never for consumers. The
`upstream-oracle` CI job goes further, building the upstream release with configure and make and comparing every
script-generated header with the Bazel build's.

When upgrading jemalloc, a failing fidelity test means an upstream script changed and its Starlark counterpart must
follow.

## Validated Platforms

- Ubuntu 20.04 & 22.04
- Debian 10
- MacOS 15 (M3)

## Known Issues

- **Windows:** An effort to was made to translate upstream MSVC configuration, but it has not been validated and will 
    likely fail. Generating private_namespace.h also fails there: the tool that runs `nm` is not implemented on Windows.
- **FreeBSD:** An effort was made to translate existing autoconf feature detection to Bazel config settings, but no 
    attempt has been made to build on FreeBSD.
- **Centos 7:** Fails due to the lack of defining `JEMALLOC_MADV_FREE`. Though, the original build does not set it when 
    `MADV_FREE` is present. Supporting both and being faithful to the configure script would require an additional 
    platform setting.
- C++ compilation might be broken for LLVM around detecting libstdc++.
- **macOS:** Plain malloc does not reach jemalloc yet. The zone that replaces it is registered by a constructor in
    src/zone.c that nothing references, so linking the static archive leaves it out. The je_* API works.
    examples/test_8_malloc and test_9_malloc_config skip macOS until the zone is always linked.

## Contributing

Before contributing new versions or updates to the Bazel Central Registry, these contributions should be made as Merge 
Requests here:
  - Fork the repository targeting the existing BCR release branch (e.g `bcr-5.3.0`) for the jemalloc version or create 
    a new one 
  - Verify the that all tests pass on the supported platforms e.g. `bazel test //...`
  - Open a Merge Request
