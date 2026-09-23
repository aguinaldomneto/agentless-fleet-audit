-- 002: ingestão da saída do coletor, regras de compliance e fila de notificação.
--
-- A lógica fica no banco de propósito: a ingestão inteira roda em UMA transação.
-- Se qualquer linha quebrar o parse, nada é gravado pela metade.
SET ROLE inventory_rw;

ALTER TABLE findings ADD COLUMN resolve_notified_at timestamptz;

-- Liga cada amostra de disco à coleta que a gerou (auditoria + regra usa a última coleta)
ALTER TABLE fs_usage ADD COLUMN run_id bigint REFERENCES collection_runs(id) ON DELETE CASCADE;
CREATE INDEX fs_usage_run ON fs_usage (run_id);

-- Abre ou atualiza um achado. Escalar warning -> critical zera notified_at
-- para que o alerta seja reenviado com a nova severidade.
CREATE FUNCTION upsert_finding(p_host integer, p_rule text, p_sev text,
                               p_subject text, p_detail text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE findings
       SET last_seen   = now(),
           detail      = p_detail,
           notified_at = CASE WHEN severity <> p_sev AND p_sev = 'critical'
                              THEN NULL ELSE notified_at END,
           severity    = p_sev
     WHERE host_id = p_host AND rule = p_rule AND subject = p_subject
       AND resolved_at IS NULL;
    IF NOT FOUND THEN
        INSERT INTO findings (host_id, rule, severity, subject, detail)
        VALUES (p_host, p_rule, p_sev, p_subject, p_detail);
    END IF;
END $$;

CREATE FUNCTION resolve_finding(p_host integer, p_rule text, p_subject text)
RETURNS void LANGUAGE sql AS $$
    UPDATE findings SET resolved_at = now()
     WHERE host_id = p_host AND rule = p_rule AND subject = p_subject
       AND resolved_at IS NULL;
$$;

-- Regras sobre o estado atual do host. Só resolve achados quando a coleta
-- foi completa (p_full): coleta truncada não prova que o problema sumiu.
CREATE FUNCTION evaluate_rules(p_host integer, p_full boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r      record;
    v_keys text[] := '{}';
BEGIN
    FOR r IN
        -- disco: >= 85% warning, >= 90% critical (última amostra de cada mount)
        SELECT 'fs_usage' AS rule,
               CASE WHEN used_pct >= 90 THEN 'critical' ELSE 'warning' END AS sev,
               mount AS subject,
               format('%s%% usado, %s MB livres', used_pct, avail_kb / 1024) AS detail
          FROM fs_usage
         WHERE host_id = p_host
           AND run_id = (SELECT max(run_id) FROM fs_usage WHERE host_id = p_host)
           AND used_pct >= 85
        UNION ALL
        -- certificado: <= 30 dias warning, <= 7 dias (ou vencido) critical
        SELECT 'cert_expiry',
               CASE WHEN not_after <= now() + interval '7 days' THEN 'critical' ELSE 'warning' END,
               path,
               CASE WHEN not_after <= now()
                    THEN format('VENCIDO em %s (%s)', not_after::date, subject)
                    ELSE format('vence em %s dias, %s (%s)',
                                not_after::date - current_date, not_after::date, subject)
               END
          FROM certificates
         WHERE host_id = p_host AND not_after <= now() + interval '30 days'
        UNION ALL
        -- conta com UID 0 que não é o root
        SELECT 'uid0_extra', 'critical', name,
               format('UID 0 com shell %s', shell)
          FROM host_users
         WHERE host_id = p_host AND uid = 0 AND name <> 'root'
    LOOP
        PERFORM upsert_finding(p_host, r.rule, r.sev, r.subject, r.detail);
        v_keys := v_keys || (r.rule || '|' || r.subject);
    END LOOP;

    IF p_full THEN
        UPDATE findings SET resolved_at = now()
         WHERE host_id = p_host AND resolved_at IS NULL
           AND rule IN ('fs_usage', 'cert_expiry', 'uid0_extra')
           AND NOT (rule || '|' || subject = ANY (v_keys));
    END IF;
END $$;

-- Converte "Sep 28 04:10:31 2026 GMT" (formato do openssl) em timestamptz UTC.
CREATE FUNCTION parse_openssl_date(p text)
RETURNS timestamptz LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN (to_timestamp(regexp_replace(btrim(p), '\s+GMT$', ''),
                         'Mon DD HH24:MI:SS YYYY')::timestamp AT TIME ZONE 'UTC');
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- Ponto de entrada chamado pelo n8n, uma vez por host por execução.
CREATE FUNCTION ingest_collection(p_host_id integer, p_raw text, p_error text DEFAULT NULL)
RETURNS TABLE (run_id bigint, run_status text, open_findings integer)
LANGUAGE plpgsql
SET TimeZone = 'UTC'
AS $$
DECLARE
    v_line  text;
    f       text[];
    -- clock_timestamp: avança dentro da transação (now() não). É o marcador
    -- de "visto nesta coleta" usado para apagar o que sumiu do servidor.
    v_now   timestamptz := clock_timestamp();
    v_at    timestamptz;
    v_full  boolean;
    v_errs  text := '';
    v_nafter timestamptz;
    v_run   bigint;
    v_status text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM hosts WHERE id = p_host_id) THEN
        RAISE EXCEPTION 'host_id % não existe', p_host_id;
    END IF;

    -- Nada voltou: SSH falhou, timeout, gateway fora do ar...
    IF p_raw IS NULL OR btrim(p_raw) = '' THEN
        INSERT INTO collection_runs (host_id, status, error, raw_output)
        VALUES (p_host_id, 'failed', coalesce(nullif(p_error, ''), 'saída vazia'), p_raw)
        RETURNING id INTO v_run;
        PERFORM upsert_finding(p_host_id, 'collection_failed', 'critical', 'ssh',
                               coalesce(nullif(p_error, ''), 'saída vazia'));
        RETURN QUERY SELECT v_run, 'failed'::text,
            (SELECT count(*)::int FROM findings x
              WHERE x.host_id = p_host_id AND x.resolved_at IS NULL);
        RETURN;
    END IF;

    v_full := p_raw ~ '(^|\n)END\|ok\s*$';

    INSERT INTO collection_runs (host_id, status, raw_output)
    VALUES (p_host_id, 'partial', p_raw)
    RETURNING id INTO v_run;

    FOREACH v_line IN ARRAY string_to_array(replace(p_raw, E'\r', ''), E'\n') LOOP
        CONTINUE WHEN v_line = '';
        f := string_to_array(v_line, '|');
        CASE f[1]
        WHEN 'META' THEN
            v_at := coalesce(nullif(f[8], '')::timestamptz, v_now);
            INSERT INTO host_facts (host_id, hostname_reported, os, os_release,
                                    kernel, arch, last_seen)
            VALUES (p_host_id, f[3], f[4], f[5], f[6], f[7], v_now)
            ON CONFLICT (host_id) DO UPDATE
               SET hostname_reported = EXCLUDED.hostname_reported,
                   os = EXCLUDED.os, os_release = EXCLUDED.os_release,
                   kernel = EXCLUDED.kernel, arch = EXCLUDED.arch,
                   last_seen = EXCLUDED.last_seen;
        WHEN 'UPTIME' THEN
            UPDATE host_facts SET uptime_seconds = nullif(f[2], '')::bigint
             WHERE host_id = p_host_id;
        WHEN 'LOAD' THEN
            UPDATE host_facts
               SET load_1m = f[2]::numeric, load_5m = f[3]::numeric, load_15m = f[4]::numeric
             WHERE host_id = p_host_id;
        WHEN 'FS' THEN
            INSERT INTO fs_usage (time, host_id, run_id, mount, size_kb, used_kb, avail_kb, used_pct)
            VALUES (coalesce(v_at, v_now), p_host_id, v_run, f[2],
                    f[3]::bigint, f[4]::bigint, f[5]::bigint, f[6]::numeric);
        WHEN 'USER' THEN
            INSERT INTO host_users (host_id, name, uid, gid, shell, interactive, last_seen)
            VALUES (p_host_id, f[2], f[3]::int, f[4]::int, f[5], f[6] = '1', v_now)
            ON CONFLICT (host_id, name) DO UPDATE
               SET uid = EXCLUDED.uid, gid = EXCLUDED.gid, shell = EXCLUDED.shell,
                   interactive = EXCLUDED.interactive, last_seen = EXCLUDED.last_seen;
        WHEN 'PKG' THEN
            UPDATE host_facts SET pkg_manager = f[2], pkg_count = f[3]::int
             WHERE host_id = p_host_id;
        WHEN 'SWBUNDLE' THEN
            INSERT INTO host_software (host_id, name, revision, last_seen)
            VALUES (p_host_id, f[2], f[3], v_now)
            ON CONFLICT (host_id, name) DO UPDATE
               SET revision = EXCLUDED.revision, last_seen = EXCLUDED.last_seen;
        WHEN 'CERT' THEN
            v_nafter := parse_openssl_date(f[3]);
            IF v_nafter IS NULL THEN
                v_errs := v_errs || format('cert: data ilegível em %s: %s', f[2], f[3]) || E'\n';
            ELSE
                INSERT INTO certificates (host_id, path, subject, not_after, last_seen)
                VALUES (p_host_id, f[2], f[4], v_nafter, v_now)
                ON CONFLICT (host_id, path) DO UPDATE
                   SET subject = EXCLUDED.subject, not_after = EXCLUDED.not_after,
                       last_seen = EXCLUDED.last_seen;
            END IF;
        WHEN 'ERR' THEN
            v_errs := v_errs || f[2] || ': ' || coalesce(f[3], '') || E'\n';
        ELSE
            NULL;  -- END, UPTIME bruto, tipos futuros: ignorados
        END CASE;
    END LOOP;

    -- Só com coleta completa dá para afirmar que algo SUMIU do servidor.
    IF v_full THEN
        DELETE FROM host_users    WHERE host_id = p_host_id AND last_seen < v_now;
        DELETE FROM host_software WHERE host_id = p_host_id AND last_seen < v_now;
        DELETE FROM certificates  WHERE host_id = p_host_id AND last_seen < v_now;
        PERFORM resolve_finding(p_host_id, 'collection_failed', 'ssh');
        v_status := 'ok';
    ELSE
        PERFORM upsert_finding(p_host_id, 'collection_failed', 'warning', 'ssh',
                               'saída truncada (sem END|ok)');
        v_status := 'partial';
    END IF;

    UPDATE collection_runs
       SET collected_at = v_at, status = v_status,
           error = nullif(btrim(concat_ws(E'\n', nullif(p_error, ''), v_errs), E' \n'), '')
     WHERE id = v_run;

    PERFORM evaluate_rules(p_host_id, v_full);

    RETURN QUERY SELECT v_run, v_status,
        (SELECT count(*)::int FROM findings x
          WHERE x.host_id = p_host_id AND x.resolved_at IS NULL);
END $$;

-- Fila de notificação: alertas novos/escalados e recuperações.
-- Recuperação só é avisada se o alerta original chegou a ser avisado.
CREATE VIEW v_pending_notifications AS
SELECT f.id, h.name AS host, f.rule, f.severity, f.subject, f.detail,
       CASE WHEN f.resolved_at IS NULL THEN 'firing' ELSE 'resolved' END AS state,
       f.first_seen, f.resolved_at
  FROM findings f JOIN hosts h ON h.id = f.host_id
 WHERE (f.resolved_at IS NULL AND f.notified_at IS NULL)
    OR (f.resolved_at IS NOT NULL AND f.notified_at IS NOT NULL
        AND f.resolve_notified_at IS NULL);

-- Chamado depois que a mensagem foi enviada com sucesso.
CREATE FUNCTION mark_notified(p_ids bigint[])
RETURNS integer LANGUAGE sql AS $$
    WITH u AS (
        UPDATE findings
           SET notified_at         = CASE WHEN resolved_at IS NULL THEN now() ELSE notified_at END,
               resolve_notified_at = CASE WHEN resolved_at IS NOT NULL THEN now() ELSE resolve_notified_at END
         WHERE id = ANY (p_ids)
        RETURNING 1)
    SELECT count(*)::int FROM u;
$$;

-- Retenção: fs_usage cresce a cada coleta
CREATE FUNCTION purge_old_data(p_keep interval DEFAULT '90 days')
RETURNS void LANGUAGE sql AS $$
    DELETE FROM fs_usage        WHERE time       < now() - p_keep;
    DELETE FROM collection_runs WHERE started_at < now() - p_keep;
$$;

REVOKE EXECUTE ON FUNCTION upsert_finding, resolve_finding, evaluate_rules,
    ingest_collection, mark_notified, purge_old_data FROM PUBLIC;

RESET ROLE;
