#!/bin/sh
# Testes dos parsers do coletor + smoke test da coleta local.
# Uso: sh tests/run.sh            (ou: dash tests/run.sh / busybox sh tests/run.sh)
set -u
cd "$(dirname "$0")/.." || exit 1

COLLECT_LIB_ONLY=1
export COLLECT_LIB_ONLY
# shellcheck source=collector/collect.sh
. ./collector/collect.sh

fail=0
pass=0
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT

check() { # nome parser fixture
    "$2" < "tests/fixtures/$3.txt" > "$tmp"
    if diff -u "tests/expected/$3.out" "$tmp"; then
        pass=$((pass + 1)); echo "ok   - $1"
    else
        fail=$((fail + 1)); echo "FAIL - $1"
    fi
}

check "df -P linux (exclui pseudo-FS, mount com espaço)" parse_df_posix linux_df_P
check "bdf hp-ux (linha quebrada de device longo)"       parse_bdf       hpux_bdf
check "load average linux"                               parse_load      linux_uptime
check "load average hp-ux"                               parse_load      hpux_uptime
check "load average busybox"                             parse_load      busybox_uptime
check "passwd (shells interativos, uid 0 extra)"         parse_passwd    passwd
check "swlist -l bundle hp-ux"                           parse_swlist_bundle hpux_swlist_bundle

# emit deve neutralizar '|' e quebra de linha dentro de campos
got=$(emit X 'a|b' 'c
d')
if [ "$got" = "X|a/b|c d" ]; then pass=$((pass + 1)); echo "ok   - emit sanitiza campos"
else fail=$((fail + 1)); echo "FAIL - emit sanitiza campos: $got"; fi

# bind mount de arquivo (ex.: /keys/collector.pub no container) deve ser descartado
got=$(printf 'FS|/|10|5|5|50\nFS|/etc/passwd|10|5|5|50\nFS|/nao/existe|1|1|0|100\n' | filter_dir_mounts)
if [ "$got" = "FS|/|10|5|5|50" ]; then pass=$((pass + 1)); echo "ok   - descarta montagem que não é diretório"
else fail=$((fail + 1)); echo "FAIL - filter_dir_mounts: $got"; fi

# versão do SO: os-release > redhat-release > SuSE-release > debian_version
osroot=$(mktemp -d) || exit 1
mkdir -p "$osroot/etc"
printf 'CentOS release 6.10 (Final)\n' > "$osroot/etc/redhat-release"
got=$(OS_ROOT=$osroot os_pretty)
printf 'NAME="X"\nPRETTY_NAME="Ubuntu 12.04.5 LTS"\n' > "$osroot/etc/os-release"
got2=$(OS_ROOT=$osroot os_pretty)
rm -f "$osroot/etc/os-release" "$osroot/etc/redhat-release"
printf '7.11\n' > "$osroot/etc/debian_version"
got3=$(OS_ROOT=$osroot os_pretty)
rm -rf "$osroot"
if [ "$got" = "CentOS release 6.10 (Final)" ] && [ "$got2" = "Ubuntu 12.04.5 LTS" ] && [ "$got3" = "Debian 7.11" ]; then
    pass=$((pass + 1)); echo "ok   - versão do SO sem /etc/os-release (legado)"
else fail=$((fail + 1)); echo "FAIL - os_pretty: [$got] [$got2] [$got3]"; fi

# smoke test: coleta real na máquina local
COLLECT_LIB_ONLY=0 sh ./collector/collect.sh > "$tmp" 2>&1
first=$(head -n 1 "$tmp" | cut -d'|' -f1)
last=$(tail -n 1 "$tmp")
if [ "$first" = META ] && [ "$last" = "END|ok" ] && grep -q '^FS|' "$tmp"; then
    pass=$((pass + 1)); echo "ok   - coleta local (META ... FS ... END)"
else
    fail=$((fail + 1)); echo "FAIL - coleta local"; cat "$tmp"
fi

echo "---"
echo "$pass passaram, $fail falharam"
[ "$fail" -eq 0 ]
