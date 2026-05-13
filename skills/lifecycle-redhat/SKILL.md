---
name: lifecycle-redhat
description: >-
  Check lifecycle status for any Red Hat product using the Product Life
  Cycles API. Supports RHBK (Keycloak), Quay, RHDH, OCP, and any other
  Red Hat product. Use when asking about Red Hat product version support,
  EOL dates, GA dates, or support phases. Also use for RHBK or Quay
  version lifecycle checks, or when checking if a specific version of
  any Red Hat product is still supported.
---
# Check Red Hat Product Lifecycle

Query the Red Hat Product Life Cycles API for version support status of any Red Hat product.

## When to Use

- Check if a specific version of RHBK, Quay, or any Red Hat product is still supported
- Find GA dates, support phase end dates, and EOL dates
- Get RHBK major version summaries (groups minor releases into active/EOL majors)
- Find the latest supported version of any Red Hat product
- Check lifecycle status for products not covered by dedicated lifecycle-* skills

## Prerequisites

- Python 3.9+
- Internet connectivity to reach `https://access.redhat.com`

## Usage

### Check a product by alias

```bash
uv run scripts/check_lifecycle.py --product rhbk
uv run scripts/check_lifecycle.py --product quay
```

### Check by full product name

```bash
uv run scripts/check_lifecycle.py --product "Red Hat Quay"
```

### Filter to a specific version

```bash
uv run scripts/check_lifecycle.py --product rhbk --version 26
```

### RHBK major version grouping

```bash
uv run scripts/check_lifecycle.py --product rhbk --group-major
```

### Show only active versions

```bash
uv run scripts/check_lifecycle.py --product quay --active-only
```

### JSON output

```bash
uv run scripts/check_lifecycle.py --product rhbk --json
```

### List known product aliases

```bash
uv run scripts/check_lifecycle.py --list-products
```

## Known Product Aliases

| Alias | Full Product Name |
|-------|-------------------|
| `rhdh` | Red Hat Developer Hub |
| `ocp` | Red Hat OpenShift Container Platform |
| `rhbk` | Red Hat build of Keycloak |
| `quay` | Red Hat Quay |
| `rosa` | Red Hat OpenShift Service on AWS |
| `osd` | Red Hat OpenShift Dedicated |

Any product name not in the alias list is passed to the API as-is.

## Output

### Version Table

| Column | Description |
|--------|-------------|
| VERSION | Product version (e.g., `26.2`, `3.15`) |
| SUPPORTED | `yes` or `no` |
| TYPE | Support phase name from the API |
| GA_DATE | General Availability date |
| END_DATE | Latest end-of-support date across all phases |

### RHBK Major Version Table (`--group-major`)

| Column | Description |
|--------|-------------|
| MAJOR | Major version number (e.g., `26`) |
| ACTIVE | `yes` if any minor release is still supported |
| GA_DATE | Earliest GA date among minor releases |
| END_DATE | Latest end date among minor releases |
| MINOR_RELEASES | List of minor releases in this major |

## Data Source

**Red Hat Product Life Cycles API**: `https://access.redhat.com/product-life-cycles/api/v1/products?name=<product>`

## Related Skills

- **`lifecycle-rhdh`**: Dedicated RHDH lifecycle with OCP compatibility details
- **`lifecycle-ocp`**: Dedicated OCP lifecycle with EUS phase classification
