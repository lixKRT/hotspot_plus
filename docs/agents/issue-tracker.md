# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Target

- Repository: `lixKRT/hotspot_plus`
- Visibility: public
- Default branch: `main`

## Conventions

- Create an issue: `gh issue create --title "..." --body-file <file>`.
- Read an issue: `gh issue view <number> --json number,title,body,labels,comments`.
- Make an issue a sub-issue: `gh issue edit <parent> --add-sub-issue <child>`.
- Add a native blocking edge: `gh issue edit <child> --add-blocked-by <blocker>`.
- Apply the triage label `ready-for-agent` to agent-grabbable tickets.
- Close with a short explanation comment, then `gh issue close <number>`.

Do not file into the upstream repository. Do not close or modify a parent issue.
