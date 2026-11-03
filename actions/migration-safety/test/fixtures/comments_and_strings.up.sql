-- ALTER TABLE users DROP COLUMN email;  (commented out)
/* DROP TABLE users;
   /* nested */ RENAME COLUMN a TO b; */
INSERT INTO audit (note) VALUES ('ALTER TABLE users DROP COLUMN email; -- not a comment');
INSERT INTO audit (note) VALUES (E'it\'s fine; DROP TABLE users');
CREATE TABLE "weird" ("drop column" text, "rename" text);
CREATE OR REPLACE FUNCTION cleanup() RETURNS void AS $fn$
BEGIN
    DROP TABLE scratch; -- only runs when someone calls the function
END
$fn$ LANGUAGE plpgsql;
COMMENT ON COLUMN users.email IS 'we will DROP COLUMN this later';
