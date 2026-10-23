#!/bin/sh

for symbol in `"$CAT" "$@"` ; do
  "$ECHO" "#define ${symbol} JEMALLOC_N(${symbol})"
done
