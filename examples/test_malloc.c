/*
 * Under the platform's default prefix, plain malloc must reach jemalloc: through the replaced symbols when there is no
 * prefix, and through the default malloc zone on macOS, where the prefix is je_. thread.allocated counts the bytes this
 * thread allocates through jemalloc. The manual marks it [--enable-stats], but in this version thread events keep the
 * counter and src/ctl.c does not gate it on stats, so the check also runs without stats.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define JEMALLOC_NO_DEMANGLE
#include <jemalloc/jemalloc.h>

int main(void) {
    uint64_t before, after;
    size_t sz = sizeof(uint64_t);

    if (je_mallctl("thread.allocated", &before, &sz, NULL, 0) != 0) {
        fprintf(stderr, "Error: je_mallctl 'thread.allocated' failed\n");
        return 1;
    }
    // The volatile store keeps the compiler from eliding the malloc/free pair
    void * volatile p = malloc(4096);
    if (p == NULL) {
        fprintf(stderr, "malloc(4096) failed\n");
        return 1;
    }
    int ret = je_mallctl("thread.allocated", &after, &sz, NULL, 0);
    free(p);
    if (ret != 0) {
        fprintf(stderr, "Error: je_mallctl 'thread.allocated' failed\n");
        return 1;
    }

    if (after - before < 4096) {
        fprintf(stderr, "malloc(4096) did not allocate from jemalloc\n");
        return 1;
    }
    return 0;
}
