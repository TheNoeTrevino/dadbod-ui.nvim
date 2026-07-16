# Conventions

Read `./CONTRIBUTING.md`. It is the canonical copy for the git workflow, commit
content, module responsibilities and testing

The rules that are easiest to get wrong:

- Commits are atomic. One logical change each, split along logical lines -
  never a feature AND a bug fix together. Tests ship in the same commit as the
  production code they cover, so every commit is bisectable under `make test`.
- Never write in `./doc/` - it is generated from the annotated sources.
- `make help` lists every command; `make test` and `make fmt` before a PR.
- hand written documentation is in `./docs/` (with an s at the end)
  - look here for any questions documenation might answer
