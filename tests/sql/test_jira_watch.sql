-- Testes de jira_watch_diff (mudança de responsável/status/prioridade feita
-- por humano no Jira). Rodam numa transação desfeita no final.
\set QUIET on
BEGIN;
SET client_min_messages = warning;
DELETE FROM jira_watch WHERE jira_key = 'KAN-99';

DO $$
DECLARE r record;
BEGIN
    -- primeira vez que vê a chave: só grava a base, não é "mudança"
    SELECT * INTO r FROM jira_watch_diff('KAN-99', 'Fulano', 'A Fazer', 'High');
    ASSERT r.changed = false, 'primeira vez não deveria acusar mudança';
    ASSERT (SELECT count(*) FROM jira_watch WHERE jira_key = 'KAN-99') = 1, 'deveria ter gravado a base';
    RAISE NOTICE 'ok - primeira observação só grava, não avisa';

    -- nada mudou: sem novidade
    SELECT * INTO r FROM jira_watch_diff('KAN-99', 'Fulano', 'A Fazer', 'High');
    ASSERT r.changed = false, 'sem mudança não deveria acusar';
    RAISE NOTICE 'ok - repetir os mesmos valores não avisa';

    -- responsável mudou: acusa e devolve o valor antigo
    SELECT * INTO r FROM jira_watch_diff('KAN-99', 'Ciclana', 'A Fazer', 'High');
    ASSERT r.changed = true, 'responsável mudou, deveria acusar';
    ASSERT r.old_assignee = 'Fulano', 'valor antigo do responsável';
    ASSERT (SELECT assignee FROM jira_watch WHERE jira_key = 'KAN-99') = 'Ciclana', 'deveria ter atualizado';
    RAISE NOTICE 'ok - mudança de responsável é detectada e o estado novo é gravado';

    -- status e prioridade mudam juntos
    SELECT * INTO r FROM jira_watch_diff('KAN-99', 'Ciclana', 'Em andamento', 'Highest');
    ASSERT r.changed = true, 'status/prioridade mudaram, deveria acusar';
    ASSERT r.old_status = 'A Fazer' AND r.old_priority = 'High', 'valores antigos de status/prioridade';
    RAISE NOTICE 'ok - mudança de status e prioridade juntas é detectada';

    -- responsável nulo (não atribuído) não quebra a comparação
    SELECT * INTO r FROM jira_watch_diff('KAN-99', NULL, 'Em andamento', 'Highest');
    ASSERT r.changed = true AND r.old_assignee = 'Ciclana', 'voltar a não atribuído é mudança';
    SELECT * INTO r FROM jira_watch_diff('KAN-99', NULL, 'Em andamento', 'Highest');
    ASSERT r.changed = false, 'repetir NULL não deveria acusar (IS DISTINCT FROM)';
    RAISE NOTICE 'ok - responsável nulo não gera falso positivo';
END $$;

ROLLBACK;
\echo 'todos os testes SQL de jira_watch passaram'
