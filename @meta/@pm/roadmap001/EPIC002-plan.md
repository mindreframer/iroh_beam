# EPIC002 Plan: Identity, Addresses, and Tickets

## Progress

- [ ] Phase 2.1: Define secret-key, endpoint-ID, address, and ticket public value contracts.
- [ ] Phase 2.2: Implement key generation/import/export, ID derivation, parsing, and redaction.
- [ ] Phase 2.3: Implement validated endpoint-address construction and normalization.
- [ ] Phase 2.4: Implement standard endpoint-ticket encoding and decoding.
- [ ] Phase 2.5: Add atomic optional file-backed identity persistence.
- [ ] Phase 2.6: Add interoperability, corruption, race, permission, and leak tests plus identity docs.
- [ ] Phase 2.7: Pass the epic gate and commit the completed identity surface.

## Implementation Steps

1. Define small Elixir structs/opaque native values and stable return/error shapes without binding an endpoint.
2. Add native key operations, endpoint-ID text/bytes/equality behavior, explicit private export, and secret-safe `Inspect`.
3. Validate and normalize relay/direct address parts while preserving a deterministic representation.
4. Use pinned `iroh-tickets` for standard endpoint tickets and document reuse, staleness, and IP disclosure.
5. Implement create-if-absent identity files through unique temporary publication, restrictive permissions, and corruption-safe loading.
6. Add upstream vectors, generated round trips, concurrent creators, malformed input, Unicode path, permissions, and redaction tests; explain why live endpoints do not share a secret key.
7. Run full QA, confirm all criteria, review for secret fixtures/generated files, and commit only when green.

## Test Isolation Checklist

- [ ] Every persistence test owns and removes a unique temporary directory.
- [ ] Known test secrets are synthetic and scanned from all observable output.
- [ ] Creation races use barriers, not timing assumptions.
- [ ] Platform-specific permission assertions are conditional and documented.
- [ ] Tests never contact a relay, DNS, or other network service.

## Quality Gate

- [ ] Key/ID, address, and standard-ticket compatibility tests pass.
- [ ] Persistence race, corruption, permissions, and restart tests pass.
- [ ] Redaction scans pass for inspection, errors, logs, and test output.
- [ ] QA succeeds and the diff contains no endpoint/network implementation.
- [ ] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh`. Only after all Epic 2 criteria pass, commit as `roadmap001 - epic 2 - <identity and ticket outcome>` with a body summarizing interoperability, persistence, redaction, and verification.
