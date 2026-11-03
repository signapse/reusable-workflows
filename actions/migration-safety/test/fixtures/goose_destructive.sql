-- +goose Up
ALTER TABLE feature_flags DROP COLUMN key;

-- +goose Down
ALTER TABLE feature_flags ADD COLUMN key text;
