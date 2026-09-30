#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "ovh" / "config-status.py"
SPEC = importlib.util.spec_from_file_location("ovh_config_status", SCRIPT)
STATUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATUS)


class OvhConfigStatusTest(unittest.TestCase):
    def test_hcl_evaluation_and_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            key = root / "clusters" / "alpha" / ".key.pub"
            key.parent.mkdir(parents=True)
            key.write_text("ssh-ed25519 test\n", encoding="utf-8")
            cluster_file = root / "alpha.tfvars"
            cluster_file.write_text(
                '''
cluster = { id = "alpha", region = "GRA11" }
network = { private = { cidr = "10.0.1.0/24", vlan_id = 1 } }
infra = { masters = { count = 2 }, workers = { count = 1 } }
bastion = { public_ip = "192.0.2.1" }
''',
                encoding="utf-8",
            )
            bastion_file = root / "bastion.tfvars"
            bastion_file.write_text(
                '''
bastion = { region = "GRA11" }
clusters = { alpha = { cidr = "10.0.1.0/24", vlan_id = 1, nodes = 3 } }
''',
                encoding="utf-8",
            )
            cluster = STATUS.evaluate_tfvars(
                cluster_file,
                "jsonencode({id=var.cluster.id,region=var.cluster.region,cidr=var.network.private.cidr,vlan_id=var.network.private.vlan_id,nodes=var.infra.masters.count+var.infra.workers.count,bastion_public_ip=var.bastion.public_ip})",
                ("cluster", "network", "infra", "bastion"),
            )
            bastion = STATUS.evaluate_tfvars(
                bastion_file,
                "jsonencode({region=var.bastion.region,clusters={for name,c in var.clusters:name=>{cidr=c.cidr,vlan_id=c.vlan_id,nodes=c.nodes,public_key_file=try(c.public_key_file,null)}}})",
                ("bastion", "clusters"),
            )
            results = STATUS.compare_configs(
                bastion, {"alpha": cluster}, root, root
            )
            self.assertTrue(results)
            self.assertEqual({status for status, _ in results}, {"ok"})

            bastion["clusters"]["alpha"]["nodes"] = 2
            bastion["clusters"]["orphan"] = {
                "cidr": "10.0.1.0/24",
                "vlan_id": 1,
                "nodes": 1,
                "public_key_file": None,
            }
            results = STATUS.compare_configs(bastion, {"alpha": cluster}, root, root)
            self.assertIn(("mismatch", "cluster alpha: node count"), results)
            self.assertIn(("missing", "bastion entry orphan: no matching cluster tfvars"), results)
            self.assertIn(("mismatch", "bastion clusters: duplicate CIDRs and VLAN IDs"), results)

    def test_cross_cluster_checks_block_duplicates_and_overlap(self):
        clusters = {
            "alpha": {"id": "alpha", "region": "GRA11", "cidr": "10.0.10.0/24", "vlan_id": 10, "nodes": 3},
            "beta": {"id": "beta", "region": "GRA11", "cidr": "10.0.10.0/25", "vlan_id": 10, "nodes": 3},
        }
        with mock.patch.object(STATUS, "cluster_state_values", return_value=None):
            lines, hard = STATUS.cross_cluster_checks(clusters, Path("/nonexistent"), Path("/nonexistent"), "p")
        self.assertTrue(hard)
        messages = [m for _, m in lines]
        self.assertTrue(any(m.startswith("duplicate VLAN ID 10") for m in messages))
        self.assertTrue(any(m.startswith("CIDR overlap:") for m in messages))

    def test_cross_cluster_checks_pass_when_unique(self):
        clusters = {
            "alpha": {"id": "alpha", "region": "GRA11", "cidr": "10.0.10.0/24", "vlan_id": 10, "nodes": 3},
            "beta": {"id": "beta", "region": "GRA11", "cidr": "10.0.20.0/24", "vlan_id": 20, "nodes": 3},
        }
        with mock.patch.object(STATUS, "cluster_state_values", return_value=None):
            lines, hard = STATUS.cross_cluster_checks(clusters, Path("/nonexistent"), Path("/nonexistent"), "p")
        self.assertFalse(hard)
        self.assertEqual({s for s, _ in lines if s != "skipped"}, {"ok"})

    def test_detach_violations_block_when_bastion_references_cluster(self):
        lines, hard = STATUS.detach_violations({"alpha", "beta"}, True, "alpha")
        self.assertTrue(hard)
        self.assertIn(
            ("mismatch", "cluster alpha is still in the bastion clusters map; remove it and apply the bastion before destroy"),
            lines,
        )
        self.assertIn(("mismatch", "bastion still owns a private port for alpha; apply the bastion after removing the entry"), lines)

    def test_detach_violations_pass_when_detached(self):
        lines, hard = STATUS.detach_violations({"beta"}, False, "alpha")
        self.assertFalse(hard)
        self.assertEqual({s for s, _ in lines}, {"ok"})

    def test_octavia_orphan_blocked_only_without_lb(self):
        ports = [("a6780655-076e-4aec-aac0-b12bf37f469b", "10.0.30.70")]
        # LB still in state: ports are expected and cleaned during destroy.
        lines, hard = STATUS.octavia_orphan_violations(True, ports)
        self.assertFalse(hard)
        self.assertEqual({s for s, _ in lines}, {"ok"})
        # LB gone but port remains: orphan blocks subnet deletion.
        lines, hard = STATUS.octavia_orphan_violations(False, ports)
        self.assertTrue(hard)
        self.assertIn(("mismatch", "orphaned Octavia port a6780655-076e-4aec-aac0-b12bf37f469b (10.0.30.70); no LB in state — delete it before destroy"), lines)
        # No ports at all.
        lines, hard = STATUS.octavia_orphan_violations(False, [])
        self.assertFalse(hard)
        self.assertEqual({s for s, _ in lines}, {"ok"})


if __name__ == "__main__":
    unittest.main()
