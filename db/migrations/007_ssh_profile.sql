-- 007: perfil de SSH por host.
--   modern = chave ed25519 e algoritmos padrão do OpenSSH atual (default)
--   legacy = chave RSA + ssh-rsa (SHA-1) liberado SÓ para este host.
--            Para OpenSSH < 6.5: CentOS 6, Ubuntu 12.04, HP-UX/AIX antigos.
SET ROLE inventory_rw;
ALTER TABLE hosts
    ADD COLUMN ssh_profile text NOT NULL DEFAULT 'modern'
        CHECK (ssh_profile IN ('modern', 'legacy'));
RESET ROLE;
