# bats helper — bootstraps path + tool checks.
: "${BATS_TEST_DIRNAME:?}"
export PATH="$BATS_TEST_DIRNAME/helpers/stub_bin:$PATH"
