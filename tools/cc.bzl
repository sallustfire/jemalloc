"Project specific configuration of rules_cc"

_COPTS_GCC_COMPATIBLE = [
    "-Wall",
    "-Wextra",
    "-Wsign-compare",
    "-Wundef",
    "-Wno-format-zero-length",
    "-Wpointer-arith",
    "-Wno-missing-braces",
    "-Wno-missing-field-initializers",
    "-Wimplicit-fallthrough",
    "-pipe",
]

_COPTS_GCC = _COPTS_GCC_COMPATIBLE + ["-Wno-missing-attributes"]

_COPTS_MSVC_COMPATIBLE = [
    "/Zi",
    "/MT",
    "/W3",
    "/FS",
]

# The language standards jemalloc's sources are written in, configure.ac's
# preferred -std=gnu11 and -std=c++17. They are a property of these sources, so
# they are declared here rather than left to the toolchain's default. MSVC has
# no GNU C dialect, so C compiles there keep cl's default, as upstream's msvc/
# projects do.
CONLYOPTS = select({
    "@rules_cc//cc/compiler:clang-cl": [],
    "@rules_cc//cc/compiler:msvc-cl": [],
    "//conditions:default": ["-std=gnu11"],
})

CXXOPTS = select({
    "@rules_cc//cc/compiler:clang-cl": ["/std:c++17"],
    "@rules_cc//cc/compiler:msvc-cl": ["/std:c++17"],
    "//conditions:default": ["-std=c++17"],
})

# Platform and compiler COPTS consistent with configure/make
COPTS = ["-D_REENTRANT"] + select({
    "@rules_cc//cc/compiler:clang": _COPTS_GCC_COMPATIBLE + ["-Wshorten-64-to-32"],
    "@rules_cc//cc/compiler:gcc": _COPTS_GCC,
    "@rules_cc//cc/compiler:mingw-gcc": _COPTS_GCC,
    "@rules_cc//cc/compiler:msvc-cl": _COPTS_MSVC_COMPATIBLE,
    "@rules_cc//cc/compiler:clang-cl": _COPTS_MSVC_COMPATIBLE,
    "//conditions:default": [],
}) + select({
    # -fvisibility=hidden goes to compilers that take GCC's command line, for object formats that honour symbol
    # visibility (ELF, Mach-O, wasm). On PE/COFF, exports come from dllexport or .def files, so the compilers that
    # target only PE/COFF get nothing. The select keys on the compiler alone, so a GCC-style clang targeting Windows
    # still gets the flag, where it marks symbols hidden to no effect.
    # clang-cl takes MSVC's command line and ignores a bare -fvisibility=hidden ("unknown argument ignored in
    # clang-cl", clang 23.1.2); it does not define __GNUC__, so configure's GCC=yes would be false for it, and it
    # targets PE/COFF. mingw-gcc targets PE/COFF too: configure.ac sets abi="pecoff" for *-*-mingw* and *-*-cygwin*
    # (configure.ac:854-855).
    #
    # configure.ac adds the flag only when GCC=yes and the ABI is ELF (configure.ac:971-974). This build also adds it
    # on Mach-O, deliberately: Mach-O honours visibility, and configure leaves it off there only because its test
    # checks for ELF.
    "@rules_cc//cc/compiler:clang": ["-fvisibility=hidden"],
    "@rules_cc//cc/compiler:emscripten": ["-fvisibility=hidden"],
    "@rules_cc//cc/compiler:gcc": ["-fvisibility=hidden"],
    "//conditions:default": [],
}) + select({
    "@platforms//os:android": [
        "-DPIC",
        "-D_GNU_SOURCE",
    ],
    "@platforms//os:linux": [
        "-DPIC",
        "-D_GNU_SOURCE",
    ],
    "@platforms//os:freebsd": [
        "-DPIC",
        "-D_BSD_SOURCE",
    ],
    "@platforms//os:macos": ["-DPIC"],
    "//conditions:default": [],
}) + select({
    "//settings/flags:prof_frame_pointer": ["-fno-omit-frame-pointer"],
    "//settings/flags:prof_gcc": ["-fno-omit-frame-pointer"],
    "//conditions:default": [],
})
