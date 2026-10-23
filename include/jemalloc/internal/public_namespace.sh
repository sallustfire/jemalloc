#!/bin/sh

for nm in `"$CAT" $1` ; do
  n=`"$ECHO" ${nm} |"$TR" ':' ' ' |"$AWK" '{print $1}'`
  "$ECHO" "#define je_${n} JEMALLOC_N(${n})"
done
