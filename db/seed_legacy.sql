-- Alvos legados do laboratório (make legacy-up). Idempotente.
SET ROLE inventory_rw;
INSERT INTO hosts (name, address, cert_paths, ssh_profile) VALUES
    ('ubuntu-12', 'ubuntu-12', '/opt/app/certs', 'legacy'),   -- OpenSSH 5.9: sem ed25519
    ('centos-7',  'centos-7',  '/opt/app/certs', 'modern')    -- OpenSSH 7.4: ed25519 ok
ON CONFLICT (name) DO UPDATE SET enabled = true, address = EXCLUDED.address,
                                 ssh_profile = EXCLUDED.ssh_profile;
RESET ROLE;
