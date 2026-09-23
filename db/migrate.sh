#!/bin/sh
# Aplica as migrations de db/migrations em ordem, uma única vez cada.
# Roda dentro do container do Postgres:
#   docker compose exec -T postgres sh /schema/migrate.sh
set -eu
DB=${1:-inventory}
DIR=$(dirname "$0")/migrations

q() { PGOPTIONS="-c client_min_messages=warning" psql -v ON_ERROR_STOP=1 -X -q -U "${POSTGRES_USER:-postgres}" -d "$DB" "$@"; }

q -c "CREATE TABLE IF NOT EXISTS schema_migrations (
        version    text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now())"

# Baseline: bancos criados antes deste script já têm o 001 aplicado.
if [ "$(q -tAc "SELECT to_regclass('public.hosts') IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM schema_migrations)")" = t ]; then
    echo "baseline: 001_schema já presente"
    q -c "INSERT INTO schema_migrations (version) VALUES ('001_schema')"
fi

for f in "$DIR"/*.sql; do
    v=$(basename "$f" .sql)
    if [ "$(q -tAc "SELECT count(*) FROM schema_migrations WHERE version = '$v'")" = 1 ]; then
        continue
    fi
    echo "aplicando $v"
    # -1 = tudo numa transação: a migration e o registro dela, ou nada.
    q -1 -f "$f" -c "INSERT INTO schema_migrations (version) VALUES ('$v')"
done
echo "migrations em dia"
