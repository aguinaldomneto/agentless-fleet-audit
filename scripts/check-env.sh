#!/bin/sh
# Valida o .env antes de qualquer coisa lê-lo (make, docker compose, n8n/credentials.py).
# Nunca imprime valor de segredo, só nomes de variável e números de linha.
set -eu

f=${1:-.env}

if [ ! -f "$f" ]; then
    echo "ERRO: $f não encontrado"
    exit 1
fi

erro=0

if grep -q "$(printf '\r')" "$f"; then
    printf '%s\n' "ERRO: $f tem quebra de linha CRLF (editado no Windows/Bloco de Notas). Corrija com: sed -i 's/\\r\$//' $f"
    erro=1
fi

awk -F= '
    /^[A-Za-z_][A-Za-z0-9_]*=/ && /[ \t]$/ { print "ERRO: linha " NR " (" $1 ") termina com espaço ou tab"; e=1 }
    END { exit e }
' "$f" || erro=1

awk '
    !/^[ \t]*#/ && NF && !/=/ { print "ERRO: linha " NR " sem \"=\" (token colado quebrou em duas linhas?)"; e=1 }
    END { exit e }
' "$f" || erro=1

# Sempre obrigatórias: sem elas o docker compose ou o n8n/credentials.py já falham,
# mas aqui a mensagem aponta a variável sem precisar ler stack trace de container.
for v in POSTGRES_PASSWORD N8N_DB_PASSWORD INVENTORY_RW_PASSWORD GRAFANA_RO_PASSWORD \
    GRAFANA_ADMIN_PASSWORD N8N_ENCRYPTION_KEY GATEWAY_TOKEN BRIDGE_TOKEN TELEGRAM_BOT_TOKEN; do
    grep -q "^$v=." "$f" || { echo "ERRO: $v vazio ou ausente"; erro=1; }
done

# Jira é opcional (ver .env.example), mas não pode ficar preenchido pela metade.
jira_email=$(grep -c "^JIRA_EMAIL=." "$f" || true)
jira_token=$(grep -c "^JIRA_API_TOKEN=." "$f" || true)
if [ "$jira_email" -ne "$jira_token" ]; then
    echo "ERRO: JIRA_EMAIL e JIRA_API_TOKEN têm que estar os dois preenchidos ou os dois vazios"
    erro=1
fi

if [ "$erro" -eq 0 ]; then
    echo "OK: $f validado"
fi
exit "$erro"
