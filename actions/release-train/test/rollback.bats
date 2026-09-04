#!/usr/bin/env bats
load 'helpers/load'

SCRIPT="$BATS_TEST_DIRNAME/../scripts/rollback.sh"

setup() {
  export TMP="$(mktemp -d)"
  export PATH="$TMP/stub:$PATH"
  mkdir -p "$TMP/stub"

  # Bare "remote" so the script's real `git push` has somewhere to land.
  git init -q --bare "$TMP/origin.git"

  # Fake `aws` — success only for tag 1.2.19, failure for anything else.
  cat > "$TMP/stub/aws" <<'EOS'
#!/usr/bin/env bash
if [[ "$*" == *"1.2.19"* ]]; then
  echo '{"imageIds":[{"imageTag":"1.2.19"}]}'
  exit 0
fi
exit 1
EOS
  chmod +x "$TMP/stub/aws"

  # Fake `gh` — `repo clone` seeds a real local git repo (with the Helm
  # values file rollback.sh expects) wired to the bare "origin" above, so
  # the script's real `git checkout`/`commit`/`push` all work unmodified.
  # `pr create`/`pr merge` are stubbed outputs.
  cat > "$TMP/stub/gh" <<EOS
#!/usr/bin/env bash
case "\$1" in
  repo)
    dest="\$4"
    mkdir -p "\$dest/charts/signstream"
    (
      cd "\$dest"
      git init -q
      git config user.email t@t.t
      git config user.name t
      git remote add origin "$TMP/origin.git"
      printf 'image:\n  tag: "1.2.18"\n' > charts/signstream/values-http.yaml
      git add -A
      git commit -q -m init
    )
    ;;
  pr)
    case "\$2" in
      create) echo "https://github.com/signapse/signapse-core-k8s/pull/999" ;;
      merge)  exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$TMP/stub/gh"

  # Stub detector — real detector needs real refs in a real repo, which we
  # don't have here; a canned "touched" response exercises the warning path
  # without depending on serialization-detector.sh's git plumbing.
  cat > "$TMP/detector.sh" <<'EOS'
#!/usr/bin/env bash
echo '{"touched":true,"files":["internal/core/domain/gloss_message.go"]}'
EOS
  chmod +x "$TMP/detector.sh"
  export SERIALIZATION_SCRIPT="$TMP/detector.sh"
  export SIGNAPSE_CORE_K8S_PAT=xxxxx
  # rollback.sh pushes straight to this URL instead of the real
  # signapse-core-k8s remote — no network, no real PAT needed.
  export ROLLBACK_PUSH_URL_OVERRIDE="$TMP/origin.git"
}

teardown() { rm -rf "$TMP"; }

@test "bad service name → error" {
  run "$SCRIPT" foobar 1.2.19
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "invalid service"
}

@test "unknown tag in ECR → error" {
  run "$SCRIPT" http 9.9.9
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not found"
}

@test "happy path outputs PR URL" {
  run "$SCRIPT" http 1.2.19
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "https://github.com/signapse/signapse-core-k8s/pull/999"
}
