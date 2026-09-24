#!/bin/sh
# -----------------------------------------------------------------------------
# collect.sh — coletor de inventário agentless (POSIX sh)
#
# Alvos suportados: Linux (glibc/busybox) e HP-UX 11i.
# Nada é instalado no servidor: o script é enviado via SSH e executado em memória.
#
#   ssh collector@host 'sh -s -- /caminho/certs' < collect.sh
#
# Regras de portabilidade (não quebrar):
#   - sem bashismos ([[ ]], arrays, local, $(( )) com operadores GNU, etc.)
#   - sem jq/python/base64/timeout/date +%s no lado remoto (não existem no HP-UX)
#   - awk apenas POSIX (nada de gawk: gensub, strftime, arrays multidim.)
#
# Formato de saída: uma linha por registro, campos separados por '|'.
#   META|schema|hostname|os|os_release|kernel|arch|collected_at_utc
#   UPTIME|seconds|raw
#   LOAD|1m|5m|15m
#   FS|mount|size_kb|used_kb|avail_kb|used_pct
#   USER|name|uid|gid|shell|interactive(1/0)
#   PKG|manager|count
#   SWBUNDLE|name|revision                      (HP-UX)
#   CERT|path|not_after_raw|subject
#   ERR|section|message
#   END|ok
# A linha END permite ao consumidor detectar saída truncada (conexão caiu).
# -----------------------------------------------------------------------------

SCHEMA_VERSION=1

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/openssl/bin:/usr/contrib/bin
LC_ALL=C
export PATH LC_ALL

# Pontos de montagem ignorados (ERE). Sobrescreva com EXCLUDE_MOUNTS.
# Obs.: usa [.] em vez de \. porque awk -v interpreta barras invertidas.
: "${EXCLUDE_MOUNTS:=^/(dev|proc|sys|run)(/|$)|^/etc/(hosts|hostname|resolv[.]conf)$}"

# --- utilitários -------------------------------------------------------------

# emit CAMPO... -> imprime registro; troca '|' e quebras de linha dentro dos campos
emit() {
    _out=""
    _sep=""
    for _f in "$@"; do
        case $_f in
            *'|'*|*'
'*) _f=$(printf '%s' "$_f" | tr '|\n' '/ ') ;;
        esac
        _out="$_out$_sep$_f"
        _sep="|"
    done
    printf '%s\n' "$_out"
}

err() { emit ERR "$1" "$2"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- parsers (leem stdin, testáveis com fixtures) ---------------------------

# Saída de `df -P -k` (Linux/busybox). Formato POSIX garante 1 linha por FS.
parse_df_posix() {
    awk -v excl="$EXCLUDE_MOUNTS" '
        NR == 1 { next }
        NF < 6  { next }
        {
            m = $6
            for (i = 7; i <= NF; i++) m = m " " $i
            if (m ~ excl) next
            p = $5; sub(/%/, "", p)
            print "FS|" m "|" $2 "|" $3 "|" $4 "|" p
        }'
}

# Saída de `bdf` (HP-UX). Quando o nome do device é longo, o bdf quebra a
# linha: o device fica sozinho numa linha e os números vão para a próxima.
parse_bdf() {
    awk -v excl="$EXCLUDE_MOUNTS" '
        NR == 1  { next }
        NF == 0  { next }
        NF == 1  { pend = 1; next }
        {
            o = pend ? 0 : 1
            pend = 0
            kb = $(1 + o); u = $(2 + o); a = $(3 + o); p = $(4 + o)
            sub(/%/, "", p)
            m = $(5 + o)
            for (i = 6 + o; i <= NF; i++) m = m " " $i
            if (m ~ excl) next
            print "FS|" m "|" kb "|" u "|" a "|" p
        }'
}

# Saída de `uptime` (Linux, busybox e HP-UX) -> LOAD|1m|5m|15m
parse_load() {
    sed -n 's/.*load average[s]*: *//p' | tr -d ',' |
        awk 'NF >= 3 { print "LOAD|" $1 "|" $2 "|" $3 }'
}

# /etc/passwd -> USER|...
parse_passwd() {
    awk -F: '
        /^[ \t]*#/ || NF < 7 { next }
        {
            inter = ($7 ~ /(nologin|false|sync|shutdown|halt)$/ || $7 == "") ? 0 : 1
            print "USER|" $1 "|" $3 "|" $4 "|" $7 "|" inter
        }'
}

# `swlist -l bundle` (HP-UX) -> SWBUNDLE|nome|revisão
parse_swlist_bundle() {
    awk '
        /^[ \t]*#/ || NF < 2 { next }
        { print "SWBUNDLE|" $1 "|" $2 }'
}

# Descarta registros FS cujo ponto de montagem não é diretório. Bind mount de
# arquivo (comum em containers: /etc/hosts, segredos, chaves) aparece no df com
# os números do disco do host, mas não é um filesystem com capacidade própria.
filter_dir_mounts() {
    while IFS= read -r _l; do
        _m=${_l#FS|}
        _m=${_m%%|*}
        if [ -d "$_m" ]; then printf '%s\n' "$_l"; fi
    done
}

# --- seções de coleta --------------------------------------------------------

# Nome da distribuição. /etc/os-release só existe a partir de ~2012: CentOS 6,
# RHEL 5/6, SLES 11 e similares só têm os arquivos antigos. $1 = raiz (testes).
os_pretty() {
    _root=${1:-}
    if [ -r "$_root/etc/os-release" ]; then
        sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$_root/etc/os-release"
    elif [ -r "$_root/etc/redhat-release" ]; then
        head -n 1 "$_root/etc/redhat-release"
    elif [ -r "$_root/etc/SuSE-release" ]; then
        head -n 1 "$_root/etc/SuSE-release"
    elif [ -r "$_root/etc/debian_version" ]; then
        printf 'Debian %s\n' "$(head -n 1 "$_root/etc/debian_version")"
    fi
}

collect_meta() {
    _os=$(uname -s)
    _rel=$(os_pretty)
    [ -n "$_rel" ] || _rel=$(uname -r)   # HP-UX: B.11.31
    emit META "$SCHEMA_VERSION" "$(uname -n)" "$_os" "$_rel" "$(uname -r)" \
        "$(uname -m)" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

collect_uptime() {
    _raw=$(uptime 2>/dev/null)
    _secs=""
    if [ -r /proc/uptime ]; then
        _secs=$(awk '{ printf "%d", $1 }' /proc/uptime)
    fi
    emit UPTIME "$_secs" "$_raw"
    printf '%s\n' "$_raw" | parse_load
}

collect_fs() {
    # -l = somente FS locais. Evita travar em montagem NFS "stale".
    case $OS in
        HP-UX)
            if _o=$(bdf -l 2>/dev/null) && [ -n "$_o" ]; then
                printf '%s\n' "$_o" | parse_bdf | filter_dir_mounts
            else
                err fs "bdf falhou"
            fi
            ;;
        *)
            # busybox df não aceita -l: tenta com -l e cai para sem -l.
            if _o=$(df -P -k -l 2>/dev/null) && [ -n "$_o" ]; then
                printf '%s\n' "$_o" | parse_df_posix | filter_dir_mounts
            elif _o=$(df -P -k 2>/dev/null) && [ -n "$_o" ]; then
                printf '%s\n' "$_o" | parse_df_posix | filter_dir_mounts
            else
                err fs "df falhou"
            fi
            ;;
    esac
}

collect_users() {
    if [ -r /etc/passwd ]; then
        parse_passwd < /etc/passwd
    else
        err users "/etc/passwd ilegível"
    fi
}

collect_packages() {
    if [ "$OS" = HP-UX ]; then
        if have swlist; then
            swlist -l bundle 2>/dev/null | parse_swlist_bundle
        else
            err packages "swlist não encontrado"
        fi
        return
    fi
    if have dpkg-query; then
        emit PKG dpkg "$(dpkg-query -W -f '.\n' 2>/dev/null | wc -l | tr -d ' ')"
    elif have rpm; then
        emit PKG rpm "$(rpm -qa 2>/dev/null | wc -l | tr -d ' ')"
    elif have apk; then
        emit PKG apk "$(apk info 2>/dev/null | wc -l | tr -d ' ')"
    else
        err packages "gerenciador de pacotes não identificado"
    fi
}

# Recebe diretórios/arquivos como argumentos. Lê apenas o 1º certificado de
# cada arquivo (limitação conhecida para bundles).
collect_certs() {
    [ $# -gt 0 ] || return 0
    if ! have openssl; then
        err certs "openssl não encontrado"
        return 0
    fi
    for _p in "$@"; do
        if [ ! -e "$_p" ]; then
            err certs "caminho inexistente: $_p"
            continue
        fi
        find "$_p" -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) 2>/dev/null |
        while IFS= read -r _c; do
            _end=$(openssl x509 -in "$_c" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
            [ -n "$_end" ] || continue  # não é certificado (ex.: só chave)
            _sub=$(openssl x509 -in "$_c" -noout -subject 2>/dev/null | sed 's/^subject= *//')
            emit CERT "$_c" "$_end" "$_sub"
        done
    done
}

main() {
    OS=$(uname -s)
    collect_meta
    collect_uptime
    collect_fs
    collect_users
    collect_packages
    collect_certs "$@"
    emit END ok
}

# COLLECT_LIB_ONLY=1 permite carregar as funções nos testes sem executar a coleta.
if [ "${COLLECT_LIB_ONLY:-0}" != 1 ]; then
    main "$@"
fi
