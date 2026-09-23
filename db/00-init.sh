#!/bin/sh
# Executado pelo entrypoint oficial do Postgres apenas na PRIMEIRA subida (volume vazio).
# Cria: banco do n8n, banco de inventário e papéis com privilégio mínimo.
set -eu
SCHEMA_DIR=${SCHEMA_DIR:-/schema}

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE n8n          LOGIN PASSWORD '${N8N_DB_PASSWORD}';
CREATE ROLE inventory_rw LOGIN PASSWORD '${INVENTORY_RW_PASSWORD}';
CREATE ROLE grafana_ro   LOGIN PASSWORD '${GRAFANA_RO_PASSWORD}';
CREATE DATABASE n8n       OWNER n8n;
CREATE DATABASE inventory OWNER inventory_rw;
REVOKE ALL ON DATABASE inventory FROM PUBLIC;
GRANT CONNECT ON DATABASE inventory TO grafana_ro;
SQL

sh "$SCHEMA_DIR/migrate.sh" inventory

if [ "${LOAD_LAB_SEED:-false}" = true ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname inventory -f "$SCHEMA_DIR/seed_lab.sql"
fi
