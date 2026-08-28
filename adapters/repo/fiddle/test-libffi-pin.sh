#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pin="$root/libffi.json"
build="$root/build.sh"

command -v ruby >/dev/null 2>&1 || {
  printf 'libffi pin test requires ruby\n' >&2
  exit 69
}

ruby --disable-gems -rjson -e '
  pin = JSON.parse(File.read(ARGV.fetch(0)))
  expected = {
    "version" => "3.4.6",
    "release_url" => "https://github.com/libffi/libffi/releases/tag/v3.4.6",
    "archive_url" => "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz",
    "archive_name" => "libffi-3.4.6.tar.gz",
    "archive_root" => "libffi-3.4.6",
    "archive_size" => 1_391_684,
    "sha256" => "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"
  }
  expected.each do |key, value|
    abort "unexpected #{key}: #{pin[key].inspect}" unless pin[key] == value
  end
' "$pin"

# These are literal shell assignments in the adapter, not values to expand here.
# shellcheck disable=SC2016
for assignment in \
  'export BUILD_CC="$CC"' \
  'export BUILD_CXX="$CXX"' \
  'export CC_FOR_BUILD="$CC"' \
  'export CXX_FOR_BUILD="$CXX"' \
  'export AR_FOR_BUILD="$AR"' \
  'export RANLIB_FOR_BUILD="$RANLIB"' \
  'export HOST_CC="$CC"' \
  'export HOST_CXX="$CXX"' \
  'export HOST_AR="$AR"' \
  'export HOST_RANLIB="$RANLIB"'; do
  grep -Fxq "$assignment" "$build" || {
    printf 'fiddle build does not pin native build probes: %s\n' \
      "$assignment" >&2
    exit 65
  }
done

if [[ -n "${RZ_DEP_LIBFFI_ARCHIVE:-}" ]]; then
  [[ -f "$RZ_DEP_LIBFFI_ARCHIVE" ]] || {
    printf 'RZ_DEP_LIBFFI_ARCHIVE is not a file: %s\n' "$RZ_DEP_LIBFFI_ARCHIVE" >&2
    exit 66
  }
  expected="$(ruby --disable-gems -rjson -e \
    'print JSON.parse(File.read(ARGV.fetch(0))).fetch("sha256")' "$pin")"
  actual="$(sha256sum "$RZ_DEP_LIBFFI_ARCHIVE" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    printf 'libffi archive SHA-256 mismatch: got %s expected %s\n' \
      "$actual" "$expected" >&2
    exit 65
  }
fi

printf 'libffi source pin accepted\n'
