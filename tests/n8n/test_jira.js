// Testes dos Code nodes do Jira fora do n8n. Uso: node tests/n8n/test_jira.js
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const load = (f) => fs.readFileSync(path.join(__dirname, '../../n8n/code', f), 'utf8');
const payload = (rows) => new Function('$input', load('jira_payload.js'))({ all: () => rows.map((json) => ({ json })) });
const pick = (json) => new Function('$json', load('jira_pick_transition.js'))(json);

const row = (o) => ({ id: 7, action: 'open', host: 'alpine-01', address: 'target-alpine',
  rule: 'cert_expiry', severity: 'critical', subject: '/opt/app/certs/app.crt', detail: 'vence em 5 dia(s)',
  first_seen: '2026-09-23T17:05:00Z', resolved_at: null, jira_key: null,
  base_url: 'https://acme.atlassian.net/', project: 'OPS', issue_type: 'Incident', ...o });
const allText = (adf) => JSON.stringify(adf).match(/"text":"[^"]*"/g).join(' ');

let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok   -', name); };

t('abertura: URL, projeto, tipo, resumo e labels', () => {
  const [{ json }] = payload([row()]);
  assert.strictEqual(json.url, 'https://acme.atlassian.net/rest/api/3/issue');
  const f = json.body.fields;
  assert.strictEqual(f.project.key, 'OPS');
  assert.strictEqual(f.issuetype.name, 'Incident');
  assert.strictEqual(f.summary, '[CRÍTICA] alpine-01: Certificado próximo do vencimento');
  assert.ok(f.labels.includes('fleet-audit-evt-7'));
  assert.ok(f.labels.every((l) => !/\s/.test(l)), 'label do Jira não aceita espaço');
});

t('descrição em ADF com host, data no fuso de SP e rótulos', () => {
  const [{ json }] = payload([row()]);
  const d = json.body.fields.description;
  assert.strictEqual(d.type, 'doc');
  const txt = allText(d);
  assert.match(txt, /alpine-01 \(target-alpine\)/);
  assert.match(txt, /23\/09\/2026 14:05:00/);
});

t('fechamento: comentário com duração e URL de transições', () => {
  const [{ json }] = payload([row({ action: 'close', jira_key: 'OPS-42', resolved_at: '2026-09-24T19:20:00Z' })]);
  assert.strictEqual(json.url, 'https://acme.atlassian.net/rest/api/3/issue/OPS-42/comment');
  assert.strictEqual(json.transitions_url, 'https://acme.atlassian.net/rest/api/3/issue/OPS-42/transitions');
  assert.match(allText(json.body.body), /1d 2h 15min/);
});

t('base_url inválida falha com instrução', () => {
  assert.throws(() => payload([row({ base_url: 'http://inseguro' })]), /make set-jira/);
  assert.throws(() => payload([row({ base_url: 'https://x.net/../evil' })]), /inválida/);
});

t('Postgres vazio não gera requisição', () => {
  assert.deepStrictEqual(payload([{ success: true }]), []);
});

t('transição: escolhe a de categoria done, independente do nome', () => {
  const out = pick({ transitions: [
    { id: '11', name: 'Em andamento', to: { statusCategory: { key: 'indeterminate' } } },
    { id: '31', name: 'Resolvido', to: { statusCategory: { key: 'done' } } },
  ] });
  assert.deepStrictEqual(out.json, { transition_id: '31', transition_name: 'Resolvido' });
  assert.strictEqual(pick({ transitions: [] }).json.transition_id, null);
});

console.log(`---\n${n} passaram`);
