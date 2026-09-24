// Nó "Montar mensagem" (Code, Run Once for All Items).
// Entrada: linhas de v_pending_notifications (+ address, chat_id).
// Saída: 1 item por evento { chat_id, text, ids: [id], buttons } — uma mensagem por
// evento, no formato de chamado. Eventos abertos levam botões Reconhecer/Silenciar.
// Nenhum item = nada a enviar.
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
  high: { icon: '🟠', label: 'ALTA' },
  medium: { icon: '🟡', label: 'MÉDIA' },
  warning: { icon: '🟠', label: 'ALTA' },   // legado
  info: { icon: '🟡', label: 'MÉDIA' },     // legado
};
const ORDER = { critical: 0, high: 1, warning: 1, medium: 2, info: 2 };
const STATE = { firing: 0, reminder: 1, resolved: 2 };
const SILENCE_MIN = 240;

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

function render(r, now) {
  const sev = SEV[r.severity] || { icon: '⚪', label: String(r.severity).toUpperCase() };
  const open = r.state !== 'resolved';
  const reminder = r.state === 'reminder';
  const host = r.address && r.address !== r.host ? `${esc(r.host)} (${esc(r.address)})` : esc(r.host);
  const title = reminder ? `${sev.icon} <b>LEMBRETE: EVENTO AINDA ABERTO</b>`
    : open ? `${sev.icon} <b>EVENTO ABERTO</b>` : '✅ <b>EVENTO RESOLVIDO</b>';
  const status = reminder ? `ATIVO (lembrete nº ${r.reminder_number || 1})`
    : open ? 'ATIVO (aguardando ação)' : 'NORMALIZADO';
  const lines = [
    title,
    '━━━━━━━━━━━━━━━━━━',
    `🚨 <b>Severidade:</b> ${sev.label}`,
    `📌 <b>Status:</b> ${status}`,
    `🖥️ <b>Host:</b> ${host}`,
    `⚠️ <b>Alerta:</b> ${esc(RULE[r.rule] || r.rule)}`,
    `📄 <b>Objeto:</b> <code>${esc(r.subject)}</code>`,
    `📝 <b>${open ? 'Detalhe' : 'Último estado'}:</b> ${esc(r.detail)}`,
    `🕒 <b>Data de criação:</b> ${fmtDate(r.first_seen)}`,
  ];
  if (reminder) lines.push(`⏳ <b>Aberto há:</b> ${fmtDuration(r.first_seen, now)}`);
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

// Novos primeiro, depois lembretes, recuperações por último; críticos antes.
rows.sort((a, b) =>
  (STATE[a.state] ?? 9) - (STATE[b.state] ?? 9) ||
  (ORDER[a.severity] ?? 9) - (ORDER[b.severity] ?? 9) ||
  String(a.host).localeCompare(String(b.host)) || a.id - b.id);

const now = new Date();
return rows.slice(0, MAX_PER_RUN).map((r) => ({
  json: {
    chat_id: String(chatId),
    text: render(r, now),
    ids: [r.id],
    // botões só em evento aberto; o callback volta pelo telegram-bridge
    buttons: r.state === 'resolved' ? [] : [[
      { text: '✅ Reconhecer', data: `ack:${r.id}` },
      { text: '🔕 Silenciar 4h', data: `sil:${r.id}:${SILENCE_MIN}` },
    ]],
  },
}));
