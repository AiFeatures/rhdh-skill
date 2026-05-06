# Contributing

## Quick Setup

```bash
git clone https://github.com/redhat-developer/rhdh-skill.git
cd rhdh-skill
uv sync --extra dev                  # Install dev dependencies
git config core.hooksPath .githooks  # Enable pre-commit hooks
```

The `core.hooksPath` setting points git at the checked-in `.githooks/` directory. If `pre-commit` is installed, linting and tests run automatically on every commit. If not, commits proceed with a warning.

## Running Tests

```bash
uv run pytest          # All tests
uv run pytest -v       # Verbose
uv run pytest -k name  # Filter by test name
```

## Linting

```bash
uv run ruff check .        # Lint
uv run ruff format --check # Format check
uv run ruff format .       # Auto-format
```

Pre-commit hooks run both automatically on staged files.

## Project Layout

```
skills/
├── rhdh/            # Orchestrator — routes to other skills
├── create-plugin/   # Plugin lifecycle (backend, frontend, export, wiring)
├── overlay/         # Extensions Catalog overlay management
├── rhdh-local/      # Local RHDH testing
├── rhdh-jira/       # Jira integration (RHIDP, RHDHPLAN, RHDHBUGS, RHDHSUPP)
└── skill-maker/     # Create or consolidate skills
tests/               # pytest test suite
```

## Adding a Skill

Use the `skill-maker` skill or follow the [Agent Skills specification](https://agentskills.io/specification). Every skill needs:

- `SKILL.md` with YAML frontmatter (`name`, `description`)
- Description under 1024 characters
- Body under 500 lines — use `references/` for deeper content

## Editing Skills

Follow the rules in [AGENTS.md](./AGENTS.md):

- **Surgical changes** — touch only what you must
- **Run tests** — `uv run pytest` before reporting done
- **No speculative features** — minimum code that solves the problem

## CLAUDE.md

`CLAUDE.md` contains `@AGENTS.md` — a directive that points Claude Code to the canonical file. Don't edit `CLAUDE.md` directly; edit `AGENTS.md`.

## Pull Requests

- Branch from `main`
- Ensure `uv run ruff check .` and `uv run pytest` pass
- Keep commits focused — one concern per commit
