/*
 * Checks the library's compile-time configuration through its config.* mallctls. Each argument is NAME=0 or NAME=1,
 * such as config.debug=1, and the test fails unless the mallctl NAME reads as that value.
 */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define JEMALLOC_NO_DEMANGLE
#include <jemalloc/jemalloc.h>

int main(int argc, char **argv) {
    int failures = 0;
    for (int i = 1; i < argc; i++) {
        char name[128];
        const char *equals = strchr(argv[i], '=');
        if (equals == NULL || (size_t)(equals - argv[i]) >= sizeof(name) ||
            (strcmp(equals + 1, "0") != 0 && strcmp(equals + 1, "1") != 0)) {
            fprintf(stderr, "%s: expected NAME=0 or NAME=1\n", argv[i]);
            return 2;
        }
        memcpy(name, argv[i], (size_t)(equals - argv[i]));
        name[equals - argv[i]] = '\0';
        bool expected = equals[1] == '1';

        bool value;
        size_t sz = sizeof(value);
        if (je_mallctl(name, &value, &sz, NULL, 0) != 0) {
            fprintf(stderr, "mallctl %s failed\n", name);
            failures++;
        } else if (value != expected) {
            fprintf(stderr, "%s is %s, expected %s\n", name, value ? "true" : "false", expected ? "true" : "false");
            failures++;
        }
    }
    return failures == 0 ? 0 : 1;
}
