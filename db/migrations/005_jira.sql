-- 005: integração com Jira (abertura e fechamento de chamado).
-- O estado do Jira fica em colunas próprias, independente do Telegram:
-- se o Jira cair, o Telegram continua funcionando, e vice-versa.
SET ROLE inventory_rw;

ALTER TABLE findings
    ADD COLUMN jira_key       text,
    ADD COLUMN jira_closed_at timestamptz;

-- Fila de trabalho do workflow do Jira.
--   open : evento crítico aberto ainda sem chamado
--   close: evento resolvido cujo chamado ainda não foi fechado
-- Só entra na fila se jira_project estiver configurado (make set-jira).
CREATE VIEW v_jira_queue AS
WITH cfg AS (
    SELECT max(value) FILTER (WHERE key = 'jira_base_url')   AS base_url,
           max(value) FILTER (WHERE key = 'jira_project')    AS project,
           coalesce(max(value) FILTER (WHERE key = 'jira_issue_type'), 'Task') AS issue_type
      FROM settings
)
SELECT f.id,
       CASE WHEN f.resolved_at IS NULL THEN 'open' ELSE 'close' END AS action,
       h.name AS host, h.address, f.rule, f.severity, f.subject, f.detail,
       f.first_seen, f.resolved_at, f.jira_key,
       cfg.base_url, cfg.project, cfg.issue_type
  FROM findings f
  JOIN hosts h ON h.id = f.host_id
 CROSS JOIN cfg
 WHERE cfg.project IS NOT NULL AND cfg.base_url IS NOT NULL
   AND (   (f.resolved_at IS NULL     AND f.jira_key IS NULL AND f.severity = 'critical')
        OR (f.resolved_at IS NOT NULL AND f.jira_key IS NOT NULL AND f.jira_closed_at IS NULL));

-- Chamado criado: grava a chave (ex.: OPS-42). Valida o formato para não
-- gravar lixo caso a API devolva algo inesperado.
CREATE FUNCTION jira_mark_opened(p_id bigint, p_key text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF p_key !~ '^[A-Z][A-Z0-9_]+-[0-9]+$' THEN
        RAISE EXCEPTION 'chave Jira inválida: %', p_key;
    END IF;
    UPDATE findings SET jira_key = p_key WHERE id = p_id AND jira_key IS NULL;
    RETURN p_key;
END $$;

CREATE FUNCTION jira_mark_closed(p_id bigint)
RETURNS void LANGUAGE sql AS $$
    UPDATE findings SET jira_closed_at = now() WHERE id = p_id AND jira_key IS NOT NULL;
$$;

REVOKE EXECUTE ON FUNCTION jira_mark_opened, jira_mark_closed FROM PUBLIC;

RESET ROLE;
