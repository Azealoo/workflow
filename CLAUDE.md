# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Principles

### Think Before Coding
Read before writing. Understand the goal, constraints, and existing code before proposing any change. If the intent is ambiguous, ask — don't assume and produce throwaway work.

### Simplicity First
Prefer the least complex solution that fully satisfies the requirement. Do not add abstraction layers, helpers, or configuration hooks for hypothetical future needs. Three concrete lines beat one premature abstraction.

### Surgical Changes
Touch only what the task requires. Do not refactor surrounding code, rename variables, add comments, or clean up style in files that are not directly related to the goal. Each change should be auditable: the diff should tell exactly one story.

### Goal-Driven Execution
Every action maps to the stated goal. If a step does not move toward that goal, skip it. When blocked, diagnose before switching approaches — do not retry blindly or pivot to a different solution without understanding why the first failed.

## Repository State

This repository is currently at its initial stage. No source code, build system, or test infrastructure exists yet.

### Existing Configuration

`.claude/settings.local.json` — grants these shell permissions for Claude Code:
- `npm list *`
- `npm root *`
- `lsb_release -a`

Update this file (via the `update-config` skill) when additional tool permissions are needed, rather than expanding permissions broadly.

## When Code Is Added

Once a language/framework is chosen, update this file with:
- **Build / lint / test commands** — exact commands, including how to run a single test
- **Architecture overview** — data flow, module boundaries, key entry points
- **Non-obvious conventions** — anything that can't be inferred by reading the code
