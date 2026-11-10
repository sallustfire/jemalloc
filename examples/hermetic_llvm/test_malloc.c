#include <stdio.h>
#include <stdlib.h>
#include <jemalloc/jemalloc.h>

int main(void) {
    void *p = malloc(64);
    if (p == NULL) {
        fprintf(stderr, "malloc failed\n");
        return 1;
    }
    free(p);

    const char *version;
    size_t sz = sizeof(version);
    if (mallctl("version", &version, &sz, NULL, 0) != 0) {
        fprintf(stderr, "mallctl(\"version\") failed, so jemalloc is not linked\n");
        return 1;
    }
    printf("jemalloc %s\n", version);
    return 0;
}
