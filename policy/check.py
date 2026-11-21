"""Cost guardrail checks for a Terraform plan (terraform show -json) and an Infracost estimate.

Usage:
  python policy/check.py tags         plan.json
  python policy/check.py rightsizing  plan.json
  python policy/check.py availability plan.json
  python policy/check.py budget       infracost.json 20

Each check prints PASS or FAIL lines and exits with 1 if anything failed, which stops the pipeline.
No third-party packages needed.
"""
import json
import os
import sys

REQUIRED_TAGS = ["Project", "CostCenter", "Owner", "Environment"]
ALLOWED_FAMILIES = ["t4g", "t3", "t3a"]           # burstable, cheap families
ALLOWED_SIZES = ["nano", "micro", "small", "medium"]
MAX_DISK_GB = 20


def planned(plan):
    """Resources the plan creates or updates, with their values after the change."""
    for rc in plan.get("resource_changes", []):
        if set(rc["change"]["actions"]) & {"create", "update"}:
            yield rc["type"], rc["address"], rc["change"]["after"] or {}


def check_tags(plan):
    results = []
    for rtype, addr, after in planned(plan):
        if "tags_all" in after:
            missing = [t for t in REQUIRED_TAGS if t not in (after.get("tags_all") or {})]
            results.append((not missing, f"{addr} has cost tags" if not missing else f"{addr} is missing tags: {', '.join(missing)}"))
        if rtype == "aws_launch_template":
            for spec in after.get("tag_specifications") or []:
                missing = [t for t in REQUIRED_TAGS if t not in (spec.get("tags") or {})]
                kind = spec.get("resource_type")
                results.append((not missing, f"{addr} tags every {kind}" if not missing else f"{addr} {kind}s are missing tags: {', '.join(missing)}"))
    return results


def check_rightsizing(plan):
    results = []
    resources = list(planned(plan))
    for rtype, addr, after in resources:
        if rtype == "aws_launch_template":
            itype = after.get("instance_type") or ""
            family, _, size = itype.partition(".")
            ok = family in ALLOWED_FAMILIES and size in ALLOWED_SIZES
            results.append((ok, f"{addr} uses {itype}" if ok else f"{addr} uses {itype}; allowed: {'/'.join(ALLOWED_FAMILIES)} up to medium"))
            for bdm in after.get("block_device_mappings") or []:
                for ebs in bdm.get("ebs") or []:
                    gb, vtype = ebs.get("volume_size") or 0, ebs.get("volume_type")
                    ok = gb <= MAX_DISK_GB and vtype == "gp3"
                    results.append((ok, f"{addr} disk is {gb} GB {vtype}" if ok else f"{addr} disk is {gb} GB {vtype}; use gp3, {MAX_DISK_GB} GB or less"))
    has_scaling = any(t == "aws_autoscaling_policy" and a.get("policy_type") == "TargetTrackingScaling" for t, _, a in resources)
    results.append((has_scaling, "Auto Scaling follows load (target tracking)" if has_scaling else "No target tracking scaling policy: capacity won't follow load"))
    has_night = any(t == "aws_autoscaling_schedule" for t, _, _ in resources)
    results.append((has_night, "Scales down in quiet hours" if has_night else "No scheduled scale-down for quiet hours"))
    return results


def check_availability(plan):
    results = []
    resources = list(planned(plan))
    zones = {a.get("availability_zone") for t, _, a in resources if t == "aws_subnet"}
    results.append((len(zones) >= 2, f"Spread across {len(zones)} Availability Zones"))
    for rtype, addr, after in resources:
        if rtype == "aws_autoscaling_group":
            n = after.get("min_size") or 0
            results.append((n >= 2, f"{addr} keeps at least {n} instances by day" if n >= 2 else f"{addr} min_size is {n}; needs 2 to survive losing one"))
        if rtype == "aws_autoscaling_schedule":
            n = after.get("min_size") or 0
            results.append((n >= 1, f"{addr} never scales below {n}" if n >= 1 else f"{addr} scales to 0, so the service goes down"))
    return results


def check_budget(estimate, limit):
    cost = float(estimate.get("totalMonthlyCost") or 0)
    ok = cost <= limit
    return [(ok, f"Estimated ${cost:.2f}/month is within the ${limit:.0f} budget ({cost / limit:.0%})" if ok
             else f"Estimated ${cost:.2f}/month is over the ${limit:.0f} budget")]


def report(name, results):
    lines = [f"{'PASS' if ok else 'FAIL'}  {msg}" for ok, msg in results]
    print("\n".join(lines))
    failed = sum(1 for ok, _ in results if not ok)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### {name}: {'passed' if not failed else f'{failed} failed'}\n\n```\n" + "\n".join(lines) + "\n```\n")
    return 1 if failed or not results else 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, path = argv[0], argv[1]
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if cmd == "budget":
        return report("Budget gate", check_budget(data, float(argv[2])))
    checks = {"tags": ("Cost tag check", check_tags), "rightsizing": ("Rightsizing check", check_rightsizing),
              "availability": ("Availability check", check_availability)}
    name, fn = checks[cmd]
    return report(name, fn(data))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
