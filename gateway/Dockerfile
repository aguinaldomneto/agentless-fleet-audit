# Tag de minor, não de patch: ao contrário do n8n/Grafana/Postgres (versão
# exata, ver .env.example), aqui é de propósito — patch de Python/Alpine é
# só correção de segurança, sem mudança de comportamento. Rebuild periódico
# (sem cache) é o suficiente para pegar essas correções.
FROM python:3.12-alpine
RUN apk add --no-cache openssh-client \
 && addgroup -g 1000 collector && adduser -D -u 1000 -G collector collector \
 && mkdir -p /state && chown collector:collector /state
COPY gateway.py /app/gateway.py
USER collector
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["python3", "-u", "/app/gateway.py"]
