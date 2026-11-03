-- Additive only: new table, new nullable column, new index, NOT NULL with DEFAULT.
CREATE TABLE IF NOT EXISTS add_ons (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE "provider_events"
    ADD COLUMN "product" VARCHAR(100);

ALTER TABLE usage_events
    ADD COLUMN "account_id" VARCHAR(255) NOT NULL DEFAULT '';

ALTER TABLE gloss_signs ALTER COLUMN language_id DROP NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_add_ons_name ON add_ons (name);
