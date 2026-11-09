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

echo "::group::bazel build ${bazel_args[*]} //tools/fidelity:generated_headers"
bazel build "${bazel_args[@]}" //tools/fidelity:generated_headers
execroot="$(bazel info "${bazel_args[@]}" execution_root)"
files="$(bazel cquery "${bazel_args[@]}" --output=files //tools/fidelity:generated_headers)"
outputs=()
while IFS= read -r output; do
  outputs+=("${output}")
done <<<"${files}"
echo "::endgroup::"

bazel_output() {
  local matches=()
  for output in "${outputs[@]}"; do
    [[ "${output}" == */bin/include/"$1" ]] && matches+=("${execroot}/${output}")
  done
  if [[ ${#matches[@]} -ne 1 ]]; then
    echo "::error::$1: expected one output of //tools/fidelity:generated_headers, found ${#matches[@]}" >&2
    return 1
  fi
  echo "${matches[0]}"
}

# The page, virtual address and huge page sizes describe the machine, not the code, so upstream takes Bazel's values.
internal_defs="$(bazel_output jemalloc/internal/jemalloc_internal_defs.h)"
for macro in LG_PAGE LG_VADDR LG_HUGEPAGE; do
  value="$(sed -n "s/^#define ${macro} \(.*\)$/\1/p" "${internal_defs}")"
  if [[ -z "${value}" ]]; then
    echo "::error::jemalloc/internal/jemalloc_internal_defs.h: ${macro} is not defined"
    exit 1
  fi
  option="$(echo "${macro}" | tr "A-Z_" "a-z-")"
  configure_args+=("--with-${option}=${value}")
done

echo "::group::${upstream##*/}: ./configure ${configure_args[*]}"
(
  cd "${upstream}"
  ./configure "${configure_args[@]}"
  make -j"$(getconf _NPROCESSORS_ONLN)" include/jemalloc/internal/private_namespace.h
)
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
  if ! actual_header="$(bazel_output "${header}")"; then
    status=1
    continue
  fi
  expected="${work}/upstream.h"
  actual="${work}/bazel.h"
  cat "${upstream}/include/${header}" > "${expected}"
  cat "${actual_header}" > "${actual}"
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

# configure writes public_symbols.txt, and passes export_syms (the prefixed public_syms, then wrap_syms) to
# private_symbols.sh, which lists them in private_symbols.awk behind SYM_PREFIX. Both follow configure's probes, as
# Bazel's follow its configured headers. Of wrap_syms, private_namespace.h shows only the symbols jemalloc defines.
listing=jemalloc/internal/public_symbols.txt
if actual_listing="$(bazel_output "${listing}")"; then
  if diff -u --label "upstream/${listing}" --label "bazel/${listing}" "${upstream}/include/${listing}" "${actual_listing}"; then
    echo "${listing}: identical"
  else
    echo "::error::${listing} differs from upstream ./configure ${configure_args[*]}"
    status=1
  fi
else
  status=1
fi
upstream_exports() {
  local sym_prefix
  sym_prefix="$(sed -n 's/^  sym_prefix = "\(.*\)"$/\1/p' "$1")"
  sed -n 's/^        \([^ ]*\) \\$/\1/p' "$1" | sed "s/^${sym_prefix}//" | LC_ALL=C sort
}
if actual_exports="$(bazel_output jemalloc/internal/private_namespace.export_syms)"; then
  upstream_awk="${upstream}/include/jemalloc/internal/private_symbols.awk"
  if diff -u --label "upstream/export_syms" --label "bazel/export_syms" \
    <(upstream_exports "${upstream_awk}") <(LC_ALL=C sort "${actual_exports}"); then
    echo "export_syms: identical"
  else
    echo "::error::export_syms differs from upstream ./configure ${configure_args[*]} (${upstream_awk##*/})"
    status=1
  fi
else
  status=1
fi

header=jemalloc/internal/jemalloc_internal_defs.h
macros() {
  sed -n -e 's|^#define \([A-Za-z0-9_]*\)\(.*\)$|\1\2|p' -e 's|^/\* #undef \([A-Za-z0-9_]*\) \*/$|\1 (undefined)|p' "$1" |
    sed -e 's/[[:space:]]*$//' -e 's/^\([A-Za-z0-9_]*\)$/\1 (empty)/' | LC_ALL=C sort
}
differences="$(diff <(macros "${upstream}/include/${header}") <(macros "${internal_defs}") | sed -n -e 's/^< /upstream: /p' -e 's/^> /bazel:    /p' || true)"
if [[ -z "${differences}" ]]; then
  echo "${header}: identical macros"
else
  echo "::error::${header} differs from upstream ./configure ${configure_args[*]}"
  echo "${differences}"
  status=1
fi
exit "${status}"
