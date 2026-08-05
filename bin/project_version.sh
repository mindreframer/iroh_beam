#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mix_version=$(awk -F '"' '/^[[:space:]]*@version "/ { print $2; exit }' "$root/mix.exs")
native_version=$(awk -F '"' '/^version = "/ { print $2; exit }' "$root/native/iroh_beam_nif/Cargo.toml")

if [ -z "$mix_version" ] || [ -z "$native_version" ]; then
  echo "could not resolve project versions" >&2
  exit 1
fi

if [ "$mix_version" != "$native_version" ]; then
  echo "version mismatch: mix=$mix_version native=$native_version" >&2
  exit 1
fi

printf '%s\n' "$mix_version"
