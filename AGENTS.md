# AGENTS.md — Coding Agent Rules (CSE: Execute & Verify)

This repo follows the CSE workflow: **Problem → Contract → Code**.
Product decisions (WHY / WHAT / RULES / ARCHITECTURE / PLAN) are made outside this agent.
Your job is **HOW / IMPLEMENT / REFACTOR / TEST / BUILD / DEBUG** — within the given task.

## Before you start
- Read `PRODUCT.md`, `UX.md`, `ARCHITECTURE.md`, `PLAN.md`, `DECISIONS.md` if present.
- Inspect the current code state first (read-only). Do not assume.
- Work only on the current TASK. Anything not in it is out of scope.

## Confirmed decisions
Decisions in `DECISIONS.md` and the task's Constraints are fixed.
Do not redesign them unless implementation becomes impossible or a documented platform
limitation requires it — and if so, stop and report instead of changing them silently.

## How to implement
- One **vertical slice** at a time: a complete, independently verifiable path (UI → logic → storage/API → result).
- Never implement the whole app in one pass.
- Make the smallest change that correctly satisfies the current contract.
- Do not invent product rules (timezones, deletion, duplicates, offline, permissions, validity). If a rule is missing and it matters, stop and ask.
- Do not redesign the architecture to solve a local problem.
- No speculative features, no unused abstractions (protocols, repositories, DI containers, coordinators, generic wrappers) without real value.
- No new third-party dependencies without a concrete benefit. Prefer platform-native frameworks
  (iOS: Swift, SwiftUI, Observation, URLSession + async/await, Keychain for secrets).
- Handle realistic states: loading / success / empty / error / offline / permission denied / partial data / first use.
- Never log secrets, tokens, or private keys.

## Forbidden ways to "fix" things
- Arbitrary delays / sleeps
- Silent catch blocks
- Magic constants or one-off special cases
- Disabling or skipping tests
- Ignoring or suppressing warnings

Fix the root cause.

## Task format you will receive
Goal · Context · Requirements · Non-goals · Existing Architecture · Constraints · Validation · Definition of Done.
Respect Non-goals as strictly as Requirements.

## Before reporting done (Gate Review)
Run the task's Validation commands, then report on each:

| Check | Question |
|---|---|
| Build | Does it compile? |
| Tests | Do relevant tests pass? |
| Warnings | Any new warnings? |
| Architecture | Any unnecessary complexity added? |
| Scope | Anything implemented outside the task? |
| Regression | Did existing behavior break? |
| Error handling | Are realistic failure paths handled? |
| Security | Is sensitive data handled correctly? |
| Product contract | Still matches confirmed behavior? |
| Risks | What remains uncertain or fragile? |

State clearly what was actually verified vs. not verified.
Recommend **PASS** or **FIX FIRST**. If FIX FIRST, do not add features — propose a focused repair task.

## Keep docs in sync
- Update `PLAN.md` (current stage, completed work, known risks) when a slice is done.
- Append new confirmed decisions to `DECISIONS.md` with date and rationale — only when the user confirmed them.
