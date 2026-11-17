# arapsys/.github

Default community health files for repositories in the `arapsys` organisation.

The reusable workflows (`pr-check.yml`, `security.yml`) and their tests moved to the private [arapsys/ci](https://github.com/arapsys/ci) (arapsys/redd#193). Call them as `arapsys/ci/.github/workflows/<name>.yml@<full sha>`; its README documents them. Pins to commits in this repository still resolve, but get no fixes.

## What lives here

| File | What it is |
|---|---|
| `PULL_REQUEST_TEMPLATE.md` | Default pull request template. |
| `.github/ISSUE_TEMPLATE/` | Default issue forms: a task form (issue type Task) and a defect form (issue type Bug). |
| `SECURITY.md` | Default security policy: how to report a vulnerability or exposed data. |

## Inheritance

GitHub applies the default community health files in this repository (pull request template, issue forms, `SECURITY.md`) to every repository in the organisation that has no file of its own of that type. This only works because this repository is public, so it stays public. A repository with its own file keeps its own.
