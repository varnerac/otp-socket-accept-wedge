#!/bin/sh
# Build OTP from source (erts and the apps it needs) for one variant:
#   base    master at the parent of erlang/otp#11537
#   pr      erlang/otp#11537
#   fix     base + fix.patch
#   pr-fix  erlang/otp#11537 + fix.patch
set -eu

base=0961685119796964cae49a398e095bb57f183418
pr=d84a0ab3a7df4985e113715691345514d8b88195

variant=${1:-}
dir=${2:-otp-$variant}
case $variant in
  base | fix) sha=$base ;;
  pr | pr-fix) sha=$pr ;;
  *) echo "usage: $0 base|pr|fix|pr-fix [dir]" >&2; exit 2 ;;
esac
patch=$(cd "$(dirname "$0")" && pwd)/fix.patch

git init -q "$dir"
cd "$dir"
git fetch -q --depth 1 https://github.com/erlang/otp.git "$sha"
git checkout -qf FETCH_HEAD
case $variant in *fix) git apply "$patch" ;; esac

for app in lib/*/; do
  case $(basename "$app") in kernel | stdlib | compiler | parsetools | sasl) ;; *) touch "$app/SKIP" ;; esac
done
./otp_build configure --without-termcap --without-javac --without-wx \
  --without-odbc --without-ssl
make -j"$(getconf _NPROCESSORS_ONLN)"
