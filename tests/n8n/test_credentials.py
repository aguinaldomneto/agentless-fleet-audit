#!/usr/bin/env python3
"""Workflows só referenciam credenciais que o credentials.py cria (mesmo ID, nome e tipo)."""
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "n8n"))
import credentials  # noqa: E402

ENV = {"INVENTORY_RW_PASSWORD": "p", "GATEWAY_TOKEN": "g", "BRIDGE_TOKEN": "b",
       "JIRA_EMAIL": "a@b.c", "JIRA_API_TOKEN": "t"}


class TestCredentials(unittest.TestCase):
    def test_nos_usam_credenciais_geradas(self):
        created = {c["id"]: c for c in credentials.build(ENV)}
        for wf_path in sorted((ROOT / "n8n" / "workflows").glob("*.json")):
            wf = json.loads(wf_path.read_text())
            for node in wf["nodes"]:
                for ctype, ref in node.get("credentials", {}).items():
                    where = f"{wf_path.name}: {node['name']}"
                    self.assertIn(ref["id"], created, where)
                    self.assertEqual(created[ref["id"]]["type"], ctype, where)
                    self.assertEqual(created[ref["id"]]["name"], ref["name"], where)

    def test_nos_que_autenticam_tem_credencial(self):
        for wf_path in sorted((ROOT / "n8n" / "workflows").glob("*.json")):
            for node in json.loads(wf_path.read_text())["nodes"]:
                p = node["parameters"]
                needs = node["type"].endswith(".postgres") or p.get("authentication") not in (None, "none")
                if needs:
                    self.assertTrue(node.get("credentials"), f"{wf_path.name}: {node['name']} sem credencial")

    def test_jira_opcional(self):
        base = {k: v for k, v in ENV.items() if not k.startswith("JIRA")}
        self.assertNotIn("httpBasicAuth", {c["type"] for c in credentials.build(base)})

    def test_variavel_faltando_aborta(self):
        with self.assertRaises(SystemExit):
            credentials.build({"GATEWAY_TOKEN": "g", "BRIDGE_TOKEN": "b"})

    def test_env_com_aspas_e_comentarios(self):
        path = ROOT / "tests" / "n8n" / "_tmp.env"
        path.write_text("# comentario\nJIRA_API_TOKEN=\"a=b/c\"\nX='y'\n\n")
        try:
            env = credentials.read_env(path)
        finally:
            path.unlink()
        self.assertEqual(env["JIRA_API_TOKEN"], "a=b/c")
        self.assertEqual(env["X"], "y")


if __name__ == "__main__":
    unittest.main(verbosity=1)
