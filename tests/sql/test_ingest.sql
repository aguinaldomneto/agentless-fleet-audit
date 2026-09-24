-- Testes da ingestão e das regras. Rodam numa transação desfeita no final.
--   psql -U inventory_rw -d inventory -v ON_ERROR_STOP=1 -f tests/sql/test_ingest.sql
\set QUIET on
BEGIN;
SET client_min_messages = warning;

INSERT INTO hosts (name, address) VALUES ('t-01', 't-01');
CREATE TEMP TABLE t_host AS SELECT id FROM hosts WHERE name = 't-01';

-- Saída do coletor com datas relativas a "agora"
CREATE FUNCTION pg_temp.raw(p_pct int, p_cert_days int, p_backdoor bool, p_end bool)
RETURNS text LANGUAGE sql AS $$
    SELECT concat_ws(E'\n',
        'META|1|t-01|Linux|Debian GNU/Linux 12 (bookworm)|6.1.0|x86_64|' ||
            to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'UPTIME|821| 04:14:37 up 13 min,  0 users,  load average: 0.00, 0.10, 0.08',
        'LOAD|0.00|0.10|0.08',
        'FS|/|1000000|200000|800000|20',
        'FS|/data|65536|' || (65536 * p_pct / 100) || '|' || (65536 - 65536 * p_pct / 100) || '|' || p_pct,
        'USER|root|0|0|/bin/bash|1',
        CASE WHEN p_backdoor THEN 'USER|backdoor|0|0|/bin/sh|1' END,
        'USER|collector|1000|1000|/bin/sh|1',
        'PKG|dpkg|123',
        'CERT|/opt/app/certs/app.crt|' ||
            to_char((now() + make_interval(days => p_cert_days)) AT TIME ZONE 'UTC',
                    'Mon DD HH24:MI:SS YYYY') || ' GMT|CN=t-01.lab.local',
        'ERR|certs|caminho inexistente: /nao/existe',
        CASE WHEN p_end THEN 'END|ok' END);
$$;

CREATE FUNCTION pg_temp.open_findings() RETURNS text LANGUAGE sql AS $$
    SELECT coalesce(string_agg(rule || ':' || subject || ':' || severity, ', ' ORDER BY rule), '')
      FROM findings WHERE host_id = (SELECT id FROM t_host) AND resolved_at IS NULL;
$$;
CREATE FUNCTION pg_temp.pending() RETURNS text LANGUAGE sql AS $$
    SELECT coalesce(string_agg(rule || ':' || state, ', ' ORDER BY rule), '')
      FROM v_pending_notifications WHERE host = 't-01';
$$;
CREATE FUNCTION pg_temp.ack() RETURNS void LANGUAGE sql AS $$
    SELECT mark_notified(array_agg(id)) FROM v_pending_notifications WHERE host = 't-01';
$$;

DO $$
DECLARE h int := (SELECT id FROM t_host); r record; got text;
BEGIN
    -- 1. Coleta completa com 3 problemas
    SELECT * INTO r FROM ingest_collection(h, pg_temp.raw(90, 20, true, true));
    ASSERT r.run_status = 'ok', 'status deveria ser ok: ' || r.run_status;
    got := pg_temp.open_findings();
    ASSERT got = 'cert_expiry:/opt/app/certs/app.crt:medium, fs_usage:/data:critical, uid0_extra:backdoor:critical', '1: ' || got;
    ASSERT (SELECT pkg_count FROM host_facts WHERE host_id = h) = 123, '1: pkg_count';
    ASSERT (SELECT error FROM collection_runs WHERE id = r.run_id) LIKE '%caminho inexistente%', '1: ERR registrado';
    ASSERT (SELECT days_left FROM v_cert_expiry WHERE host = 't-01') = 20, '1: days_left';
    got := pg_temp.pending();
    ASSERT got = 'cert_expiry:firing, fs_usage:firing, uid0_extra:firing', '1 pending: ' || got;
    PERFORM pg_temp.ack();
    RAISE NOTICE 'ok - coleta completa gera 3 achados e 3 notificações';

    -- 2. Mesma situação de novo: sem duplicar, sem renotificar
    PERFORM ingest_collection(h, pg_temp.raw(90, 20, true, true));
    ASSERT (SELECT count(*) FROM findings WHERE host_id = h) = 3, '2: duplicou achado';
    ASSERT pg_temp.pending() = '', '2: renotificou: ' || pg_temp.pending();
    RAISE NOTICE 'ok - deduplicação (sem alerta repetido)';

    -- 3. Disco normalizou, backdoor removido, cert agora a 5 dias
    PERFORM ingest_collection(h, pg_temp.raw(50, 5, false, true));
    got := pg_temp.open_findings();
    ASSERT got = 'cert_expiry:/opt/app/certs/app.crt:critical', '3: ' || got;
    ASSERT NOT EXISTS (SELECT 1 FROM host_users WHERE host_id = h AND name = 'backdoor'), '3: usuário sumido continua';
    got := pg_temp.pending();
    ASSERT got = 'cert_expiry:firing, fs_usage:resolved, uid0_extra:resolved', '3 pending: ' || got;
    PERFORM pg_temp.ack();
    RAISE NOTICE 'ok - escalada renotifica; resolvidos geram aviso de recuperação';

    -- 4. Saída truncada: não resolve nada nem apaga inventário
    PERFORM ingest_collection(h, pg_temp.raw(50, 5, false, false));
    ASSERT (SELECT status FROM collection_runs WHERE host_id = h ORDER BY id DESC LIMIT 1) = 'partial', '4: status';
    got := pg_temp.open_findings();
    ASSERT got = 'cert_expiry:/opt/app/certs/app.crt:critical, collection_failed:ssh:high', '4: ' || got;
    RAISE NOTICE 'ok - saída truncada vira partial + achado de coleta';

    -- 5. SSH falhou (saída vazia): coleta falhou escala para critical
    PERFORM pg_temp.ack();
    SELECT * INTO r FROM ingest_collection(h, '', 'ssh: connect to host t-01 port 22: Connection refused');
    ASSERT r.run_status = 'failed', '5: status';
    ASSERT pg_temp.pending() = 'collection_failed:firing', '5: escalada não renotificou: ' || pg_temp.pending();
    ASSERT (SELECT count(*) FROM host_users WHERE host_id = h) = 2, '5: falha apagou inventário';
    RAISE NOTICE 'ok - falha de SSH registrada sem apagar inventário';

    -- 6. Volta ao normal: collection_failed resolvido
    PERFORM pg_temp.ack();
    PERFORM ingest_collection(h, pg_temp.raw(50, 5, false, true));
    ASSERT pg_temp.pending() = 'collection_failed:resolved', '6: ' || pg_temp.pending();
    RAISE NOTICE 'ok - coleta recuperada gera aviso de recuperação';

    -- 7. Formato de data do openssl com dia de 1 dígito (dois espaços)
    ASSERT parse_openssl_date('Oct  3 09:05:01 2027 GMT') = '2027-10-03 09:05:01+00', '7: dia 1 dígito';
    ASSERT parse_openssl_date('lixo') IS NULL, '7: data inválida deveria dar NULL';
    RAISE NOTICE 'ok - datas do openssl';
END $$;

ROLLBACK;
\echo 'todos os testes SQL passaram'
