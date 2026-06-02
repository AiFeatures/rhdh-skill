# Release Branch CI Configuration

Shared definitions for commissioning and decommissioning RHDH release branch CI in `openshift/release`. Both `workflows/commission-release.md` and `workflows/decommission-release.md` reference this file.

## File Paths

For a given release version `{VERSION}` (e.g. `1.10`):

| File | Path |
|------|------|
| **CI config** | `ci-operator/config/redhat-developer/rhdh/redhat-developer-rhdh-release-{VERSION}.yaml` |
| **Generated jobs** | `ci-operator/jobs/redhat-developer/rhdh/redhat-developer-rhdh-release-{VERSION}-*.yaml` |
| **Branch protection** | `core-services/prow/02_config/redhat-developer/rhdh/_prowconfig.yaml` |

## Branch Protection

Each release branch has an entry under `branch-protection.orgs.redhat-developer.repos.rhdh.branches` in `_prowconfig.yaml`.

When commissioning, **read the latest existing release branch entry** from `_prowconfig.yaml` and copy its structure (keys, contexts, settings). Do not hardcode the block — the required status check contexts and protection settings change over time.

When decommissioning, remove the entire `release-{VERSION}:` block, preserving indentation and formatting of surrounding entries.

## Release Branch vs Main Differences

When creating a release branch config from `main` or another release branch, **read both the `main` config and the latest existing release branch config** to understand the current patterns, then apply these structural adjustments:

| Adjustment | How to determine the correct value |
|------------|-----------------------------------|
| **Slack channel** | Read the latest release branch config. Pattern: `#rhdh-e2e-alerts-{X}-{Y}` (dots replaced with hyphens) |
| **Cron schedule** | Read the latest release branch config to see the current schedule pattern. Release branches use a different schedule than `main` to spread load |
| **Cleanup jobs** | Compare `main` with the latest release branch. Jobs present in `main` but absent from all release branches are main-only — remove them |
| **Presubmit tests** | Compare `main` with the latest release branch. Note differences in `always_run`, `max_concurrency`, and other settings — apply the release branch pattern |
| **`zz_generated_metadata.branch`** | Set to `release-{VERSION}` |

Version-specific settings to verify with the user:

| Setting | How to determine |
|---------|-----------------|
| **OCP versions** | Read the source config's `e2e-ocp-v4-*-helm-nightly` entries. Ask the user which OCP versions to include for the new branch |
| **K8s version** (`MAPT_KUBERNETES_VERSION`) | Read from the source config. Ask the user if it should change |
| **OSD version** | Read from the source config. Ask the user if it should change |
| **`releases.latest.release`** | Compare `channel` and `version` between main and release branches |
| **`build_root` tag** | Read from the source config. Ask the user if it should change |

## Post-Change Step

After modifying any CI config files, always run:

```bash
make update
```

This regenerates Prow job configs in `ci-operator/jobs/` and `zz_generated_metadata` sections. It also cleans up generated jobs for deleted configs.
