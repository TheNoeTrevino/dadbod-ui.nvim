" The `db_ui#` autoload entry points that third-party integrations (e.g.
" vim-dadbod-completion) call. The implementations live in lua/dadbod-ui; these
" are thin delegators. The full public API surface lands in M11 -- this file
" currently provides only what integrations need today.

" Connection info for a dbui buffer's `b:dbui_db_key_name`. Used by
" vim-dadbod-completion (FileType sql) to resolve the connection and its
" tables/schemas for completion.
function! db_ui#get_conn_info(db_key_name) abort
  return luaeval('require("dadbod-ui").get_conn_info(_A)', a:db_key_name)
endfunction

" Connection/table info for the current buffer, for embedding in a 'statusline'
" or 'winbar'. Accepts an optional opts dict
" (`{ 'prefix', 'separator', 'show' }`); returns '' for non-dbui buffers.
function! db_ui#statusline(...) abort
  return luaeval('require("dadbod-ui").statusline(_A)', get(a:, 1, {}))
endfunction
