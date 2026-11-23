#!/usr/bin/env bats
# Deploy window gate (SIG-2764, spec "Guardrails"): Mon-Thu 09:00-16:00 and
# Fri 09:00-12:00 Europe/London, hotfix bypasses. NOW is the injected clock,
# always given in UTC here so the GMT/BST cases are explicit.
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/deploy-window.sh"

# decide <utc-time> [labels-json]: prints the decision.
decide() {
  printf '%s' "${2:-[]}" | NOW="$1" "$SCRIPT" | jq -r .decision
}

@test "Mon 08:59 is closed, Mon 09:00 is open (GMT)" {
  # 2026-11-02 is a Monday, after the clocks went back (UTC = UK time).
  [ "$(decide 2026-11-02T08:59:00Z)" = deferred ]
  [ "$(decide 2026-11-02T09:00:00Z)" = open ]
}

@test "Thu 15:59 is open, Thu 16:00 is closed" {
  [ "$(decide 2026-11-05T15:59:00Z)" = open ]
  [ "$(decide 2026-11-05T16:00:00Z)" = deferred ]
}

@test "Fri 11:59 is open, Fri 12:00 is closed" {
  [ "$(decide 2026-11-06T11:59:00Z)" = open ]
  [ "$(decide 2026-11-06T12:00:00Z)" = deferred ]
}

@test "Tuesday and Wednesday afternoons are open" {
  [ "$(decide 2026-11-03T13:30:00Z)" = open ]
  [ "$(decide 2026-11-04T15:00:00Z)" = open ]
}

@test "the weekend is closed all day" {
  [ "$(decide 2026-11-07T10:00:00Z)" = deferred ]
  [ "$(decide 2026-11-08T14:00:00Z)" = deferred ]
}

@test "BST: 08:00 UTC is 09:00 in London, so open; 07:59 UTC is closed" {
  # 2026-07-06 is a Monday in British Summer Time (UTC+1).
  [ "$(decide 2026-07-06T07:59:00Z)" = deferred ]
  [ "$(decide 2026-07-06T08:00:00Z)" = open ]
  # Thu 16:00 BST is 15:00 UTC.
  [ "$(decide 2026-07-09T14:59:00Z)" = open ]
  [ "$(decide 2026-07-09T15:00:00Z)" = deferred ]
}

@test "the clocks changing: Monday after the spring change opens at 08:00 UTC" {
  # Clocks went forward on Sun 2026-03-29.
  run bash -c "echo '[]' | NOW=2026-03-30T08:00:00Z '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "open" and (.local_time | test("09:00 BST"))' > /dev/null
}

@test "the clocks changing: deferred on Friday evening GMT, next opening is Monday 09:00 BST" {
  run bash -c "echo '[]' | NOW=2026-03-27T18:00:00Z '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "deferred" and .next_open == "Mon 2026-03-30 09:00 BST"' > /dev/null
}

@test "the clocks changing back: Monday after the autumn change opens at 09:00 UTC" {
  # Clocks went back on Sun 2026-10-25.
  [ "$(decide 2026-10-26T08:00:00Z)" = deferred ]
  [ "$(decide 2026-10-26T09:00:00Z)" = open ]
}

@test "deferred reports the next opening: Thu 16:00 -> Fri 09:00, Fri 12:00 -> Mon 09:00" {
  run bash -c "echo '[]' | NOW=2026-11-05T16:00:00Z '$SCRIPT'"
  echo "$output" | jq -e '.next_open == "Fri 2026-11-06 09:00 GMT"' > /dev/null
  run bash -c "echo '[]' | NOW=2026-11-06T12:00:00Z '$SCRIPT'"
  echo "$output" | jq -e '.next_open == "Mon 2026-11-09 09:00 GMT"' > /dev/null
}

@test "hotfix on any ticket bypasses the window" {
  [ "$(decide 2026-11-07T10:00:00Z '[["Bug"],["Bug","hotfix"]]')" = hotfix ]
  [ "$(decide 2026-11-02T08:59:00Z '[["hotfix"]]')" = hotfix ]
}

@test "inside the window a hotfix is simply open" {
  [ "$(decide 2026-11-02T10:00:00Z '[["hotfix"]]')" = open ]
}

@test "no hotfix label: other labels do not bypass" {
  [ "$(decide 2026-11-07T10:00:00Z '[["Bug","Hotfix-ish"],["Feature"]]')" = deferred ]
}

@test "HOTFIX_LABEL renames the bypass label" {
  run bash -c "echo '[[\"urgent\"]]' | HOTFIX_LABEL=urgent NOW=2026-11-07T10:00:00Z '$SCRIPT'"
  echo "$output" | jq -e '.decision == "hotfix"' > /dev/null
}

@test "empty stdin means no tickets" {
  run bash -c "NOW=2026-11-02T10:00:00Z '$SCRIPT' < /dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "open"' > /dev/null
}

@test "NOW as epoch seconds" {
  # 1793966400 = 2026-11-06T12:00:00Z (Fri 12:00 GMT)
  [ "$(decide 1793966400)" = deferred ]
  [ "$(decide 1793966340)" = open ]
}

@test "bad NOW or bad stdin fails" {
  run bash -c "echo '[]' | NOW=tomorrow '$SCRIPT'"
  [ "$status" -ne 0 ]
  run bash -c "echo '{}' | NOW=2026-11-02T10:00:00Z '$SCRIPT'"
  [ "$status" -ne 0 ]
}
