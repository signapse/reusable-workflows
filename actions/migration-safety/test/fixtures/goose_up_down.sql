-- +goose Up
-- +goose StatementBegin
CREATE TABLE feature_flags (id bigint PRIMARY KEY, key text);
-- +goose StatementEnd

-- +goose Down
DROP TABLE feature_flags;
