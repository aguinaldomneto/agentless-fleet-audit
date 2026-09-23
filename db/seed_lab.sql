-- Hosts do laboratório (nomes = serviços do docker-compose)
SET ROLE inventory_rw;
INSERT INTO hosts (name, address, cert_paths) VALUES
    ('debian-01', 'target-debian', '/opt/app/certs'),
    ('rocky-01',  'target-rocky',  '/opt/app/certs'),
    ('alpine-01', 'target-alpine', '/opt/app/certs');
RESET ROLE;
