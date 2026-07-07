---
name: base-images-and-rpms
description: >-
  Updates base images with updateBaseImages.sh and regenerates rpms.lock.yaml with
  rpm-lockfile-prototype in redhat-developer/rhdh, rhdh-must-gather, and rhdh-operator.
  Use for weekly upstream maintenance, UBI/RHEL base image bumps, RPM lockfile refresh,
  base-images-and-rpms, main, release-*, UBI/RHEL base image bumps, or RPM lockfile refresh.
---

# Base images and RPMs

## Goal

Refresh **base images** and **RPM lockfiles** in the three upstream GitHub repos:

| Repo | RPM containerfile | `rpms.in.yaml` |
|------|-------------------|----------------|
| [redhat-developer/rhdh](https://github.com/redhat-developer/rhdh) | `build/containerfiles/Containerfile` | repo root |
| [redhat-developer/rhdh-must-gather](https://github.com/redhat-developer/rhdh-must-gather) | `Containerfile` | repo root |
| [redhat-developer/rhdh-operator](https://github.com/redhat-developer/rhdh-operator) | `.rhdh/docker/Dockerfile` | repo root |

Upstream helper scripts live in GitLab midstream [rhidp/rhdh](https://gitlab.cee.redhat.com/rhidp/rhdh) on branch `rhdh-1-rhel-9` (see [updateBaseImages.sh](https://gitlab.cee.redhat.com/rhidp/rhdh/-/blob/rhdh-1-rhel-9/build/scripts/updateBaseImages.sh)).

## Prerequisites

- `jq`, `skopeo`, `curl`, `git`
- `podman` for rhdh node header version detection (see `.nvm/releases/README.adoc`)
- `gh` when `updateBaseImages.sh` opens PRs (`--pr`, the default)
- `python3` and `pip` when `rpm-lockfile-prototype` is not already installed
- Registry auth for base image queries: `docker login registry.redhat.io` (or `skopeo login`)

Install `rpm-lockfile-prototype` manually when needed:

```bash
python3 -m pip install --user https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/heads/main.zip 2>/dev/null
```

On Fedora/RHEL hosts, `dnf install podman skopeo python3-dnf` may also be required for lockfile generation.

## Branch mapping

Accepted `-b` values: `main` or any `release-*` branch (e.g. `release-1.9`, `release-1.10`, `release-2.1`).

| GitHub branch (`-b`) | GitLab scripts branch (`-sb` for `updateBaseImages.sh`) |
|----------------------|---------------------------------------------------------|
| `main` | `rhdh-1-rhel-9` |
| `release-X.Y` | `rhdh-X.Y-rhel-9` |

Verify the target branch exists in each repo before running.

## Run the bundled script

**Execute** [scripts/base-images-and-rpms.sh](scripts/base-images-and-rpms.sh); do not reimplement the workflow inline.

```bash
SKILL=skills/base-images-and-rpms   # under 1-rhdh-skill checkout
chmod +x "${SKILL}/scripts/base-images-and-rpms.sh"

# All three repos under a parent directory
"${SKILL}/scripts/base-images-and-rpms.sh" -b release-1.10 --parent-dir ~/RHDH/DH/1

# Explicit paths and on-disk tools
"${SKILL}/scripts/base-images-and-rpms.sh" -b main \
  --update-base-images-script ~/RHDH/DH/4/4-rhdh/build/scripts/updateBaseImages.sh \
  --rpm-lockfile-prototype ~/.local/bin/rpm-lockfile-prototype \
  ~/RHDH/DH/1/1-rhdh \
  ~/RHDH/DH/1/1-rhdh-operator \
  ~/RHDH/DH/1/1-must-gather
```

### Flags

| Flag | Purpose |
|------|---------|
| `-b`, `--branch` | **Required.** `main` or `release-*` |
| `--update-base-images-script PATH` | Use local `updateBaseImages.sh` (expects `createPR.sh` alongside; fetches if missing) |
| `--rpm-lockfile-prototype PATH` | Use local binary; otherwise `~/.local/bin/rpm-lockfile-prototype` or pip install |
| `--parent-dir PATH` | Auto-discover `1-rhdh`, `1-rhdh-operator`, `1-must-gather` (and common aliases) |
| `REPO_DIR ...` | Explicit repo checkouts |
| `--skip-base` / `--skip-rpm` | Run only one half of the workflow |
| `--dirty` | Allow dirty trees for `updateBaseImages.sh` |
| `--push` | Let `updateBaseImages.sh` push when branch policy allows (still uses `--pr` fallback) |
| `--no-pr` | Commit locally with `--no-push` only |
| `--dry-run` | Print commands without executing |

**Default:** base image updates use `--pr --no-push` (local commits + PR creation, no push). RPM lockfile and node header changes are committed and **pushed to the same open `chore/automated-update-base-images-*` PR branch** when one exists; otherwise a `chore/automated-update-rpm-lockfile/<branch>` PR is opened.

## Workflow

1. Pick branch (`-b`).
2. Ensure local clones are fetched and clean enough for `updateBaseImages.sh` (or pass `--dirty`).
3. Run the script on all three repos.
4. Review open PRs — each should include base image, `rpms.lock.yaml`, and (for rhdh) node header updates when applicable.
5. Human merges PRs; do **not** push directly to protected branches without review.

## What each step does

### Base images (`updateBaseImages.sh`)

Mirrors [weekly-maintenance.sh](https://gitlab.cee.redhat.com/rhidp/rhdh/-/blob/rhdh-1-rhel-9/build/ci/weekly-maintenance.sh) upstream section:

```bash
updateBaseImages.sh -w REPO_ROOT -b BRANCH -sb SCRIPTS_BRANCH -maxdepth 5 --pr
```

`-maxdepth 5` reaches `.rhdh/docker/Dockerfile` in the operator repo as well as top-level containerfiles.

`updateBaseImages.sh` calls `createPr()` once per image bump; upstream `createPR.sh` runs `gh pr view --web` on **every** call, which re-opens the same PR URL. This skill sets `GITLAB_PIPELINE=true` during `updateBaseImages.sh` to suppress that, then opens each repo's PR once in the browser when `--pr` is in effect.

### RPM lockfiles (`rpm-lockfile-prototype`)

Matches each repo's GitHub Action, then commits and pushes to the automation PR:

```bash
rpm-lockfile-prototype -f CONTAINERFILE rpms.in.yaml
git add rpms.lock.yaml
git commit -s -m "chore: update rpms.lock.yaml [skip-build]"
git push origin <chore/automated-update-base-images-*>   # same PR as base images
```

When no base-images PR exists (e.g. `--skip-base`), the script uses `chore/automated-update-rpm-lockfile/<branch>` and opens a PR.

### Node headers (rhdh only)

When the `ubi9/nodejs-*` builder image in `build/containerfiles/Containerfile` ships a different Node version than `.nvmrc` / `.nvm/releases/`, the script:

1. Reads `node --version` from the updated builder image (`podman`/`docker`)
2. Downloads `https://nodejs.org/dist/<version>/node-<version>-headers.tar.gz` into `.nvm/releases/`
3. Updates `.nvmrc` (version without `v` prefix)
4. Removes stale `node-v*-headers.tar.gz` files and pushes to the same automation PR

See [rhdh `.nvm/releases/README.adoc`](https://github.com/redhat-developer/rhdh/blob/main/.nvm/releases/README.adoc).

## Anti-patterns

- Pushing without human review.
- Running on a branch that does not exist in one of the three repos.
- Omitting `registry.redhat.io` login before base image updates.
- Committing `rpms.lock.yaml` without checking the base image minor (e.g. UBI `9.8`) still matches `rpms.in.yaml` repo URLs.

## Additional resources

- Per-repo notes: [references/repos.md](references/repos.md)
