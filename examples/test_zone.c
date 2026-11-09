/*
 * On macOS jemalloc replaces malloc by overlaying the default malloc zone, and the default prefix je_ makes it read
 * JE_MALLOC_CONF.
 */
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define JEMALLOC_NO_DEMANGLE
#include <jemalloc/jemalloc.h>

int main(void) {
    void *p = malloc(64);
    malloc_zone_t *zone = p ? malloc_zone_from_ptr(p) : NULL;
    const char *name = zone ? malloc_get_zone_name(zone) : NULL;
    if (name == NULL || strcmp(name, "jemalloc_zone") != 0) {
        fprintf(stderr, "malloc returned memory from zone %s, not jemalloc_zone\n", name ? name : "(none)");
        return 1;
    }
    free(p);

    unsigned narenas;
    size_t sz = sizeof(narenas);
    if (je_mallctl("opt.narenas", &narenas, &sz, NULL, 0) != 0 || narenas != 3) {
        fprintf(stderr, "opt.narenas is not 3, so JE_MALLOC_CONF was not read\n");
        return 1;
    }
    return 0;
}
