// Nó "Escolher transição" (Code, Run Once for Each Item).
// A API não tem "fechar chamado": cada projeto tem seu próprio fluxo.
// Escolhe a primeira transição cujo destino é da categoria "done".
// Fonte da verdade deste código: n8n/code/jira_pick_transition.js.
const list = $json.transitions || [];
const done = list.find((t) => t?.to?.statusCategory?.key === 'done');
return { json: { transition_id: done ? String(done.id) : null, transition_name: done ? done.name : null } };
