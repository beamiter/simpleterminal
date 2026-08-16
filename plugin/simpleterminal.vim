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
# What happens to a workspace's remote terminals when SimpleRemote disconnects:
# 'keep' leaves the shells running and labels them '(detached)', 'kill' stops
# them. Kept, by default -- the ssh/docker session is an independent process
# and may be holding the user's work.
g:simpleterminal_remote_on_disconnect = get(g:, 'simpleterminal_remote_on_disconnect', 'keep')

command! -bang -nargs=* SimpleTerminalNew simpleterminal#New(<q-args>, '<bang>' ==# '!')
command! SimpleTerminalToggle simpleterminal#Toggle()
command! SimpleTerminalShow simpleterminal#Show()
command! SimpleTerminalHide simpleterminal#Hide()
command! SimpleTerminalNext simpleterminal#Cycle(1)
command! SimpleTerminalPrev simpleterminal#Cycle(-1)
command! -nargs=1 -complete=customlist,simpleterminal#Complete SimpleTerminalSelect simpleterminal#Select(<q-args>)
command! SimpleTerminalKill simpleterminal#Kill()
command! -range=0 -nargs=? SimpleTerminalSend simpleterminal#SendRange(<count>, <line1>, <line2>, <q-args>)
command! SimpleTerminalList simpleterminal#List()
command! SimpleTerminalHealth simpleterminal#Health()

nnoremap <silent> <Plug>(simpleterminal-toggle) <ScriptCmd>simpleterminal#Toggle()<CR>
nnoremap <silent> <Plug>(simpleterminal-new) <ScriptCmd>simpleterminal#New('')<CR>
nnoremap <silent> <Plug>(simpleterminal-new-local) <ScriptCmd>simpleterminal#New('', true)<CR>
nnoremap <silent> <Plug>(simpleterminal-next) <ScriptCmd>simpleterminal#Cycle(1)<CR>
nnoremap <silent> <Plug>(simpleterminal-prev) <ScriptCmd>simpleterminal#Cycle(-1)<CR>

# SimpleRemote integration. Registered whether or not SimpleRemote is
# installed: User autocommands nobody fires cost nothing, and the plugin load
# order is not ours to know.
augroup SimpleTerminalRemote
  autocmd!
  autocmd User SimpleRemoteDisconnected simpleterminal#OnRemoteDisconnected()
  autocmd User SimpleRemoteConnected simpleterminal#OnRemoteConnected()
augroup END

highlight default link SimpleTerminalBorder FloatBorder
