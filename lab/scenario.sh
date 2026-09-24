#!/bin/sh
# Liga e desliga os problemas de demonstração nos alvos em execução.
#   resolve: corrige tudo (disco, UID 0, certificados) e grava um marcador para o
#            alvo continuar saudável mesmo após reiniciar ou ser recriado.
#   break:   remove o marcador e reinicia o alvo, que volta ao cenário do compose.
set -eu
action=${1:-}
case $action in resolve|break) ;; *) echo "uso: $0 resolve|break" >&2; exit 2 ;; esac

COMPOSE="docker compose --profile fleet --profile legacy"
targets=$($COMPOSE ps --services --status running \
          | grep -E '^(target-|web-|db-|app-|bkp-|ubuntu-|centos-)' || true)
if [ -z "$targets" ]; then echo "nenhum alvo em execução" >&2; exit 1; fi

for s in $targets; do
    if [ "$action" = resolve ]; then
        # shellcheck disable=SC2016  # expandido dentro do container
        $COMPOSE exec -T "$s" sh -c '
            touch "/lab-state/$(uname -n)/resolved"
            rm -f /data/fill.bin
            if [ -n "${UID0_USER:-}" ]; then sed -i "/^${UID0_USER}:/d" /etc/passwd; fi
            openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$(uname -n).lab.local" \
                -keyout /opt/app/certs/app.key -out /opt/app/certs/app.crt 2>/dev/null
            chmod 644 /opt/app/certs/app.crt'
        echo "$s: resolvido"
    else
        # shellcheck disable=SC2016
        $COMPOSE exec -T "$s" sh -c 'rm -f "/lab-state/$(uname -n)/resolved" /opt/app/certs/app.crt'
        $COMPOSE restart "$s" >/dev/null
        echo "$s: cenário de demonstração restaurado"
    fi
done
echo "rode a coleta no n8n (ou espere o próximo ciclo de 15 min)"
