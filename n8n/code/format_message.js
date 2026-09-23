// Nó "Montar mensagem" (Code, Run Once for All Items).
// Entrada: linhas de v_pending_notifications (+ address, chat_id).
// Saída: 1 item por evento { chat_id, text, ids: [id] } — uma mensagem por evento,
// no formato de chamado. Nenhum item = nada a enviar.
// Fonte da verdade deste código: n8n/code/format_message.js (testado em tests/n8n).
const MAX_PER_RUN = 20; // evita rajada no Telegram; o excedente sai na próxima execução
const TZ = 'America/Sao_Paulo';

const RULE = {
  cert_expiry: 'Certificado próximo do vencimento',
  fs_usage: 'Uso de filesystem acima do limite',
  uid0_extra: 'Conta com UID 0 além do root',
  collection_failed: 'Falha na coleta (SSH)',
};
const SEV = {
  critical: { icon: '🔴', label: 'CRÍTICA' },
  warning: { icon: '🟡', label: 'ATENÇÃO' },
  info: { icon: '🔵', label: 'INFORMATIVA' },
};
const ORDER = { critical: 0, warning: 1, info: 2 };

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const fmtDate = (v) => {
  if (!v) return '-';
  const d = new Date(v);
  if (isNaN(d)) return esc(v);
  return new Intl.DateTimeFormat('pt-BR', {
    timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).format(d).replace(',', '');
};
const fmtDuration = (from, to) => {
  const min = Math.max(0, Math.round((new Date(to) - new Date(from)) / 60000));
  const d = Math.floor(min / 1440), h = Math.floor((min % 1440) / 60), m = min % 60;
  return [d && `${d}d`, h && `${h}h`, `${m}min`].filter(Boolean).join(' ');
};

function render(r) {
  const sev = SEV[r.severity] || { icon: '⚪', label: String(r.severity).toUpperCase() };
  const open = r.state !== 'resolved';
  const host = r.address && r.address !== r.host ? `${esc(r.host)} (${esc(r.address)})` : esc(r.host);
  const lines = [
    open ? `${sev.icon} <b>EVENTO ABERTO</b>` : '✅ <b>EVENTO RESOLVIDO</b>',
    '━━━━━━━━━━━━━━━━━━',
    `🚨 <b>Severidade:</b> ${sev.label}`,
    `📌 <b>Status:</b> ${open ? 'ATIVO (aguardando ação)' : 'NORMALIZADO'}`,
    `🖥️ <b>Host:</b> ${host}`,
    `⚠️ <b>Alerta:</b> ${esc(RULE[r.rule] || r.rule)}`,
    `📄 <b>Objeto:</b> <code>${esc(r.subject)}</code>`,
    `📝 <b>${open ? 'Detalhe' : 'Último estado'}:</b> ${esc(r.detail)}`,
    `🕒 <b>Data de criação:</b> ${fmtDate(r.first_seen)}`,
  ];
  if (!open) {
    lines.push(`🏁 <b>Data de resolução:</b> ${fmtDate(r.resolved_at)}`);
    lines.push(`⏱️ <b>Duração:</b> ${fmtDuration(r.first_seen, r.resolved_at)}`);
  }
  lines.push(`🔖 <i>evento #${r.id} · fleet-audit</i>`);
  return lines.join('\n');
}

const rows = $input.all().map((i) => i.json).filter((r) => r.id != null);
if (rows.length === 0) return [];

const chatId = rows[0].chat_id;
if (!chatId) {
  throw new Error("chat_id do Telegram não configurado. Rode: make set-chat-id CHAT_ID=<id>");
}

// Abertos primeiro (críticos antes), recuperações por último.
rows.sort((a, b) =>
  (a.state === 'resolved') - (b.state === 'resolved') ||
  (ORDER[a.severity] ?? 9) - (ORDER[b.severity] ?? 9) ||
  String(a.host).localeCompare(String(b.host)) || a.id - b.id);

return rows.slice(0, MAX_PER_RUN).map((r) => ({
  json: { chat_id: String(chatId), text: render(r), ids: [r.id] },
}));
