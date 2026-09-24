-- 006: três níveis de severidade, lembretes recorrentes e ações pelo Telegram.
--
--   critical (CRÍTICA) -> lembrete a cada  60 min enquanto aberto
--   high     (ALTA)    -> lembrete a cada 180 min
--   medium   (MÉDIA)   -> lembrete a cada 480 min
--
-- Intervalos configuráveis em settings (remind_minutes_critical/high/medium).
-- Lembrete para quando o evento é reconhecido (ack) ou silenciado; volta se a
-- severidade subir, porque aí é um problema maior do que o que foi reconhecido.
SET ROLE inventory_rw;

-- Severidades: warning -> high, info -> medium
ALTER TABLE findings DROP CONSTRAINT findings_severity_check;
UPDATE findings SET severity = CASE severity WHEN 'warning' THEN 'high' WHEN 'info' THEN 'medium' ELSE severity END;
ALTER TABLE findings ADD CONSTRAINT findings_severity_check
    CHECK (severity IN ('critical', 'high', 'medium'));

ALTER TABLE findings
    ADD COLUMN last_notified_at timestamptz,
    ADD COLUMN reminder_count   integer NOT NULL DEFAULT 0,
    ADD COLUMN acked_at         timestamptz,
    ADD COLUMN acked_by         text,
    ADD COLUMN silenced_until   timestamptz;
UPDATE findings SET last_notified_at = notified_at WHERE notified_at IS NOT NULL;

CREATE FUNCTION sev_rank(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p WHEN 'critical' THEN 3 WHEN 'high' THEN 2 WHEN 'medium' THEN 1 ELSE 0 END;
$$;

-- Escalada (severidade sobe): renotifica e desfaz reconhecimento/silêncio.
CREATE OR REPLACE FUNCTION upsert_finding(p_host integer, p_rule text, p_sev text,
                                          p_subject text, p_detail text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- compatibilidade com chamadas antigas
    p_sev := CASE p_sev WHEN 'warning' THEN 'high' WHEN 'info' THEN 'medium' ELSE p_sev END;

    UPDATE findings
       SET last_seen      = now(),
           detail         = p_detail,
           notified_at    = CASE WHEN sev_rank(p_sev) > sev_rank(severity) THEN NULL ELSE notified_at END,
           acked_at       = CASE WHEN sev_rank(p_sev) > sev_rank(severity) THEN NULL ELSE acked_at END,
           acked_by       = CASE WHEN sev_rank(p_sev) > sev_rank(severity) THEN NULL ELSE acked_by END,
           silenced_until = CASE WHEN sev_rank(p_sev) > sev_rank(severity) THEN NULL ELSE silenced_until END,
           severity       = p_sev
     WHERE host_id = p_host AND rule = p_rule AND subject = p_subject
       AND resolved_at IS NULL;
    IF NOT FOUND THEN
        INSERT INTO findings (host_id, rule, severity, subject, detail)
        VALUES (p_host, p_rule, p_sev, p_subject, p_detail);
    END IF;
END $$;

-- Regras com três níveis
CREATE OR REPLACE FUNCTION evaluate_rules(p_host integer, p_full boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r      record;
    v_keys text[] := '{}';
BEGIN
    FOR r IN
        -- disco: >= 90% crítica, >= 85% alta
        SELECT 'fs_usage' AS rule,
               CASE WHEN used_pct >= 90 THEN 'critical' ELSE 'high' END AS sev,
               mount AS subject,
               format('%s%% usado, %s MB livres de %s MB',
                      round(used_pct)::int, avail_kb / 1024, size_kb / 1024) AS detail
          FROM fs_usage
         WHERE host_id = p_host
           AND run_id = (SELECT max(run_id) FROM fs_usage WHERE host_id = p_host)
           AND used_pct >= 85
        UNION ALL
        -- certificado: <= 7 dias (ou vencido) crítica, <= 15 alta, <= 30 média
        SELECT 'cert_expiry',
               CASE WHEN not_after <= now() + interval '7 days'  THEN 'critical'
                    WHEN not_after <= now() + interval '15 days' THEN 'high'
                    ELSE 'medium' END,
               path,
               CASE WHEN not_after <= now()
                    THEN format('VENCIDO em %s (%s)',
                                to_char(not_after AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'), subject)
                    ELSE format('vence em %s dia(s), em %s (%s)',
                                (not_after AT TIME ZONE 'America/Sao_Paulo')::date
                                    - (now() AT TIME ZONE 'America/Sao_Paulo')::date,
                                to_char(not_after AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
                                subject)
               END
          FROM certificates
         WHERE host_id = p_host AND not_after <= now() + interval '30 days'
        UNION ALL
        SELECT 'uid0_extra', 'critical', name, format('UID 0 com shell %s', shell)
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

-- Fila de notificação: novo/escalado (firing), lembrete (reminder) e recuperação.
-- Colunas novas só no final (exigência do CREATE OR REPLACE VIEW).
CREATE OR REPLACE VIEW v_pending_notifications AS
WITH cfg AS (
    SELECT coalesce(max(value) FILTER (WHERE key = 'remind_minutes_critical')::int, 60)  AS c,
           coalesce(max(value) FILTER (WHERE key = 'remind_minutes_high')::int,     180) AS h,
           coalesce(max(value) FILTER (WHERE key = 'remind_minutes_medium')::int,   480) AS m
      FROM settings
)
SELECT f.id, h.name AS host, f.rule, f.severity, f.subject, f.detail,
       CASE WHEN f.resolved_at IS NOT NULL THEN 'resolved'
            WHEN f.notified_at IS NULL     THEN 'firing'
            ELSE 'reminder' END AS state,
       f.first_seen, f.resolved_at,
       f.reminder_count + 1 AS reminder_number,
       f.acked_by
  FROM findings f
  JOIN hosts h ON h.id = f.host_id
 CROSS JOIN cfg
 WHERE (f.resolved_at IS NULL AND f.notified_at IS NULL)
    OR (f.resolved_at IS NOT NULL AND f.notified_at IS NOT NULL AND f.resolve_notified_at IS NULL)
    OR (f.resolved_at IS NULL AND f.notified_at IS NOT NULL
        AND f.acked_at IS NULL
        AND (f.silenced_until IS NULL OR f.silenced_until <= now())
        AND now() - coalesce(f.last_notified_at, f.notified_at)
            >= make_interval(mins => CASE f.severity WHEN 'critical' THEN cfg.c
                                                     WHEN 'high'     THEN cfg.h
                                                     ELSE cfg.m END));

CREATE OR REPLACE FUNCTION mark_notified(p_ids bigint[])
RETURNS integer LANGUAGE sql AS $$
    WITH u AS (
        UPDATE findings
           SET notified_at         = CASE WHEN resolved_at IS NULL AND notified_at IS NULL THEN now() ELSE notified_at END,
               reminder_count      = CASE WHEN resolved_at IS NULL AND notified_at IS NOT NULL THEN reminder_count + 1 ELSE reminder_count END,
               last_notified_at    = CASE WHEN resolved_at IS NULL THEN now() ELSE last_notified_at END,
               resolve_notified_at = CASE WHEN resolved_at IS NOT NULL THEN now() ELSE resolve_notified_at END
         WHERE id = ANY (p_ids)
        RETURNING 1)
    SELECT count(*)::int FROM u;
$$;

-- Ação vinda de um botão do Telegram.
--   p_data: 'ack:<id>'  ou  'sil:<id>:<minutos>'
-- Só aceita o chat configurado em settings (telegram_chat_id).
CREATE FUNCTION telegram_action(p_chat text, p_data text, p_by text)
RETURNS TABLE (ok boolean, message text, finding_id bigint)
LANGUAGE plpgsql AS $$
DECLARE
    m      text[];
    v_id   bigint;
    v_min  int;
    v_host text;
BEGIN
    IF p_chat IS DISTINCT FROM (SELECT value FROM settings WHERE key = 'telegram_chat_id') THEN
        RETURN QUERY SELECT false, 'chat não autorizado'::text, NULL::bigint; RETURN;
    END IF;
    m := regexp_match(coalesce(p_data, ''), '^(ack|sil):([0-9]{1,12})(?::([0-9]{1,4}))?$');
    IF m IS NULL THEN
        RETURN QUERY SELECT false, 'ação inválida'::text, NULL::bigint; RETURN;
    END IF;
    v_id := m[2]::bigint;
    SELECT h.name INTO v_host FROM findings f JOIN hosts h ON h.id = f.host_id
     WHERE f.id = v_id AND f.resolved_at IS NULL;
    IF v_host IS NULL THEN
        RETURN QUERY SELECT false, format('Evento #%s já resolvido ou inexistente', v_id), v_id; RETURN;
    END IF;

    IF m[1] = 'ack' THEN
        UPDATE findings SET acked_at = now(), acked_by = left(coalesce(p_by, '?'), 100) WHERE id = v_id;
        RETURN QUERY SELECT true,
            format('✅ Evento #%s (%s) reconhecido por %s. Lembretes pausados até resolver ou piorar.',
                   v_id, v_host, coalesce(p_by, '?')), v_id;
    ELSE
        v_min := least(greatest(coalesce(m[3]::int, 240), 15), 1440);
        UPDATE findings SET silenced_until = now() + make_interval(mins => v_min) WHERE id = v_id;
        RETURN QUERY SELECT true,
            format('🔕 Evento #%s (%s) silenciado por %s por %s h.',
                   v_id, v_host, coalesce(p_by, '?'), round(v_min / 60.0, 1)), v_id;
    END IF;
END $$;

REVOKE EXECUTE ON FUNCTION telegram_action FROM PUBLIC;

RESET ROLE;
