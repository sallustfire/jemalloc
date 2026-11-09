function add(set, list, name,    n, a, i) {
    n = split(list, a, ",")
    for (i = 1; i <= n; i++)
        set[a[i]] = name
}

function compare(var, list, upstream, fork,    s) {
    for (s in upstream)
        if (!(s in fork)) {
            printf "%s: configure.ac adds %s to %s; add it to %s in include/jemalloc/internal/symbols.bzl\n", upstream[s], s, var, list
            failed = 1
        }
    for (s in fork)
        if (!(s in upstream)) {
            printf "%s lists %s, which configure.ac never adds to %s\n", fork[s], s, var
            failed = 1
        }
}

BEGIN {
    PROCINFO["sorted_in"] = "@ind_str_asc"
    add(fork_public, public, "PUBLIC_SYMBOLS")
    add(fork_wrap, wrap, "WRAP_SYMBOLS")
    add(fork_wrap, unwrapped, "configure_symbols_test's unwrapped")
}

match($0, /^[[:space:]]*(public|wrap)_syms="([^"]*)"/, m) {
    n = split(m[2], tokens, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
        t = tokens[i]
        if (t == "" || t == "${" m[1] "_syms}")
            continue
        sub(/\$\{jemalloc_version_gid\}/, gid, t)
        if (t ~ /\$/) {
            printf "%s:%d: cannot interpret %s in %s_syms\n", FILENAME, FNR, t, m[1]
            failed = 1
        } else if (m[1] == "public") {
            upstream_public[t] = FILENAME ":" FNR
        } else {
            upstream_wrap[t] = FILENAME ":" FNR
        }
    }
    next
}

/(public|wrap)_syms=/ && !/^[[:space:]]*wrap_syms=$/ && !/^[[:space:]]*public_syms=`for sym in \$\{public_syms\}; do echo "\$\{sym\}"; done \|grep -v / {
    printf "%s:%d: cannot interpret %s\n", FILENAME, FNR, $0
    failed = 1
}

END {
    if (length(upstream_public) == 0 || length(upstream_wrap) == 0) {
        printf "%s: found no public_syms or wrap_syms assignments\n", FILENAME
        exit 1
    }
    compare("public_syms", "PUBLIC_SYMBOLS", upstream_public, fork_public)
    compare("wrap_syms", "WRAP_SYMBOLS", upstream_wrap, fork_wrap)
    exit failed
}
