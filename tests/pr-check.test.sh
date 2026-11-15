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
  : > "$work/output"
  (
    cd "$work" || exit 99
    TITLE="$4" BODY="$5" AUTHOR="${8:-someone}" \
    COMMITS_FILE="$work/commits" FILES_FILE="$work/files" \
    PATHS_FILE="${9:-paths}" GITHUB_OUTPUT="$work/output" \
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

# Bots.
run "a bot with no Checks section passes" pass - "build(deps): bump a package" "" "Directory.Packages.props" "" "renovate[bot]"
run "a bot with a bad title fails" fail - "Update dependency x" "" "Directory.Packages.props" "" "renovate[bot]"
run "a bot touching a sensitive path is still labelled" pass true "build(deps): bump a package" "" "tests/Directory.Packages.props" "" "renovate[bot]"

printf '\n%s passed, %s failed\n' "$pass" "$failures"
[ "$failures" = 0 ]
