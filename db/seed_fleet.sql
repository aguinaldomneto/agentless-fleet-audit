-- Frota extra do laboratório (make fleet-up). Nomes = serviços do docker-compose.
-- Idempotente: rodar de novo só reabilita.
SET ROLE inventory_rw;
INSERT INTO hosts (name, address, cert_paths) VALUES
    ('web-01', 'web-01', '/opt/app/certs'),
    ('web-02', 'web-02', '/opt/app/certs'),
    ('db-01',  'db-01',  '/opt/app/certs'),
    ('app-01', 'app-01', '/opt/app/certs'),
    ('app-02', 'app-02', '/opt/app/certs'),
    ('bkp-01', 'bkp-01', '/opt/app/certs')
ON CONFLICT (name) DO UPDATE SET enabled = true, address = EXCLUDED.address;
RESET ROLE;
