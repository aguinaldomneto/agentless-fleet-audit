#!/usr/bin/env python3
"""
Mantém o código dos Code nodes versionado em arquivos .js testáveis.

  python3 n8n/sync_code.py          # copia n8n/code/*.js para dentro dos workflows
  python3 n8n/sync_code.py --check  # CI: falha se JSON e .js estiverem diferentes

Ligação: o nó precisa ter  "notes": "code: <arquivo>.js".
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).parent
check = "--check" in sys.argv
drift = []

for wf_path in sorted((ROOT / "workflows").glob("*.json")):
    wf = json.loads(wf_path.read_text())
    changed = False
    for node in wf["nodes"]:
        note = node.get("notes", "")
        if not note.startswith("code: "):
            continue
        src = (ROOT / "code" / note[len("code: "):].strip()).read_text()
        if node["parameters"].get("jsCode") != src:
            drift.append(f"{wf_path.name}: {node['name']}")
            node["parameters"]["jsCode"] = src
            changed = True
    if changed and not check:
        wf_path.write_text(json.dumps(wf, ensure_ascii=False, indent=2) + "\n")

if check and drift:
    sys.exit("código fora de sincronia (rode python3 n8n/sync_code.py):\n  " + "\n  ".join(drift))
print("sincronizado" if not drift else "atualizado: " + ", ".join(drift))
