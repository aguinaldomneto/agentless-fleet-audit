-- 008: observa mudança feita por humano no chamado do Jira (responsável,
-- status/fila, prioridade) para avisar no Telegram. Independente da
-- abertura/fechamento automático (findings.jira_key), que continua em 005.
SET ROLE inventory_rw;

CREATE TABLE jira_watch (
    jira_key   text PRIMARY KEY,
    assignee   text,
    status     text NOT NULL,
    priority   text,
    checked_at timestamptz NOT NULL DEFAULT now()
);

-- Compara o que veio do Jira agora com o que ficou salvo na rodada anterior
-- e já grava o estado novo (upsert). Primeira vez que vê a chave: só grava a
-- base — não é "mudança", senão tudo que já existia viraria aviso ao ligar
-- o poll pela primeira vez.
CREATE FUNCTION jira_watch_diff(p_key text, p_assignee text, p_status text, p_priority text)
RETURNS TABLE(changed boolean, old_assignee text, old_status text, old_priority text)
LANGUAGE plpgsql AS $$
DECLARE
    r jira_watch;
BEGIN
    SELECT * INTO r FROM jira_watch WHERE jira_key = p_key FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO jira_watch (jira_key, assignee, status, priority) VALUES (p_key, p_assignee, p_status, p_priority);
        RETURN QUERY SELECT false, NULL::text, NULL::text, NULL::text;
        RETURN;
    END IF;

    IF r.assignee IS DISTINCT FROM p_assignee OR r.status IS DISTINCT FROM p_status OR r.priority IS DISTINCT FROM p_priority THEN
        UPDATE jira_watch SET assignee = p_assignee, status = p_status, priority = p_priority, checked_at = now()
         WHERE jira_key = p_key;
        RETURN QUERY SELECT true, r.assignee, r.status, r.priority;
        RETURN;
    END IF;

    UPDATE jira_watch SET checked_at = now() WHERE jira_key = p_key;
    RETURN QUERY SELECT false, NULL::text, NULL::text, NULL::text;
END $$;

REVOKE EXECUTE ON FUNCTION jira_watch_diff FROM PUBLIC;

RESET ROLE;
