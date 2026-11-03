-- Replace a unique index with an exclusion constraint (billing 025 shape).
DROP INDEX IF EXISTS uq_running_account_add_on;

ALTER TABLE account_add_ons
    ADD CONSTRAINT one_running_add_on_per_status
    EXCLUDE USING gist (account_id WITH =, add_on_id WITH =)
    WHERE (end_date IS NULL);

ALTER TABLE account_subscriptions
    DROP CONSTRAINT uq_one_non_ended_subscription_per_product_tier;
