# Atalhos do laboratório. Requer: docker compose, ssh, openssl.
SSH_OPTS = -i lab/keys/collector -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
SECRETS  = POSTGRES_PASSWORD N8N_DB_PASSWORD INVENTORY_RW_PASSWORD GRAFANA_RO_PASSWORD \
           GRAFANA_ADMIN_PASSWORD N8N_ENCRYPTION_KEY GATEWAY_TOKEN BRIDGE_TOKEN

.PHONY: env keys up down reset migrate import-workflows test test-sql test-gateway lint fleet-up fleet-down \
        collect-debian collect-rocky collect-alpine forget-hostkeys set-chat-id set-jira import-workflow test-n8n test-bridge set-reminders \
        n8n-wait n8n-credentials n8n-setup lab-resolve lab-break

env:             ## cria .env com segredos aleatórios (nunca sobrescreve)
	@if [ -f .env ]; then echo ".env já existe, nada feito"; else \
	  cp .env.example .env; \
	  for v in $(SECRETS); do sed -i "s|^$$v=.*|$$v=$$(openssl rand -hex 24)|" .env; done; \
	  echo ".env criado. Guarde N8N_ENCRYPTION_KEY fora daqui."; fi

keys:            ## gera o par de chaves do coletor
	sh lab/gen-keys.sh

up: env keys     ## sobe o laboratório completo, já com credenciais e workflows no n8n
	docker compose up -d --build
	$(MAKE) n8n-setup

down:            ## para o laboratório (mantém dados)
	docker compose down

reset:           ## APAGA volumes (banco, n8n, grafana) e recomeça do zero
	docker compose down -v

migrate:         ## aplica migrations pendentes no banco em execução
	docker compose exec -T postgres sh /schema/migrate.sh

# IDs fixos dos workflows (campo "id" de cada JSON em n8n/workflows)
WF_IDS = fleetAuditColeta fleetAuditTgAcao
N8N_EXEC = docker compose exec -T n8n

n8n-wait:
	@i=0; until $(N8N_EXEC) wget -qO- http://localhost:5678/healthz >/dev/null 2>&1; do \
	  i=$$((i+1)); [ $$i -lt 60 ] || { echo "n8n não respondeu em 2 min"; exit 1; }; sleep 2; done

n8n-credentials: n8n-wait ## cria/atualiza as credenciais do n8n a partir do .env (IDs fixos)
	@python3 n8n/credentials.py .env >/dev/null    # valida antes (falha aqui se faltar variável)
	@python3 n8n/credentials.py .env | $(N8N_EXEC) sh -c \
	  'umask 077; f=$$(mktemp); cat > "$$f"; n8n import:credentials --input="$$f"; rc=$$?; rm -f "$$f"; exit $$rc'

import-workflows: n8n-wait ## importa e publica TODOS os workflows (credenciais já vêm ligadas)
	$(N8N_EXEC) n8n import:workflow --separate --input=/workflows
	@for id in $(WF_IDS); do $(N8N_EXEC) n8n publish:workflow --id=$$id >/dev/null && echo "publicado: $$id"; done
	@if grep -q '^JIRA_API_TOKEN=.' .env; then \
	  $(N8N_EXEC) n8n publish:workflow --id=fleetAuditJira01 >/dev/null && echo "publicado: fleetAuditJira01"; \
	else echo "Jira sem JIRA_API_TOKEN no .env: workflow importado, não publicado"; fi
	docker compose restart n8n    # publicação pela CLI só vale após reiniciar

import-workflow: n8n-wait ## importa e publica um só: make import-workflow WF=jira
	@test -n "$(WF)" || (echo "uso: make import-workflow WF=<nome sem .json>"; exit 1)
	$(N8N_EXEC) n8n import:workflow --input=/workflows/$(WF).json
	$(N8N_EXEC) n8n publish:workflow --id=$$(python3 -c "import json;print(json.load(open('n8n/workflows/$(WF).json'))['id'])")
	docker compose restart n8n

n8n-setup: n8n-credentials import-workflows ## credenciais + workflows + publicação, sem nenhum clique

forget-hostkeys: ## após recriar os alvos (chave de host nova)
	docker compose exec collector-gateway rm -f /state/known_hosts

test: test-gateway test-bridge test-n8n ## testes do coletor, gateway, bridge e Code nodes (sem Docker)
	sh tests/run.sh

test-gateway:
	cd gateway && python3 -m unittest -q

test-bridge:
	cd telegram-bridge && python3 -m unittest -q

test-n8n:
	node tests/n8n/test_format_message.js
	node tests/n8n/test_jira.js
	python3 n8n/sync_code.py --check
	python3 tests/n8n/test_credentials.py

set-chat-id:     ## grava o chat_id do Telegram no banco: make set-chat-id CHAT_ID=123456
	@case "$(CHAT_ID)" in ''|*[!0-9-]*) echo "uso: make set-chat-id CHAT_ID=<número>"; exit 1;; esac
	@echo "INSERT INTO settings (key, value) VALUES ('telegram_chat_id', '$(CHAT_ID)') \
	  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" | \
	  docker compose exec -T postgres psql -U inventory_rw -d inventory -q -v ON_ERROR_STOP=1 && echo "chat_id gravado"

test-sql:        ## testes da ingestão e do Jira no Postgres em execução
	for t in tests/sql/test_*.sql; do \
	  docker compose exec -T postgres psql -U inventory_rw -d inventory -X -v ON_ERROR_STOP=1 -f - < $$t || exit 1; done

set-reminders:   ## intervalos de lembrete em minutos: make set-reminders CRITICAL=60 HIGH=180 MEDIUM=480
	@for v in "$(or $(CRITICAL),60)" "$(or $(HIGH),180)" "$(or $(MEDIUM),480)"; do \
	  case "$$v" in ''|*[!0-9]*) echo "valores devem ser minutos (inteiros)"; exit 1;; esac; done
	@printf "%s\n" \
	  "INSERT INTO settings (key, value) VALUES ('remind_minutes_critical', '$(or $(CRITICAL),60)'), ('remind_minutes_high', '$(or $(HIGH),180)'), ('remind_minutes_medium', '$(or $(MEDIUM),480)')" \
	  "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" | \
	  docker compose exec -T postgres psql -U inventory_rw -d inventory -q -v ON_ERROR_STOP=1 && echo "lembretes configurados"

set-jira:        ## make set-jira BASE_URL=https://x.atlassian.net PROJECT=OPS [ISSUE_TYPE=Incident]
	@echo "$(BASE_URL)" | grep -Eq '^https://[A-Za-z0-9.-]+$$' || { echo "BASE_URL inválida (ex.: https://seu-site.atlassian.net)"; exit 1; }
	@echo "$(PROJECT)" | grep -Eq '^[A-Z][A-Z0-9_]+$$' || { echo "PROJECT inválido (chave do projeto, ex.: OPS)"; exit 1; }
	@echo "$(or $(ISSUE_TYPE),Task)" | grep -Eq '^[A-Za-z][A-Za-z ]{0,40}$$' || { echo "ISSUE_TYPE inválido"; exit 1; }
	@printf "%s\n" \
	  "INSERT INTO settings (key, value) VALUES ('jira_base_url', '$(BASE_URL)'), ('jira_project', '$(PROJECT)'), ('jira_issue_type', '$(or $(ISSUE_TYPE),Task)')" \
	  "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" | \
	  docker compose exec -T postgres psql -U inventory_rw -d inventory -q -v ON_ERROR_STOP=1 && echo "Jira configurado"

FLEET = web-01 web-02 db-01 app-01 app-02 bkp-01
FLEET_SQL = 'web-01','web-02','db-01','app-01','app-02','bkp-01'

fleet-up:        ## sobe +6 servidores com cenários variados e cadastra no banco
	docker compose --profile fleet up -d --build $(FLEET)
	docker compose exec -T postgres psql -U inventory_rw -d inventory -q -v ON_ERROR_STOP=1 < db/seed_fleet.sql && echo "frota cadastrada: $(FLEET)"

fleet-down:      ## desabilita a frota no banco ANTES de parar (senão vira alerta de falha de SSH)
	echo "UPDATE hosts SET enabled = false WHERE name IN ($(FLEET_SQL));" | \
	  docker compose exec -T postgres psql -U inventory_rw -d inventory -q -v ON_ERROR_STOP=1
	docker compose --profile fleet stop $(FLEET)

lab-resolve:     ## corrige todos os cenários (disco, UID 0, certificados) e mantém após reiniciar
	sh lab/scenario.sh resolve

lab-break:       ## volta os alvos ao estado de demonstração (alertas voltam no próximo ciclo)
	sh lab/scenario.sh break

lint:            ## shellcheck em modo POSIX
	shellcheck -s sh collector/collect.sh tests/run.sh lab/gen-keys.sh lab/target/entrypoint.sh lab/scenario.sh db/00-init.sh db/migrate.sh

# Coleta manual (sem n8n) — útil para depurar o coletor
collect-debian:
	ssh $(SSH_OPTS) -p 2221 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
collect-rocky:
	ssh $(SSH_OPTS) -p 2222 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
collect-alpine:
	ssh $(SSH_OPTS) -p 2223 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
