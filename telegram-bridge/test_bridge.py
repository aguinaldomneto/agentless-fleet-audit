"""Testes do telegram-bridge com um Telegram falso e um n8n falso (sem rede)."""
import json
import os
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "123:SEGREDO"
os.environ.update(TELEGRAM_BOT_TOKEN=TOKEN, BRIDGE_TOKEN="bt", POLL_TIMEOUT="1")
import bridge  # noqa: E402

CALLS, N8N_CALLS, UPDATES = [], [], []
STOP = threading.Event()


class FakeTelegram(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        _, bot, method = self.path.split("/")
        if bot != "bot" + TOKEN:
            return self._reply(401, {"ok": False, "description": "Unauthorized"})
        CALLS.append((method, body))
        if method == "sendMessage" and body["chat_id"] == "999":
            return self._reply(400, {"ok": False, "description": "Bad Request: chat not found"})
        if method == "getUpdates":
            res = list(UPDATES)
            UPDATES.clear()
            if not res:
                STOP.set()
            return self._reply(200, {"ok": True, "result": res})
        self._reply(200, {"ok": True, "result": {"message_id": 42} if method == "sendMessage" else True})

    def _reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


class FakeN8n(FakeTelegram):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        N8N_CALLS.append((self.headers.get("X-Bridge-Token"), body))
        ok = body["data"] != "ack:99"
        self._reply(200, [{"ok": ok, "message": "✅ reconhecido" if ok else "Evento #99 já resolvido"}])


def serve(handler):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_address[1]}", srv


def callback(data, cb_id="cb1"):
    return {"update_id": 7, "callback_query": {
        "id": cb_id, "data": data, "from": {"id": 5, "first_name": "Aguinaldo", "last_name": "Neto"},
        "message": {"message_id": 10, "chat": {"id": 555}}}}


class Bridge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bridge.API, _ = serve(FakeTelegram)
        n8n, _ = serve(FakeN8n)
        bridge.ACTION_URL = n8n + "/webhook/x"
        cls.base, _ = serve(bridge.Handler)

    def setUp(self):
        CALLS.clear(); N8N_CALLS.clear(); UPDATES.clear(); STOP.clear()

    def post(self, path, body, token="bt"):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"X-Bridge-Token": token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_validacao(self):
        ok = {"chat_id": "555", "text": "oi", "buttons": [[{"text": "✅", "data": "ack:13"}]]}
        self.assertEqual(bridge.validate_send(ok)[2], [[{"text": "✅", "callback_data": "ack:13"}]])
        for bad in [{"chat_id": "abc", "text": "x"}, {"chat_id": "1", "text": "x" * 5000},
                    {"chat_id": "1", "text": "x", "buttons": [[{"text": "a", "data": "ack:1;rm"}]]},
                    {"chat_id": "1", "text": "x", "buttons": [[{"text": "a", "data": "x" * 70}]]}]:
            with self.assertRaises(bridge.BadRequest, msg=bad):
                bridge.validate_send(bad)

    def test_envio_com_botoes(self):
        code, out = self.post("/send", {"chat_id": "555", "text": "<b>alerta</b>",
                                        "buttons": [[{"text": "✅ Reconhecer", "data": "ack:13"},
                                                     {"text": "🔕 4h", "data": "sil:13:240"}]]})
        self.assertEqual((code, out), (200, {"ok": True, "message_id": 42}))
        method, body = CALLS[0]
        self.assertEqual(method, "sendMessage")
        self.assertEqual(body["parse_mode"], "HTML")
        self.assertEqual(body["reply_markup"]["inline_keyboard"][0][1]["callback_data"], "sil:13:240")

    def test_sem_token_401_e_erro_do_telegram_sem_vazar_token(self):
        self.assertEqual(self.post("/send", {"chat_id": "1", "text": "x"}, token="errado")[0], 401)
        code, out = self.post("/send", {"chat_id": "999", "text": "x"})
        self.assertEqual(code, 502)
        self.assertIn("chat not found", out["error"])
        self.assertNotIn("SEGREDO", json.dumps(out))

    def test_clique_reconhecer(self):
        UPDATES.append(callback("ack:13"))
        bridge.poll_forever(STOP)
        token, sent = N8N_CALLS[0]
        self.assertEqual(token, "bt")
        self.assertEqual(sent["chat_id"], "555")
        self.assertEqual(sent["from_name"], "Aguinaldo Neto")
        methods = [m for m, _ in CALLS if m != "getUpdates"]
        self.assertEqual(methods, ["answerCallbackQuery", "editMessageReplyMarkup", "sendMessage"])
        offsets = [b.get("offset") for m, b in CALLS if m == "getUpdates"]
        self.assertEqual(offsets[1], 8, "deveria confirmar o update (offset = id + 1)")

    def test_clique_recusado_so_responde(self):
        UPDATES.append(callback("ack:99"))
        bridge.poll_forever(STOP)
        methods = [m for m, _ in CALLS if m != "getUpdates"]
        self.assertEqual(methods, ["answerCallbackQuery"])
        self.assertIn("já resolvido", CALLS[1][1]["text"])


if __name__ == "__main__":
    unittest.main()
