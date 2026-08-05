# EPIC006 Plan: Private Relay and Separate-BEAM Proof

## Progress

- [ ] Phase 6.1: Define the private-relay fixture, path proof, and `dev_cluster` test-only role.
- [ ] Phase 6.2: Add pinned Docker Compose relay configuration, shared-token access, and readiness.
- [ ] Phase 6.3: Integrate relay startup/reuse, diagnostics, tags, and explicit teardown into QA.
- [ ] Phase 6.4: Add `dev_cluster` separate-BEAM endpoint lifecycle and transport helpers.
- [ ] Phase 6.5: Prove forced relay-only stream exchange, token rejection, and direct-path control.
- [ ] Phase 6.6: Test relay/endpoint restarts and add local/two-machine documentation and examples.
- [ ] Phase 6.7: Pass the epic gate and commit the private-network proof.

## Implementation Steps

1. Document that `dev_cluster` is a local control-plane helper and define path evidence required to prove Iroh transport.
2. Pin the official multi-architecture relay image by digest, add dev config/shared test token/localhost ports/readiness, and verify repeatable Compose startup.
3. Extend `bin/qa_check.sh` to check Docker, start or reuse the relay, wait with a deadline, run tagged tests, print diagnostics on failure, and document teardown.
4. Add the test-only dependency and helpers that start the application in separate `:peer` VMs with unique identities and deterministic cleanup.
5. Disable direct IP transports, connect both endpoints to the relay, exchange bounded data, assert relay path, verify wrong tokens fail redacted, and retain a direct-path control.
6. Add controlled relay/endpoint restart and reconnect coverage plus self-hosted local and optional two-machine examples that never claim Erlang distribution support.
7. Run full QA, confirm all criteria/non-goals, inspect image/credentials/resources, and commit only when green.

## Test Isolation Checklist

- [ ] Relay image is pinned by verified digest and test ports bind only as documented.
- [ ] Every child VM and endpoint has unique names, identity, ALPN, and cleanup.
- [ ] Shared token is synthetic and absent from captured output.
- [ ] Path assertions use Iroh path data, not inferred timing.
- [ ] Public/two-machine tests are optional and excluded from default QA.

## Quality Gate

- [ ] Compose readiness, reuse, diagnostics, and teardown checks pass.
- [ ] Correct/wrong token and relay-only/direct path tests pass.
- [ ] Separate-BEAM large transfer, restart/reconnect, cleanup, coverage, and redaction tests pass.
- [ ] QA succeeds without public infrastructure or sibling checkouts.
- [ ] Documentation contains no automatic BEAM cluster/Erlang distribution claim.
- [ ] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh`. Only after Epic 6 is complete, commit as `roadmap001 - epic 6 - <private relay proof outcome>` with a body summarizing relay pinning, separate-BEAM evidence, path assertions, and verification.
