-- Testes da fila do Jira. Rodam numa transação desfeita no final.
\set QUIET on
BEGIN;
SET client_min_messages = warning;
-- isola do ambiente: o banco real pode ter o Jira configurado (desfeito no ROLLBACK)
DELETE FROM settings WHERE key IN ('jira_base_url', 'jira_project', 'jira_issue_type');
INSERT INTO hosts (name, address) VALUES ('j-01', '10.0.0.9');

DO $$
DECLARE h int := (SELECT id FROM hosts WHERE name = 'j-01'); fid bigint; n int;
BEGIN
    INSERT INTO findings (host_id, rule, severity, subject, detail)
    VALUES (h, 'cert_expiry', 'critical', '/c.crt', 'vence') RETURNING id INTO fid;
    INSERT INTO findings (host_id, rule, severity, subject, detail)
    VALUES (h, 'fs_usage', 'high', '/data', '86%');

    -- sem configuração: fila vazia (integração desligada)
    ASSERT NOT EXISTS (SELECT 1 FROM v_jira_queue WHERE host = 'j-01'), 'fila deveria estar vazia sem config';

    INSERT INTO settings (key, value) VALUES ('jira_base_url', 'https://x.atlassian.net'), ('jira_project', 'OPS')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

    -- só o crítico entra para abertura; alta não abre chamado
    SELECT count(*) INTO n FROM v_jira_queue WHERE host = 'j-01';
    ASSERT n = 1, 'esperado 1 item, veio ' || n;
    ASSERT (SELECT action || '/' || issue_type FROM v_jira_queue WHERE id = fid) = 'open/Task', 'ação/tipo';
    RAISE NOTICE 'ok - só evento crítico abre chamado; tipo padrão Task';

    -- chave inválida é recusada
    BEGIN
        PERFORM jira_mark_opened(fid, 'lixo');
        RAISE EXCEPTION 'deveria ter recusado';
    EXCEPTION WHEN raise_exception THEN
        ASSERT SQLERRM LIKE 'chave Jira inválida%', SQLERRM;
    END;
    PERFORM jira_mark_opened(fid, 'OPS-42');
    ASSERT NOT EXISTS (SELECT 1 FROM v_jira_queue WHERE id = fid), 'aberto não deveria voltar à fila';
    RAISE NOTICE 'ok - chave validada e evento sai da fila';

    -- resolvido: entra para fechamento; depois de fechado, sai
    UPDATE findings SET resolved_at = now() WHERE id = fid;
    ASSERT (SELECT action || '/' || jira_key FROM v_jira_queue WHERE id = fid) = 'close/OPS-42', 'fechamento';
    PERFORM jira_mark_closed(fid);
    ASSERT NOT EXISTS (SELECT 1 FROM v_jira_queue WHERE id = fid), 'fechado não deveria voltar à fila';
    RAISE NOTICE 'ok - resolvido fecha o chamado uma única vez';
END $$;

ROLLBACK;
\echo 'todos os testes SQL do Jira passaram'
