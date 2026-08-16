vim9script

var s_sessions: list<dict<any>> = []
var s_current = -1
var s_popup = 0
# Buffers of shells that have exited, still waiting to be wiped. See Reap().
var s_orphans: list<number> = []

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

def PopupAlive(): bool
  # s_popup can outlive the popup it names: popup_close() elsewhere, or a
  # :popupclear, leaves the id behind as a stale number. popup_close() happens
  # to tolerate a stale id, but code that has to decide *whether* a popup is on
  # screen cannot -- Toggle() would flip the wrong way and Prune() would refuse
  # to wipe a buffer nothing is showing. One place to ask, so all three agree.
  return s_popup > 0 && index(popup_list(), s_popup) >= 0
enddef

def Displayed(bufnr: number): bool
  # :bwipeout on a buffer that is on screen in a popup fails with E994, so
  # anything that reclaims a buffer has to look first. win_findbuf() does not
  # report popup windows, so our own popup has to be checked separately -- and
  # only when it is really open, because winbufnr(0) means the current window.
  return !empty(win_findbuf(bufnr))
    || (PopupAlive() && winbufnr(s_popup) == bufnr)
enddef

def SessionAlive(session: dict<any>): bool
  var bufnr = get(session, 'bufnr', -1)
  if !bufexists(bufnr) || getbufvar(bufnr, '&buftype') !=# 'terminal'
    return false
  endif
  # The job is authoritative, not session.running. term_start() is deliberately
  # given no term_finish, so an exited shell's buffer keeps buftype=terminal
  # forever -- bufexists() alone called every dead shell alive and Cycle() then
  # walked the user through them. session.running cannot stand in for the job
  # either: exit_cb only runs once Vim is back in its main loop, and a whole
  # Cycle() -> Prune() -> Show() chain runs without ever getting there. Measured
  # here: a shell dead for a full second still had session.running == true,
  # while job_status() said 'dead' immediately -- and asking is what reaps the
  # job and lets exit_cb fire at all. That stale window is exactly when the user
  # types `exit` and reaches straight for <F7>.
  var job = term_getjob(bufnr)
  if type(job) != v:t_job
    # No job to ask. Trust the bookkeeping rather than declare a session dead on
    # a guess -- Prune() wipes what it drops, and a wrong guess costs a shell.
    return get(session, 'running', false)
  endif
  return job_status(job) ==# 'run'
enddef

def Reap()
  # Wipe the buffers of shells that have exited. Dropping the session is not
  # enough on its own: term_start() leaves the finished shell's buffer behind
  # holding its whole scrollback, and once it is no longer a session nothing in
  # this plugin can reach it again, so it would sit there for the rest of the
  # Vim session.
  #
  # A buffer that is still on screen cannot be wiped -- :bwipeout fails with
  # E994 on one shown in a popup -- and that is not a rare corner: the popup
  # showing what the command printed on its way out is exactly the state a shell
  # exits into. So orphans are kept on a list and retried on the next Prune()
  # rather than being abandoned after one failed attempt.
  var pending: list<number> = []
  for bufnr in s_orphans
    if !bufexists(bufnr)
      continue
    endif
    if !Displayed(bufnr)
      execute 'silent! bwipeout! ' .. bufnr
    endif
    if bufexists(bufnr)
      add(pending, bufnr)
    endif
  endfor
  s_orphans = pending
enddef

def Prune()
  var current_buf = s_current >= 0 && s_current < len(s_sessions)
    ? get(s_sessions[s_current], 'bufnr', -1) : -1
  var live: list<dict<any>> = []
  for session in s_sessions
    if SessionAlive(session)
      add(live, session)
    else
      add(s_orphans, get(session, 'bufnr', -1))
    endif
  endfor
  s_sessions = live
  Reap()
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

def CurrentBuffer(): number
  # The buffer s_current names, read *without* pruning first. Prune() drops a
  # session whose shell has exited and slides s_current onto a live neighbour,
  # so any command that acts on the terminal the user is looking at has to read
  # s_current before that happens -- otherwise a shell exiting quietly redirects
  # :SimpleTerminalKill and :SimpleTerminalSend onto somebody else's still
  # running shell, which is a far worse outcome than doing nothing.
  return s_current >= 0 && s_current < len(s_sessions)
    ? get(s_sessions[s_current], 'bufnr', -1) : -1
enddef

def Registered(bufnr: number): bool
  # Is this buffer still one of the live sessions? Asked straight after a
  # Prune(), this is the only honest way to tell "the terminal the user was
  # pointed at is still running" from "its shell exited but its buffer is still
  # lying around". bufexists() cannot tell them apart -- the buffer outliving
  # the job is deliberate, and is the very thing that made bufexists() useless
  # as a liveness test in SessionAlive().
  for session in s_sessions
    if get(session, 'bufnr', -1) == bufnr
      return true
    endif
  endfor
  return false
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
  if PopupAlive()
    popup_close(s_popup)
  endif
  s_popup = 0
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
  # No term_finish here, on purpose. It only accepts 'close' or 'open'; the
  # 'noclose' that used to sit here is not a value at all, so term_start() threw
  # E475 and took all of New() down with it -- every :SimpleTerminalNew failed
  # and no session was ever registered. Leaving the option out already gives
  # what 'noclose' was reaching for: the buffer survives the job so the popup
  # still shows what the shell printed on its way out. Prune() reclaims it once
  # nothing is showing it.
  var options: dict<any> = {
    hidden: 1,
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
  # PopupAlive() rather than a bare s_popup test, so that Hide(), Toggle() and
  # Displayed() all decide "is a popup really up" by the same rule. The outcome
  # here is unchanged either way -- popup_close() on a stale id is a silent
  # no-op and s_popup lands on zero regardless -- but Displayed() now leans on
  # that question being answered in one place, and two spellings of it drift.
  if PopupAlive()
    popup_close(s_popup)
  endif
  s_popup = 0
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
  if PopupAlive()
    Hide()
  else
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
  var target = CurrentBuffer()
  Hide()
  if bufexists(target)
    var job = term_getjob(target)
    if type(job) == v:t_job && job_status(job) ==# 'run'
      job_stop(job)
    endif
    execute 'silent! bwipeout! ' .. target
  endif
  Prune()
enddef

export def Send(text: string)
  var target = CurrentBuffer()
  Prune()
  if !Registered(target)
    # Registered(), not bufexists(). The ordinary way a shell dies is with its
    # popup still up, and Reap() then cannot wipe the buffer (E994), so
    # bufexists() stays true for the terminal the user is looking at long after
    # its shell is gone. Guarding on bufexists() therefore waved the dead
    # terminal through to term_sendkeys(), which posts into a pty nobody is
    # reading: no output, no error, no warning -- the command just vanished and
    # the warning below never fired in the one case it was written for.
    #
    # Say which of the two it is. Refusing with 'no terminal session' while
    # three shells are running would send the user looking for the wrong
    # problem -- the sessions are fine, the one they were pointed at has exited.
    Warn(empty(s_sessions) ? 'no terminal session' : 'current terminal has exited')
    return
  endif
  term_sendkeys(target, text .. "\<CR>")
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
