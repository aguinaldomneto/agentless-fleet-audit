#!/usr/bin/env python3
"""
Gera as credenciais do n8n a partir do .env, com IDs fixos.

Os workflows versionados referenciam esses IDs, então depois de
`make n8n-setup` nenhum nó precisa de credencial escolhida na mão.

Saída: JSON no stdout, no formato do `n8n import:credentials`. O n8n cifra
os dados com N8N_ENCRYPTION_KEY na importação; o JSON só existe em memória
(pipe) e num arquivo temporário apagado dentro do container.

Jira é opcional: só entra se JIRA_EMAIL e JIRA_API_TOKEN estiverem no .env.

Uso: python3 n8n/credentials.py [.env]  |  python3 n8n/credentials.py --ids
"""
import json
import sys

# IDs fixos (16 caracteres alfanuméricos, como os do n8n). Os workflows usam estes.
IDS = {
    "postgres": "fleetAuditPostgr",
    "gateway": "fleetAuditGatewy",
    "bridge": "fleetAuditBridge",
    "jira": "fleetAuditJiraBA",
}


def read_env(path):
    env = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            env[key.strip()] = value
    return env


def build(env):
    def need(key):
        if not env.get(key):
            sys.exit(f"credentials.py: {key} vazio no .env")
        return env[key]

    creds = [
        {"id": IDS["postgres"], "name": "Postgres (inventory_rw)", "type": "postgres",
         "data": {"host": "postgres", "port": 5432, "database": "inventory",
                  "user": "inventory_rw", "password": need("INVENTORY_RW_PASSWORD"),
                  "ssl": "disable"}},
        {"id": IDS["gateway"], "name": "Gateway", "type": "httpHeaderAuth",
         "data": {"name": "X-Gateway-Token", "value": need("GATEWAY_TOKEN")}},
        {"id": IDS["bridge"], "name": "Bridge", "type": "httpHeaderAuth",
         "data": {"name": "X-Bridge-Token", "value": need("BRIDGE_TOKEN")}},
    ]
    if env.get("JIRA_EMAIL") and env.get("JIRA_API_TOKEN"):
        creds.append({"id": IDS["jira"], "name": "Jira", "type": "httpBasicAuth",
                      "data": {"user": env["JIRA_EMAIL"], "password": env["JIRA_API_TOKEN"]}})
    return creds


def main(argv):
    if argv[1:2] == ["--ids"]:
        print(json.dumps(IDS))
        return
    creds = build(read_env(argv[1] if len(argv) > 1 else ".env"))
    json.dump(creds, sys.stdout)
    names = ", ".join(c["name"] for c in creds)
    sys.stderr.write(f"credenciais geradas: {names}\n")


if __name__ == "__main__":
    main(sys.argv)
