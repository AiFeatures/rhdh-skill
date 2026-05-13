#!/usr/bin/env python3
"""Check OCP and RHDH lifecycle status using the Red Hat Product Life Cycles API.

Outputs human-readable tables to stdout and a JSON summary to stderr.

Usage:
  check_ocp_lifecycle.py                          # Show all OCP + RHDH versions
  check_ocp_lifecycle.py --version 4.16           # Check a specific OCP version
  check_ocp_lifecycle.py --rhdh-version 1.9       # Check a specific RHDH version
  check_ocp_lifecycle.py --rhdh-only              # Show only RHDH lifecycle
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Import shared OCP lifecycle classifier
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "_shared"))
from ocp_lifecycle import classify_ocp_versions

LIFECYCLE_API_URL = "https://access.redhat.com/product-life-cycles/api/v1/products"


def fetch_api(product_name):
    """Fetch lifecycle data from the Red Hat Product Life Cycles API."""
    url = f"{LIFECYCLE_API_URL}?name={product_name.replace(' ', '+')}"
    req = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "rhdh-skill"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError) as exc:
        print(f"ERROR: Failed to fetch lifecycle data for {product_name}: {exc}", file=sys.stderr)
        sys.exit(1)


def parse_rhdh_versions(api_data, filter_version=None):
    """Parse RHDH lifecycle data into structured version info."""
    versions_raw = api_data.get("data", [{}])[0].get("versions", [])
    results = []
    for ver in versions_raw:
        name = ver.get("name", "")
        if filter_version and name != filter_version:
            continue
        vtype = ver.get("type", "")
        phases = ver.get("phases", [])

        def phase_date(pname):
            for p in phases:
                if p.get("name") == pname:
                    d = p.get("end_date", "N/A")
                    if d and isinstance(d, str) and d[:4].isdigit():
                        return d[:10]
                    return str(d) if d else "N/A"
            return "N/A"

        ocp_compat = ver.get("openshift_compatibility", "")
        ocp_versions = [v.strip() for v in ocp_compat.split(",") if v.strip()] if ocp_compat else []

        results.append(
            {
                "version": name,
                "type": vtype,
                "supported": vtype != "End of life",
                "ga_date": phase_date("General availability"),
                "full_support_end": phase_date("Full support"),
                "maintenance_end": phase_date("Maintenance support"),
                "ocp_versions": ocp_versions,
            }
        )
    results.sort(
        key=lambda v: [int(x) for x in v["version"].split(".")] if "." in v["version"] else [0]
    )
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check RHDH and OCP lifecycle status.")
    parser.add_argument("--version", "-v", help="Check a specific OCP version")
    parser.add_argument("--rhdh-version", help="Check a specific RHDH version")
    parser.add_argument("--rhdh-only", action="store_true", help="Show only RHDH lifecycle")
    parser.add_argument("--json", dest="json_output", action="store_true", help="Output as JSON")
    args = parser.parse_args(argv)

    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")

    # 1. Fetch RHDH lifecycle data
    rhdh_response = fetch_api("Red Hat Developer Hub")
    rhdh_data = parse_rhdh_versions(rhdh_response, args.rhdh_version)

    if args.rhdh_version and not rhdh_data:
        print(f"ERROR: RHDH version '{args.rhdh_version}' not found", file=sys.stderr)
        sys.exit(1)

    # Print RHDH lifecycle table
    print("=== RHDH Lifecycle ===")
    print()
    print(
        f"{'VERSION':<10s} {'SUPPORTED':<10s} {'TYPE':<22s} {'GA_DATE':<12s} "
        f"{'FULL_SUPPORT_END':<25s} {'MAINTENANCE_END':<25s} SUPPORTED_OCP_VERSIONS"
    )
    print(
        f"{'-------':<10s} {'---------':<10s} {'----':<22s} {'-------':<12s} "
        f"{'----------------':<25s} {'---------------':<25s} ----------------------"
    )
    for v in rhdh_data:
        sup = "yes" if v["supported"] else "no"
        ocp = ", ".join(v["ocp_versions"])
        print(
            f"{v['version']:<10s} {sup:<10s} {v['type']:<22s} {v['ga_date']:<12s} "
            f"{v['full_support_end']:<25s} {v['maintenance_end']:<25s} {ocp}"
        )
    print()

    # Union of OCP versions supported by active RHDH releases
    rhdh_supported_ocp = sorted(
        {ocp for v in rhdh_data if v["supported"] for ocp in v["ocp_versions"]},
        key=lambda x: [int(n) for n in x.split(".")],
    )
    print(f"OCP versions supported by active RHDH releases: {' '.join(rhdh_supported_ocp)}")
    print()
    print("Per-release OCP support:")
    for v in rhdh_data:
        if v["supported"]:
            print(f"  RHDH {v['version']}: {', '.join(v['ocp_versions'])}")
    print()

    # 2. Fetch OCP lifecycle data (unless --rhdh-only)
    if not args.rhdh_only:
        ocp_response = fetch_api("Red Hat OpenShift Container Platform")
        ocp_data = classify_ocp_versions(ocp_response, today)

        if args.version:
            ocp_data = [v for v in ocp_data if v["version"] == args.version]
            if not ocp_data:
                print(f"ERROR: OCP version '{args.version}' not found", file=sys.stderr)
                sys.exit(1)

        print("=== OCP Lifecycle ===")
        print()
        print(
            f"{'VERSION':<10s} {'OCP_SUPP':<10s} {'RHDH_SUPP':<10s} "
            f"{'PHASE':<35s} {'GA_DATE':<12s} {'END_DATE':<12s}"
        )
        print(
            f"{'-------':<10s} {'--------':<10s} {'---------':<10s} "
            f"{'-----':<35s} {'-------':<12s} {'--------':<12s}"
        )
        for v in ocp_data:
            ocp_sup = "yes" if v["ocp_supported"] else "no"
            rhdh_sup = "yes" if v["version"] in rhdh_supported_ocp else "no"
            print(
                f"{v['version']:<10s} {ocp_sup:<10s} {rhdh_sup:<10s} "
                f"{v['phase']:<35s} {v['ga_date']:<12s} {v['end_of_support_date']:<12s}"
            )
        print()

    # 3. JSON summary to stderr
    supported_versions = [v for v in rhdh_data if v["supported"]]
    eol_versions = [v for v in rhdh_data if not v["supported"]]
    summary = {
        "checked_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rhdh_supported_count": len(supported_versions),
        "rhdh_eol_count": len(eol_versions),
        "rhdh_supported_versions": supported_versions,
        "rhdh_eol_versions": eol_versions,
        "ocp_versions_supported_by_rhdh": rhdh_supported_ocp,
    }
    print(json.dumps(summary, indent=2), file=sys.stderr)


if __name__ == "__main__":
    main()
