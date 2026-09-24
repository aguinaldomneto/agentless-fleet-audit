#!/bin/sh
# Upgrade de versão major do Postgres do laboratório (ex.: 16 -> 17) por dump/restore.
#
#   make pg-upgrade                       # alvo padrão: postgres:17-alpine
#   make pg-upgrade IMAGE=postgres:17.6-alpine
#
# Por que dump/restore e não pg_upgrade: o formato do diretório de dados muda entre
# versões major (o 17 não abre dados do 16) e o pg_upgrade exige os binários das duas
# versões no mesmo container. O dump é portável e dá para conferir linha a linha.
#
# Segurança:
#   - quem escreve no banco (n8n, gateway, bridge, grafana) é parado ANTES do dump:
#     nada gravado depois do backup se perde;
#   - o volume antigo não é alterado; a nova versão sobe num volume novo;
#   - contagem de linhas de TODAS as tabelas de TODOS os bancos, antes e depois;
#   - qualquer falha antes do fim volta sozinha para a versão anterior.
#   Rollback manual depois do fim: cp backups/env-<data>.bak .env && docker compose up -d
set -eu
cd "$(dirname "$0")/.."

TARGET=${1:-postgres:17-alpine}
WRITERS="n8n grafana collector-gateway telegram-bridge"
TS=$(date +%Y%m%d-%H%M%S)
BK=backups
DUMP="$BK/pg-dumpall-$TS.sql"
LOG="$BK/pg-restore-$TS.log"
ENV_BAK="$BK/env-$TS.bak"
STAGE=preparação
ENV_CHANGED=false

COUNT_SQL="SELECT coalesce(string_agg(format('%s.%s=%s', schemaname, relname,
  (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, relname), false, true, '')))[1]::text),
  ' ' ORDER BY schemaname, relname), '(sem tabelas)') FROM pg_stat_user_tables"
DBS_SQL="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1"

say() { printf '\n==> [%s] %s\n' "$STAGE" "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }
env_get() { sed -n "s/^$1=//p" .env | tail -n 1; }
env_set() {
    if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env
    else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
psql_pg() { docker compose exec -T postgres psql -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
counts() {
    for db in $(psql_pg -d postgres -Atc "$DBS_SQL"); do
        printf '%s: %s\n' "$db" "$(psql_pg -d "$db" -Atc "$COUNT_SQL")"
    done
}

rollback() {
    rc=$?
    [ "$rc" -ne 0 ] || return 0
    printf '\n!!! Falhou na etapa "%s". Voltando para a versão anterior...\n' "$STAGE" >&2
    if [ "$ENV_CHANGED" = true ]; then cp "$ENV_BAK" .env; fi
    docker compose up -d --wait postgres >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker compose up -d $WRITERS >/dev/null 2>&1 || true
    printf 'Ambiente de volta em %s (volume %s).\n' "$OLD_IMAGE" "$OLD_VOL" >&2
    [ -s "$DUMP" ] && printf 'Backup preservado: %s\n' "$DUMP" >&2
    printf 'Volume novo (%s) mantido para análise; remova com docker volume rm quando quiser.\n' "$NEW_VOL" >&2
}

# --- verificações (nada é alterado até aqui) ---------------------------------
[ -f .env ] || die ".env não encontrado (rode na raiz do repositório)"
OLD_IMAGE=$(env_get POSTGRES_IMAGE)
OLD_VOL=$(env_get POSTGRES_VOLUME); [ -n "$OLD_VOL" ] || OLD_VOL=fleet-audit_pgdata
PGPW=$(env_get POSTGRES_PASSWORD)
[ -n "$PGPW" ] || die "POSTGRES_PASSWORD vazio no .env"

CUR=$(psql_pg -d postgres -Atc "SHOW server_version_num") || die "o Postgres atual não respondeu (docker compose up -d postgres)"
CUR_MAJOR=$((CUR / 10000))
NEW_MAJOR=$(docker run --rm --entrypoint postgres "$TARGET" -V | sed -n 's/.*) \([0-9][0-9]*\).*/\1/p')
[ -n "$NEW_MAJOR" ] || die "não consegui ler a versão de $TARGET"
NEW_VOL="fleet-audit_pgdata$NEW_MAJOR"
[ "$NEW_MAJOR" -gt "$CUR_MAJOR" ] || die "atual é $CUR_MAJOR e o alvo é $NEW_MAJOR: nada a fazer (downgrade não é suportado)"
if docker volume inspect "$NEW_VOL" >/dev/null 2>&1; then
    die "o volume $NEW_VOL já existe (upgrade anterior incompleto?). Confira e remova com 'docker volume rm $NEW_VOL'."
fi
mkdir -p "$BK"
printf 'Upgrade do Postgres %s -> %s\n  imagem: %s -> %s\n  volume: %s -> %s (o antigo fica intacto)\n' \
    "$CUR_MAJOR" "$NEW_MAJOR" "$OLD_IMAGE" "$TARGET" "$OLD_VOL" "$NEW_VOL"

trap rollback EXIT

STAGE="1/7 parar escritores"
say "$WRITERS"
# shellcheck disable=SC2086
docker compose stop $WRITERS

STAGE="2/7 backup"
say "pg_dumpall -> $DUMP"
( umask 077; docker compose exec -T postgres pg_dumpall -U postgres > "$DUMP" )
tail -n 5 "$DUMP" | grep -q 'cluster dump complete' || die "dump incompleto: $DUMP"
counts > "$BK/counts-before-$TS.txt"
cat "$BK/counts-before-$TS.txt"

STAGE="3/7 subir $TARGET vazio"
docker compose stop postgres
say "volume novo $NEW_VOL, sem rodar o init (o conteúdo vem do dump)"
POSTGRES_IMAGE="$TARGET" POSTGRES_VOLUME="$NEW_VOL" POSTGRES_SKIP_INIT=true \
    docker compose up -d --wait postgres
# O entrypoint oficial sobe um servidor temporário só no socket durante o initdb.
# Pronto de verdade = aceitando conexão TCP.
i=0
until docker compose exec -T -e PGPASSWORD="$PGPW" postgres psql -h 127.0.0.1 -U postgres -Atc 'SELECT 1' >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 60 ] || die "o Postgres $NEW_MAJOR não ficou pronto"; sleep 2
done

STAGE="4/7 restore"
say "log em $LOG"
docker compose exec -T postgres psql -U postgres -X -q -v ON_ERROR_STOP=0 -f - < "$DUMP" > "$LOG" 2>&1 || true
# Único erro esperado: o papel postgres já existe no cluster novo.
if grep 'ERROR' "$LOG" | grep -v 'role "postgres" already exists' | head -n 5 | grep .; then
    die "restore com erros (veja $LOG)"
fi

STAGE="5/7 conferência"
counts > "$BK/counts-after-$TS.txt"
if ! diff -u "$BK/counts-before-$TS.txt" "$BK/counts-after-$TS.txt"; then
    die "contagem de linhas diferente depois do restore"
fi
say "contagens idênticas em todas as tabelas"
docker compose exec -T postgres vacuumdb -U postgres --all --analyze-in-stages -q

STAGE="6/7 gravar no .env"
( umask 077; cp .env "$ENV_BAK" )
ENV_CHANGED=true
env_set POSTGRES_IMAGE "$TARGET"
env_set POSTGRES_VOLUME "$NEW_VOL"

STAGE="7/7 subir tudo"
docker compose up -d --wait postgres
# shellcheck disable=SC2086
docker compose up -d $WRITERS
trap - EXIT

printf '\nOK: %s\n' "$(psql_pg -d postgres -Atc 'SELECT version()')"
cat <<EOF

Backup: $DUMP (contém hashes de senha: não compartilhe)
.env anterior: $ENV_BAK
Rollback, se precisar:  cp $ENV_BAK .env && docker compose up -d
Depois de alguns dias sem problema, libere o espaço do volume antigo:
  docker volume rm $OLD_VOL
EOF
