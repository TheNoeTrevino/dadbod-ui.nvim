" Compatibility shims for the original vim-dadbod-ui `db_ui#` autoload API, so
" third-party integrations written against it keep working with this Lua port.
" The implementations live in lua/dadbod-ui; these are thin delegators. The full
" public API surface lands in M11 -- this file currently provides only what
" integrations need today.

" Connection info for a dbui buffer's `b:dbui_db_key_name`. Used by
" vim-dadbod-completion (FileType sql) to resolve the connection and its
" tables/schemas for completion.
function! db_ui#get_conn_info(db_key_name) abort
  return luaeval('require("dadbod-ui").get_conn_info(_A)', a:db_key_name)
endfunction
