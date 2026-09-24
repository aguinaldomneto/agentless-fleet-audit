-- Testes de lembretes recorrentes, reconhecimento e silêncio.
\set QUIET on
BEGIN;
SET client_min_messages = warning;
-- isola do ambiente: usa os intervalos padrão 60/180/480 (desfeito no ROLLBACK)
DELETE FROM settings WHERE key LIKE 'remind_minutes_%';
INSERT INTO hosts (name, address) VALUES ('n-01', 'n-01');
INSERT INTO settings (key, value) VALUES ('telegram_chat_id', '555')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE FUNCTION pg_temp.st(p_id bigint) RETURNS text LANGUAGE sql AS $$
    SELECT coalesce((SELECT state FROM v_pending_notifications WHERE id = p_id), '-');
$$;

DO $$
DECLARE h int := (SELECT id FROM hosts WHERE name = 'n-01');
        c bigint; hi bigint; md bigint; r record;
BEGIN
    INSERT INTO findings (host_id, rule, severity, subject, detail) VALUES (h, 'r', 'critical', 'c', 'x') RETURNING id INTO c;
    INSERT INTO findings (host_id, rule, severity, subject, detail) VALUES (h, 'r', 'high',     'h', 'x') RETURNING id INTO hi;
    INSERT INTO findings (host_id, rule, severity, subject, detail) VALUES (h, 'r', 'medium',   'm', 'x') RETURNING id INTO md;

    ASSERT pg_temp.st(c) = 'firing', 'novo deveria ser firing';
    PERFORM mark_notified(ARRAY[c, hi, md]);
    ASSERT pg_temp.st(c) = '-' AND pg_temp.st(hi) = '-' AND pg_temp.st(md) = '-', 'recém avisados não deveriam voltar';

    -- 2h depois do último aviso: só o crítico (60 min) pede lembrete
    UPDATE findings SET last_notified_at = now() - interval '2 hours' WHERE id IN (c, hi, md);
    ASSERT pg_temp.st(c) = 'reminder', 'crítico após 2h';
    ASSERT pg_temp.st(hi) = '-', 'alta só após 3h';
    -- 4h: alta também; média ainda não (8h)
    UPDATE findings SET last_notified_at = now() - interval '4 hours' WHERE id IN (hi, md);
    ASSERT pg_temp.st(hi) = 'reminder' AND pg_temp.st(md) = '-', 'alta 4h / média 4h';
    UPDATE findings SET last_notified_at = now() - interval '9 hours' WHERE id = md;
    ASSERT pg_temp.st(md) = 'reminder', 'média após 9h';
    RAISE NOTICE 'ok - intervalos 1h / 3h / 8h por severidade';

    PERFORM mark_notified(ARRAY[c]);
    ASSERT (SELECT reminder_count FROM findings WHERE id = c) = 1, 'contador de lembretes';
    ASSERT pg_temp.st(c) = '-', 'lembrete enviado reinicia o relógio';
    RAISE NOTICE 'ok - lembrete enviado reinicia o intervalo e conta';

    -- intervalo configurável
    INSERT INTO settings VALUES ('remind_minutes_critical', '30') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
    UPDATE findings SET last_notified_at = now() - interval '40 minutes' WHERE id = c;
    ASSERT pg_temp.st(c) = 'reminder', 'intervalo configurado 30 min';
    RAISE NOTICE 'ok - intervalo configurável via settings';

    -- ack pelo Telegram: chat errado é recusado
    SELECT * INTO r FROM telegram_action('999', 'ack:' || c, 'Intruso');
    ASSERT NOT r.ok AND r.message = 'chat não autorizado', 'chat errado';
    SELECT * INTO r FROM telegram_action('555', 'ack:1;drop', 'x');
    ASSERT NOT r.ok, 'payload inválido';
    SELECT * INTO r FROM telegram_action('555', 'ack:' || c, 'Aguinaldo');
    ASSERT r.ok AND r.message LIKE '%reconhecido por Aguinaldo%', r.message;
    ASSERT pg_temp.st(c) = '-', 'reconhecido não recebe lembrete';
    RAISE NOTICE 'ok - reconhecer valida o chat e pausa lembretes';

    -- escalada desfaz o reconhecimento
    UPDATE findings SET severity = 'high', acked_at = now() WHERE id = hi;
    PERFORM upsert_finding(h, 'r', 'critical', 'h', 'piorou');
    ASSERT pg_temp.st(hi) = 'firing', 'escalada deveria renotificar mesmo reconhecido';
    RAISE NOTICE 'ok - piorou: reconhecimento desfeito e novo alerta';

    -- silenciar 1h: some; quando expira, volta
    SELECT * INTO r FROM telegram_action('555', 'sil:' || md || ':60', 'Aguinaldo');
    ASSERT r.ok, r.message;
    ASSERT pg_temp.st(md) = '-', 'silenciado';
    UPDATE findings SET silenced_until = now() - interval '1 minute' WHERE id = md;
    ASSERT pg_temp.st(md) = 'reminder', 'silêncio expirado volta a lembrar';
    RAISE NOTICE 'ok - silenciar tem prazo e expira';

    -- resolvido: avisa a recuperação mesmo se reconhecido; ação em resolvido é recusada
    UPDATE findings SET resolved_at = now() WHERE id = c;
    ASSERT pg_temp.st(c) = 'resolved', 'recuperação de evento reconhecido';
    SELECT * INTO r FROM telegram_action('555', 'ack:' || c, 'x');
    ASSERT NOT r.ok AND r.message LIKE '%já resolvido%', r.message;
    RAISE NOTICE 'ok - recuperação sempre avisada';
END $$;

ROLLBACK;
\echo 'todos os testes SQL de notificação passaram'
