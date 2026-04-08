# Design Docs: Implementation Tracking

Design docs are only useful if we can answer:

1) What is implemented (and where in the repo)?
2) What is still missing / planned?
3) What evidence exists that it works?

## Repo conventions (canonical)

- The canonical tracker for “what is implemented vs missing” is always a `docs/component-issues/*.md` file.
- Each design doc must include a short **Tracking** section near the top that links to exactly one canonical tracker under `docs/component-issues/*.md`.
  - Do not duplicate checklists/status in the design doc; keep the design as the “why/how”, and the tracker as the “what’s done/what’s next”.
- Every `docs/component-issues/*.md` tracker must include a **Design** link to the relevant `docs/design/*.md` doc(s).

## Recommended template for a design doc tracking block

```md
## Tracking

- Canonical tracker: docs/component-issues/<name>.md
```

Useful entry points:

- `docs/design/architecture-overview.md` for the shortest external technical orientation
- `docs/design/gitops-operating-model.md` for the authoritative repo and workflow model
