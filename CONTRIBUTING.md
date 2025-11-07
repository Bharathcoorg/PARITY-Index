# Contributing to PARITY Index

Thanks for contributing! This guide explains the branching model, coding standards, and the PR process.

## Branching Model
- `main`: protected, production-ready. Squash merges only.
- `dev`: integration branch for upcoming releases.
- Feature branches: `feature/<scope>`, bug fixes: `fix/<scope>`, docs: `docs/<scope>`.

## Pull Requests
- Keep PRs focused; include a clear summary, scope, and impact.
- Link related issues. Use labels like `contracts`, `docs`, `infra`.
- Add tests for contract changes; include security implications if applicable.
- Prefer squash merge to keep history clean.

## Coding Standards (Contracts)
- Use consistent `SPDX-License-Identifier` and `pragma` versions.
- Include Natspec summaries for public/external functions.
- Follow least-privilege for roles and access control.
- Guard external entrypoints against reentrancy and validate inputs.

## Commit Style
- Conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`.

## Reviews
- At least one reviewer for non-trivial changes.
- Address comments or explain rationale; avoid force-push to shared branches.

## Local Setup
- Contracts are in `contracts/` (PR will migrate from current structure).
- Choose Foundry or Hardhat; document commands in `contracts/README.md`.