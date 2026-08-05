#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"

qa_stage() {
  printf '\n[qa/%s] %s\n' "$1" "$2"
}

run_quiet() {
  local output
  local status

  if output="$("$@" 2>&1)"; then
    return 0
  else
    status=$?
    printf '%s\n' "${output}" >&2
    return "${status}"
  fi
}

qa_stage elixir "locked dependencies, format, compile"
run_quiet env MIX_ENV=test mix deps.get --check-locked
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors

qa_stage elixir "ExUnit"
MIX_ENV=test mix test --no-compile

qa_stage rust "format"
cargo +1.91.0 fmt --manifest-path native/iroh_beam_nif/Cargo.toml --all -- --check

qa_stage rust "check"
cargo +1.91.0 check --manifest-path native/iroh_beam_nif/Cargo.toml --locked --all-targets

qa_stage rust "Clippy"
cargo +1.91.0 clippy --manifest-path native/iroh_beam_nif/Cargo.toml --locked --all-targets -- -D warnings

qa_stage rust "tests"
cargo +1.91.0 test --manifest-path native/iroh_beam_nif/Cargo.toml --locked --all-targets

qa_stage dependency "crates.io-only Iroh"
if grep -R -E '(path[[:space:]]*=.*iroh|/Users/.*/iroh)' \
  native/iroh_beam_nif/Cargo.toml native/iroh_beam_nif/Cargo.lock mix.exs mix.lock; then
  printf '%s\n' 'local Iroh dependency detected' >&2
  exit 1
fi

qa_stage ok "all checks passed"
