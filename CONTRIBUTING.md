# Contributing

First of all, thank you for considering contributing to this project!

## Before you start

Run `make install-hooks` to install our precommit hooks. This is just `stylua` formatting.

Make sure that the changes you are making correlate to an issue on github. We want to make sure we are on the same page on what will be in the project, and don't want to waste each other's time.

You must run the instructions in [testing](#testing) before opening a PR. Please save my github minutes 🙏

## Common Commands

Please use `make help` to see what commands we have available. Common commands to the workflow are all here, so you don't have to spend time trying to figure out
and remember what commands to run. Please use it, and run format and test before every commit/often.

## Git Workflow

1. Fork the repository
2. Create your feature/bugfix branch _off nightly_: `git switch nightly && git checkout -b feature-123/your-feature`
   a. The 123 numbers should represent the issue you are working on.
3. When committing, use the [conventional commit format](https://www.conventionalcommits.org/en/v1.0.0/).

- You can use the `git log` for examples of previous commit messages.
- Please try to have an understandable and followable commit history, open a new branch (don't PR changes from your main to the repository's main).

4. Open a PR to `nightly` (not `main`!) and reference the issue you are working on
   a. e.g. `Fixes #123`

FYI, docs are auto generated from the codebase. So DONT write in the `./doc/` folder. You will be wasting your time and the PR will be rejected!!!

### Commit Content

The style is a conventional commit. But the content of the commit needs to be atomic, always.

Commits should also be split into logical changes.

For example, a commit should NOT contain a new feature AND a bug fix.

Each commit should be able to be described in one sentence in the description:

> Fix buffer splitting when opening buffers from the same connection by using canonical buffer names

And should also include the motivation behind the commit:

> This was specifically broken on windows

And the title should just introduce the change. This would be a good commit:

```gitcommit
fix(query-buf): splitting when opening query buffers

Fix query buffer splitting when opening buffers from the same connection by using canonical buffer names.

This was specifically broken on windows.
Probably wasn't caught due to most development taking place on linux platforms

Fixes: #123
```

> [!NOTE]
> Parenthesis is the scope

Tests should be in the commit that introduces the production code change. This is so the commit is bisectable, and we can just run `make test` during the bisect as we see fit.

## Module Structure and Their Responsibilities

The UI, and any nice features live in Lua.
`vim-dadbod` stays the engine.

I try to keep the modules small and focused, with a single responsibility.

Please adhere to these separations as much as possible.

`init.lua` - public entry point / `setup()`

`api/` - the stable Lua scripting facade, namespaced by scope (the `vim.lsp.buf` convention): `init.lua` (callable-anywhere verbs, addressed by connection name), `buf.lua` (verbs on the current query buffer), `dbout.lua` (verbs on the current result buffer), `resolve.lua` (shared connection-name resolution).

`bridge.lua` - the only module allowed to touch `vim-dadbod`, the 'bridge'

`constants.lua` - some display variables like notification titles and such. More importantly, this is where things go that shouldn't ever change

`config.lua` - defaults and option resolution.

`state.lua` - the central instance (connections, entries, paths). We treat this the single source of truth for anything stateful

`connections.lua` - connection discovery and the `connections.json` store.

`types.lua` - shared type annotations for nice lsp completions and type safety.

`utils.lua` - small shared helpers.

`notifications.lua` - user facing messages

`hooks.lua` - user-configurable lifecycle hooks.

`mappings.lua` - keybindings + help.

`icons.lua` - effective drawer icon set.

`highlights.lua` - drawer extmark highlighting.

`spinner.lua` - animated spinner timer registry.

`spinners.lua` - spinner frame catalog (data).

`paginator.lua` - LIMIT/OFFSET result pagination (styles from the adapter registry).

`bind_params.lua` - bind-parameter detection, quoting and substitution.

`table_helpers.lua` - table-helper merge + ordering (templates live on the adapter specs).

`adapters/` - the per-database registry, one spec file per adapter (introspection SQL, table helpers, EXPLAIN templates, pagination style, export flags). Adding an adapter is one file here; users can register their own via `api.register_adapter`.

`schemas/` - introspection behavior over the adapter specs: `init.lua` (command building, dispatch), `parse.lua` (the shared parsing toolkit).

`introspect.lua` - connect + schema/table introspection for a connection.

`connections_controller.lua` - interactive connections.json CRUD.

`query.lua` - query buffers: open, set the `b:dbui_*` contract, execute.

`picker/` - the connection picker: `init.lua` routes to the configured/available backend (Snacks, Telescope, fzf-lua, with a `vim.ui.select` fallback), one file per backend, `utils.lua` for the shared items + select action.

`drawer/` - the tree UI: `init.lua` (window + render), `content.lua` (pure `Node[]` builders), `actions.lua` (cursor verbs), `paint.lua` (buffer writes).

`dbout/` - result buffers: `init.lua` (wiring), `winbar.lua`, `pagination.lua`, `cells.lua` (folds + cell/FK nav), `ctx.lua` (shared state).

`export.lua` - native CLI result export orchestration, with `export_formats.lua` (pure formatters), `export_extract.lua` (output parsing) and `export_adapters.lua` (capability access over the adapter specs).

### Requires

Requires go at the top of the file. An inline `require` inside a function means
there is a require cycle or an optional dependency, and gets a comment saying
which (see `picker/utils.lua` for the one real cycle: api -> picker ->
picker.utils -> api).

## Testing

If you are making significant changes, please consider adding tests.

Specs are written busted-style (`describe` / `it` / `assert`), but they run under
[mini.test](https://github.com/echasnovski/mini.test) - there is no busted to
install. `make test` bootstraps everything it needs into `.tests/` on the first
run, so there is no setup step:

```bash
make test   # run the spec suite
make fmt    # format with stylua
```

`make help` lists the rest, including `make test-integration` (which exercises
the export goldens against real databases, and does need `make deps` + docker).
