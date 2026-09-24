#!/bin/sh
# Entrypoint comum dos servidores-alvo do laboratório (Debian, Rocky, Alpine).
set -eu

# Chave pública do coletor (montada read-only pelo compose)
install -d -m 700 -o collector -g collector /home/collector/.ssh
install -m 600 -o collector -g collector /keys/collector.pub /home/collector/.ssh/authorized_keys

# useradd/adduser criam a conta com senha '!' (bloqueada). Sem PAM (Alpine),
# o sshd recusa até login por chave em conta bloqueada. '*' = sem senha, não bloqueada.
sed -i 's/^collector:![^:]*:/collector:*:/' /etc/shadow

# Estado persistente do alvo (bind mount ./lab/state): chaves de host e marcador de
# "cenário resolvido". Chave de host estável = recriar o container não parece ataque
# man-in-the-middle para o gateway (StrictHostKeyChecking=accept-new).
STATE="/lab-state/$(hostname)"
mkdir -p "$STATE"
if ls "$STATE"/ssh_host_*_key >/dev/null 2>&1; then
    cp -p "$STATE"/ssh_host_* /etc/ssh/
else
    ssh-keygen -A >/dev/null
    cp -p /etc/ssh/ssh_host_* "$STATE"/
fi

# make lab-resolve grava o marcador; com ele, o alvo sobe sem os problemas de demonstração
RESOLVED=false
if [ -f "$STATE/resolved" ]; then RESOLVED=true; fi

# Certificado de aplicação com validade curta, para demonstrar o alerta de expiração
mkdir -p /opt/app/certs
if [ ! -f /opt/app/certs/app.crt ]; then
    days="${CERT_DAYS:-365}"
    if [ "$RESOLVED" = true ]; then days=365; fi
    openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
        -subj "/CN=$(hostname).lab.local" \
        -keyout /opt/app/certs/app.key -out /opt/app/certs/app.crt 2>/dev/null
    chmod 644 /opt/app/certs/app.crt
fi

# Enche parcialmente /data (tmpfs do compose) para demonstrar alerta de disco
if [ "$RESOLVED" = false ] && [ "${FILL_DATA_MB:-0}" -gt 0 ] && [ -d /data ] && [ ! -f /data/fill.bin ]; then
    dd if=/dev/zero of=/data/fill.bin bs=1048576 count="$FILL_DATA_MB" 2>/dev/null || true
fi

# Conta extra com UID 0 (cenário de compliance: "root" escondido). Login continua
# bloqueado: o sshd só aceita o usuário collector (AllowUsers abaixo).
if [ "$RESOLVED" = false ] && [ -n "${UID0_USER:-}" ] && ! grep -q "^${UID0_USER}:" /etc/passwd; then
    echo "${UID0_USER}:x:0:0:uid0 de laboratório:/root:/bin/sh" >> /etc/passwd
fi

exec /usr/sbin/sshd -D -e \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o PermitRootLogin=no \
    -o AllowUsers=collector
