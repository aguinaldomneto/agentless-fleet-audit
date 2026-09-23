# Atalhos do laboratório. Requer: docker compose, ssh, openssl.
SSH_OPTS = -i lab/keys/collector -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
SECRETS  = POSTGRES_PASSWORD N8N_DB_PASSWORD INVENTORY_RW_PASSWORD GRAFANA_RO_PASSWORD \
           GRAFANA_ADMIN_PASSWORD N8N_ENCRYPTION_KEY GATEWAY_TOKEN

.PHONY: env keys up down reset migrate import-workflows test test-sql test-gateway lint \
        collect-debian collect-rocky collect-alpine forget-hostkeys set-chat-id test-n8n

env:             ## cria .env com segredos aleatórios (nunca sobrescreve)
	@if [ -f .env ]; then echo ".env já existe, nada feito"; else \
	  cp .env.example .env; \
	  for v in $(SECRETS); do sed -i "s|^$$v=.*|$$v=$$(openssl rand -hex 24)|" .env; done; \
	  echo ".env criado. Guarde N8N_ENCRYPTION_KEY fora daqui."; fi

keys:            ## gera o par de chaves do coletor
	sh lab/gen-keys.sh

up: env keys     ## sobe o laboratório completo
	docker compose up -d --build

down:            ## para o laboratório (mantém dados)
	docker compose down

reset:           ## APAGA volumes (banco, n8n, grafana) e recomeça do zero
	docker compose down -v

migrate:         ## aplica migrations pendentes no banco em execução
	docker compose exec -T postgres sh /schema/migrate.sh

import-workflows: ## importa n8n/workflows/*.json no n8n em execução
	docker compose exec -T n8n n8n import:workflow --separate --input=/workflows

forget-hostkeys: ## após recriar os alvos (chave de host nova)
	docker compose exec collector-gateway rm -f /state/known_hosts

test: test-gateway test-n8n ## testes do coletor, gateway e Code nodes (sem Docker)
	sh tests/run.sh

test-gateway:
	cd gateway && python3 -m unittest -q

test-n8n:
	node tests/n8n/test_format_message.js
	python3 n8n/sync_code.py --check

set-chat-id:     ## grava o chat_id do Telegram no banco: make set-chat-id CHAT_ID=123456
	@case "$(CHAT_ID)" in ''|*[!0-9-]*) echo "uso: make set-chat-id CHAT_ID=<número>"; exit 1;; esac
	@echo "INSERT INTO settings (key, value) VALUES ('telegram_chat_id', '$(CHAT_ID)') \
	  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" | \
	  docker compose exec -T postgres psql -U inventory_rw -d inventory -q -v ON_ERROR_STOP=1 && echo "chat_id gravado"

test-sql:        ## testes da ingestão no Postgres em execução
	docker compose exec -T postgres psql -U inventory_rw -d inventory -X -v ON_ERROR_STOP=1 -f - < tests/sql/test_ingest.sql

lint:            ## shellcheck em modo POSIX
	shellcheck -s sh collector/collect.sh tests/run.sh lab/gen-keys.sh lab/target/entrypoint.sh db/00-init.sh db/migrate.sh

# Coleta manual (sem n8n) — útil para depurar o coletor
collect-debian:
	ssh $(SSH_OPTS) -p 2221 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
collect-rocky:
	ssh $(SSH_OPTS) -p 2222 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
collect-alpine:
	ssh $(SSH_OPTS) -p 2223 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
