#!/bin/sh
# Run wedge:check/0 and compare its verdict with expected.txt.
#   ./check.sh 26.0.2        in the erlang:26.0.2-alpine image
#   ./check.sh fix otp-fix   with a tree from ./build.sh fix
set -eu

name=${1:?usage: $0 VERSION | VARIANT DIR}
if [ $# -gt 1 ]; then
  dir=$(cd "$2" && pwd)
  [ -x "$dir/bin/erl" ] || { echo "no $dir/bin/erl" >&2; exit 2; }
fi
cd "$(dirname "$0")"
want=$(awk -v n="$name" '$1 == n { sub(/^[^ ]+ +/, ""); print }' expected.txt)
[ -n "$want" ] || { echo "no expected result for $name" >&2; exit 2; }

run='erlc -o "$OUT" wedge.erl && erl -noshell -pa "$OUT" -s wedge check -s init stop'
if [ $# -gt 1 ]; then
  out=$(PATH="$dir/bin:$PATH" OUT=$(mktemp -d) sh -c "$run") || :
else
  docker=${DOCKER:-$(command -v docker || command -v podman)}
  out=$("$docker" run --rm -v "$PWD:/w:ro" -w /w -e OUT=/tmp \
    "erlang:$name-alpine" sh -c "$run") || :
fi
echo "$out"

got=$(echo "$out" | tail -n 1)
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$name: \`$got\`" >>"$GITHUB_STEP_SUMMARY"
if [ "$got" = "$want" ]; then
  echo "PASS $name"
else
  echo "FAIL $name: expected $want"
  exit 1
fi
