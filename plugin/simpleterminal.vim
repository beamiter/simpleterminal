vim9script

if exists('g:loaded_simpleterminal')
  finish
endif
g:loaded_simpleterminal = 1

if v:version < 901 || !has('terminal') || !has('popupwin')
  echohl WarningMsg
  echomsg '[SimpleTerminal] Vim 9.1 with +terminal and +popupwin is required.'
  echohl None
  finish
endif

g:simpleterminal_width = get(g:, 'simpleterminal_width', 82)
g:simpleterminal_height = get(g:, 'simpleterminal_height', 76)
g:simpleterminal_border = get(g:, 'simpleterminal_border', 1)
g:simpleterminal_prefer_remote = get(g:, 'simpleterminal_prefer_remote', 1)
g:simpleterminal_shell = get(g:, 'simpleterminal_shell', '')

command! -nargs=* SimpleTerminalNew simpleterminal#New(<q-args>)
command! SimpleTerminalToggle simpleterminal#Toggle()
command! SimpleTerminalShow simpleterminal#Show()
command! SimpleTerminalHide simpleterminal#Hide()
command! SimpleTerminalNext simpleterminal#Cycle(1)
command! SimpleTerminalPrev simpleterminal#Cycle(-1)
command! SimpleTerminalKill simpleterminal#Kill()
command! -nargs=1 SimpleTerminalSend simpleterminal#Send(<q-args>)
command! SimpleTerminalList simpleterminal#List()
command! SimpleTerminalHealth simpleterminal#Health()

nnoremap <silent> <Plug>(simpleterminal-toggle) <ScriptCmd>simpleterminal#Toggle()<CR>
nnoremap <silent> <Plug>(simpleterminal-new) <ScriptCmd>simpleterminal#New('')<CR>
nnoremap <silent> <Plug>(simpleterminal-next) <ScriptCmd>simpleterminal#Cycle(1)<CR>
nnoremap <silent> <Plug>(simpleterminal-prev) <ScriptCmd>simpleterminal#Cycle(-1)<CR>

highlight default link SimpleTerminalBorder FloatBorder
