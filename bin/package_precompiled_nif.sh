#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <project-version> <nif-version> <target>" >&2
  exit 64
fi

project_version=$1
nif_version=$2
target=$3
crate=iroh_beam_nif
crate_dir=native/iroh_beam_nif

lib_prefix=lib
source_suffix=.so
case "$target" in
  *-apple-*) source_suffix=.dylib ;;
  *-pc-windows-*) lib_prefix=; source_suffix=.dll ;;
esac

archive_suffix=$source_suffix
case "$target" in
  *-apple-*) archive_suffix=.so ;;
esac

source_dir="$crate_dir/target/$target/release"
source_file="$source_dir/${lib_prefix}${crate}${source_suffix}"
final_name="${lib_prefix}${crate}-v${project_version}-nif-${nif_version}-${target}${archive_suffix}"
archive_name="${final_name}.tar.gz"

if [[ ! -f "$source_file" ]]; then
  echo "error: missing compiled NIF: $source_file" >&2
  exit 1
fi

cp "$source_file" "$source_dir/$final_name"
tar -C "$source_dir" -czf "$archive_name" "$final_name"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "file-name=$archive_name"
    echo "file-path=$archive_name"
  } >>"$GITHUB_OUTPUT"
fi

printf 'Packaged %s\n' "$archive_name"
