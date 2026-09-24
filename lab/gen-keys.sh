#!/bin/sh
# Gera os pares de chaves do coletor (ficam fora do git). Idempotente.
#   collector      ed25519  -> frota moderna
#   collector_rsa  RSA 3072 -> só hosts com ssh_profile=legacy (OpenSSH < 6.5)
set -eu
cd "$(dirname "$0")/keys"
gen() { # arquivo tipo bits
    # docker cria DIRETÓRIO vazio no lugar de um bind mount inexistente
    if [ -d "$1" ]; then rmdir "$1" 2>/dev/null || { echo "remova lab/keys/$1 (é um diretório)"; exit 1; }; fi
    if [ -f "$1" ]; then echo "já existe: lab/keys/$1"; return; fi
    ssh-keygen -q -t "$2" ${3:+-b "$3"} -N '' -C collector@lab -f "$1"
    echo "ok: lab/keys/$1 e lab/keys/$1.pub"
}
gen collector ed25519
gen collector_rsa rsa 3072
