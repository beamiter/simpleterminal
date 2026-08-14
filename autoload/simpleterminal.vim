vim9script

var s_sessions: list<dict<any>> = []
var s_current = -1
var s_popup = 0

def Warn(message: string)
  echohl WarningMsg
  echomsg '[SimpleTerminal] ' .. message
  echohl None
enddef

def ClampPercent(value: any, fallback: number): number
  return type(value) == v:t_number ? min([100, max([20, value])]) : fallback
enddef

def LocalRoot(): string
  if exists('*g:VimrcProjectRoot')
    var root = g:VimrcProjectRoot()
    if isdirectory(root)
      return root
    endif
  endif
  return getcwd()
enddef

def ShellCommand(argument: string): list<string>
  var shell = empty(get(g:, 'simpleterminal_shell', '')) ? &shell : g:simpleterminal_shell
  if empty(argument)
    return [shell]
  endif
  return [shell, &shellcmdflag, argument]
enddef

def ValidSpec(value: any): bool
  return type(value) == v:t_dict
    && type(get(value, 'command', 0)) == v:t_list
    && !empty(value.command)
enddef

def Spec(argument: string): dict<any>
  var provider = get(g:, 'SimpleTerminalSpecProvider', v:null)
  if type(provider) == v:t_func
    var provided = call(provider, [argument])
    if ValidSpec(provided)
      return provided
    endif
  endif
  if get(g:, 'simpleterminal_prefer_remote', 1)
      && exists('*g:SimpleRemoteTerminalSpec')
    var remote = g:SimpleRemoteTerminalSpec(argument)
    if ValidSpec(remote)
      return remote
    endif
  endif
  var root = LocalRoot()
  return {
    command: ShellCommand(argument),
    cwd: root,
    name: 'local:' .. fnamemodify(root, ':t'),
    remote: false,
  }
enddef

def SessionAlive(session: dict<any>): bool
  return bufexists(get(session, 'bufnr', -1))
    && getbufvar(session.bufnr, '&buftype') ==# 'terminal'
enddef

def Prune()
  var current_buf = s_current >= 0 && s_current < len(s_sessions)
    ? get(s_sessions[s_current], 'bufnr', -1) : -1
  s_sessions = filter(s_sessions, (_, session) => SessionAlive(session))
  s_current = -1
  for index in range(len(s_sessions))
    if s_sessions[index].bufnr == current_buf
      s_current = index
      break
    endif
  endfor
  if s_current < 0 && !empty(s_sessions)
    s_current = len(s_sessions) - 1
  endif
enddef

def Current(): dict<any>
  Prune()
  return s_current >= 0 && s_current < len(s_sessions) ? s_sessions[s_current] : {}
enddef

def OnExit(buf: number, _job: any, status: number)
  for session in s_sessions
    if get(session, 'bufnr', -1) == buf
      session.status = status
      session.running = false
      break
    endif
  endfor
enddef

def InstallTerminalMaps(popup: number)
  win_execute(popup, 'tnoremap <buffer> <silent> <F8> <C-\><C-n><Cmd>SimpleTerminalToggle<CR>')
  win_execute(popup, 'tnoremap <buffer> <silent> <F7> <C-\><C-n><Cmd>SimpleTerminalNext<CR>')
  win_execute(popup, 'tnoremap <buffer> <silent> <S-F7> <C-\><C-n><Cmd>SimpleTerminalPrev<CR>')
enddef

def OpenPopup(session: dict<any>)
  if s_popup > 0
    popup_close(s_popup)
    s_popup = 0
  endif
  var width = max([20, float2nr(&columns * ClampPercent(
    get(g:, 'simpleterminal_width', 82), 82) / 100.0)])
  var available_height = max([5, &lines - &cmdheight - 2])
  var height = max([5, float2nr(available_height * ClampPercent(
    get(g:, 'simpleterminal_height', 76), 76) / 100.0)])
  s_popup = popup_create(session.bufnr, {
    pos: 'center',
    minwidth: width,
    maxwidth: width,
    minheight: height,
    maxheight: height,
    border: get(g:, 'simpleterminal_border', 1) ? [1, 1, 1, 1] : [0, 0, 0, 0],
    borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    title: $' {get(session, "name", "terminal")} ',
    mapping: false,
    zindex: 250,
    highlight: 'Normal',
    borderhighlight: ['SimpleTerminalBorder'],
  })
  InstallTerminalMaps(s_popup)
  win_execute(s_popup, 'setlocal nonumber norelativenumber signcolumn=no')
  win_execute(s_popup, 'startinsert')
enddef

export def New(argument: string = '')
  var spec = Spec(argument)
  if !ValidSpec(spec)
    Warn('could not build a terminal command')
    return
  endif
  Hide()
  var options: dict<any> = {
    hidden: 1,
    term_finish: 'noclose',
    term_name: 'SimpleTerminal:' .. get(spec, 'name', 'shell'),
  }
  var cwd = get(spec, 'cwd', '')
  if type(cwd) == v:t_string && isdirectory(cwd)
    options.cwd = cwd
  endif
  var buf = -1
  options.exit_cb = (job, status) => OnExit(buf, job, status)
  buf = term_start(spec.command, options)
  if buf <= 0
    Warn('term_start() failed')
    return
  endif
  add(s_sessions, {
    bufnr: buf,
    name: get(spec, 'name', 'terminal-' .. buf),
    cwd: cwd,
    remote: get(spec, 'remote', false),
    running: true,
    status: v:null,
  })
  s_current = len(s_sessions) - 1
  OpenPopup(s_sessions[s_current])
enddef

export def Hide()
  if s_popup > 0
    popup_close(s_popup)
    s_popup = 0
  endif
enddef

export def Show()
  var session = Current()
  if empty(session)
    New('')
    return
  endif
  OpenPopup(session)
enddef

export def Toggle()
  if s_popup > 0 && index(popup_list(), s_popup) >= 0
    Hide()
  else
    s_popup = 0
    Show()
  endif
enddef

export def Cycle(delta: number)
  Prune()
  if empty(s_sessions)
    New('')
    return
  endif
  Hide()
  s_current = (s_current + delta) % len(s_sessions)
  if s_current < 0
    s_current += len(s_sessions)
  endif
  Show()
enddef

export def Kill()
  var session = Current()
  if empty(session)
    return
  endif
  Hide()
  var job = term_getjob(session.bufnr)
  if type(job) == v:t_job && job_status(job) ==# 'run'
    job_stop(job)
  endif
  execute 'silent! bwipeout! ' .. session.bufnr
  Prune()
enddef

export def Send(text: string)
  var session = Current()
  if empty(session)
    Warn('no terminal session')
    return
  endif
  term_sendkeys(session.bufnr, text .. "\<CR>")
enddef

export def List()
  Prune()
  if empty(s_sessions)
    echomsg '[SimpleTerminal] no sessions'
    return
  endif
  for index in range(len(s_sessions))
    var session = s_sessions[index]
    echomsg printf('%s %d  %s  %s', index == s_current ? '*' : ' ',
      session.bufnr, session.name, get(session, 'running', false) ? 'running' : 'exited')
  endfor
enddef

export def State(): dict<any>
  Prune()
  return {
    sessions: deepcopy(s_sessions),
    current: s_current,
    popup: s_popup,
  }
enddef

export def Health()
  Prune()
  echomsg 'SimpleTerminal health'
  echomsg $'  terminal: {has("terminal") ? "yes" : "no"}'
  echomsg $'  popupwin: {has("popupwin") ? "yes" : "no"}'
  echomsg $'  sessions: {len(s_sessions)}'
  echomsg $'  remote provider: {exists("*g:SimpleRemoteTerminalSpec") ? "available" : "absent"}'
enddef
