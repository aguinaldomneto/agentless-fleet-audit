// Testes dos Code nodes de mudança no chamado Jira, fora do n8n.
// Uso: node tests/n8n/test_jira_changes.js
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const load = (f) => fs.readFileSync(path.join(__dirname, '../../n8n/code', f), 'utf8');
const parse = (issues) => new Function('$input', load('jira_changes_parse.js'))({ first: () => ({ json: { issues } }) });
const message = (json) => new Function('$json', load('jira_change_message.js'))(json);

let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok   -', name); };

t('parse: extrai key, responsável, status e prioridade', () => {
  const out = parse([
    { key: 'KAN-33', fields: { assignee: { displayName: 'Fulano' }, status: { name: 'Em andamento' }, priority: { name: 'High' } } },
    { key: 'KAN-34', fields: { assignee: null, status: { name: 'A Fazer' }, priority: { name: 'Medium' } } },
  ]);
  assert.deepStrictEqual(out[0].json, { key: 'KAN-33', assignee: 'Fulano', status: 'Em andamento', priority: 'High' });
  assert.strictEqual(out[1].json.assignee, null);
});

t('parse: sem chamados não gera item nenhum', () => {
  assert.deepStrictEqual(parse([]), []);
});

const row = (o) => ({
  jira_key: 'KAN-33', chat_id: '555',
  assignee: 'Fulano', status: 'Em andamento', priority: 'High',
  old_assignee: 'Fulano', old_status: 'A Fazer', old_priority: 'High',
  ...o,
});

t('mensagem: só lista o(s) campo(s) que mudou', () => {
  const { json } = message(row());
  assert.strictEqual(json.chat_id, '555');
  assert.match(json.text, /CHAMADO ATUALIZADO/);
  assert.match(json.text, /Status:<\/b> A Fazer → Em andamento/);
  assert.doesNotMatch(json.text, /Responsável:/);
  assert.doesNotMatch(json.text, /Prioridade:/);
});

t('mensagem: responsável vazio aparece como "não atribuído"', () => {
  const { json } = message(row({ old_assignee: null, assignee: 'Fulano', old_status: 'Em andamento', old_priority: 'High' }));
  assert.match(json.text, /Responsável:<\/b> não atribuído → Fulano/);
});

t('mensagem: escapa HTML do valor (nome de status/prioridade não confiável)', () => {
  const { json } = message(row({ old_status: '<script>', status: 'Em andamento', old_priority: 'High' }));
  assert.match(json.text, /&lt;script&gt;/);
  assert.doesNotMatch(json.text, /<script>/);
});

t('mensagem: mais de um campo mudou ao mesmo tempo', () => {
  const { json } = message(row({ old_assignee: null, old_status: 'A Fazer', old_priority: 'Medium' }));
  assert.match(json.text, /Responsável:/);
  assert.match(json.text, /Status:/);
  assert.match(json.text, /Prioridade:/);
});

console.log(`---\n${n} passaram`);
