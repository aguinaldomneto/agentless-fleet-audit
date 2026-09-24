FROM python:3.12-alpine
RUN adduser -D -u 1000 bridge
COPY bridge.py /app/bridge.py
USER bridge
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8081/health || exit 1
CMD ["python3", "-u", "/app/bridge.py"]
