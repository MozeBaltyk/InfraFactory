#!/usr/bin/env python3
"""Read-only OVH bastion/cluster configuration convergence diagnostics.

Normal mode print bastion<->cluster convergence plus cross-cluster safety
checks. With --preflight it prints only the cross-cluster safety checks and
exits non-zero on any deploy-blocking violation.
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")


def colors():
    if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
        return {
            "heading": "\033[34m",
            "ok": "\033[32m",
            "mismatch": "\033[31m",
            "missing": "\033[33m",
            "skipped": "\033[2m",
            "reset": "\033[0m",
        }
    return {name: "" for name in ("heading", "ok", "mismatch", "missing", "skipped", "reset")}


def evaluate_tfvars(path, expression, variables):
    """Evaluate selected HCL values with OpenTofu without loading any state."""
    with tempfile.TemporaryDirectory(prefix="ovh-config-status-") as tmp:
        module = Path(tmp)
        (module / "main.tf").write_text(
            "\n".join(f'variable "{name}" {{ type = any }}' for name in variables),
            encoding="utf-8",
        )
        result = subprocess.run(
            ["tofu", f"-chdir={module}", "console", f"-var-file={path.resolve()}"],
            input=expression + "\n",
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        if result.returncode:
            raise ValueError("OpenTofu could not evaluate tfvars")
        # OpenTofu emits undeclared-variable warnings to stdout before the value.
        value = next((line for line in reversed(result.stdout.splitlines()) if line.strip()), "")
        return json.loads(json.loads(value))


def compare_configs(bastion, clusters, project_root, bastion_module, check_bidirectional=True):
    lines = []
    entries = bastion["clusters"]
    id_counts = Counter(cluster["id"] for cluster in clusters.values())
    parsed_ids = set(id_counts)
    if any(count > 1 for count in id_counts.values()):
        lines.append(("mismatch", "cluster tfvars: duplicate cluster.id"))

    for workspace, cluster in sorted(clusters.items()):
        cluster_id = cluster["id"]
        if workspace != cluster_id:
            lines.append(("mismatch", f"cluster {workspace}: workspace differs from cluster.id"))
        entry = entries.get(cluster_id)
        if entry is None:
            lines.append(("missing", f"cluster {cluster_id}: absent from bastion clusters map"))
            continue

        mismatches = [
            label
            for label, expected, actual in (
                ("CIDR", cluster["cidr"], entry["cidr"]),
                ("VLAN ID", cluster["vlan_id"], entry["vlan_id"]),
                ("node count", cluster["nodes"], entry["nodes"]),
            )
            if expected != actual
        ]
        if mismatches:
            lines.append(("mismatch", f"cluster {cluster_id}: {', '.join(mismatches)}"))
        else:
            lines.append(("ok", f"cluster {cluster_id}: map key, CIDR, VLAN ID and node count"))

        if cluster["region"] == bastion["region"]:
            lines.append(("ok", f"cluster {cluster_id}: region matches bastion"))
        else:
            lines.append(("mismatch", f"cluster {cluster_id}: region differs from bastion"))

        key_file = entry.get("public_key_file")
        key_path = Path(key_file) if key_file else project_root / "clusters" / cluster_id / ".key.pub"
        if key_file and not key_path.is_absolute():
            key_path = bastion_module / key_path
        if key_path.is_file() and key_path.stat().st_size:
            lines.append(("ok", f"cluster {cluster_id}: public-key artifact exists"))
        else:
            lines.append(("missing", f"cluster {cluster_id}: public-key artifact"))

    if check_bidirectional:
        for name in sorted(set(entries) - parsed_ids):
            lines.append(("missing", f"bastion entry {name}: no matching cluster tfvars"))

    cidrs = Counter(entry["cidr"] for entry in entries.values())
    vlans = Counter(entry["vlan_id"] for entry in entries.values())
    duplicates = []
    if any(count > 1 for count in cidrs.values()):
        duplicates.append("CIDRs")
    if any(count > 1 for count in vlans.values()):
        duplicates.append("VLAN IDs")
    if duplicates:
        lines.append(("mismatch", f"bastion clusters: duplicate {' and '.join(duplicates)}"))
    else:
        lines.append(("ok", "bastion clusters: CIDRs and VLAN IDs are unique"))
    return lines


def deployed_bastion_ip(repo, project_root, project, bastion_env):
    command = r'''
set -euo pipefail
if [[ -f $1 ]]; then set -a; source "$1"; set +a; fi
export TF_DATA_DIR=$2 TF_WORKSPACE=$3
exec tofu -chdir="$4" output -raw public_ip
'''
    result = subprocess.run(
        [
            "bash",
            "-c",
            command,
            "bash",
            str(project_root / ".env"),
            str(repo / ".local" / "tofu-data" / "ovh" / project / "bastion"),
            bastion_env,
            str(repo / "providers" / "ovh" / "bastion"),
        ],
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    output = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return output[-1] if result.returncode == 0 and output else None


CLUSTER_EXPRESSION = "jsonencode({id=var.cluster.id,region=var.cluster.region,cidr=var.network.private.cidr,vlan_id=try(var.network.private.vlan_id,0),nodes=var.infra.masters.count+var.infra.workers.count,bastion_public_ip=try(var.bastion.public_ip,null)})"
BASTION_EXPRESSION = "jsonencode({region=var.bastion.region,clusters={for name,c in var.clusters:name=>{cidr=c.cidr,vlan_id=try(c.vlan_id,0),nodes=try(c.nodes,1),public_key_file=try(c.public_key_file,null)}}})"


def cluster_state_values(repo, project_root, project, workspace):
    """Return {type.name: values} from the cluster workspace state, or None."""
    command = r'''
set -euo pipefail
if [[ -f $1 ]]; then set -a; source "$1"; set +a; fi
export TF_DATA_DIR=$2 TF_WORKSPACE=$3
exec tofu -chdir="$4" show -json
'''
    result = subprocess.run(
        [
            "bash", "-c", command, "bash",
            str(project_root / ".env"),
            str(repo / ".local" / "tofu-data" / "ovh" / project / "clusters"),
            workspace,
            str(repo / "providers" / "ovh" / "clusters"),
        ],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    if result.returncode:
        return None
    try:
        state = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    resources = []

    def walk(module):
        resources.extend(module.get("resources", []))
        for child in module.get("child_modules", []):
            walk(child)

    walk(state.get("values", {}).get("root_module", {}))
    return {f"{r.get('type')}.{r.get('name')}": (r.get("values") or {}) for r in resources}


def cross_cluster_checks(clusters, repo, project_root, project):
    """Deploy-blocking invariants across cluster tfvars and their states.

    OVH private networks are uniquely keyed by (project, region, vlan_id), so
    two cluster tfvars in one project must never share a VLAN or overlapping
    CIDR, and each workspace's state must own the network matching its own
    cluster.id/vlan. Returns (lines, hard_violation).
    """
    lines = []
    hard = False

    # VLAN uniqueness (the OVH private-network identity key).
    by_vlan = {}
    for cluster in clusters.values():
        by_vlan.setdefault(cluster["vlan_id"], []).append(cluster["id"])
    duplicated = sorted(((v, names) for v, names in by_vlan.items() if len(names) > 1), key=lambda kv: str(kv[0]))
    if duplicated:
        for vlan, names in duplicated:
            lines.append(("mismatch", f"duplicate VLAN ID {vlan} across clusters: {', '.join(sorted(names))}"))
        hard = True
    else:
        lines.append(("ok", "clusters: VLAN IDs are unique in this project+region"))

    # CIDR validity and overlap.
    cidr_issues = False
    nets = []
    for cluster in clusters.values():
        try:
            nets.append((cluster["id"], ipaddress.ip_network(cluster["cidr"], strict=False)))
        except ValueError:
            lines.append(("mismatch", f"cluster {cluster['id']}: invalid CIDR '{cluster['cidr']}'"))
            hard = True
            cidr_issues = True
    for i in range(len(nets)):
        for j in range(i + 1, len(nets)):
            if nets[i][1].overlaps(nets[j][1]):
                lines.append(("mismatch", f"CIDR overlap: {nets[i][0]} ({nets[i][1]}) with {nets[j][0]} ({nets[j][1]})"))
                hard = True
                cidr_issues = True
    if not cidr_issues:
        lines.append(("ok", "clusters: CIDRs are valid and non-overlapping"))

    # State identity + cross-workspace duplicate ownership.
    owners = {}
    for workspace, cluster in sorted(clusters.items()):
        cluster_id = cluster["id"]
        state = cluster_state_values(repo, project_root, project, workspace)
        if state is None:
            lines.append(("skipped", f"cluster {cluster_id}: state unavailable (network identity not checked)"))
            continue
        net = state.get("ovh_cloud_project_network_private.cluster")
        if net is None:
            lines.append(("ok", f"cluster {cluster_id}: no private network in state yet"))
            continue
        expected_name = f"{cluster_id}-private"
        name, vlan = net.get("name"), net.get("vlan_id")
        if name != expected_name or vlan != cluster["vlan_id"]:
            got = f"{name} (vlan {vlan})" if name is not None else f"vlan {vlan}"
            lines.append(("mismatch", f"cluster {cluster_id}: state network {got} != expected {expected_name} (vlan {cluster['vlan_id']})"))
            hard = True
        else:
            lines.append(("ok", f"cluster {cluster_id}: state network identity matches tfvars"))
        net_id = net.get("id")
        if net_id:
            owners.setdefault(net_id, []).append(f"{cluster_id} ('{name}')")
    for net_id, names in owners.items():
        if len(names) > 1:
            lines.append(("mismatch", f"private network {net_id} owned by multiple workspaces: {', '.join(sorted(names))}"))
            hard = True
    return lines, hard


def select_bastion(project_root, requested=None):
    """Return (bastion_env, bastion_tfvars) or (None, None)."""
    bastion_dir = project_root / "bastion"
    if requested:
        if not SAFE_NAME.fullmatch(requested) or requested in {".", ".."}:
            return None, None
        tfvars = bastion_dir / f"{requested}.tfvars"
        return (requested, tfvars) if tfvars.is_file() else (None, tfvars)
    candidates = sorted(bastion_dir.glob("*.tfvars"))
    if len(candidates) != 1:
        return None, None
    return candidates[0].stem, candidates[0]


def bastion_port_exists(repo, project_root, project, bastion_env, cluster_id):
    """True/False whether the bastion state still owns this cluster's private port, None if unreadable."""
    command = r'''
set -euo pipefail
if [[ -f $1 ]]; then set -a; source "$1"; set +a; fi
export TF_DATA_DIR=$2 TF_WORKSPACE=$3
exec tofu -chdir="$4" state list
'''
    result = subprocess.run(
        [
            "bash", "-c", command, "bash",
            str(project_root / ".env"),
            str(repo / ".local" / "tofu-data" / "ovh" / project / "bastion"),
            bastion_env,
            str(repo / "providers" / "ovh" / "bastion"),
        ],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    if result.returncode:
        return None
    return f'openstack_networking_port_v2.bastion_private["{cluster_id}"]' in result.stdout


def detach_violations(cluster_keys, port_exists, destroy_env):
    """Violations that would block a clean cluster destroy (bastion detach)."""
    lines = []
    hard = False
    if destroy_env in cluster_keys:
        lines.append(("mismatch", f"cluster {destroy_env} is still in the bastion clusters map; remove it and apply the bastion before destroy"))
        hard = True
    else:
        lines.append(("ok", f"cluster {destroy_env} is absent from the bastion clusters map"))
    if port_exists is True:
        lines.append(("mismatch", f"bastion still owns a private port for {destroy_env}; apply the bastion after removing the entry"))
        hard = True
    elif port_exists is False:
        lines.append(("ok", f"bastion no longer owns a private port for {destroy_env}"))
    else:
        lines.append(("skipped", "bastion state unavailable (port detach not verified)"))
    return lines, hard


def octavia_port_ids(project_root, network_id):
    """List live Octavia-owned ports on the network (id, ip). None if unreadable."""
    command = r'''
set -euo pipefail
for f in "${OPENRC:-}" "$1"; do if [[ -n $f && -f $f ]]; then set -a; source "$f"; set +a; break; fi
done
openstack port list --network "$2" --device-owner Octavia -f value -c ID -c "Fixed IP Addresses"
'''
    result = subprocess.run(
        ["bash", "-c", command, "bash", str(project_root / "openrc.sh"), network_id],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    if result.returncode:
        return None
    ports = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(None, 1)
        ports.append((parts[0], parts[1] if len(parts) > 1 else "-"))
    return ports


def octavia_orphan_violations(has_lb, ports):
    """Octavia ports are expected only while the LB is still in state to be destroyed."""
    lines = []
    hard = False
    if ports and has_lb:
        lines.append(("ok", "Octavia ports present and LB still in state (destroy will clean them)"))
    elif ports and not has_lb:
        for pid, ip in ports:
            lines.append(("mismatch", f"orphaned Octavia port {pid} ({ip}); no LB in state — delete it before destroy"))
        hard = True
    else:
        lines.append(("ok", "no orphaned Octavia ports on cluster network"))
    return lines, hard


def main():
    argv = sys.argv[1:]
    mode = "env"
    destroy_env = None
    if argv and argv[0] == "--preflight":
        mode = "preflight"
        argv = argv[1:]
    elif argv and argv[0] == "--destroy":
        if len(argv) < 2:
            print(f"usage: {sys.argv[0]} --destroy ENV REPO PROJECT", file=sys.stderr)
            return 2
        mode = "destroy"
        destroy_env = argv[1]
        argv = argv[2:]
    if len(argv) != 2:
        print(f"usage: {sys.argv[0]} [--preflight | --destroy ENV] REPO PROJECT", file=sys.stderr)
        return 2
    repo = Path(argv[0]).resolve()
    project = argv[1]
    if not SAFE_NAME.fullmatch(project) or project in {".", ".."}:
        return 2
    if destroy_env is not None and (not SAFE_NAME.fullmatch(destroy_env) or destroy_env in {".", ".."}):
        return 2

    project_root = repo / "env" / "OVH" / project
    bastion_dir = project_root / "bastion"
    color = colors()
    heading = {"env": "OVH configuration convergence", "preflight": "OVH preflight", "destroy": "OVH destroy preflight"}[mode]
    print(f"\n{color['heading']}{heading}{color['reset']}")

    def print_status(name, message):
        print(f"  {color[name]}[{name}]{color['reset']} {message}")

    # Evaluate every cluster tfvars (shared by all modes).
    clusters = {}
    parse_failed = False
    cluster_files = sorted((project_root / "clusters").glob("*.tfvars"))
    if not cluster_files:
        print_status("missing", "project has no cluster tfvars")
    for path in cluster_files:
        try:
            clusters[path.stem] = evaluate_tfvars(
                path, CLUSTER_EXPRESSION, ("cluster", "network", "infra", "bastion")
            )
        except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError):
            parse_failed = True
            print_status("skipped", f"cluster {path.stem}: tfvars could not be evaluated with OpenTofu")

    if mode == "destroy":
        bastion_env, bastion_tfvars = select_bastion(project_root, os.environ.get("BASTION_ENV"))
        if bastion_env is None or bastion_tfvars is None:
            print_status("missing", "bastion selection: set BASTION_ENV or provide exactly one bastion tfvars")
            return 1
        try:
            bastion = evaluate_tfvars(bastion_tfvars, BASTION_EXPRESSION, ("bastion", "clusters"))
        except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError):
            print_status("skipped", "bastion tfvars could not be evaluated with OpenTofu")
            return 1
        port = bastion_port_exists(repo, project_root, project, bastion_env, destroy_env)
        lines, hard = detach_violations(set(bastion["clusters"].keys()), port, destroy_env)
        for status, message in lines:
            print(f"  {color[status]}[{status}]{color['reset']} {message}")

        # Octavia amphora ports orphaned by a prior LB destroy block subnet deletion.
        state = cluster_state_values(repo, project_root, project, destroy_env)
        network_id = None
        has_lb = False
        if state is not None:
            has_lb = "ovh_cloud_project_loadbalancer.kube_api" in state
            regions = (state.get("ovh_cloud_project_network_private.cluster") or {}).get("regions_openstack_ids") or {}
            network_id = next(iter(regions.values()), None)
        if network_id is None:
            print_status("skipped", "cluster network not found in state (octavia orphan check skipped)")
        else:
            ports = octavia_port_ids(project_root, network_id)
            if ports is None:
                print_status("skipped", "OpenStack port listing unavailable (octavia orphan check skipped)")
            else:
                o_lines, o_hard = octavia_orphan_violations(has_lb, ports)
                for status, message in o_lines:
                    print(f"  {color[status]}[{status}]{color['reset']} {message}")
                hard = hard or o_hard
        return 1 if hard else 0

    # Cross-cluster deploy-blocking invariants (env + preflight modes).
    cross_lines, hard = cross_cluster_checks(clusters, repo, project_root, project)
    for status, message in cross_lines:
        print(f"  {color[status]}[{status}]{color['reset']} {message}")

    if mode == "preflight":
        if parse_failed:
            print_status("skipped", "some cluster tfvars could not be evaluated; re-check manually")
        return 1 if hard else 0

    requested = os.environ.get("BASTION_ENV")
    if requested:
        if not SAFE_NAME.fullmatch(requested) or requested in {".", ".."}:
            print_status("skipped", "bastion selection: BASTION_ENV is not a path-safe identifier")
            return 0
        bastion_env = requested
        bastion_tfvars = bastion_dir / f"{bastion_env}.tfvars"
        if not bastion_tfvars.is_file():
            print_status("missing", "bastion selection: BASTION_ENV tfvars")
            return 0
    else:
        candidates = sorted(bastion_dir.glob("*.tfvars"))
        if len(candidates) != 1:
            print_status(
                "skipped",
                "bastion selection: set BASTION_ENV "
                f"({len(candidates)} bastion tfvars found; exactly one required)"
            )
            return 0
        bastion_tfvars = candidates[0]
        bastion_env = bastion_tfvars.stem

    try:
        bastion = evaluate_tfvars(bastion_tfvars, BASTION_EXPRESSION, ("bastion", "clusters"))
    except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError):
        print_status("skipped", "bastion tfvars could not be evaluated with OpenTofu")
        return 0

    for status, message in compare_configs(
        bastion,
        clusters,
        project_root,
        repo / "providers" / "ovh" / "bastion",
        check_bidirectional=not parse_failed,
    ):
        print(f"  {color[status]}[{status}]{color['reset']} {message}")
    if parse_failed:
        print_status("skipped", "full bidirectional map check: some cluster tfvars could not be evaluated")

    state_ip = deployed_bastion_ip(repo, project_root, project, bastion_env)
    for cluster in sorted(clusters.values(), key=lambda item: item["id"]):
        cluster_id = cluster["id"]
        configured_ip = cluster["bastion_public_ip"]
        if state_ip is None:
            status, message = "skipped", "deployed bastion public IP unavailable"
        elif configured_ip is None:
            status, message = "missing", "bastion.public_ip"
        elif configured_ip != state_ip:
            status, message = "mismatch", "bastion public IP differs from deployed state"
        else:
            status, message = "ok", "bastion public IP matches deployed state"
        print(f"  {color[status]}[{status}]{color['reset']} cluster {cluster_id}: {message}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
