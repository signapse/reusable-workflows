-- 006_rate_micros
--
-- Per-unit rates move to integer "micros" (1,000,000 micros = 1 major unit,
-- 10,000 micros = 1 penny/cent). Existing per-unit prices are stored in minor
-- units (pence/cents) and are converted x10,000. Recurring price and min-usage
-- charge are directly-payable amounts and stay minor units (renamed _minor).
-- The discount percentage widens for finer precision, and the dead
-- price_modifier float is dropped.

-- 1. Widen the per-unit price columns to BIGINT BEFORE multiplying so the
--    x10,000 conversion cannot overflow the old INTEGER (int32) range.
ALTER TABLE unit_rates
    ALTER COLUMN price_per_prepaid_unit TYPE BIGINT,
    ALTER COLUMN price_per_payg_unit    TYPE BIGINT,
    ALTER COLUMN price_per_invoice_unit TYPE BIGINT;

-- 2. Convert minor units -> micros (x10,000) with a checksum guard. RAISE
--    EXCEPTION aborts the migration transaction on any row-count or summed-total
--    drift, so a bad conversion rolls back rather than corrupting money.
DO $$
DECLARE
    before_cnt bigint; before_sum bigint;
    after_cnt  bigint; after_sum  bigint;
BEGIN
    SELECT count(*),
           COALESCE(sum(price_per_prepaid_unit
                      + price_per_payg_unit
                      + price_per_invoice_unit), 0)
      INTO before_cnt, before_sum FROM unit_rates;

    UPDATE unit_rates SET
        price_per_prepaid_unit = price_per_prepaid_unit * 10000,
        price_per_payg_unit    = price_per_payg_unit    * 10000,
        price_per_invoice_unit = price_per_invoice_unit * 10000;

    SELECT count(*),
           COALESCE(sum(price_per_prepaid_unit
                      + price_per_payg_unit
                      + price_per_invoice_unit), 0)
      INTO after_cnt, after_sum FROM unit_rates;

    IF after_cnt <> before_cnt THEN
        RAISE EXCEPTION 'unit_rates row count changed: % -> %', before_cnt, after_cnt;
    END IF;
    IF after_sum <> before_sum * 10000 THEN
        RAISE EXCEPTION 'unit_rates checksum mismatch: expected %, got %',
            before_sum * 10000, after_sum;
    END IF;
END $$;

-- 3. Rename the per-unit price columns to the _micros suffix.
ALTER TABLE unit_rates RENAME COLUMN price_per_prepaid_unit TO price_per_prepaid_unit_micros;
ALTER TABLE unit_rates RENAME COLUMN price_per_payg_unit    TO price_per_payg_unit_micros;
ALTER TABLE unit_rates RENAME COLUMN price_per_invoice_unit TO price_per_invoice_unit_micros;

-- 4. Recurring price/min-charge: widen to BIGINT (all money columns are bigint)
--    and rename to _minor. Values are unchanged - they are already minor units.
ALTER TABLE recurring_rates
    ALTER COLUMN price            TYPE BIGINT,
    ALTER COLUMN min_usage_charge TYPE BIGINT;
ALTER TABLE recurring_rates RENAME COLUMN price            TO price_minor;
ALTER TABLE recurring_rates RENAME COLUMN min_usage_charge TO min_usage_charge_minor;

-- 5. Widen the discount percentage for finer precision (NUMERIC(8,5)).
ALTER TABLE discount_bands ALTER COLUMN discount_percent TYPE NUMERIC(8, 5);

-- 6. Drop the dead price_modifier float (never affected any money calculation).
ALTER TABLE usage_events DROP COLUMN price_modifier;
