# Contributing

First of all, thank you for considering contributing to this project!

## Git Workflow

1. Fork the repository
2. Create your feature/bugfix branch: `git checkout -b feature-123/your-feature`
   a. The 123 numbers should represent the issue you are working on.
3. When committing, use the [conventional commit format](https://www.conventionalcommits.org/en/v1.0.0/).

- You can use the `git log` for examples of previous commit messages.
- Please try to have an understandable and followable commit history, open a new branch (don't PR changes from your main to the repository's main).

4. Open a PR to main

## Config for Local Development

Point to your local clone, this is with lazy.nvim:

```lua
return {
  dir = "~/haunt.nvim",
  ---@class HauntConfig
  opts = {
  ....
}
```

## Module Structure and Their Responsibilities

The UI, and any nice features live in Lua.
`vim-dadbod` stays the engine.

I try to keep the modules small and focused, with a single responsibility.

Please adhere to these separations as much as possible.

`init.lua` - public entry point / `setup()`

`bridge.lua` - the only module allowed to touch `vim-dadbod`, the 'bridge'

`config.lua` - defaults and `g:db_ui_*` -> Lua option resolution.

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

`paginator.lua` - per-adapter LIMIT/OFFSET result pagination.

`bind_params.lua` - bind-parameter detection, quoting and substitution.

`table_helpers.lua` - per-adapter table-helper templates (data).

`schemas/` - per-adapter introspection SQL + parsers: `init.lua` dispatches, `parse.lua` is the shared toolkit, one file per adapter.

`introspect.lua` - connect + schema/table introspection for a connection.

`connections_controller.lua` - interactive connections.json CRUD.

`query.lua` - query buffers: open, set the `b:dbui_*` contract, execute.

`drawer/` - the tree UI: `init.lua` (window + render), `content.lua` (pure `Node[]` builders), `actions.lua` (cursor verbs), `paint.lua` (buffer writes).

`dbout/` - result buffers: `init.lua` (wiring), `winbar.lua`, `pagination.lua`, `cells.lua` (folds + cell/FK nav), `ctx.lua` (shared state).

`export.lua` - native CLI result export orchestration, with `export_formats.lua` (pure formatters), `export_extract.lua` (output parsing) and `export_adapters.lua` (capability matrix).

For the layering rules (why `state` is the sink, how the drawer↔query cycle is
broken) and the annotation conventions (module interface classes, `---@private`,
split-directory idiom), see [`docs/architecture.md`](docs/architecture.md).

## Testing

If you are making significant changes, please consider adding tests.
We use [busted](https://github.com/lunarmodules/busted) for testing.

To run tests locally, you can use:

```bash
make deps   # clone plenary + vim-dadbod into .deps/ (first run only)
make test   # run the spec suite
make fmt    # format with stylua

You must run this script before opening a PR. It will save everyone time
```
