#!/bin/sh
# Gera o par de chaves SSH do coletor (fica fora do git).
set -eu
cd "$(dirname "$0")/keys"
if [ -f collector ]; then
    echo "chave já existe em lab/keys/collector"
    exit 0
fi
ssh-keygen -t ed25519 -N '' -C collector@lab -f collector
echo "ok: lab/keys/collector (privada) e lab/keys/collector.pub"
