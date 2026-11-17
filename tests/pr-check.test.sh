#!/usr/bin/env bash
# pr-check.test.sh: extracts the Check step from .github/workflows/pr-check.yml
# and runs it against sample pull requests. Every rule has a case that
# passes and a case that breaks it, so a rule that passes everything fails
# here. Needs bash, git and yq (mikefarah). No network.
#
#   bash tests/pr-check.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0; failures=0

yq -r '.jobs.check.steps[] | select(.id == "check") | .run' \
  "$root/.github/workflows/pr-check.yml" > "$work/check.sh" || { echo "FAIL  could not extract the check step"; exit 1; }
[ -s "$work/check.sh" ] || { echo "FAIL  the check step is empty"; exit 1; }

printf '%s\n' '# test list' 'src/Gate/' 'tests/' 'docs/controls.md' > "$work/paths"
printf '%s\n' '# policy' 'docs/controls.md' '*masking*.json' > "$work/policy"
printf '%s\n' '# size ignore' 'packages.lock.json' '*.g.cs' 'tests/synthetic/' '**/Migrations/' > "$work/size-ignore"

good_title='docs(engineering): add practices review'
all_ticked='## Summary
Something.

## Checks
- [x] Verification run and output shown above
- [x] Generated content declared: `Co-Authored-By` trailers on the commits
- [x] No real customer, contract or personal data in this diff
- [x] Any security-sensitive path touched is explained above'

# run <name> <want: pass|fail> <want sensitive: true|false|-> <title> <body> <files> [commits] [author] [paths file]
run() {
  local name="$1" want="$2" want_sensitive="$3"
  printf '%s\n' "$6" > "$work/files"
  printf '%s\n' "${7:-}" > "$work/commits"
  # SIZES, SIZE_IGNORE and DEPS are locals of size_case or risk_case when one
  # is the caller,
  # visible here through bash's dynamic scoping; unset otherwise.
  printf '%s' "${SIZES:-}" > "$work/sizes"
  printf '%s' "${DEPS:-}" > "$work/deps"
  printf '%s' "${TESTS_PATCH:-}" > "$work/tests.patch"
  printf '%s' "${ISSUE_LABELS:-}" > "$work/issue-labels"
  printf '%s' "${ADDED:-}" > "$work/added"
  # GitHub's changed_files: by default, as many as sizes lists.
  printf '%s\n' "${CHANGED-$(grep -c . "$work/sizes" || true)}" > "$work/changed-files"
  : > "$work/output"
  : > "$work/summary"
  (
    cd "$work" || exit 99
    TITLE="$4" BODY="$5" AUTHOR="${8:-someone}" \
    COMMITS_FILE="$work/commits" FILES_FILE="$work/files" \
    PATHS_FILE="${9:-paths}" GITHUB_OUTPUT="$work/output" \
    SIZE_FILE="$work/sizes" SIZE_IGNORE_FILE="${SIZE_IGNORE:-size-ignore}" \
    GITHUB_STEP_SUMMARY="$work/summary" DEPS_FILE="$work/deps" \
    WORKFLOWS_DIR="${WORKFLOWS:-$work/no-workflows}" \
    POLICY_PATHS_FILE="${POLICY:-policy}" CODE_PATHS="${CODE:-src/}" \
    TESTS_PATCH_FILE="$work/tests.patch" TESTS_PATHS="tests/" \
    APPROVAL_LABEL="${APPROVAL-}" ISSUE_LABELS_FILE="$work/issue-labels" \
    CHANGED_FILES_FILE="$work/changed-files" WARN_FILES="${WARN-}" MAX_FILES="${MAX-}" \
    FOLLOWUPS_SECTION="${FOLLOWUPS-}" MEMORY_DIR="docs/project/memory.d/" ADDED_FILE="$work/added" \
    LEFTOVERS_SECTION="${LEFTOVERS-}" DRAFT="${DRAFT_STATE-false}" LABELS="${LABELS_JSON-[]}" \
      bash "$work/check.sh"
  ) > "$work/log" 2>&1
  local code=$? got=pass
  [ "$code" = 0 ] || got=fail
  local got_sensitive
  got_sensitive="$(sed -n 's/^sensitive=//p' "$work/output")"
  if [ "$got" = "$want" ] && { [ "$want_sensitive" = - ] || [ "$got_sensitive" = "$want_sensitive" ]; }; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s\ngot:  %s sensitive=%s\nwant: %s sensitive=%s\n' "$name" "$got" "$got_sensitive" "$want" "$want_sensitive"
    sed 's/^/      /' "$work/log"
  fi
}

# Title.
run "a conventional title passes" pass false "$good_title" "$all_ticked" "README.md"
run "a title with no type fails" fail - "add practices review" "$all_ticked" "README.md"
run "a title with an unknown type fails" fail - "feature: add practices review" "$all_ticked" "README.md"
run "a breaking-change title passes" pass - "feat(api)!: drop the old route" "$all_ticked" "README.md"
run "a title over 72 characters fails" fail - "docs: $(printf 'x%.0s' {1..70})" "$all_ticked" "README.md"

# Checks section.
run "a description with no Checks section fails" fail - "$good_title" "## Summary
Something." "README.md"
run "an unticked box with no reason fails" fail - "$good_title" "## Checks
- [ ] Verification run and output shown above
- [x] No real customer, contract or personal data in this diff" "README.md"
run "an unticked last box with no reason fails" fail - "$good_title" "## Checks
- [x] Verification run and output shown above
- [ ] No real customer, contract or personal data in this diff" "README.md"
run "an unticked box with a reason passes" pass - "$good_title" "## Checks
- [ ] Verification run and output shown above
No build exists yet.
- [x] No real customer, contract or personal data in this diff" "README.md"
run "a box after another section is not read as a check" pass - "$good_title" "## Checks
- [x] Verification run and output shown above

## Notes
- [ ] an unrelated list item" "README.md"

# Provenance.
no_provenance='## Checks
- [x] Verification run and output shown above
- [ ] Generated content declared
No reason that helps.'
run "a co-authored commit without the provenance box fails" fail - "$good_title" "$no_provenance" "README.md" \
  "docs: x

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
run "a Generated with line without the provenance box fails" fail - "$good_title" "$no_provenance
Generated with Claude Code" "README.md"
run "no generated content needs no provenance box" pass - "$good_title" "$no_provenance" "README.md" "docs: x"
run "a co-authored commit with the provenance box passes" pass - "$good_title" "$all_ticked" "README.md" \
  "docs: x

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"

# Security-sensitive paths.
unexplained_sensitive='## Checks
- [x] Verification run and output shown above
- [ ] Any security-sensitive path touched is explained above
It is fine, trust me.'
run "a file under a listed directory is sensitive" pass true "$good_title" "$all_ticked" "src/Gate/Scanner.cs"
run "a listed file is sensitive" pass true "$good_title" "$all_ticked" "docs/controls.md"
run "an unlisted file is not sensitive" pass false "$good_title" "$all_ticked" "docs/vault.md"
run "a comment line in the list matches nothing" pass false "$good_title" "$all_ticked" "# test list"
run "a sensitive change without the box fails" fail true "$good_title" "$unexplained_sensitive" "tests/Masking/LeakTests.cs"
run "an unlisted change without the sensitive box passes" pass false "$good_title" "$unexplained_sensitive" "docs/vault.md"
run "no paths file means nothing is sensitive" pass false "$good_title" "$unexplained_sensitive" "src/Gate/Scanner.cs" "" someone missing-paths

# Issue reference: a warning, never a failure.
# issue <name> <want warning: yes|no> <first lines of the body>
issue() {
  run "$1" pass - "$good_title" "$3
$all_ticked" "README.md"
  local got=no
  grep -q '^::warning title=pr-check::No issue referenced' "$work/log" && got=yes
  if [ "$got" = "$2" ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$1 (warning: $2)"
  else
    failures=$((failures + 1)); printf 'FAIL  %s\nwarning got: %s want: %s\n' "$1" "$got" "$2"
  fi
}
issue "Closes #12 needs no warning"                    no  "Closes #12"
issue "fixes: #3 needs no warning"                     no  "This fixes: #3 for now."
issue "Resolved owner/repo#7 needs no warning"         no  "Resolved arapsys/redd#7"
issue "an issue URL needs no warning"                  no  "Closes https://github.com/arapsys/redd/issues/25"
issue "Part of #9 needs no warning"                    no  "Part of #9"
issue "No issue: with a reason needs no warning"       no  "No issue: memory consolidation"
issue "no reference warns"                             yes "Some summary."
issue "the empty template line warns"                  yes "Closes #"
issue "No issue: with no reason warns"                 yes "No issue:"
issue "an example inside a comment warns"              yes "<!-- e.g. Closes #12 -->"
issue "a keyword inside a word warns"                  yes "Encloses #12"
issue "a bare #12 warns"                               yes "See #12"

# Size: reported, never a failure.
# size_case <name> <want label> <want warning: yes|no> <rows> [ignore file] [author]
# Rows are "additions deletions path", one per line, space-separated (no test
# path has a space); they become the API's tab-separated lines. Every case
# also checks the PR still passes, so size never fails the check.
# These cases test the arithmetic and the ignore list on rows as the API
# reports them. Whether GitHub reports a rename or a binary file the way
# scripts/pr-size.sh counts it is checked live on a real PR, not here.
size_case() {
  local SIZES SIZE_IGNORE="${5:-size-ignore}"
  SIZES="$(printf '%s' "$4" | tr ' ' '\t')"
  run "$1" pass - "$good_title" "Closes #1
$all_ticked" "README.md" "" "${6:-someone}"
  local got got_warn=no
  got="$(sed -n 's/^size=//p' "$work/output")"
  grep -q '^::warning title=pr-check::This pull request is size/' "$work/log" && got_warn=yes
  if [ "$got" = "$2" ] && [ "$got_warn" = "$3" ] && grep -q "Size: $2" "$work/summary"; then
    pass=$((pass + 1)); printf 'ok    %s (%s, warning: %s)\n' "$1" "$2" "$3"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s\ngot:  %s warning=%s\nwant: %s warning=%s\n' "$1" "$got" "$got_warn" "$2" "$3"
    sed 's/^/      /' "$work/log"
  fi
}
size_case "no files is size/S"                     size/S  no  ""
size_case "100 lines is still size/S"              size/S  no  "60 40 src/A.cs"
size_case "101 lines is size/M"                    size/M  no  "60 41 src/A.cs"
size_case "200 lines is still size/M"              size/M  no  "150 50 src/A.cs"
size_case "201 lines is size/L and warns"          size/L  yes "150 51 src/A.cs"
size_case "400 lines is still size/L"              size/L  yes "400 0 src/A.cs"
size_case "401 lines is size/XL, warns, passes"    size/XL yes "401 0 src/A.cs"
size_case "a 150-line PR is size/M"               size/M  no  "120 30 src/A.cs"
size_case "a 250-line PR is size/L"               size/L  yes "200 50 src/A.cs"
size_case "lines add up across files"              size/M  no  "60 0 src/A.cs
50 0 src/B.cs"
size_case "a 0/0 row adds nothing"                 size/S  no  "0 0 docs/diagram.png
100 0 src/A.cs"
size_case "a lock file is skipped"                 size/S  no  "900 0 src/App/packages.lock.json
10 0 src/A.cs"
size_case "generated code is skipped"              size/S  no  "500 0 obj/Api.g.cs"
size_case "synthetic fixtures are skipped"         size/S  no  "500 0 tests/synthetic/base.xml"
size_case "a nested Migrations folder is skipped"  size/S  no  "500 0 src/Data/Migrations/0001_Init.cs"
size_case "a look-alike name is counted"           size/L  yes "300 0 tests/synthetic-old/base.xml"
size_case "a bot still gets a size"                size/M  no  "200 0 src/A.cs" "" "renovate[bot]"
size_case "no ignore file counts everything"       size/XL yes "900 0 src/App/packages.lock.json" missing-ignore
if [ -z "${SIZES+set}" ] && [ -z "${SIZE_IGNORE+set}" ]; then
  pass=$((pass + 1)); echo "ok    size_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  size_case leaked SIZES or SIZE_IGNORE into later tests"
fi

# Risk tier: reported, never a failure. The first rule that applies decides.
# risk_case <name> <want tier> <want rule text> <rows> [author] [deps patch]
# Rows are "additions deletions path", as for size_case; their paths are the
# changed files. The deps patch stands in for the files API's patch of
# Directory.Packages.props or global.json.
risk_case() {
  local SIZES DEPS="${6:-}" files
  SIZES="$(printf '%s' "$4" | tr ' ' '\t')"
  files="$(printf '%s\n' "$4" | awk 'NF { print $3 }')"
  run "$1" pass - "$good_title" "Closes #1
$all_ticked" "$files" "" "${5:-someone}"
  local got
  got="$(sed -n 's/^risk=//p' "$work/output")"
  if [ "$got" = "risk/$2" ] && grep -qF "Risk: $2, because the pull request $3" "$work/log" \
     && grep -qF "### Risk: $2" "$work/summary"; then
    pass=$((pass + 1)); printf 'ok    %s (risk/%s)\n' "$1" "$2"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s\ngot:  %s\nwant: risk/%s, rule "%s"\n' "$1" "$got" "$2" "$3"
    sed 's/^/      /' "$work/log"
  fi
}
minor='@@ -1,3 +1,3 @@
-    <PackageVersion Include="TUnit" Version="1.2.3" />
+    <PackageVersion Include="TUnit" Version="1.3.0" />'
major='@@ -1,3 +1,3 @@
-    <PackageVersion Include="TUnit" Version="1.2.3" />
+    <PackageVersion Include="TUnit" Version="2.0.0" />'
sdk='@@ -1,4 +1,4 @@
 {
   "sdk": {
-    "version": "10.0.100",
+    "version": "11.0.100",'
risk_case "a security-sensitive path is high"   high   "touches a security-sensitive path" "10 0 src/Gate/Scanner.cs"
risk_case "a sensitive doc is high, not low"    high   "touches a security-sensitive path" "5 0 docs/controls.md"
risk_case "a migration is high"                 high   "touches a migration: src/Data/Migrations/0002_Add.cs" "10 0 src/Data/Migrations/0002_Add.cs"
risk_case "a look-alike migration name is not"  medium "matches no high or low rule" "10 0 src/Data/MigrationsHelper.cs"
risk_case "a package major bump is high"        high   "major version bump: TUnit 1 to 2" "1 1 Directory.Packages.props" "renovate[bot]" "$major"
risk_case "an SDK major bump is high"           high   "major version bump: dotnet-sdk 10 to 11" "1 1 global.json" "renovate[bot]" "$sdk"
risk_case "docs only, small, is low"            low    "is documentation only, size/S" "20 0 docs/vault.md
5 0 README.md"
risk_case "docs only but size/L is medium"      medium "matches no high or low rule" "500 0 docs/vault.md"
risk_case "docs plus code is medium"            medium "matches no high or low rule" "20 0 docs/vault.md
5 0 src/Api/Upload.cs"
risk_case "a docs look-alike folder is medium"  medium "matches no high or low rule" "5 0 docsite/index.html"
risk_case "a Renovate minor bump is low"        low    "is a Renovate patch or minor update of dependency files, size/S" "1 1 Directory.Packages.props
40 40 src/App/packages.lock.json" "renovate[bot]" "$minor"
risk_case "Renovate with no readable patch is medium" medium "matches no high or low rule" "1 1 Directory.Packages.props" "renovate[bot]" ""
risk_case "Renovate touching code is medium"    medium "matches no high or low rule" "1 1 Directory.Packages.props
3 0 src/A.cs" "renovate[bot]" "$minor"
risk_case "a person's minor bump is medium"     medium "matches no high or low rule" "1 1 Directory.Packages.props" "someone" "$minor"
risk_case "another bot's minor bump is medium"  medium "matches no high or low rule" "1 1 Directory.Packages.props" "dependabot[bot]" "$minor"
risk_case "a code change is medium"             medium "matches no high or low rule" "10 0 src/Api/Upload.cs"
if [ -z "${DEPS+set}" ]; then
  pass=$((pass + 1)); echo "ok    risk_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  risk_case leaked DEPS into later tests"
fi

# Trigger path filters in changed workflows.
# workflow_case <name> <want: pass|fail> <want error text, or -> <file contents>...
# Each contents argument becomes one changed workflow, .github/workflows/w<n>.yml.
workflow_case() {
  local name="$1" want="$2" text="$3" WORKFLOWS="$work/workflows" n=0 files=""
  shift 3
  rm -rf "$WORKFLOWS"; mkdir -p "$WORKFLOWS"; : > "$WORKFLOWS/index.tsv"
  for contents in "$@"; do
    n=$((n + 1))
    printf '%s\n' "$contents" > "$WORKFLOWS/$n.yml"
    printf '%s\t%s\n' "$n" ".github/workflows/w$n.yml" >> "$WORKFLOWS/index.tsv"
    files+=".github/workflows/w$n.yml"$'\n'
  done
  run "$name" "$want" - "$good_title" "Closes #1
$all_ticked" "$files"
  if [ "$text" != - ]; then
    if grep -qF -- "$text" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$name" "$text"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$name" "$text"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
clean='on:
  pull_request:
    types: [opened]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action@v1
        with:
          paths: src/'
workflow_case "a pull_request paths filter fails" fail "w1.yml filters a trigger by path (pull_request.paths)" 'on:
  pull_request:
    paths: [src/**]'
workflow_case "a push paths-ignore filter fails" fail "(push.paths-ignore)" 'on:
  push:
    branches: [main]
    paths-ignore: [docs/**]'
workflow_case "both filters on two events are named" fail "(pull_request.paths, push.paths-ignore)" 'on:
  pull_request: {paths: [a]}
  push: {paths-ignore: [b]}'
workflow_case "a workflow with no filter passes" pass "no workflow filters a trigger by path" "$clean"
workflow_case "paths: in a step input is not a trigger" pass - "$clean"
workflow_case "a one-word trigger passes" pass - 'on: push'
workflow_case "a list of triggers passes" pass - 'on: [push, pull_request]'
workflow_case "an event with no settings passes" pass - 'on:
  workflow_dispatch:
  push:'
workflow_case "a clean file beside a filtered one still fails" fail "w2.yml filters a trigger" "$clean" 'on:
  pull_request:
    paths: [x]'
workflow_case "a file that isn't YAML fails" fail "could not be read as YAML" 'on: [push
  : :'
run "no changed workflow skips the rule" pass - "$good_title" "$all_ticked" "README.md"
if [ -z "${WORKFLOWS+set}" ]; then
  pass=$((pass + 1)); echo "ok    workflow_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  workflow_case leaked WORKFLOWS into later tests"
fi

# Policy and code in separate pull requests.
# policy_case <name> <want: pass|fail> <want log text, or -> <files> [policy file] [code prefixes]
policy_case() {
  local POLICY="${5:-policy}" CODE="${6:-src/}"
  run "$1" "$2" - "$good_title" "Closes #1
$all_ticked" "$4"
  if [ "$3" != - ]; then
    if grep -qF -- "$3" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$1" "$3"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$1" "$3"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
policy_case "policy plus code fails" fail "changes policy (docs/controls.md) and code (src/Gate/Rule.cs)" "docs/controls.md
src/Gate/Rule.cs"
policy_case "a masking file plus code fails" fail "policy (config/masking.rules.json)" "config/masking.rules.json
src/Api/Upload.cs"
policy_case "policy alone passes" pass "policy changes with no code" "docs/controls.md"
policy_case "policy plus tests and docs passes" pass - "docs/controls.md
tests/Gate/RuleTests.cs
docs/engineering.md"
policy_case "code alone passes" pass "no policy path touched" "src/Gate/Rule.cs"
policy_case "a policy file under src/ alone passes" pass "policy changes with no code" "src/Masking/masking.json"
policy_case "a policy file under src/ plus code fails" fail "code (src/Masking/Masker.cs)" "src/Masking/masking.json
src/Masking/Masker.cs"
policy_case "a renamed policy file counts by its old name" fail "policy (docs/controls.md)" "docs/control-list.md
docs/controls.md
src/A.cs"
policy_case "a look-alike of src/ is not code" pass - "docs/controls.md
srcgen/A.cs" policy "src/"
policy_case "every code prefix counts" fail "code (app/A.cs)" "docs/controls.md
app/A.cs" policy "src/ app/"
policy_case "a blank line in the file list is ignored" fail "changes policy (docs/controls.md)" "docs/controls.md

src/A.cs"
policy_case "no changed files passes" pass "no policy path touched" ""
policy_case "no policy file means no rule" pass - "docs/controls.md
src/A.cs" missing-policy
# A git that fails on the policy list: the rule must fail, not pass.
mkdir -p "$work/bad-git"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in *"$POLICY_PATHS_FILE"*check-ignore*) exit 128 ;; esac' \
  'exec "$REAL_GIT" "$@"' > "$work/bad-git/git"
chmod +x "$work/bad-git/git"
REAL_GIT="$(command -v git)" PATH="$work/bad-git:$PATH" \
  policy_case "a git error on the policy list fails" fail "Could not match the changed files against" "docs/controls.md"
if [ -z "${POLICY+set}" ] && [ -z "${CODE+set}" ]; then
  pass=$((pass + 1)); echo "ok    policy_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  policy_case leaked POLICY or CODE into later tests"
fi

# A fix keeps its tests.
# fix_case <name> <want: pass|fail> <want log text, or -> <title> <tests patch>
fix_case() {
  local TESTS_PATCH="$5"
  run "$1" "$2" - "$4" "Closes #1
$all_ticked" "tests/A/ATests.cs"
  if [ "$3" != - ]; then
    if grep -qF -- "$3" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$1" "$3"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$1" "$3"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
removes='=== tests/A/ATests.cs
@@ -10,4 +10,3 @@
     [Test]
     public async Task works()
-        await Assert.That(result).IsEqualTo(3);
+        await Task.CompletedTask;'
fix_case "a fix that removes an assertion fails" fail "This fix removes 1 assertion or test lines under tests/ and adds 0" "fix(gate): stop the crash" "$removes"
fix_case "a fix! title is still a fix" fail "removes 1" "fix!: stop the crash" "$removes"
fix_case "a refactor may remove an assertion" pass - "refactor(gate): tidy" "$removes"
fix_case "a fix that changes an assertion passes" pass "1 assertion or test lines removed, 1 added" "fix(gate): stop the crash" '=== tests/A/ATests.cs
@@ -12 +12 @@
-        await Assert.That(result).IsEqualTo(3);
+        await Assert.That(result).IsEqualTo(4);'
fix_case "commenting out an assertion fails" fail "removes 1" "fix: x" '=== tests/A/ATests.cs
@@ -12 +12 @@
-        await Assert.That(result).IsEqualTo(3);
+        // await Assert.That(result).IsEqualTo(3);'
fix_case "deleting a commented-out assertion passes" pass "0 assertion or test lines removed" "fix: x" '=== tests/A/ATests.cs
@@ -12 +11,0 @@
-        // await Assert.That(result).IsEqualTo(3);'
fix_case "removing a [Test] attribute fails" fail "removes 1" "fix: x" '=== tests/A/ATests.cs
@@ -9,2 +9,1 @@
-    [Test]
     public async Task works()'
fix_case "removing an [Arguments] line is not a test" pass - "fix: x" '=== tests/A/ATests.cs
@@ -9,2 +9,1 @@
-    [Arguments(1)]
     [Test]'
fix_case "a fix that adds a test passes" pass "0 assertion or test lines removed, 2 added" "fix: x" '=== tests/A/ATests.cs
@@ -20,0 +21,4 @@
+    [Test]
+    public async Task new_case()
+        => await Assert.That(1).IsEqualTo(1);'
fix_case "a fix that adds a skip fails" fail "skips 1 more test(s)" "fix: x" '=== tests/A/ATests.cs
@@ -9 +9,2 @@
+    [Skip("flaky")]
     [Test]'
fix_case "a fix that removes a skip passes" pass - "fix: x" '=== tests/A/ATests.cs
@@ -9,2 +9 @@
-    [Skip("flaky")]
     [Test]'
fix_case "lines move between files and still balance" pass "1 assertion or test lines removed, 1 added" "fix: x" '=== tests/A/ATests.cs
@@ -12 +11,0 @@
-        await Assert.That(a).IsTrue();
=== tests/B/BTests.cs
@@ -1,0 +2 @@
+        await Assert.That(a).IsTrue();'
fix_case "a test file with no patch warns" pass "GitHub gave no diff for tests/synthetic/big.docx" "fix: x" '=== no-patch tests/synthetic/big.docx'
fix_case "a fix with no test changes passes" pass - "fix: x" ""
if [ -z "${TESTS_PATCH+set}" ]; then
  pass=$((pass + 1)); echo "ok    fix_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  fix_case leaked TESTS_PATCH into later tests"
fi

# Workflow changes need the approval label on a linked issue.
# approval_case <name> <want> <want log text, or -> <files> <issue labels tsv> [label] [author]
approval_case() {
  local APPROVAL="${6-ci-approved}" ISSUE_LABELS="$5"
  run "$1" "$2" - "$good_title" "Closes #1
$all_ticked" "$4" "" "${7:-someone}"
  if [ "$3" != - ]; then
    if grep -qF -- "$3" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$1" "$3"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$1" "$3"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
approval_case "an approved workflow change passes" pass "workflow change approved by #120" \
  ".github/workflows/pr.yml" $'120\tclaude-ready,ci-approved'
approval_case "an unapproved workflow change fails" fail "no issue it closes or is part of carries 'ci-approved'" \
  ".github/workflows/pr.yml" $'120\tclaude-ready'
approval_case "a workflow change with no linked issue fails" fail "carries 'ci-approved'" ".github/workflows/pr.yml" ""
approval_case "an issue that couldn't be read fails" fail "carries 'ci-approved'" ".github/workflows/pr.yml" $'7\t'
approval_case "one approved issue of two is enough" pass "approved by #9" ".github/workflows/pr.yml" $'8\tbug\n9\tci-approved'
approval_case "a look-alike label doesn't count" fail - ".github/workflows/pr.yml" $'120\tci-approved-later'
approval_case "a workflow renamed away counts by its old name" fail - "ci/old.yml
.github/workflows/old.yml" ""
approval_case "a non-workflow change needs no label" pass - "src/A.cs" ""
approval_case "a file beside the workflows folder needs no label" pass - ".github/zizmor.yml" ""
approval_case "with no label configured the rule is off" pass - ".github/workflows/pr.yml" "" ""
approval_case "a dependency bot is exempt" pass - ".github/workflows/pr.yml" "" ci-approved "renovate[bot]"
if [ -z "${APPROVAL+set}" ] && [ -z "${ISSUE_LABELS+set}" ]; then
  pass=$((pass + 1)); echo "ok    approval_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  approval_case leaked APPROVAL or ISSUE_LABELS into later tests"
fi

# File count: GitHub's changed_files against the listed files, and the limits.
# files_case <name> <want> <want log text, or -> <listed files> <changed_files> [warn] [max]
files_case() {
  local SIZES CHANGED="$5" WARN="${6-20}" MAX="${7-30}" i
  SIZES="$(for ((i = 1; i <= $4; i++)); do printf '1\t0\tsrc/F%d.cs\n' "$i"; done)"
  run "$1" "$2" - "$good_title" "Closes #1
$all_ticked" "$(cut -f3 <<<"$SIZES")"
  if [ "$3" != - ]; then
    if grep -qF -- "$3" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$1" "$3"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$1" "$3"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
files_case "20 files passes quietly" pass "Risk: medium" 20 20
files_case "21 files warns and is risk/high" pass "Risk: high, because the pull request changes 21 files, over 20" 21 21
files_case "21 files says why" pass "over 20. Split it unless it is one mechanical change" 21 21
files_case "30 files still passes" pass "changes 30 files, over 20" 30 30
files_case "31 files fails" fail "changes 31 files, over the limit of 30. Split it into pull requests of 20 files or fewer" 31 31
files_case "a cut-short list fails" fail "GitHub listed 3000 of the 3400 changed files" 3000 3400 "" ""
files_case "a cut-short list fails with no limits set" fail "listed 5 of the 6" 5 6 "" ""
files_case "an unreadable count fails" fail "count of changed files couldn't be read" 3 "" "" ""
files_case "no limits set means no warning" pass "Risk: medium" 50 50 "" ""
if [ -z "${CHANGED+set}" ] && [ -z "${WARN+set}" ] && [ -z "${MAX+set}" ]; then
  pass=$((pass + 1)); echo "ok    files_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  files_case leaked CHANGED, WARN or MAX into later tests"
fi

# Follow-ups and open questions: one section, every item linked.
# fu_case <name> <want> <want log text, or -> <section text, or - for none> [added files] [author]
fu_case() {
  local FOLLOWUPS="Follow-ups and open questions" ADDED="${5:-}" section=""
  [ "$4" = - ] || section="## Follow-ups and open questions
$4
"
  run "$1" "$2" - "$good_title" "Closes #1

$section
$all_ticked" "README.md" "" "${6:-someone}"
  if [ "$3" != - ]; then
    if grep -qF -- "$3" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$1" "$3"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$1" "$3"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
entry="docs/project/memory.d/context/2026-11-17-9-x-scope.md"
fu_case "None passes" pass "no follow-ups or open questions" "None"
fu_case "a bulleted None. passes" pass "no follow-ups or open questions" "- None."
fu_case "a missing section fails" fail "has no '## Follow-ups and open questions' section" -
fu_case "an empty section fails" fail "section is empty" ""
fu_case "an issue link passes" pass "every follow-up and open question is linked" "- Cover unions in OUT-4 #168"
fu_case "a cross-repo link passes" pass "every follow-up and open question is linked" "- Pin bump arapsys/.github#18"
fu_case "an added memory entry passes" pass "every follow-up and open question is linked" \
  "- Is .Length a leak? memory: 2026-11-17-9-x-scope" "$entry"
fu_case "a memory id the PR doesn't add fails" fail "adds no entry with that id" \
  "- Is .Length a leak? memory: 2026-11-17-9-x-other" "$entry"
fu_case "a memory file outside memory.d doesn't count" fail "adds no entry with that id" \
  "- x memory: 2026-11-17-9-x-scope" "docs/elsewhere/2026-11-17-9-x-scope.md"
fu_case "a raise: item passes with a warning" pass "has 1 raise: item(s) with no issue yet" "- Add a .Length sanitizer raise: optional DAT-2 sanitizer"
fu_case "an unlinked bullet fails" fail "links nothing" "- Someone should look at unions"
fu_case "prose instead of bullets fails" fail "isn't a bullet" "We might want to widen OUT-5 later."
fu_case "a #N inside a word doesn't count" fail "links nothing" "- see issue#12x"
fu_case "a hint inside a comment is ignored" fail "section is empty" "<!-- e.g. - thing #12 -->"
fu_case "one bad item among good ones fails" fail "links nothing" "- a #12
- b raise: c
- d"
fu_case "an added entry with no memory: bullet fails" fail "adds the memory entry 2026-11-17-9-x-scope, but" \
  "None" "$entry"
fu_case "an added entry listed beside an issue passes" pass "every follow-up and open question is linked" \
  "- a #12
- b memory: 2026-11-17-9-x-scope" "$entry"
fu_case "each unlisted entry is named" fail "adds the memory entry 2026-11-17-9-x-other" \
  "- b memory: 2026-11-17-9-x-scope" "$entry
docs/project/memory.d/pitfalls/2026-11-17-9-x-other.md"
fu_case "a README added under memory.d is not an entry" pass "no follow-ups or open questions" \
  "None" "docs/project/memory.d/README.md"
fu_case "a file deeper than one folder is not an entry" pass "no follow-ups or open questions" \
  "None" "docs/project/memory.d/context/sub/x.md"
fu_case "a listed id doesn't cover a shorter id inside it" fail "adds the memory entry 2026-11-17-9-x, but" \
  "- b memory: 2026-11-17-9-x-scope" "$entry
docs/project/memory.d/context/2026-11-17-9-x.md"
fu_case "a dependency bot is exempt" pass - - "" "renovate[bot]"
run "with the followups rule off nothing is checked" pass - "$good_title" "Closes #1
$all_ticked" "README.md"
if [ -z "${FOLLOWUPS+set}" ] && [ -z "${ADDED+set}" ]; then
  pass=$((pass + 1)); echo "ok    fu_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  fu_case leaked FOLLOWUPS or ADDED into later tests"
fi

# Review leftovers: filled in once out of draft or labelled reviewed.
# lo_case <name> <want> <want log text, or -> <section text, or - for none> [draft] [labels JSON] [author]
lo_case() {
  local LEFTOVERS="Review leftovers" DRAFT_STATE="${5-false}" LABELS_JSON="${6:-[]}" section=""
  [ "$4" = - ] || section="## Review leftovers
$4
"
  run "$1" "$2" - "$good_title" "Closes #1

$section
$all_ticked" "README.md" "" "${7:-someone}"
  if [ "$3" != - ]; then
    if grep -qF -- "$3" "$work/log"; then
      pass=$((pass + 1)); printf 'ok    %s (names %s)\n' "$1" "$3"
    else
      failures=$((failures + 1)); printf 'FAIL  %s\nwant the log to contain: %s\n' "$1" "$3"
      sed 's/^/      /' "$work/log"
    fi
  fi
}
hint='<!-- "None", or one bullet per review finding left unfixed, each with its reason. -->'
lo_case "None passes" pass "no review leftovers" "None"
lo_case "none in any case passes" pass "no review leftovers" "- NONE."
lo_case "a listed finding passes" pass "review leftovers listed" "- Rename x: out of scope, raised as #12"
lo_case "prose passes" pass "review leftovers listed" "Kept the long name; it matches the API."
lo_case "a missing section fails" fail "has no '## Review leftovers' section (out of draft)" -
lo_case "only the template hint fails" fail "section is empty (out of draft)" "$hint"
lo_case "an empty section fails" fail "section is empty" ""
lo_case "an all-caps placeholder fails" fail "placeholder 'REVIEW_LEFTOVERS'" "REVIEW_LEFTOVERS"
lo_case "a bracketed placeholder fails" fail "placeholder '{{REVIEW_LEFTOVERS}}'" "$hint
{{REVIEW_LEFTOVERS}}"
lo_case "TODO fails" fail "placeholder 'TODO'" "- TODO"
lo_case "tbd: with text fails" fail "placeholder 'tbd: after round 2'" "tbd: after round 2"
lo_case "a placeholder beside a finding fails" fail "placeholder 'REVIEW_LEFTOVERS'" "- Rename x: out of scope
REVIEW_LEFTOVERS"
lo_case "a word that starts with todo is not a placeholder" pass "review leftovers listed" "- Todos page left as is: no owner yet"
lo_case "a capitalised word is not a placeholder" pass "review leftovers listed" "- Deferred"
lo_case "a draft with a placeholder passes with a warning" pass "::warning title=pr-check::The '## Review leftovers' section still holds" \
  "REVIEW_LEFTOVERS" true
lo_case "a draft with no section passes with a warning" pass "::warning title=pr-check::The description has no" - true
lo_case "a reviewed draft with a placeholder fails" fail "(labelled reviewed)" "REVIEW_LEFTOVERS" true '["size/S", "reviewed"]'
lo_case "a reviewed draft with None passes" pass "no review leftovers" "None" true '["reviewed"]'
lo_case "another label doesn't count as reviewed" pass "::warning title=pr-check::The '## Review leftovers' section still holds" "REVIEW_LEFTOVERS" true '["reviewed-later"]'
lo_case "an empty draft state counts as out of draft" fail "(out of draft)" "TODO" ""
lo_case "a dependency bot is exempt" pass - - false '[]' "renovate[bot]"
run "with the leftovers rule off nothing is checked" pass - "$good_title" "Closes #1
$all_ticked" "README.md"
if [ -z "${LEFTOVERS+set}" ] && [ -z "${DRAFT_STATE+set}" ] && [ -z "${LABELS_JSON+set}" ]; then
  pass=$((pass + 1)); echo "ok    lo_case leaves no state behind"
else
  failures=$((failures + 1)); echo "FAIL  lo_case leaked LEFTOVERS, DRAFT_STATE or LABELS_JSON into later tests"
fi

# Bots.
run "a bot with no Checks section passes" pass - "build(deps): bump a package" "" "Directory.Packages.props" "" "renovate[bot]"
run "a bot with a bad title fails" fail - "Update dependency x" "" "Directory.Packages.props" "" "renovate[bot]"
run "an agent app without a Checks section fails" fail - "$good_title" "" "README.md" "" "arapsys-redd-agent[bot]"
run "an agent app with the template passes" pass - "$good_title" "Closes #1
$all_ticked" "README.md" "" "arapsys-redd-agent[bot]"
run "an agent app's generated commit needs the provenance box" fail - "$good_title" "Closes #1
$no_provenance" "README.md" "docs: x

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" "arapsys-redd-agent[bot]"
run "Dependabot is exempt by default" pass - "build(deps): bump a package" "" "Directory.Packages.props" "" "dependabot[bot]"
run "a bot touching a sensitive path is still labelled" pass true "build(deps): bump a package" "" "tests/Directory.Packages.props" "" "renovate[bot]"

printf '\n%s passed, %s failed\n' "$pass" "$failures"
[ "$failures" = 0 ]
