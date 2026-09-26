// Nó "Montar mudanças" (Code, Run Once for All Items).
// Entrada: 1 item com a resposta de GET /rest/api/3/search (fields=status,assignee,priority).
// Saída: 1 item por chamado retornado, só com os campos que este workflow observa.
// Fonte da verdade deste código: n8n/code/jira_changes_parse.js (testado em tests/n8n).
const issues = $input.first().json.issues || [];
return issues.map((it) => ({
  json: {
    key: it.key,
    assignee: it.fields && it.fields.assignee ? it.fields.assignee.displayName : null,
    status: it.fields && it.fields.status ? it.fields.status.name : null,
    priority: it.fields && it.fields.priority ? it.fields.priority.name : null,
  },
}));
