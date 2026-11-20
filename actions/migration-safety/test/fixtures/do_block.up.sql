DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE column_name = 'legacy') THEN
        ALTER TABLE users DROP COLUMN legacy;
    END IF;
END $$;
