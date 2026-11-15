# arapsys/.github

Shared GitHub workflows and default community health files for repositories in the `arapsys` organisation.

## What lives here

| File | What it is |
|---|---|
| `.github/workflows/security.yml` | Reusable workflow. Runs gitleaks, Semgrep and Trivy on a pull request. High and critical findings fail. |
| `.github/workflows/pr-check.yml` | Reusable workflow. Checks a pull request's title, Checks list and provenance, and labels changes to security-sensitive paths. |
| `.github/workflows/ci.yml` | This repository's own checks. Runs the test scripts, then runs both reusable workflows from the branch under change. |
| `PULL_REQUEST_TEMPLATE.md` | Default pull request template. |
| `.github/ISSUE_TEMPLATE/` | Default issue forms: a task form and a defect form. |
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
    types: [opened, edited, reopened, synchronize, ready_for_review]

permissions:
  contents: read
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
- it touches a security-sensitive path and the security-sensitive box is unticked.

Security-sensitive paths are listed in `.github/security-sensitive-paths` in the calling repository, in gitignore syntax, and read from the base branch. A pull request that touches one gets the `security-sensitive` label, and loses it on a later push that no longer does. A repository with no list gets no label.

A pull request opened by a bot account skips the Checks and provenance rules, since bots do not fill in the template. The title rule still applies.

### security

It runs four jobs, each its own check: `check` (`mise run check`, off with `mise-check: false`), `gitleaks`, `semgrep` and `trivy`. Its header explains the pins and the workarounds.

## Testing

```bash
bash tests/pr-check.test.sh
bash tests/security.test.sh
```

Both need bash and [yq](https://github.com/mikefarah/yq). They use no network. Each rule is also run against an input that breaks it, so a rule that passes everything fails its test.
