# Contributing

drupilot is a Claude Code plugin made of Markdown (commands, skills, agents),
JSON (manifests, configuration, hooks) and a Bash script library. There is no
build step. The repository's `CLAUDE.md` holds the conventions every change
follows; this section explains how the project is checked and how its
decisions are recorded.

- [Checks](checks.md) — the developer gate (`scripts/dev/check.sh`) and what each gate proves.
- [Architecture decision records](adr/index.md) — why things are the way they are.

## The docs site

The site is built with [Zensical](https://zensical.org/) from `docs/` and
`mkdocs.yml`, in Docker, so nothing is installed on the host:

```bash
docker compose up docs                               # http://localhost:8000, live reload
docker compose --profile build run --rm docs-build   # ./site, strict; then: rm -rf site .cache
bash scripts/dev/gen-docs.sh                         # regenerate docs/reference/*
```

The pages under `docs/reference/` that start with a `GENERATED` comment are
written by `scripts/dev/gen-docs.sh` from the scripts, the frontmatter of the
commands, skills and agents, and `config/*.json`: never edit them by hand,
edit the source and re-run it. The `docs` gate fails when they drift. The site
is English only.
