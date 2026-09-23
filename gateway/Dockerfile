FROM python:3.12-alpine
RUN apk add --no-cache openssh-client \
 && addgroup -g 1000 collector && adduser -D -u 1000 -G collector collector \
 && mkdir -p /state && chown collector:collector /state
COPY gateway.py /app/gateway.py
USER collector
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["python3", "-u", "/app/gateway.py"]
