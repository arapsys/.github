# arapsys/.github

Shared GitHub workflows and default community health files for repositories in the `arapsys` organisation.

## What lives here

| File | What it is |
|---|---|
| `.github/workflows/security.yml` | Reusable workflow. Runs gitleaks, Semgrep and Trivy on a pull request. High and critical findings fail. |
| `.github/workflows/pr-check.yml` | Reusable workflow. Checks a pull request's title, Checks list and provenance, labels changes to security-sensitive paths, and reports size and a risk tier. |
| `.github/workflows/ci.yml` | This repository's own checks. Runs the test scripts, then runs both reusable workflows from the branch under change. |
| `PULL_REQUEST_TEMPLATE.md` | Default pull request template. |
| `.github/ISSUE_TEMPLATE/` | Default issue forms: a task form (issue type Task) and a defect form (issue type Bug). |
| `SECURITY.md` | Default security policy: how to report a vulnerability or exposed data. |

`security.yml` and its test were copied from [blairforce1/.github](https://github.com/blairforce1/.github) at commit `254bdce`. `pr-check.yml` is written for arapsys, and it deliberately leaves out the PAP process rules in `blairforce1/.github`'s `pr-checks` (`Change:`, `Record:`, `class:*`, `Approved-by:` and risk labels). Repositories that adopt PAP keep calling `blairforce1/.github` for those.

## Inheritance

GitHub applies the default community health files in this repository (pull request template, issue forms, `SECURITY.md`) to every repository in the organisation that has no file of its own of that type. This only works because this repository is public. A repository with its own file keeps its own.

## Using the reusable workflows

Call them from two thin workflows in the repository, each pinned to a full commit SHA, never to a branch. They need different triggers.

```yaml
# .github/workflows/pr.yml
name: pr

on:
  pull_request_target:
    types: [opened, edited, reopened, synchronize, ready_for_review, labeled, unlabeled]

permissions:
  contents: read
  issues: read # pr-check requests it; the workflow can't start without it
  pull-requests: write

jobs:
  pr-check:
    uses: arapsys/.github/.github/workflows/pr-check.yml@<full sha> # main as of <date>
```

```yaml
# .github/workflows/security.yml
name: security

on:
  pull_request:

permissions:
  contents: read
  security-events: write

jobs:
  security:
    uses: arapsys/.github/.github/workflows/security.yml@<full sha> # main as of <date>
    with:
      mise-check: false
```

`pr-check` runs on `pull_request_target`, so a pull request cannot change the check it is judged by. It never checks out or runs the pull request's own code: it reads the title, body, commits and file names through the API as data, and reads its path list from the base branch.

`security` runs on `pull_request`, because it must scan the pull request's code. That event gives it a read-only token and no secrets, so checking that code out is safe. Don't put it on `pull_request_target`. Its checkouts set no `ref`, so there it would scan the base branch, and adding the head's `ref` would run untrusted code with a write token. `arapsys/redd` calls them this way.

### pr-check

It fails a pull request when:

- the title is not a Conventional Commit (`type(scope): description`), or runs over 72 characters;
- a box under `## Checks` is unticked with no reason on the next line;
- the pull request shows generated content (a commit co-authored by `noreply@anthropic.com`, or a "Generated with" line in the body) but the provenance box is unticked;
- it touches a security-sensitive path and the security-sensitive box is unticked;
- a workflow it adds or changes filters a trigger with `paths:` or `paths-ignore:`. A required check whose workflow doesn't run waits forever, so skip jobs inside the workflow instead. The file is fetched at the head commit and parsed with yq as data, never run. A file yq can't parse fails too;
- it changes both a policy path and code. A gate is never changed in the pull request it verifies, so policy goes in a pull request of its own. Policy paths are listed in `.github/policy-paths` in the calling repository, in gitignore syntax, read from the base branch (override with the `policy-paths-file` input). Code is any other changed file under a prefix in the `code-paths` input, `src/` by default. A file counts by its new and its old name. A repository with no policy list gets no rule;
- its title type is `fix` and, under a `tests-paths` prefix (`tests/` by default), it removes more assertion or test-attribute lines than it adds (`Assert.`, `[Test]`, `[Fact]`, `[Theory]`, `[TestMethod]`), or adds more `[Skip(` or `[Ignore(` lines than it removes. A comment line counts on neither side, so commenting out an assertion removes it. A fix never weakens the tests that check it. Lines are counted from the files API's patches, as data. A test file GitHub gives no patch for, such as a binary fixture, gets a warning, not a failure;
- the `workflow-approval-label` input is set, the pull request changes `.github/workflows/` (by a file's new or old name), and no issue it closes or is part of (`Closes #N`, `Fixes #N`, `Resolves #N`, `Part of #N` in the description, outside HTML comments) carries that label. The issues' labels are read through the API. An issue that can't be read counts as unlabelled. Dependency bots in `exempt-authors` skip the rule. Off by default. A label added later doesn't start a new run: edit the description, or re-run the check;
- GitHub listed fewer files than the pull request changes (its `changed_files`). The files API stops at 3000 without an error, so every rule above would see only part of the pull request. Always on;
- the `max-files` input is set and the pull request changes more files than that. With `warn-files` set, a pull request over it, and not over `max-files`, passes with a warning and `risk/high`. Both are off by default.

Security-sensitive paths are listed in `.github/security-sensitive-paths` in the calling repository, in gitignore syntax, and read from the base branch. A pull request that touches one gets the `security-sensitive` label, and loses it on a later push that no longer does. A repository with no list gets no label.

It reports each pull request's size, and never fails because of it. It counts added plus deleted lines from the PR files API, which diffs against the merge base, follows renames and counts binary files as 0. Paths listed in `.github/pr-size-ignore` in the calling repository are skipped. That file uses gitignore syntax and is read from the base branch. The PR gets one label: `size/S` (up to 100 lines), `size/M` (up to 200), `size/L` (up to 400) or `size/XL`. The count goes in the job summary, and `size/L` and `size/XL` add a warning annotation. Bot PRs get a size too. A caller with a local counter, such as arapsys/redd's `scripts/pr-size.sh`, should count the same way. Override the file with the `size-ignore-file` input.

It computes a risk tier and never fails because of it. This is the trial in arapsys/redd's `docs/engineering.md` §7.3. The first rule that applies decides, and the job summary names it:

| Tier | Rule |
|---|---|
| `risk/high` | Touches a security-sensitive path or a `Migrations/` folder, or bumps a major version in `Directory.Packages.props` or the SDK in `global.json`. Versions are read from the files API's patch, as data. |
| `risk/low` | Documentation only (`*.md` or `docs/`), size S or M. Or a `renovate[bot]` update of dependency files only, with no major bump in a readable patch, size S or M. |
| `risk/medium` | Everything else. |

The PR gets one `risk/*` label. To have hand-made label changes put back, add `labeled` and `unlabeled` to the caller's `pull_request_target` types. Label changes made with the workflow's own token don't start new runs, so this can't loop.

It warns, without failing, when the description names no issue. A closing keyword (`Closes #N`, `Fixes owner/repo#N`, `Resolves <issue URL>`) lists the PR under the issue's Development section and closes the issue on merge. `Part of #N` refers to an issue without closing it, and `No issue: <reason>` says why there is none. Examples inside HTML comments don't count. The PR template starts with a `Closes #` line to fill in.

A pull request by a listed dependency bot (the `exempt-authors` input, by default `renovate[bot]` and `dependabot[bot]`) skips the Checks, provenance and issue rules, since it does not fill in the template. The title rule still applies. Every other author is checked in full, including any other bot, such as an agent's GitHub App. Never add an agent's app to `exempt-authors`.

### security

It runs four jobs, each its own check: `check` (`mise run check`, off with `mise-check: false`), `gitleaks`, `semgrep` and `trivy`. `semgrep: false` and `trivy: false` skip a scanner for a pull request with nothing for it to scan, and its check still reports, as skipped, which satisfies a required check. Set these from the caller's own classification of the changed files, never by skipping the whole `security` call: the required `security / …` checks would then be missing, and the pull request would wait forever. `gitleaks` always runs, because secrets can arrive in any file. Its header explains the pins and the workarounds.

A repository adds its own Semgrep rules in a `.semgrep/` folder at its root. Each rule file needs a fixture beside it with the same stem (`no-x.yaml` and `no-x.cs`, or `no-x.test.yaml` for a YAML rule), marked `// ruleid: <id>` above each line the rule must match and `// ok: <id>` above each it must not. The `semgrep` job runs `semgrep --test` on the folder first, and fails on a rule with no fixture, a rule file where `yq` cannot read an id for every rule, a fixture without at least one `ruleid: <id>` and one `ok: <id>` line for each of its rule ids (the id matched exactly, so `no-x-extra` does not count for `no-x`), a missed `ruleid:` or a match on an `ok:`. Then it scans with those rules alongside the community ones, excluding the root `.semgrep/` itself (a `.semgrep` folder deeper down is still scanned). A rule at `ERROR` fails the check, like any other high finding. The rules are read from the pull request's checkout, like `.semgrepignore`, so a pull request can change the rules it is scanned with: treat `.semgrep/` as a security-sensitive path.

## Testing

```bash
bash tests/pr-check.test.sh
bash tests/security.test.sh
```

Both need bash and [yq](https://github.com/mikefarah/yq). They use no network. Each rule is also run against an input that breaks it, so a rule that passes everything fails its test.
