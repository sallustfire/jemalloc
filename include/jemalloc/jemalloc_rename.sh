#!/bin/sh

public_symbols_txt=$1

"$CAT" <<EOF
/*
 * Name mangling for public symbols is controlled by --with-mangling and
 * --with-jemalloc-prefix.  With default settings the je_ prefix is stripped by
 * these macro definitions.
 */
#ifndef JEMALLOC_NO_RENAME
EOF

for nm in `"$CAT" ${public_symbols_txt}` ; do
  n=`"$ECHO" ${nm} |"$TR" ':' ' ' |"$AWK" '{print $1}'`
  m=`"$ECHO" ${nm} |"$TR" ':' ' ' |"$AWK" '{print $2}'`
  "$ECHO" "#  define je_${n} ${m}"
done

"$CAT" <<EOF
#endif
EOF
