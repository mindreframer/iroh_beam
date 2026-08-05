#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"

compose_used=0

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

cleanup() {
  status=$?
  trap - EXIT

  if [[ "${status}" -ne 0 && "${compose_used}" -eq 1 ]]; then
    docker compose ps --all || true
    docker compose logs --no-color --tail=200 iroh-relay || true
  fi

  exit "${status}"
}

trap cleanup EXIT

qa_stage elixir "locked dependencies, OTP support, format, compile"
run_quiet env MIX_ENV=test mix deps.get --check-locked
otp_release="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"
test "${otp_release%%.*}" = "29"
printf '[qa/elixir] OTP %s\n' "${otp_release}"
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors

qa_stage docker "start or reuse pinned Iroh relay"
run_quiet docker info
run_quiet docker compose config --quiet
compose_used=1
previous_relay_container_id="$(docker compose ps --quiet iroh-relay)"
run_quiet docker compose up --detach iroh-relay
relay_container_id="$(docker compose ps --quiet iroh-relay)"
test -n "${relay_container_id}"

relay_ready=0
for _attempt in $(seq 1 45); do
  if curl --fail --silent --show-error http://127.0.0.1:3340/ >/dev/null 2>&1; then
    relay_ready=1
    break
  fi
  sleep 1
done
test "${relay_ready}" -eq 1

if [[ "${previous_relay_container_id}" == "${relay_container_id}" ]]; then
  relay_state="reused"
else
  relay_state="started"
fi
printf '[qa/docker] Iroh relay ready (%s)\n' "${relay_state}"

qa_stage elixir "ExUnit unit and direct integration"
MIX_ENV=test mix test --no-compile

qa_stage elixir "relay and separate-BEAM integration"
run_quiet epmd -daemon
run_quiet epmd -names
IROH_BEAM_RELAY_INTEGRATION=1 MIX_ENV=test mix test --no-compile --only relay

qa_stage rust "format"
cargo +1.91.0 fmt --manifest-path native/iroh_beam_nif/Cargo.toml --all -- --check

qa_stage rust "check"
cargo +1.91.0 check --manifest-path native/iroh_beam_nif/Cargo.toml --locked --all-targets

qa_stage rust "Clippy"
cargo +1.91.0 clippy --manifest-path native/iroh_beam_nif/Cargo.toml --locked --all-targets -- -D warnings

qa_stage rust "tests"
cargo +1.91.0 test --manifest-path native/iroh_beam_nif/Cargo.toml --locked --all-targets

qa_stage release "version, docs, and package audit"
test "$(bin/project_version.sh)" = "0.1.0"
MIX_ENV=dev mix docs --warnings-as-errors
package_audit="${project_root}/_build/package_audit"
rm -rf "${package_audit}"
mix hex.build --unpack --output "${package_audit}"
test -f "${package_audit}/LICENSE"
test -f "${package_audit}/NOTICE"
test -f "${package_audit}/native/iroh_beam_nif/Cargo.lock"
test -f "${package_audit}/native/iroh_beam_nif/.cargo/config.toml"
test -f "${package_audit}/src/iroh_dist.erl"
test -f "${package_audit}/src/iroh_dist_support.erl"
test -f "${package_audit}/src/iroh_dist_endpoint.erl"
test -f "${package_audit}/src/iroh_dist_controller.erl"
test -f "${package_audit}/src/iroh_dist_preface.erl"
test -f "${package_audit}/docs/architecture/0004-iroh-distribution-carrier.md"
test -f "${package_audit}/examples/two_machine.exs"
test -f "${package_audit}/examples/distribution_two_machine.exs"
test -f "${package_audit}/docs/distribution.md"
test ! -e "${package_audit}/test"
test ! -e "${package_audit}/@meta"

qa_stage dependency "crates.io-only Iroh"
if grep -R -E '(path[[:space:]]*=.*iroh|/Users/.*/iroh)' \
  native/iroh_beam_nif/Cargo.toml native/iroh_beam_nif/Cargo.lock mix.exs mix.lock; then
  printf '%s\n' 'local Iroh dependency detected' >&2
  exit 1
fi

qa_stage ok "all checks passed"
