# AGENTS.md

## Roadmaps

- Work is roadmap-driven. Treat a roadmap as an execution contract.
- Layout: one `@meta/@pm/ROADMAP00X.md`; usually seven epics; usually seven phases per epic.
- Each epic has a spec and a plan in `@meta/@pm/roadmap00x/`. The plan contains the phase checkboxes.
- Read the overview and every epic file before coding.
- Execute epics and phases in dependency order.
- Implement the matching unit/integration tests for every phase and epic.
- Check a phase only when its code, tests, and acceptance criteria pass. Never check work optimistically.
- After every epic, run `bin/qa_check.sh`. Fix all failures.
- Commit each green epic as `roadmap00x - epic x - <outcome>` with a concise body stating result and verification.
- Given a roadmap, finish it end to end. Do not stop between phases. Do not ask routine questions. Inspect, make the smallest reasonable assumption, and continue.

## Code

- Use the least abstraction that solves the current problem.
- Prefer direct, readable, maintainable code. Avoid speculative frameworks.
- Minimize dependencies. Each dependency adds build, security, upgrade, and release cost.
- Prefer a few local lines or small self-contained files when practical. Preserve licenses and attribution.
- Keep roadmap commits focused. No unrelated cleanup.

## Release

- A finished roadmap normally bumps the version. Synchronize Mix, Cargo, lockfiles, changelog, README, docs, metadata, and examples.
- Run full QA and docs before release.
- For Rust bindings, run the precompiled-binary pipeline after the roadmap is green.
- Monitor every target until completion. Never dispatch and walk away.
- If a failure makes the run doomed, cancel remaining jobs. Fix, test, commit, push, rerun, and monitor again.
- Verify the exact binary set, smoke tests, release tag, and SHA-256 digests.
- Generate checksums only from published binaries. Commit and push them.
- Monitor final CI and no-Rust consumers until all jobs are green.
- Complete package/docs publication when required. Report success only after code, tests, docs, commits, binaries, checksums, consumers, and CI are verified.
