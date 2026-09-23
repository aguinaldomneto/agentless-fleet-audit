// Testa o Code node fora do n8n, simulando $input.
// Uso: node tests/n8n/test_format_message.js
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const src = fs.readFileSync(path.join(__dirname, '../../n8n/code/format_message.js'), 'utf8');
const run = (rows) =>
  new Function('$input', src)({ all: () => rows.map((json) => ({ json })) });

const row = (o) => ({ id: 1, host: 'alpine-01', rule: 'cert_expiry', severity: 'critical',
  subject: '/opt/app/certs/app.crt', detail: 'vence em 5 dias', state: 'firing',
  chat_id: '123', ...o });

let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok   -', name); };

t('sem pendências não envia nada', () => {
  assert.deepStrictEqual(run([]), []);
});

t('Postgres vazio (item sem id) não envia nada', () => {
  assert.deepStrictEqual(run([{ success: true }]), []);
});

t('mensagem com alerta e recuperação, críticos primeiro', () => {
  const [out] = run([
    row({ id: 1, severity: 'warning', host: 'b' }),
    row({ id: 2, severity: 'critical', host: 'z' }),
    row({ id: 3, state: 'resolved', rule: 'fs_usage', subject: '/data' }),
  ]);
  const t = out.json.text;
  assert.match(t, /2 alerta\(s\), 1 recuperação/);
  assert.ok(t.indexOf('🔴') < t.indexOf('🟡'), 'critical antes de warning');
  assert.ok(t.indexOf('🟡') < t.indexOf('✅'), 'recuperação por último');
  assert.deepStrictEqual(out.json.ids, [2, 1, 3]);
  assert.strictEqual(out.json.chat_id, '123');
});

t('escapa HTML (subject vindo do servidor)', () => {
  const [out] = run([row({ subject: '/tmp/<script>&x' })]);
  assert.match(out.json.text, /&lt;script&gt;&amp;x/);
  assert.doesNotMatch(out.json.text, /<script>/);
});

t('respeita limite do Telegram e só marca o que foi enviado', () => {
  const many = Array.from({ length: 200 }, (_, i) => row({ id: i + 1, detail: 'x'.repeat(80) }));
  const [out] = run(many);
  assert.ok(out.json.text.length <= 4096, `tamanho ${out.json.text.length}`);
  assert.ok(out.json.ids.length < 200);
  assert.match(out.json.text, new RegExp(`e mais ${200 - out.json.ids.length}`));
});

t('sem chat_id falha com instrução clara', () => {
  assert.throws(() => run([row({ chat_id: null })]), /make set-chat-id/);
});

console.log(`---\n${n} passaram`);
