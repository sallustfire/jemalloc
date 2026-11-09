#!/usr/bin/env bash
# usage: upstream_oracle.sh TARBALL [CONFIGURE_ARG...] -- [BAZEL_ARG...]

set -o errexit -o nounset -o pipefail

tarball="$(realpath "${1:?usage: upstream_oracle.sh TARBALL [CONFIGURE_ARG...] -- [BAZEL_ARG...]}")"
shift
configure_args=()
while (($#)) && [[ "$1" != "--" ]]; do
  configure_args+=("$1")
  shift
done
if (($#)); then
  shift
fi
bazel_args=("$@")

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

tar -xjf "${tarball}" -C "${work}"
trees=("${work}"/jemalloc-*)
if [[ ${#trees[@]} -ne 1 || ! -f "${trees[0]}/VERSION" ]]; then
  echo "${tarball}: expected a single jemalloc-*/VERSION" >&2
  exit 1
fi
upstream="${trees[0]}"

echo "::group::${upstream##*/}: ./configure ${configure_args[*]}"
(
  cd "${upstream}"
  ./configure "${configure_args[@]}"
  make -j"$(nproc)" include/jemalloc/internal/private_namespace.h
)
echo "::endgroup::"

echo "::group::bazel build ${bazel_args[*]} //tools/fidelity:generated_headers"
bazel build "${bazel_args[@]}" //tools/fidelity:generated_headers
execroot="$(bazel info "${bazel_args[@]}" execution_root)"
files="$(bazel cquery "${bazel_args[@]}" --output=files //tools/fidelity:generated_headers)"
mapfile -t outputs <<<"${files}"
echo "::endgroup::"

status=0
for header in \
  jemalloc/jemalloc.h \
  jemalloc/jemalloc_mangle.h \
  jemalloc/jemalloc_mangle_jet.h \
  jemalloc/jemalloc_rename.h \
  jemalloc/internal/public_namespace.h \
  jemalloc/internal/public_unnamespace.h \
  jemalloc/internal/private_namespace.h; do
  matches=()
  for output in "${outputs[@]}"; do
    [[ "${output}" == */bin/include/"${header}" ]] && matches+=("${execroot}/${output}")
  done
  if [[ ${#matches[@]} -ne 1 ]]; then
    echo "::error::${header}: expected one output of //tools/fidelity:generated_headers, found ${#matches[@]}"
    status=1
    continue
  fi
  expected="${work}/upstream.h"
  actual="${work}/bazel.h"
  cat "${upstream}/include/${header}" > "${expected}"
  cat "${matches[0]}" > "${actual}"
  if [[ "${header}" == */private_namespace.h ]]; then
    LC_ALL=C sort -o "${expected}" "${expected}"
    LC_ALL=C sort -o "${actual}" "${actual}"
  fi
  if diff -u --label "upstream/${header}" --label "bazel/${header}" "${expected}" "${actual}"; then
    echo "${header}: identical"
  else
    echo "::error::${header} differs from upstream ./configure ${configure_args[*]}"
    status=1
  fi
done
exit "${status}"
