# Security policy

## Reporting a vulnerability

Email **security@arapsys.com** with the subject `security: <repository>`.

Do not open an issue. Most arapsys repositories are private, and GitHub's private vulnerability reporting is only offered on public repositories, so email is the one route that works for all of them.

Include the repository, the commit or tag, steps to reproduce, and the impact you believe it has.

## Reporting exposed personal or customer data

If you find personal data, or confidential customer material such as a contract, in a repository, an issue, a pull request, a log or a build artefact, email **privacy@arapsys.com** with the subject `privacy: <repository>`.

Say where it is (repository, file, commit, issue or run link). Do not copy the material into the email, an issue or a comment. A link is enough, and every copy is another disclosure.

## What to expect

- Acknowledgement within five working days.
- For a confirmed vulnerability, a fix or a written decision not to fix within 30 days of acknowledgement.
- For exposed data, removal and an assessment of whether anyone must be notified, started as soon as the report is acknowledged.
- Credit in the fix's release note if you want it.

## Scope

Every repository in the arapsys organisation that does not ship its own `SECURITY.md`. A repository's own file takes precedence over this one.

## Supported versions

Only the default branch and the latest tagged release of each repository receive fixes.
