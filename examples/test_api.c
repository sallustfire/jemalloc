#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#define JEMALLOC_NO_DEMANGLE
#include <jemalloc/jemalloc.h>
#include <errno.h>
#include <getopt.h>

void print_usage(const char* prog_name) {
    printf("Usage: %s [options]\n", prog_name);
    printf("Options:\n");
    printf("  -h, --help                 Show this help message\n");
    printf("  -v, --verbose              Enable verbose output\n");
    printf("  --expect-stats-unavailable Expect stats to be unavailable (exit 0 if unavailable, 1 if not)\n");
    printf("                             By default, test expects stats to be available\n");
}

/*
 * This function explicitly tests stats functionality and optionally prints available stats
 * which can be disabled with --disable-stats
 * Returns 0 if stats are available, 1 if stats are disabled
 */
int test_stats_functionality(int verbose) {
    size_t allocated, active, resident, metadata, mapped, retained;
    size_t sz = sizeof(size_t);
    int ret;

    // Try to access stats.allocated - will fail if stats are disabled
    ret = je_mallctl("stats.allocated", &allocated, &sz, NULL, 0);

    if (ret != 0) {
        fprintf(stderr, "Stats error: Failed to get stats.allocated: %s (error code: %d)\n",
                strerror(ret), ret);
        if (ret == ENOENT) {
            fprintf(stderr, "This indicates jemalloc was compiled with --disable-stats\n");
        }
        return 1; // Stats are unavailable
    }

    // Stats are available, print them if verbose mode
    if (verbose) {
        printf("\nJemalloc Memory Stats:\n");
        printf("  Allocated: %zu bytes (%.2f MB)\n", allocated, (double)allocated / (1024 * 1024));

        // Get additional stats and print them when available
        if (je_mallctl("stats.active", &active, &sz, NULL, 0) == 0) {
            printf("  Active: %zu bytes (%.2f MB)\n", active, (double)active / (1024 * 1024));
        }

        if (je_mallctl("stats.resident", &resident, &sz, NULL, 0) == 0) {
            printf("  Resident: %zu bytes (%.2f MB)\n", resident, (double)resident / (1024 * 1024));
        }

        if (je_mallctl("stats.metadata", &metadata, &sz, NULL, 0) == 0) {
            printf("  Metadata: %zu bytes (%.2f MB)\n", metadata, (double)metadata / (1024 * 1024));
        }

        if (je_mallctl("stats.mapped", &mapped, &sz, NULL, 0) == 0) {
            printf("  Mapped: %zu bytes (%.2f MB)\n", mapped, (double)mapped / (1024 * 1024));
        }

        if (je_mallctl("stats.retained", &retained, &sz, NULL, 0) == 0) {
            printf("  Retained: %zu bytes (%.2f MB)\n", retained, (double)retained / (1024 * 1024));
        }
    }

    return 0; // Stats are available
}

/*
 * Under the platform's default prefix, plain malloc must reach jemalloc: through the replaced symbols when there is no
 * prefix, and through the default malloc zone on macOS, where the prefix is je_. thread.allocated counts the bytes this
 * thread allocates through jemalloc. The manual marks it [--enable-stats], but in this version thread events keep the
 * counter and src/ctl.c does not gate it on stats, so the check also runs without stats.
 * Returns 0 if malloc allocated from jemalloc, 1 if not
 */
int test_malloc_is_jemalloc(void) {
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

int main(int argc, char** argv) {
    int expect_stats_available = 1; // Default: expect stats to be available
    int verbose = 0; // Default: non-verbose output

    // Define long options
    static struct option long_options[] = {
        {"help", no_argument, 0, 'h'},
        {"verbose", no_argument, 0, 'v'},
        {"expect-stats-unavailable", no_argument, 0, 'u'},
        {0, 0, 0, 0}
    };

    // Parse command line options
    int opt;
    int option_index = 0;

    while ((opt = getopt_long(argc, argv, "hv", long_options, &option_index)) != -1) {
        switch (opt) {
            case 'h':
                print_usage(argv[0]);
                return 0;
            case 'v':
                verbose = 1;
                break;
            case 'u':
                expect_stats_available = 0; // Expect stats to be unavailable
                break;
            default:
                print_usage(argv[0]);
                return 2;
        }
    }

    // Basic check to ensure jemalloc is loaded
    const char *version;
    size_t version_size = sizeof(version);
    if (je_mallctl("version", (void*)&version, &version_size, NULL, 0) != 0) {
        fprintf(stderr, "Error: mallctl 'version' failed. Jemalloc not loaded?\n");
        return 1; // Always fail if jemalloc isn't loaded
    }

    if (verbose) {
        printf("Using jemalloc version: %s\n", version);
    }

    // Perform some allocations to have something to measure
    const int num_allocs = 10;
    void* ptrs[num_allocs];
    for (int i = 0; i < num_allocs; i++) {
        // Allocate blocks of increasing size
        size_t size = 1024 * (i + 1);
        ptrs[i] = malloc(size);
        if (!ptrs[i]) {
            fprintf(stderr, "malloc failed for size %zu\n", size);
            return 1;
        }
        // Write some data to ensure pages are committed
        memset(ptrs[i], i, size);
    }

    // Test stats functionality
    int stats_unavailable = test_stats_functionality(verbose);

    // Clean up allocations
    for (int i = 0; i < num_allocs; i++) {
        free(ptrs[i]);
    }

    // Determine exit code based on stats availability and expectation
    int exit_code;

    if (expect_stats_available) {
        // Expecting stats to be available
        exit_code = stats_unavailable ? 1 : 0;
    } else {
        // Expecting stats to be unavailable
        exit_code = stats_unavailable ? 0 : 1;
    }

    // With or without stats, plain malloc must reach jemalloc
    if (test_malloc_is_jemalloc()) {
        exit_code = 1;
    }

    // Only print this if verbose mode is enabled
    if (verbose) {
        printf("\nStats %s - Test %s\n",
               stats_unavailable ? "UNAVAILABLE" : "AVAILABLE",
               exit_code == 0 ? "PASSED" : "FAILED");
    }

    return exit_code;
}