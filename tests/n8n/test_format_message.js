// Testa o Code node fora do n8n, simulando $input.
// Uso: node tests/n8n/test_format_message.js
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const src = fs.readFileSync(path.join(__dirname, '../../n8n/code/format_message.js'), 'utf8');
const run = (rows) =>
  new Function('$input', src)({ all: () => rows.map((json) => ({ json })) });

const row = (o) => ({ id: 1, host: 'alpine-01', address: 'target-alpine', rule: 'cert_expiry',
  severity: 'critical', subject: '/opt/app/certs/app.crt', detail: 'vence em 5 dias',
  state: 'firing', first_seen: '2026-09-23T17:05:00Z', resolved_at: null,
  chat_id: '123', ...o });

let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok   -', name); };

t('sem pendências não envia nada', () => {
  assert.deepStrictEqual(run([]), []);
  assert.deepStrictEqual(run([{ success: true }]), []);
});

t('evento aberto no formato de chamado', () => {
  const [out] = run([row()]);
  const txt = out.json.text;
  assert.match(txt, /^🔴 <b>EVENTO ABERTO<\/b>/);
  assert.match(txt, /Severidade:<\/b> CRÍTICA/);
  assert.match(txt, /Status:<\/b> ATIVO/);
  assert.match(txt, /Host:<\/b> alpine-01 \(target-alpine\)/);
  assert.match(txt, /Alerta:<\/b> Certificado próximo do vencimento/);
  assert.match(txt, /Data de criação:<\/b> 23\/09\/2026 14:05:00/); // UTC-3
  assert.doesNotMatch(txt, /resolução/);
  assert.deepStrictEqual(out.json.ids, [1]);
  assert.strictEqual(out.json.chat_id, '123');
});

t('evento resolvido mostra resolução e duração', () => {
  const [out] = run([row({ state: 'resolved', resolved_at: '2026-09-24T19:20:00Z' })]);
  const txt = out.json.text;
  assert.match(txt, /^✅ <b>EVENTO RESOLVIDO<\/b>/);
  assert.match(txt, /Status:<\/b> NORMALIZADO/);
  assert.match(txt, /Data de resolução:<\/b> 24\/09\/2026 16:20:00/);
  assert.match(txt, /Duração:<\/b> 1d 2h 15min/);
  assert.match(txt, /Último estado:<\/b>/);
});

t('uma mensagem por evento, abertos críticos primeiro e resolvidos por último', () => {
  const out = run([
    row({ id: 1, state: 'resolved', resolved_at: '2026-09-24T00:00:00Z' }),
    row({ id: 2, severity: 'high' }),
    row({ id: 3, severity: 'critical' }),
  ]);
  assert.deepStrictEqual(out.map((o) => o.json.ids[0]), [3, 2, 1]);
  const mix = run([row({ id: 5, state: 'reminder' }), row({ id: 6, severity: 'medium' })]);
  assert.deepStrictEqual(mix.map((o) => o.json.ids[0]), [6, 5], 'novo antes de lembrete');
});

t('lembrete: título, número do lembrete e tempo aberto', () => {
  const [out] = run([row({ state: 'reminder', reminder_number: 3, first_seen: new Date(Date.now() - 125 * 60000).toISOString() })]);
  const txt = out.json.text;
  assert.match(txt, /^🔴 <b>LEMBRETE: EVENTO AINDA ABERTO<\/b>/);
  assert.match(txt, /lembrete nº 3/);
  assert.match(txt, /Aberto há:<\/b> 2h 5min/);
});

t('botões só em evento aberto, com o id do evento', () => {
  const [a] = run([row({ id: 13 })]);
  assert.deepStrictEqual(a.json.buttons[0].map((b) => b.data), ['ack:13', 'sil:13:240']);
  const [r] = run([row({ state: 'resolved', resolved_at: '2026-09-24T00:00:00Z' })]);
  assert.deepStrictEqual(r.json.buttons, []);
});

t('severidades alta e média', () => {
  assert.match(run([row({ severity: 'high' })])[0].json.text, /🟠 <b>EVENTO ABERTO[\s\S]*ALTA/);
  assert.match(run([row({ severity: 'medium' })])[0].json.text, /🟡 <b>EVENTO ABERTO[\s\S]*MÉDIA/);
});

t('host sem address separado não duplica o nome', () => {
  const [out] = run([row({ address: 'alpine-01' })]);
  assert.match(out.json.text, /Host:<\/b> alpine-01\n/);
});

t('escapa HTML vindo do servidor', () => {
  const [out] = run([row({ subject: '/tmp/<script>&x' })]);
  assert.match(out.json.text, /&lt;script&gt;&amp;x/);
  assert.doesNotMatch(out.json.text, /<script>/);
});

t('limita a 20 mensagens por execução', () => {
  const out = run(Array.from({ length: 50 }, (_, i) => row({ id: i + 1 })));
  assert.strictEqual(out.length, 20);
  assert.ok(out.every((o) => o.json.text.length < 4096));
});

t('sem chat_id falha com instrução clara', () => {
  assert.throws(() => run([row({ chat_id: null })]), /make set-chat-id/);
});

console.log(`---\n${n} passaram`);
