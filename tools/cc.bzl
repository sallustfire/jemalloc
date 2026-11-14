"Project specific configuration of rules_cc"

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

# Only the flags that change what jemalloc's sources and the system headers mean: -D_REENTRANT (configure.ac:1876), the
# host's feature test macros (configure.ac:658-707), -fvisibility=hidden, and the frame pointers prof's gcc unwinder
# walks (configure.ac:1370).
#
# configure.ac's other defaults are the builder's choices. Target copts come after --copt, so anything here would
# override them, for every module depending on jemalloc too:
# - Warnings (configure.ac:249-264, 271, 310-311, 926-927) are set with --copt, --conlyopt and --cxxopt.
# - Debug info (-g3, -Zi, -FS; configure.ac:266, 269, 272, 312) comes from --compilation_mode.
# - -pipe (configure.ac:265) only changes the speed of the build; --copt sets it.
# - The C runtime (-MT; configure.ac:270) is the toolchain's, from its static_link_msvcrt and dynamic_link_msvcrt
#   features. Forcing it here breaks consumers linking the other runtime (LNK2038).
# - -DPIC (configure.ac:544) is defined by upstream only for its PIC objects (Makefile.in:433-436), which go into the
#   shared library and libjemalloc_pic.a, and nothing reads it. Position independent code is the toolchain's job.
COPTS = ["-D_REENTRANT"] + select({
    # configure.ac adds it only when GCC=yes and the ABI is ELF (configure.ac:846-849). It is keyed on the compiler
    # alone here, so these compilers also get it on Mach-O and PE targets.
    "@rules_cc//cc/compiler:clang": ["-fvisibility=hidden"],
    "@rules_cc//cc/compiler:clang-cl": ["-fvisibility=hidden"],
    "@rules_cc//cc/compiler:emscripten": ["-fvisibility=hidden"],
    "@rules_cc//cc/compiler:gcc": ["-fvisibility=hidden"],
    "@rules_cc//cc/compiler:mingw-gcc": ["-fvisibility=hidden"],
    "//conditions:default": [],
}) + select({
    "@platforms//os:android": ["-D_GNU_SOURCE"],
    "@platforms//os:freebsd": ["-D_BSD_SOURCE"],
    "@platforms//os:linux": ["-D_GNU_SOURCE"],
    "//conditions:default": [],
}) + select({
    "//settings/flags:prof_gcc": ["-fno-omit-frame-pointer"],
    "//conditions:default": [],
})
