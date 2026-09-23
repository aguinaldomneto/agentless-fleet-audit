# Atalhos do laboratório. Requer: docker compose, ssh, sh.
SSH_OPTS = -i lab/keys/collector -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

.PHONY: keys up down reset test lint collect-debian collect-rocky collect-alpine

keys:            ## gera o par de chaves do coletor
	sh lab/gen-keys.sh

up: keys         ## sobe o laboratório
	docker compose up -d --build

down:            ## para o laboratório (mantém dados)
	docker compose down

reset:           ## APAGA volumes (banco, n8n, grafana) e recomeça do zero
	docker compose down -v

test:            ## testes dos parsers + smoke test local
	sh tests/run.sh

lint:            ## shellcheck em modo POSIX
	shellcheck -s sh collector/collect.sh tests/run.sh lab/gen-keys.sh lab/target/entrypoint.sh db/00-init.sh

# Coleta manual (sem n8n) — útil para depurar o coletor
collect-debian:
	ssh $(SSH_OPTS) -p 2221 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
collect-rocky:
	ssh $(SSH_OPTS) -p 2222 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
collect-alpine:
	ssh $(SSH_OPTS) -p 2223 collector@127.0.0.1 'sh -s -- /opt/app/certs' < collector/collect.sh
