#include <memory>

#include "test/jemalloc_test.h"

static_assert(JEMALLOC_INFALLIBLE_NEW == 0);

TEST_BEGIN(test_failing_alloc) {
#ifdef JEMALLOC_HAVE_CXX_EXCEPTIONS
	bool saw_exception = false;
	try {
		/* Too big of an allocation to succeed. */
		void *volatile ptr = ::operator new((size_t)-1);
		(void)ptr;
	} catch (...) {
		saw_exception = true;
	}
	expect_true(saw_exception, "Didn't get a failure");
#else
	test_skip("C++ exceptions are unavailable");
#endif
}
TEST_END

int
main(void) {
	return test(test_failing_alloc);
}
