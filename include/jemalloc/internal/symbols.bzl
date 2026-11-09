"""The public and wrapped symbol lists configure.ac assembles."""

load("//tools:version.bzl", "VERSION")

_PUBLIC_SYMBOLS = [
    "aligned_alloc",
    "calloc",
    "dallocx",
    "free",
    "mallctl",
    "mallctlbymib",
    "mallctlnametomib",
    "malloc",
    "malloc_conf",
    "malloc_conf_2_conf_harder",
    "malloc_message",
    "malloc_stats_print",
    "malloc_usable_size",
    "mallocx",
    "smallocx_%s" % VERSION.gid,
    "nallocx",
    "posix_memalign",
    "rallocx",
    "realloc",
    "sallocx",
    "sdallocx",
    "xallocx",
]

_MEMALIGN = {
    "//settings/platform:has_memalign": ["memalign"],
    "//settings/platform:no_memalign": [],
}

_VALLOC = {
    "//settings/platform:has_valloc": ["valloc"],
    "//settings/platform:no_valloc": [],
}

_MALLOC_SIZE = {
    "//settings/platform:has_malloc_size": ["malloc_size"],
    "//settings/platform:no_malloc_size": [],
}

PUBLIC_SYMBOLS = _PUBLIC_SYMBOLS + select(
    _MEMALIGN,
    no_match_error = "Availability of memalign must explicitly be declared via //settings/platform:memalign_support",
) + select(
    _VALLOC,
    no_match_error = "Availability of valloc must explicitly be declared via //settings/platform:valloc_support",
) + select(
    _MALLOC_SIZE,
    no_match_error = "Availability of malloc_size must explicitly be declared via //settings/platform:malloc_size_support",
)

_WRAP_OS = {
    "@platforms//os:windows": ["tls_callback"],
    "@platforms//os:freebsd": [
        "pthread_create",
        "_malloc_thread_cleanup",
        "_malloc_tsd_cleanup_register",
        "_malloc_prefork",
        "_malloc_postfork",
    ],
    "//conditions:default": ["pthread_create"],
}

_WRAP_GLIBC = {
    "//include/jemalloc/internal:override_glibc_allocator": [
        "__libc_calloc",
        "__libc_free",
        "__libc_malloc",
        "__libc_memalign",
        "__libc_realloc",
        "__libc_valloc",
    ],
    "//conditions:default": [],
}

WRAP_SYMBOLS = select(_WRAP_OS) + select(_WRAP_GLIBC)

# Every symbol any arm of PUBLIC_SYMBOLS or WRAP_SYMBOLS can add, for comparison with configure.ac
ALL_PUBLIC_SYMBOLS = _PUBLIC_SYMBOLS + [symbol for arms in (_MEMALIGN, _VALLOC, _MALLOC_SIZE) for symbols in arms.values() for symbol in symbols]

ALL_WRAP_SYMBOLS = [symbol for arms in (_WRAP_OS, _WRAP_GLIBC) for symbols in arms.values() for symbol in symbols]
