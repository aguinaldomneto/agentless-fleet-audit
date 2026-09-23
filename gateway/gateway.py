#!/usr/bin/env python3
"""
collector-gateway — executa o collect.sh via SSH e devolve a saída bruta.

Por que existe: a chave SSH do coletor fica SÓ aqui. O n8n orquestra
(agenda, registra, alerta), mas nunca tem a chave em mãos. Se o n8n for
comprometido, o atacante não sai fazendo SSH na frota por conta própria.

Somente biblioteca padrão do Python + cliente OpenSSH.

  GET  /health                 -> 200 {"status": "ok"}
  POST /collect  (X-Gateway-Token)
       {"host_id": 1, "address": "target-alpine", "port": 22,
        "user": "collector", "cert_paths": "/opt/app/certs"}
    -> 200 {"host_id", "ok", "exit_code", "duration_ms", "stdout", "stderr",
            "error_summary"}

Falha de SSH não vira erro HTTP: volta 200 com ok=false, para o workflow
registrar a falha no banco em vez de simplesmente parar.
"""
import hmac
import json
import os
import re
import shlex
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("GATEWAY_TOKEN", "")
SSH_KEY = os.environ.get("SSH_KEY", "/keys/collector")
SCRIPT = os.environ.get("COLLECT_SCRIPT", "/collector/collect.sh")
KNOWN_HOSTS = os.environ.get("KNOWN_HOSTS", "/state/known_hosts")
# accept-new = confia na 1ª conexão e depois exige a mesma chave (TOFU).
# Chave de host mudou? A coleta falha — é o comportamento correto.
HOSTKEY_POLICY = os.environ.get("SSH_HOSTKEY_POLICY", "accept-new")
TIMEOUT = int(os.environ.get("COLLECT_TIMEOUT", "90"))
LISTEN = os.environ.get("LISTEN_ADDR", "0.0.0.0")
PORT = int(os.environ.get("LISTEN_PORT", "8080"))
MAX_BODY = 16 * 1024

# Validação estrita: nada vindo da requisição chega ao ssh sem passar aqui.
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$")   # não começa com '-'
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
PATH_RE = re.compile(r"^/[A-Za-z0-9._/-]{0,255}$")


class BadRequest(Exception):
    pass


def validate(req):
    try:
        host_id = int(req["host_id"])
        address = str(req["address"])
        port = int(req.get("port", 22))
        user = str(req.get("user", "collector"))
        paths = str(req.get("cert_paths") or "").split()
    except (KeyError, TypeError, ValueError) as exc:
        raise BadRequest(f"payload inválido: {exc}") from None
    if not HOST_RE.match(address):
        raise BadRequest("address inválido")
    if not 1 <= port <= 65535:
        raise BadRequest("port inválida")
    if not USER_RE.match(user):
        raise BadRequest("user inválido")
    for p in paths:
        if not PATH_RE.match(p) or ".." in p.split("/"):
            raise BadRequest(f"cert_path inválido: {p}")
    return host_id, address, port, user, paths


def build_ssh_cmd(address, port, user, paths):
    remote = "sh -s --" + "".join(" " + shlex.quote(p) for p in paths)
    return [
        "ssh", "-i", SSH_KEY, "-p", str(port),
        "-o", "BatchMode=yes",              # nunca pede senha/confirmação
        "-o", "IdentitiesOnly=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
        "-o", f"StrictHostKeyChecking={HOSTKEY_POLICY}",
        "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
        "-o", "LogLevel=ERROR",
        "-l", user, "--", address, remote,
    ]


def collect(host_id, address, port, user, paths):
    started = time.monotonic()
    cmd = build_ssh_cmd(address, port, user, paths)
    try:
        with open(SCRIPT, "rb") as script:
            proc = subprocess.run(cmd, stdin=script, capture_output=True, timeout=TIMEOUT)
        rc, out, err = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as exc:
        rc, out, err = 124, exc.stdout or b"", f"timeout após {TIMEOUT}s".encode()
    stdout = out.decode("utf-8", "replace")
    stderr = err.decode("utf-8", "replace").strip()
    ok = rc == 0 and "\nEND|ok" in "\n" + stdout
    return {
        "host_id": host_id,
        "ok": ok,
        "exit_code": rc,
        "duration_ms": int((time.monotonic() - started) * 1000),
        "stdout": stdout,
        "stderr": stderr[:2000],
        "error_summary": "" if ok else summarize(stderr, rc),
    }


def summarize(stderr, rc):
    """Última linha útil do stderr (sem o banner '@@@' do ssh)."""
    lines = [l.strip() for l in stderr.splitlines() if l.strip() and not l.startswith("@")]
    return lines[-1][:300] if lines else f"exit {rc} sem mensagem (saída sem END|ok)"


class Handler(BaseHTTPRequestHandler):
    server_version = "collector-gateway"
    sys_version = ""

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/collect":
            return self._send(404, {"error": "not found"})
        got = self.headers.get("X-Gateway-Token", "")
        if not TOKEN or not hmac.compare_digest(got.encode(), TOKEN.encode()):
            return self._send(401, {"error": "token inválido"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._send(400, {"error": "corpo ausente ou grande demais"})
        try:
            args = validate(json.loads(self.rfile.read(length)))
        except (BadRequest, json.JSONDecodeError) as exc:
            return self._send(400, {"error": str(exc)})
        self._send(200, collect(*args))

    def log_message(self, fmt, *args):  # log em uma linha, sem o token
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    if not TOKEN:
        sys.exit("GATEWAY_TOKEN não definido — recusando subir sem autenticação")
    ThreadingHTTPServer((LISTEN, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
