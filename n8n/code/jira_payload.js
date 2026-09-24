// Nó "Montar requisição Jira" (Code, Run Once for All Items).
// Entrada: linhas de v_jira_queue. Saída: 1 item por evento com as URLs e os
// corpos prontos para a API REST v3 do Jira Cloud (texto em formato ADF).
// Fonte da verdade deste código: n8n/code/jira_payload.js (testado em tests/n8n).
const TZ = 'America/Sao_Paulo';
const RULE = {
  cert_expiry: 'Certificado próximo do vencimento',
  fs_usage: 'Uso de filesystem acima do limite',
  uid0_extra: 'Conta com UID 0 além do root',
  collection_failed: 'Falha na coleta (SSH)',
};
const SEV = { critical: 'CRÍTICA', high: 'ALTA', medium: 'MÉDIA', warning: 'ALTA', info: 'MÉDIA' };

const fmtDate = (v) => v ? new Intl.DateTimeFormat('pt-BR', {
  timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric',
  hour: '2-digit', minute: '2-digit', second: '2-digit',
}).format(new Date(v)).replace(',', '') : '-';
const fmtDuration = (from, to) => {
  const min = Math.max(0, Math.round((new Date(to) - new Date(from)) / 60000));
  const d = Math.floor(min / 1440), h = Math.floor((min % 1440) / 60), m = min % 60;
  return [d && `${d}d`, h && `${h}h`, `${m}min`].filter(Boolean).join(' ');
};

// Atlassian Document Format: parágrafos com rótulo em negrito.
const text = (t, bold) => ({ type: 'text', text: String(t ?? '-'), ...(bold ? { marks: [{ type: 'strong' }] } : {}) });
const field = (label, value) => ({ type: 'paragraph', content: [text(`${label}: `, true), text(value)] });
const doc = (...content) => ({ type: 'doc', version: 1, content });

function openRequest(r, base) {
  const host = r.address && r.address !== r.host ? `${r.host} (${r.address})` : r.host;
  const alerta = RULE[r.rule] || r.rule;
  return {
    method: 'POST',
    url: `${base}/rest/api/3/issue`,
    body: {
      fields: {
        project: { key: r.project },
        issuetype: { name: r.issue_type || 'Task' },
        summary: `[${SEV[r.severity] || r.severity}] ${r.host}: ${alerta}`.slice(0, 250),
        // label com o id do evento: permite achar o chamado de qualquer evento
        labels: ['fleet-audit', `sev-${r.severity}`, `rule-${r.rule}`, `fleet-audit-evt-${r.id}`],
        description: doc(
          field('Severidade', SEV[r.severity] || r.severity),
          field('Host', host),
          field('Alerta', alerta),
          field('Objeto', r.subject),
          field('Detalhe', r.detail),
          field('Data de criação', fmtDate(r.first_seen)),
          { type: 'paragraph', content: [text(`Aberto automaticamente pelo fleet-audit (evento #${r.id}).`)] },
        ),
      },
    },
  };
}

function closeRequest(r, base) {
  return {
    method: 'POST',
    url: `${base}/rest/api/3/issue/${encodeURIComponent(r.jira_key)}/comment`,
    transitions_url: `${base}/rest/api/3/issue/${encodeURIComponent(r.jira_key)}/transitions`,
    body: {
      body: doc(
        { type: 'paragraph', content: [text('✅ Evento normalizado', true)] },
        field('Data de resolução', fmtDate(r.resolved_at)),
        field('Duração', fmtDuration(r.first_seen, r.resolved_at)),
        field('Último estado', r.detail),
      ),
    },
  };
}

return $input.all()
  .map((i) => i.json)
  .filter((r) => r.id != null && (r.action === 'open' || r.action === 'close'))
  .map((r) => {
    const base = String(r.base_url || '').replace(/\/+$/, '');
    if (!/^https:\/\/[A-Za-z0-9.-]+$/.test(base)) {
      throw new Error(`jira_base_url inválida: "${r.base_url}". Use: make set-jira BASE_URL=https://seu-site.atlassian.net ...`);
    }
    const req = r.action === 'open' ? openRequest(r, base) : closeRequest(r, base);
    return { json: { id: r.id, action: r.action, jira_key: r.jira_key ?? null, ...req } };
  });
