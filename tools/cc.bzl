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

# The flags that change what jemalloc's sources and the system headers mean: -D_REENTRANT (configure.ac:1876), the
# host's feature test macros (configure.ac:658-707), -fvisibility=hidden, and the frame pointers prof's gcc unwinder
# walks (configure.ac:1370). Then the warnings jemalloc's sources trip on purpose.
#
# configure.ac's other defaults are the builder's choices. Target copts come after --copt, so anything here would
# override them wherever jemalloc is compiled, including in every build that depends on this module:
# - Turning warnings on (configure.ac:249-254, 256, 271, 310-311, 926-927) is done with --copt, --conlyopt and
#   --cxxopt. Only the suppressions below stay.
# - Debug info (-g3, -Zi; configure.ac:266, 269, 312) comes from --compilation_mode. -FS (configure.ac:272) only
#   matters when compiles share a PDB, and Bazel's /Z7 embeds the debug info in each object instead.
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
}) + select({
    # The warnings configure.ac turns off for patterns jemalloc's sources use on purpose:
    # - -Wno-missing-braces (configure.ac:257-261) for the universal zero initializer {0}, as in the tcache's static
    #   initializer of nested structs, which older GCC flags (https://gcc.gnu.org/bugzilla/show_bug.cgi?id=53119).
    # - -Wno-missing-field-initializers (configure.ac:262-263), for the same initializers and for struct initializers
    #   that leave their trailing fields zero, as test/unit/hpa.c's options do.
    # - -Wno-missing-attributes (configure.ac:264), for the __libc_* aliases of je_* (src/jemalloc.c:3279-3302), which
    #   are compiled only where glibc still links its malloc hooks (before 2.34), and which GCC 9 and later flag for
    #   having fewer attributes than their targets. Clang has no such warning and warns about the unknown flag on every
    #   compile, so only GCC gets it.
    # Turning a warning off can't fail a build the way turning one on can, so the library declares these. Target copts
    # come after --copt, so a builder who wants one of these warnings anyway turns it back on with --per_file_copt,
    # which comes after both. clang-cl takes clang's -W flags as they are, and its /W4 turns on -Wextra, so it gets them
    # too. cl has no counterpart and upstream's MSVC flags suppress nothing (configure.ac:267-273).
    "@rules_cc//cc/compiler:clang": ["-Wno-missing-braces", "-Wno-missing-field-initializers"],
    "@rules_cc//cc/compiler:clang-cl": ["-Wno-missing-braces", "-Wno-missing-field-initializers"],
    "@rules_cc//cc/compiler:emscripten": ["-Wno-missing-braces", "-Wno-missing-field-initializers"],
    "@rules_cc//cc/compiler:gcc": [
        "-Wno-missing-braces",
        "-Wno-missing-field-initializers",
        "-Wno-missing-attributes",
    ],
    "@rules_cc//cc/compiler:mingw-gcc": [
        "-Wno-missing-braces",
        "-Wno-missing-field-initializers",
        "-Wno-missing-attributes",
    ],
    "//conditions:default": [],
})
