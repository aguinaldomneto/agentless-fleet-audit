// Nó "Montar mensagem de mudança" (Code, Run Once for Each Item).
// Entrada: 1 linha de jira_watch_diff (só chega aqui quando changed = true),
// com os valores atuais e os anteriores, mais o chat_id do Telegram.
// Saída: { chat_id, text } pronto para o telegram-bridge.
// Fonte da verdade deste código: n8n/code/jira_change_message.js (testado em tests/n8n).
const r = $json;
const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const who = (v) => (v ? esc(v) : 'não atribuído');

const changes = [];
if (r.old_assignee !== r.assignee) changes.push(`<b>Responsável:</b> ${who(r.old_assignee)} → ${who(r.assignee)}`);
if (r.old_status !== r.status) changes.push(`<b>Status:</b> ${esc(r.old_status)} → ${esc(r.status)}`);
if (r.old_priority !== r.priority) changes.push(`<b>Prioridade:</b> ${esc(r.old_priority)} → ${esc(r.priority)}`);

const text = ['🔄 <b>CHAMADO ATUALIZADO</b>', `🎫 Chamado: ${esc(r.jira_key)}`, ...changes].join('\n');

return { json: { chat_id: r.chat_id, text } };
