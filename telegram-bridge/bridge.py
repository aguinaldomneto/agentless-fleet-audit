#!/usr/bin/env python3
"""
telegram-bridge — única peça com o token do bot do Telegram.

Mesmo princípio do collector-gateway: o segredo fica num serviço pequeno e
auditável; o n8n só fala com ele pela rede interna.

  POST /send  (X-Bridge-Token)        n8n -> Telegram
       {"chat_id": "123", "text": "<b>...</b>",
        "buttons": [[{"text": "✅ Reconhecer", "data": "ack:13"}]]}
    -> 200 {"ok": true, "message_id": 42}   |   502 {"ok": false, "error": "..."}

  Botões (Telegram -> n8n): uma thread faz long polling em getUpdates.
  Não precisa de URL pública nem de webhook exposto na internet. Cada clique
  vai para o webhook interno do n8n, que valida e grava no banco; a resposta
  vira o aviso no Telegram e os botões da mensagem são removidos.

Somente biblioteca padrão do Python.
"""
import hmac
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
BRIDGE_TOKEN = os.environ.get("BRIDGE_TOKEN", "")
API = os.environ.get("TELEGRAM_API", "https://api.telegram.org").rstrip("/")
ACTION_URL = os.environ.get("N8N_ACTION_URL", "http://n8n:5678/webhook/fleet-audit-telegram")
LISTEN = os.environ.get("LISTEN_ADDR", "0.0.0.0")
PORT = int(os.environ.get("LISTEN_PORT", "8081"))
POLL_TIMEOUT = int(os.environ.get("POLL_TIMEOUT", "50"))
MAX_BODY = 16 * 1024

CHAT_RE = re.compile(r"^-?[0-9]{1,20}$")
DATA_RE = re.compile(r"^[a-z]{2,8}:[0-9]{1,12}(?::[0-9]{1,4})?$")  # ack:13 | sil:13:240


class BadRequest(Exception):
    pass


class TelegramError(Exception):
    pass


def log(msg):
    # nunca deixa o token vazar em log (ele faz parte da URL da API)
    sys.stderr.write(msg.replace(BOT_TOKEN, "***") if BOT_TOKEN else msg)
    sys.stderr.write("\n")


def http_json(url, payload, headers=None, timeout=15):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            return json.loads(body)
        except ValueError:
            return {"ok": False, "description": f"HTTP {exc.code}"}


def tg(method, payload, timeout=15):
    out = http_json(f"{API}/bot{BOT_TOKEN}/{method}", payload, timeout=timeout)
    if not out.get("ok"):
        raise TelegramError(f"{method}: {out.get('description', 'erro desconhecido')}")
    return out.get("result")


# --- n8n -> Telegram --------------------------------------------------------

def validate_send(req):
    chat = str(req.get("chat_id", ""))
    text = req.get("text")
    if not CHAT_RE.match(chat):
        raise BadRequest("chat_id inválido")
    if not isinstance(text, str) or not text or len(text) > 4096:
        raise BadRequest("text ausente ou maior que 4096")
    rows = req.get("buttons") or []
    if not isinstance(rows, list) or len(rows) > 3:
        raise BadRequest("buttons: no máximo 3 linhas")
    keyboard = []
    for row in rows:
        if not isinstance(row, list) or not 1 <= len(row) <= 3:
            raise BadRequest("buttons: de 1 a 3 botões por linha")
        line = []
        for b in row:
            label, data = str(b.get("text", "")), str(b.get("data", ""))
            if not label or len(label) > 64 or not DATA_RE.match(data):
                raise BadRequest(f"botão inválido: {b}")
            line.append({"text": label, "callback_data": data})
        keyboard.append(line)
    return chat, text, keyboard


def send(chat, text, keyboard):
    payload = {"chat_id": chat, "text": text, "parse_mode": "HTML",
               "disable_web_page_preview": True}
    if keyboard:
        payload["reply_markup"] = {"inline_keyboard": keyboard}
    return tg("sendMessage", payload)["message_id"]


# --- Telegram -> n8n (cliques nos botões) -----------------------------------

def parse_callback(update):
    cq = update.get("callback_query")
    if not cq or "message" not in cq:
        return None
    user = cq.get("from", {})
    name = " ".join(x for x in (user.get("first_name"), user.get("last_name")) if x) \
        or user.get("username") or str(user.get("id", "?"))
    return {
        "callback_id": cq["id"],
        "chat_id": str(cq["message"]["chat"]["id"]),
        "message_id": cq["message"]["message_id"],
        "from_name": name[:100],
        "data": str(cq.get("data", ""))[:64],
    }


def handle_callback(cb):
    try:
        res = http_json(ACTION_URL, cb, headers={"X-Bridge-Token": BRIDGE_TOKEN})
        if isinstance(res, list):  # n8n pode devolver lista de itens
            res = res[0] if res else {}
        ok, message = bool(res.get("ok")), str(res.get("message") or "Sem resposta do n8n")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log(f"falha ao chamar o n8n: {exc}")
        ok, message = False, "Falha ao registrar a ação. Tente novamente."
    tg("answerCallbackQuery", {"callback_query_id": cb["callback_id"], "text": message[:200]})
    if ok:
        tg("editMessageReplyMarkup", {"chat_id": cb["chat_id"], "message_id": cb["message_id"],
                                      "reply_markup": {"inline_keyboard": []}})
        tg("sendMessage", {"chat_id": cb["chat_id"], "text": message,
                           "reply_to_message_id": cb["message_id"]})
    return ok, message


def poll_forever(stop=None):
    offset = None
    while not (stop and stop.is_set()):
        try:
            payload = {"timeout": POLL_TIMEOUT, "allowed_updates": ["callback_query"]}
            if offset is not None:
                payload["offset"] = offset
            updates = tg("getUpdates", payload, timeout=POLL_TIMEOUT + 10)
            for u in updates:
                offset = u["update_id"] + 1   # confirma mesmo se falhar: evita loop infinito
                cb = parse_callback(u)
                if cb:
                    ok, msg = handle_callback(cb)
                    log(f"ação {cb['data']} de {cb['from_name']}: {'ok' if ok else 'recusada'} - {msg}")
        except TelegramError as exc:
            hint = " (há webhook configurado no bot? getUpdates não funciona junto)" if "409" in str(exc) or "webhook" in str(exc).lower() else ""
            log(f"telegram: {exc}{hint}")
            time.sleep(5)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            log(f"rede: {exc}")
            time.sleep(5)


class Handler(BaseHTTPRequestHandler):
    server_version = "telegram-bridge"
    sys_version = ""

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, {"status": "ok"}) if self.path == "/health" else self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/send":
            return self._send(404, {"error": "not found"})
        got = self.headers.get("X-Bridge-Token", "")
        if not hmac.compare_digest(got.encode(), BRIDGE_TOKEN.encode()):
            return self._send(401, {"error": "token inválido"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._send(400, {"error": "corpo ausente ou grande demais"})
        try:
            chat, text, keyboard = validate_send(json.loads(self.rfile.read(length)))
        except (BadRequest, ValueError, AttributeError) as exc:
            return self._send(400, {"error": str(exc)})
        try:
            self._send(200, {"ok": True, "message_id": send(chat, text, keyboard)})
        except (TelegramError, urllib.error.URLError, OSError) as exc:
            log(f"envio falhou: {exc}")
            self._send(502, {"ok": False, "error": str(exc).replace(BOT_TOKEN, "***")})

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))


def main():
    if not BOT_TOKEN or not BRIDGE_TOKEN:
        sys.exit("TELEGRAM_BOT_TOKEN e BRIDGE_TOKEN são obrigatórios")
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer((LISTEN, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
