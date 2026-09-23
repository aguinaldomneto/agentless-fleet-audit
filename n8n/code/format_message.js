// Nó "Montar mensagem" (Code, Run Once for All Items).
// Entrada: linhas de v_pending_notifications (+ chat_id).
// Saída: 1 item { chat_id, text, ids } ou nenhum item (nada a enviar).
// Fonte da verdade deste código: n8n/code/format_message.js (testado em tests/n8n).
const MAX = 3900; // limite do Telegram é 4096; sobra margem para o rodapé
const ICON = { critical: '🔴', warning: '🟡', info: '🔵', resolved: '✅' };
const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const rows = $input.all().map((i) => i.json).filter((r) => r.id != null);
if (rows.length === 0) return [];

const chatId = rows[0].chat_id;
if (!chatId) {
  throw new Error("chat_id do Telegram não configurado. Rode: make set-chat-id CHAT_ID=<id>");
}

const firing = rows.filter((r) => r.state === 'firing');
const resolved = rows.filter((r) => r.state === 'resolved');
const order = { critical: 0, warning: 1, info: 2 };
firing.sort((a, b) => order[a.severity] - order[b.severity] || a.host.localeCompare(b.host));

const block = (r) => {
  const icon = r.state === 'resolved' ? ICON.resolved : ICON[r.severity] || '⚪';
  const tag = r.state === 'resolved' ? 'RESOLVIDO' : String(r.severity).toUpperCase();
  return `${icon} <b>${esc(r.host)}</b> · ${esc(r.rule)} · ${tag}\n` +
         `<code>${esc(r.subject)}</code>\n${esc(r.detail)}`;
};

const header = `<b>fleet-audit</b>: ${firing.length} alerta(s), ${resolved.length} recuperação(ões)\n`;
let text = header;
const sent = [];
for (const r of [...firing, ...resolved]) {
  const b = '\n' + block(r) + '\n';
  if (text.length + b.length > MAX) break;
  text += b;
  sent.push(r.id);
}
const rest = rows.length - sent.length;
if (rest > 0) text += `\n… e mais ${rest}. Veja no Grafana (v_pending_notifications).`;

// Só os itens que couberam na mensagem são marcados como enviados;
// o restante sai na próxima execução.
return [{ json: { chat_id: String(chatId), text, ids: sent } }];
