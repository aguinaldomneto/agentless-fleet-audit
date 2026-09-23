-- 003: configurações do ambiente (fora do workflow versionado).
-- O chat_id do Telegram fica no banco, não no JSON do workflow: o repositório
-- é público e o mesmo workflow serve para qualquer ambiente.
SET ROLE inventory_rw;

CREATE TABLE settings (
    key        text PRIMARY KEY,
    value      text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

RESET ROLE;
