#!/usr/bin/env bash
# security.test.sh: checks two rules on .github/workflows/security.yml (see
# the workflow's header for both). No job but check reads mise-action's
# cache: every job computes the same cache key and only check writes it, so
# a scanner that reads it gets check's tools. Every tool `mise exec` runs is
# installed by `mise install` earlier in the same step: exec's own install
# skips the mise-versions mirror and spends api.github.com's anonymous rate
# limit. Each rule also runs against a fixture that breaks it, so a rule
# that passes everything fails here. Needs bash and yq (mikefarah). No
# network.
#
#   bash tests/security.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; failures=0

# offenders <workflow>: one line per mise-action step outside check whose
# cache is not false; "none" when the workflow has no such step at all, and
# "yq failed" when it cannot be read.
offenders() {
  local steps
  steps="$(yq -r '.jobs | to_entries[] | select(.key != "check") | .key as $job
    | .value.steps[] | select((.uses // "") | test("^jdx/mise-action@"))
    | $job + " " + (.with.cache | tostring)' "$1")" || { echo "yq failed"; return; }
  [ -n "$steps" ] || { echo "none"; return; }
  printf '%s\n' "$steps" | awk '$2 != "false" { print $1 }'
}

# uninstalled <workflow>: one line per `mise exec "<spec>"` with no
# `mise install "<spec>"` before it in the same step, as "<job> <spec>";
# "none" when the workflow runs no `mise exec` at all, and "yq failed" when
# it cannot be read.
uninstalled() {
  local runs job b64 script spec found=0
  runs="$(yq -r '.jobs | to_entries[] | .key as $job | .value.steps[]
    | select(.run) | $job + " " + (.run | @base64)' "$1")" || { echo "yq failed"; return; }
  while read -r job b64; do
    [ -n "$job" ] || continue
    script="$(printf '%s' "$b64" | base64 -d)"
    while read -r spec; do
      [ -n "$spec" ] || continue
      found=1
      printf '%s\n' "$script" | awk -v s="$spec" '
        index($0, "mise install \"" s "\"") { installed = 1 }
        index($0, "mise exec \"" s "\"") { exit !installed }' || echo "$job $spec"
    done <<< "$(printf '%s\n' "$script" | grep -o 'mise exec "[^"]*"' | sed 's/^mise exec "//; s/"$//')"
  done <<< "$runs"
  [ "$found" = 1 ] || echo "none"
}

# run <name> <workflow> <expected offenders> [rule, default offenders]
run() {
  got="$("${4:-offenders}" "$2")"
  if [ "$got" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$1"
  else
    failures=$((failures + 1)); printf 'FAIL  %s\ngot:  %s\nwant: %s\n' "$1" "$got" "$3"
  fi
}

run "security.yml: no scanner reads the mise cache" "$root/.github/workflows/security.yml" ""
run "security.yml: every tool mise exec runs is installed first" "$root/.github/workflows/security.yml" "" uninstalled

cat > "$work/broken.yml" <<'EOF'
jobs:
  check:
    steps: [{uses: jdx/mise-action@x}]
  semgrep:
    steps: [{uses: jdx/mise-action@x, with: {install: false}}]
  trivy:
    steps: [{uses: jdx/mise-action@x, with: {cache: false}}]
EOF
run "fixture: a scanner with the default cache is caught" "$work/broken.yml" "semgrep"

printf 'jobs:\n  check:\n    steps: [{uses: jdx/mise-action@x}]\n' > "$work/empty.yml"
run "fixture: no scanner steps at all is caught" "$work/empty.yml" "none"

# gitleaks is right; trivy installs after the exec; semgrep installs in an
# earlier step, which this rule does not accept.
cat > "$work/exec.yml" <<'EOF'
jobs:
  gitleaks:
    steps:
      - run: |
          mise install "gitleaks@$V"
          mise exec "gitleaks@$V" -- gitleaks git .
  trivy:
    steps:
      - run: |
          mise exec "trivy@$V" -- trivy fs .
          mise install "trivy@$V"
  semgrep:
    steps:
      - run: mise install "pipx:semgrep@$V"
      - run: mise exec "pipx:semgrep@$V" -- semgrep scan
EOF
# shellcheck disable=SC2016 # $V is literal text in the fixture.
run "fixture: an exec with no install before it is caught" "$work/exec.yml" \
  "$(printf '%s\n' 'trivy trivy@$V' 'semgrep pipx:semgrep@$V')" uninstalled

printf 'jobs:\n  trivy:\n    steps: [{run: trivy fs .}]\n' > "$work/noexec.yml"
run "fixture: no mise exec at all is caught" "$work/noexec.yml" "none" uninstalled

# switches <workflow>: one line per rule broken by the scanner switches:
# semgrep and trivy each gated by an input of their own that defaults to
# true, and gitleaks never gated by one. "ok" when all hold.
switches() {
  local out="" job cond def
  for job in semgrep trivy; do
    cond="$(yq -r ".jobs.$job.if // \"\"" "$1")" || { echo "yq failed"; return; }
    def="$(yq -r ".on.workflow_call.inputs.$job.default" "$1")"
    [[ "$cond" == *"inputs.$job"* ]] || out+="$job not gated by inputs.$job"$'\n'
    [ "$def" = true ] || out+="$job input does not default to true"$'\n'
  done
  cond="$(yq -r '.jobs.gitleaks.if // ""' "$1")"
  [[ "$cond" == *"inputs."* ]] && out+="gitleaks gated by an input"$'\n'
  [ -n "$out" ] && printf '%s' "$out" || echo ok
}
run "security.yml: semgrep and trivy have switches, gitleaks has none" "$root/.github/workflows/security.yml" "ok" switches

cat > "$work/switch.yml" <<'EOF'
on:
  workflow_call:
    inputs:
      semgrep: {type: boolean, default: false}
      trivy: {type: boolean, default: true}
jobs:
  gitleaks: {if: inputs.gitleaks}
  semgrep: {if: inputs.semgrep}
  trivy: {}
EOF
run "fixture: broken switches are caught" "$work/switch.yml" \
  "$(printf '%s\n' 'semgrep input does not default to true' 'trivy not gated by inputs.trivy' 'gitleaks gated by an input')" switches

# local_rules <workflow>: one line per rule broken by the repository rules
# in .semgrep/: a step in the semgrep job runs `semgrep --test` on them
# before the step that scans with them, and that scan excludes the root
# .semgrep, whose fixtures match on purpose, with a leading slash, since a
# bare .semgrep also skips a .semgrep folder at any depth. "ok" when all
# hold.
local_rules() {
  local runs b64 script i=0 test_at=-1 scan_at=-1 out=""
  runs="$(yq -r '.jobs.semgrep.steps[] | (.run // "") | @base64' "$1")" || { echo "yq failed"; return; }
  while read -r b64; do
    # Commands only: a comment that mentions semgrep --test is no test.
    script="$(printf '%s' "$b64" | base64 -d | grep -v '^[[:space:]]*#')"
    if [ "$test_at" -lt 0 ] && [[ "$script" == *"-- semgrep --test "*" .semgrep"* ]]; then test_at=$i; fi
    if [[ "$script" == *"--config .semgrep"* ]]; then
      scan_at=$i
      [[ "$script" == *"--exclude=/.semgrep "* ]] || out+="the scan does not exclude /.semgrep"$'\n'
    fi
    i=$((i + 1))
  done <<< "$runs"
  [ "$test_at" -ge 0 ] || out+="no step tests .semgrep"$'\n'
  [ "$scan_at" -ge 0 ] || out+="no step scans with .semgrep"$'\n'
  if [ "$test_at" -ge 0 ] && [ "$scan_at" -ge 0 ] && [ "$test_at" -gt "$scan_at" ]; then
    out+="the test runs after the scan"$'\n'
  fi
  [ -n "$out" ] && printf '%s' "$out" || echo ok
}
run "security.yml: repository rules are tested, then scanned with, excluding their fixtures" \
  "$root/.github/workflows/security.yml" "ok" local_rules

cat > "$work/local.yml" <<'EOF'
jobs:
  semgrep:
    steps:
      - uses: actions/checkout@x
      - run: semgrep scan --config .semgrep --exclude=.semgrep
      - run: mise exec x -- semgrep --test --metrics=off .semgrep
EOF
run "fixture: an untested or unexcluded repository rule scan is caught" "$work/local.yml" \
  "$(printf '%s\n' 'the scan does not exclude /.semgrep' 'the test runs after the scan')" local_rules

printf 'jobs:\n  semgrep:\n    steps: [{run: semgrep scan}]\n' > "$work/nolocal.yml"
run "fixture: no repository rules at all is caught" "$work/nolocal.yml" \
  "$(printf '%s\n' 'no step tests .semgrep' 'no step scans with .semgrep')" local_rules

# fixtures <workflow> <dir>: runs the semgrep job's step that tests the
# repository rules, in <dir>, with a mise that does nothing, so only the
# step's own fixture checks run. Prints its ::error lines and exit code,
# then "ran semgrep --test" if the step called mise exec with
# `-- semgrep --test ... .semgrep`.
fixtures() {
  local step
  step="$(yq -r '.jobs.semgrep.steps[] | select((.run // "") | test("-- semgrep --test")) | .run' "$1")" \
    || { echo "yq failed"; return; }
  mkdir -p "$work/bin"
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$work/mise.log" > "$work/bin/mise"; chmod +x "$work/bin/mise"
  : > "$work/mise.log"
  (cd "$2" && PATH="$work/bin:$PATH" SEMGREP_VERSION=stub bash -c "$step" 2>&1; echo "exit $?") | grep -E '^(::error|exit )'
  if grep -Eq '^exec .* -- semgrep --test .* \.semgrep$' "$work/mise.log"; then echo "ran semgrep --test"; fi
}

rule=$'rules:\n  - id: no-x\n    message: m\n    severity: ERROR\n    languages: [csharp]\n    pattern: X()'
mkrules() {  # mkrules <name> <fixture text, or - for none> [rule text]
  mkdir -p "$work/$1/.semgrep"
  printf '%s\n' "${3:-$rule}" > "$work/$1/.semgrep/no-x.yaml"
  [ "$2" = - ] || printf '%s\n' "$2" > "$work/$1/.semgrep/no-x.cs"
}
marked=$'// ruleid: no-x\nX();\n// ok: no-x\nY();'
mkrules good "$marked"
mkrules nofixture -
mkrules noruleid $'// ok: no-x\nY();'
mkrules nook $'// ruleid: no-x\nX();'
mkrules flow "$marked" 'rules: [{id: no-x, message: m, severity: ERROR, languages: [csharp], pattern: X()}]'
# Three rules: no-y has message: before id:, no-z's id line ends in a
# comment. The fixture marks only no-x, so no-y and no-z are caught.
mkrules several "$marked" $'rules:\n  - id: no-x\n    pattern: X()\n  - message: m\n    id: no-y\n    pattern: Y()\n  - id: no-z # never fires\n    pattern: Z()'
mkrules prefix $'// ruleid: no-x-extra\nX();\n// ok: no-x-extra\nY();'
mkrules noid "$marked" $'rules:\n  - id: no-x\n    pattern: X()\n  - message: m\n    pattern: Y()'
mkrules notyaml "$marked" $'rules: [\n  - id: no-x'
mkdir -p "$work/norules"
fixtures_wf() { fixtures "$root/.github/workflows/security.yml" "$1"; }
err() { printf '::error file=.semgrep/no-x.yaml,title=semgrep::%s\n' "$@"; }
run "security.yml fixtures: a rule with ruleid: and ok: marks passes" "$work/good" "$(printf '%s\n' 'exit 0' 'ran semgrep --test')" fixtures_wf
run "security.yml fixtures: a flow-style rule file with marks passes" "$work/flow" "$(printf '%s\n' 'exit 0' 'ran semgrep --test')" fixtures_wf
run "security.yml fixtures: no .semgrep folder passes" "$work/norules" "exit 0" fixtures_wf
run "security.yml fixtures: a rule with no fixture is caught" "$work/nofixture" \
  "$(err 'This rule has no fixture beside it.'; echo 'exit 1')" fixtures_wf
run "security.yml fixtures: a fixture with no ruleid: line is caught" "$work/noruleid" \
  "$(err "Rule no-x has no 'ruleid: no-x' line in its fixture."; echo 'exit 1')" fixtures_wf
run "security.yml fixtures: a fixture with no ok: line is caught" "$work/nook" \
  "$(err "Rule no-x has no 'ok: no-x' line in its fixture."; echo 'exit 1')" fixtures_wf
run "security.yml fixtures: every rule in a file is checked, whatever its key order" "$work/several" \
  "$(err "Rule no-y has no 'ruleid: no-y' line in its fixture." "Rule no-y has no 'ok: no-y' line in its fixture." \
    "Rule no-z has no 'ruleid: no-z' line in its fixture." "Rule no-z has no 'ok: no-z' line in its fixture."; echo 'exit 1')" fixtures_wf
run "security.yml fixtures: a mark for a longer id does not count" "$work/prefix" \
  "$(err "Rule no-x has no 'ruleid: no-x' line in its fixture." "Rule no-x has no 'ok: no-x' line in its fixture."; echo 'exit 1')" fixtures_wf
run "security.yml fixtures: a rule with no id is caught" "$work/noid" \
  "$(err 'Could not read an id for every rule in this file.'; echo 'exit 1')" fixtures_wf
run "security.yml fixtures: a rule file that is not YAML is caught" "$work/notyaml" \
  "$(err 'Could not read an id for every rule in this file.'; echo 'exit 1')" fixtures_wf

printf '\n%s passed, %s failed\n' "$pass" "$failures"
[ "$failures" = 0 ]
