# EPIC003 Plan: Supervised Endpoints and Network Profiles

## Progress

- [ ] Phase 3.1: Define the endpoint process API, child specification, ownership, and option schema.
- [ ] Phase 3.2: Implement native endpoint bind/info/online/close resources through the async bridge.
- [ ] Phase 3.3: Add `:n0`, minimal/direct, and no-relay profiles.
- [ ] Phase 3.4: Add validated custom relay maps and redacted bearer-token configuration.
- [ ] Phase 3.5: Implement bounded close, owner-death abort, failed-start cleanup, and restart behavior.
- [ ] Phase 3.6: Test multi-endpoint isolation, no-external mode, validation, leaks, and responsiveness; document configuration.
- [ ] Phase 3.7: Pass the epic gate and commit supervised endpoint support.

## Implementation Steps

1. Define `start_link`, `child_spec`, `close`, `id`, `addr`, `bound_sockets`, `online?`/`await_online`, and documented option defaults.
2. Wrap Iroh endpoints as native resources and route bind, status waits, and close through reference-tagged cancellable operations.
3. Map small named Elixir profiles to stable Iroh presets without exposing the upstream builder wholesale.
4. Add custom relay records, maps, optional auth token, limits, and validation/redaction.
5. Tie native endpoint lifetime to its OTP owner, handle startup rollback, add bounded graceful close plus abort fallback, and verify supervisor restart.
6. Add isolated endpoint/profile/lifecycle tests and user docs, including explicit external-infrastructure behavior for every profile.
7. Run full QA, verify criteria/non-goals, inspect resources/secrets in the diff, and commit only when green.

## Test Isolation Checklist

- [ ] Loopback binds use OS-assigned ports except deliberate conflict tests.
- [ ] No-external assertions use instrumentation, not unavailable internet.
- [ ] Supervisor tests reap old children/resources before asserting restart.
- [ ] Token fixtures are synthetic and redaction-scanned.
- [ ] Tests do not require Docker, public Iroh services, or `dev_cluster`.

## Quality Gate

- [ ] Endpoint profile, option, status, and multi-endpoint tests pass.
- [ ] Close, kill, startup rollback, restart, socket, task, and responsiveness tests pass.
- [ ] Minimal/direct mode has proven zero external attempts.
- [ ] QA succeeds and no connection/stream behavior is included.
- [ ] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh`. Only after Epic 3 is complete, commit as `roadmap001 - epic 3 - <supervised endpoint outcome>` with a body summarizing profiles, lifecycle guarantees, and verification.
