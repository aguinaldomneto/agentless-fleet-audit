#!/bin/sh
# Entrypoint comum dos servidores-alvo do laboratório (Debian, Rocky, Alpine).
set -eu

# Chave pública do coletor (montada read-only pelo compose)
install -d -m 700 -o collector -g collector /home/collector/.ssh
install -m 600 -o collector -g collector /keys/collector.pub /home/collector/.ssh/authorized_keys

# useradd/adduser criam a conta com senha '!' (bloqueada). Sem PAM (Alpine),
# o sshd recusa até login por chave em conta bloqueada. '*' = sem senha, não bloqueada.
sed -i 's/^collector:![^:]*:/collector:*:/' /etc/shadow

ssh-keygen -A >/dev/null

# Certificado de aplicação com validade curta, para demonstrar o alerta de expiração
mkdir -p /opt/app/certs
if [ ! -f /opt/app/certs/app.crt ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days "${CERT_DAYS:-365}" \
        -subj "/CN=$(hostname).lab.local" \
        -keyout /opt/app/certs/app.key -out /opt/app/certs/app.crt 2>/dev/null
    chmod 644 /opt/app/certs/app.crt
fi

# Enche parcialmente /data (tmpfs do compose) para demonstrar alerta de disco
if [ "${FILL_DATA_MB:-0}" -gt 0 ] && [ -d /data ] && [ ! -f /data/fill.bin ]; then
    dd if=/dev/zero of=/data/fill.bin bs=1048576 count="$FILL_DATA_MB" 2>/dev/null || true
fi

exec /usr/sbin/sshd -D -e \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o PermitRootLogin=no \
    -o AllowUsers=collector
