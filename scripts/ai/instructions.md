# Global agent instructions

jsh writes this file for every installed coding agent from `scripts/ai/instructions.md` in the jsh
checkout. Edit it there; `scripts/ai.sh` replaces the copies.

## Commits

- Never add `Co-authored-by` trailers or any other AI attribution to commit messages. jsh's global
  `commit-msg` hook rejects them.
- Never identify AI tools or agents in branch names, commit messages, pull request titles or
  descriptions, or merge messages. Use neutral, task-based names instead.

## Naming

- Commands read like speech: verb then noun as separate words, e.g. `just set vault`, never
  `just vault-set` or `just set-vault`. This covers just recipes, Make targets, CLI subcommands, npm
  scripts, and shell functions.
- In a justfile, write a verb recipe that takes the noun as a parameter (`set target *args:`
  dispatching on `target`) instead of one hyphenated recipe per pair.
- Keep file and directory names to a single lowercase word when one word stays clear (`amt.yaml`,
  not `amt-power.yaml`). If one word is ambiguous, add context with a directory (`vault/set.sh`)
  before reaching for a hyphen.
- Exceptions: names a tool or ecosystem requires (`package.json`, `.pre-commit-config.yaml`,
  `SKILL.md`, `*.instructions.md`) and existing names you weren't asked to change. Point out
  violations you notice instead of renaming them unprompted.

## Infisical

- Use Infisical for secrets, following the applicable project's existing configuration and tools.
- Fetch only secrets required for the authorized task, and pass them directly to the consuming
  process. Never print secrets, persist plaintext credentials, or weaken access controls.
