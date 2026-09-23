-- 004: texto dos achados em formato brasileiro (data DD/MM/AAAA no fuso de
-- São Paulo, percentual inteiro). Só muda a apresentação; as regras são as mesmas.
SET ROLE inventory_rw;

CREATE OR REPLACE FUNCTION evaluate_rules(p_host integer, p_full boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r      record;
    v_keys text[] := '{}';
BEGIN
    FOR r IN
        SELECT 'fs_usage' AS rule,
               CASE WHEN used_pct >= 90 THEN 'critical' ELSE 'warning' END AS sev,
               mount AS subject,
               format('%s%% usado, %s MB livres de %s MB',
                      round(used_pct)::int, avail_kb / 1024, size_kb / 1024) AS detail
          FROM fs_usage
         WHERE host_id = p_host
           AND run_id = (SELECT max(run_id) FROM fs_usage WHERE host_id = p_host)
           AND used_pct >= 85
        UNION ALL
        SELECT 'cert_expiry',
               CASE WHEN not_after <= now() + interval '7 days' THEN 'critical' ELSE 'warning' END,
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

RESET ROLE;
