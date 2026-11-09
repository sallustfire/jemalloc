/*
 * An explicit jemalloc_prefix renames the public API and the MALLOC_CONF environment variable, as INSTALL.md's
 * --with-jemalloc-prefix describes. JEMALLOC_NO_DEMANGLE maps the je_* names to the configured prefix.
 */
#include <stdio.h>
#define JEMALLOC_NO_DEMANGLE
#include <jemalloc/jemalloc.h>

int main(void) {
    unsigned narenas;
    size_t sz = sizeof(narenas);
    if (je_mallctl("opt.narenas", &narenas, &sz, NULL, 0) != 0 || narenas != 3) {
        fprintf(stderr, "opt.narenas is not 3, so MY_MALLOC_CONF was not read\n");
        return 1;
    }
    return 0;
}
