-- Schema do inventário. Objetos pertencem a inventory_rw (usado pelo n8n);
-- grafana_ro só lê.
SET ROLE inventory_rw;

-- Hosts monitorados (a "fonte da verdade" do que coletar)
CREATE TABLE hosts (
    id          serial PRIMARY KEY,
    name        text        NOT NULL UNIQUE,
    address     text        NOT NULL,
    port        integer     NOT NULL DEFAULT 22,
    ssh_user    text        NOT NULL DEFAULT 'collector',
    cert_paths  text        NOT NULL DEFAULT '',      -- separados por espaço
    environment text        NOT NULL DEFAULT 'lab',
    enabled     boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Cada execução do coletor, com a saída bruta para auditoria/reprocessamento
CREATE TABLE collection_runs (
    id           bigserial PRIMARY KEY,
    host_id      integer     NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    started_at   timestamptz NOT NULL DEFAULT now(),
    collected_at timestamptz,
    status       text        NOT NULL CHECK (status IN ('ok', 'partial', 'failed')),
    error        text,
    raw_output   text
);
CREATE INDEX collection_runs_host_time ON collection_runs (host_id, started_at DESC);

-- Estado atual de cada host (1 linha por host, upsert a cada coleta)
CREATE TABLE host_facts (
    host_id           integer PRIMARY KEY REFERENCES hosts(id) ON DELETE CASCADE,
    hostname_reported text,
    os                text,
    os_release        text,
    kernel            text,
    arch              text,
    uptime_seconds    bigint,
    load_1m           numeric(8,2),
    load_5m           numeric(8,2),
    load_15m          numeric(8,2),
    pkg_manager       text,
    pkg_count         integer,
    last_seen         timestamptz NOT NULL
);

-- Série temporal de uso de filesystem
CREATE TABLE fs_usage (
    time     timestamptz  NOT NULL,
    host_id  integer      NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    mount    text         NOT NULL,
    size_kb  bigint       NOT NULL,
    used_kb  bigint       NOT NULL,
    avail_kb bigint       NOT NULL,
    used_pct numeric(5,2) NOT NULL
);
CREATE INDEX fs_usage_host_mount_time ON fs_usage (host_id, mount, time DESC);

CREATE TABLE host_users (
    host_id     integer NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    name        text    NOT NULL,
    uid         integer NOT NULL,
    gid         integer NOT NULL,
    shell       text,
    interactive boolean NOT NULL,
    last_seen   timestamptz NOT NULL,
    PRIMARY KEY (host_id, name)
);

-- Bundles de patch do HP-UX (swlist)
CREATE TABLE host_software (
    host_id   integer NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    name      text    NOT NULL,
    revision  text    NOT NULL,
    last_seen timestamptz NOT NULL,
    PRIMARY KEY (host_id, name)
);

CREATE TABLE certificates (
    host_id   integer     NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    path      text        NOT NULL,
    subject   text,
    not_after timestamptz NOT NULL,
    last_seen timestamptz NOT NULL,
    PRIMARY KEY (host_id, path)
);

-- Achados das regras de compliance. Um achado aberto por (host, regra, objeto):
-- é isso que evita alerta repetido a cada coleta (deduplicação).
CREATE TABLE findings (
    id          bigserial PRIMARY KEY,
    host_id     integer     NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    rule        text        NOT NULL,
    severity    text        NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    subject     text        NOT NULL,
    detail      text,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    notified_at timestamptz,
    resolved_at timestamptz
);
CREATE UNIQUE INDEX findings_one_open ON findings (host_id, rule, subject) WHERE resolved_at IS NULL;

-- Views para o Grafana ------------------------------------------------------

CREATE VIEW v_fs_latest AS
SELECT DISTINCT ON (f.host_id, f.mount)
       h.name AS host, f.mount, f.used_pct, f.size_kb, f.avail_kb, f.time
FROM fs_usage f JOIN hosts h ON h.id = f.host_id
ORDER BY f.host_id, f.mount, f.time DESC;

CREATE VIEW v_cert_expiry AS
SELECT h.name AS host, c.path, c.subject, c.not_after,
       (c.not_after::date - current_date) AS days_left
FROM certificates c JOIN hosts h ON h.id = c.host_id;

CREATE VIEW v_host_status AS
SELECT h.name AS host, h.environment, f.os, f.os_release, f.last_seen,
       (now() - f.last_seen) > interval '2 hours' AS stale,
       (SELECT count(*) FROM findings x
         WHERE x.host_id = h.id AND x.resolved_at IS NULL) AS open_findings
FROM hosts h LEFT JOIN host_facts f ON f.host_id = h.id
WHERE h.enabled;

RESET ROLE;

GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE inventory_rw IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
