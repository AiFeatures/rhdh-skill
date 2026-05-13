---
name: lifecycle-pg
description: >-
  Check PostgreSQL version lifecycle across multiple cloud providers using
  endoflife.date APIs. Shows upstream PostgreSQL, Amazon RDS, and Azure
  Database EOL dates side by side. Use when checking PostgreSQL version
  support, planning database upgrades, or reviewing which PostgreSQL
  versions are still supported across cloud providers.
---
# Check PostgreSQL Version Lifecycle

Aggregates PostgreSQL lifecycle data from three providers via endoflife.date:

- **Upstream PostgreSQL** -- community support EOL dates
- **Amazon RDS for PostgreSQL** -- AWS RDS support EOL dates
- **Azure Database for PostgreSQL** -- Azure Flexible Server support EOL dates

## When to Use

- Check if a PostgreSQL major version is still supported
- Compare EOL dates across cloud providers
- Plan database version upgrades
- Review test plan PostgreSQL coverage

## Prerequisites

- Python 3.9+
- Internet connectivity to reach `https://endoflife.date`

## Usage

Show all PostgreSQL versions:

```bash
uv run scripts/check_pg_lifecycle.py
```

### Show only supported versions

```bash
uv run scripts/check_pg_lifecycle.py --active-only
```

### JSON output

```bash
uv run scripts/check_pg_lifecycle.py --json
```

## Output

### PostgreSQL Lifecycle Table

| Column | Description |
|--------|-------------|
| VERSION | PostgreSQL major version (e.g., `16`) |
| SUPPORTED | `yes` if supported by at least one provider |
| UPSTREAM_EOL | Community PostgreSQL end-of-life date |
| RDS_EOL | Amazon RDS end-of-support date |
| AZURE_EOL | Azure Database end-of-support date |
| RELEASE | Upstream release date |

## Data Sources

- **Upstream**: `https://endoflife.date/api/postgresql.json`
- **Amazon RDS**: `https://endoflife.date/api/amazon-rds-postgresql.json`
- **Azure DB**: `https://endoflife.date/api/azure-database-for-postgresql.json`

## Related Skills

- **`lifecycle-redhat`**: Check RHDH support policy for officially supported PostgreSQL versions
