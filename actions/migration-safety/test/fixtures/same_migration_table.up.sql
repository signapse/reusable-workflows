-- Changes to a table created in this same migration cannot break older code.
CREATE TABLE staging_rows (id bigint, payload text);
ALTER TABLE staging_rows ADD COLUMN batch int NOT NULL;
ALTER TABLE staging_rows RENAME COLUMN payload TO body;
DROP TABLE staging_rows;
