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
  var n = fallback
  if type(value) == v:t_float
    n = float2nr(value)
  elseif type(value) == v:t_number
    n = value
  else
    return fallback
  endif
  return min([100, max([20, n])])
enddef

def ConfFlag(name: string, fallback: bool): bool
  var value = get(g:, name, fallback)
  if type(value) == v:t_bool
    return value
  endif
  if type(value) == v:t_number
    return value != 0
  endif
  return fallback
enddef

def ConfText(name: string, fallback: string): string
  var value = get(g:, name, fallback)
  return type(value) == v:t_string ? value : fallback
enddef

def DisconnectPolicy(): string
  var value = get(g:, 'simpleterminal_remote_on_disconnect', 'keep')
  if type(value) != v:t_string
    return 'keep'
  endif
  var lowered = tolower(value)
  return index(['keep', 'kill'], lowered) >= 0 ? lowered : 'keep'
enddef

def LocalRoot(): string
  if exists('*g:VimrcProjectRoot')
    try
      var root = g:VimrcProjectRoot()
      if type(root) == v:t_string && isdirectory(root)
        return root
      endif
    catch
    endtry
  endif
  return getcwd()
enddef

def ShellCommand(argument: string): list<string>
  var configured = ConfText('simpleterminal_shell', '')
  var shell = empty(configured) ? &shell : configured
  if empty(argument)
    return [shell]
  endif
  return [shell, &shellcmdflag, argument]
enddef

def ValidSpec(value: any): bool
  if type(value) != v:t_dict
      || type(get(value, 'command', 0)) != v:t_list
      || empty(value.command)
    return false
  endif
  for index in range(len(value.command))
    var argument = value.command[index]
    # argv[0] names the executable; later empty strings are legitimate
    # arguments and must survive exactly (printf, language servers, etc.).
    if type(argument) != v:t_string || (index == 0 && empty(argument))
      return false
    endif
  endfor
  return (!has_key(value, 'cwd') || type(value.cwd) == v:t_string)
    && (!has_key(value, 'name') || type(value.name) == v:t_string)
    && (!has_key(value, 'remote')
      || type(value.remote) == v:t_bool || type(value.remote) == v:t_number)
    && (!has_key(value, 'workspace') || type(value.workspace) == v:t_dict)
enddef

def LocalSpec(argument: string): dict<any>
  var root = LocalRoot()
  return {
    command: ShellCommand(argument),
    cwd: root,
    name: 'local:' .. fnamemodify(root, ':t'),
    remote: false,
    workspace: {},
  }
enddef

def Spec(argument: string, local: bool = false): dict<any>
  # `local` is :SimpleTerminalNew!'s bang: the user wants a shell on this
  # machine no matter what workspace is active, so neither the provider hook
  # nor SimpleRemote gets a say.
  if local
    return LocalSpec(argument)
  endif
  var provider = get(g:, 'SimpleTerminalSpecProvider', v:null)
  if type(provider) == v:t_func
    try
      var provided = call(provider, [argument])
      if ValidSpec(provided)
        return provided
      endif
      Warn('terminal spec provider returned an invalid specification; falling back')
    catch
      Warn('terminal spec provider failed: ' .. v:exception .. '; falling back')
    endtry
  endif
  if ConfFlag('simpleterminal_prefer_remote', true)
    if exists('*g:SimpleRemoteTerminalSpec')
      try
        var remote = g:SimpleRemoteTerminalSpec(argument)
        if ValidSpec(remote)
          return remote
        endif
      catch
        Warn('SimpleRemote terminal provider failed: ' .. v:exception
          .. '; opening a local shell')
      endtry
    endif
    # SimpleRemote answers {} until the handshake is done, so a terminal
    # opened during 'connecting' silently lands on the local machine and the
    # user only finds out when `ls` shows the wrong files. Say so.
    if get(g:, 'simpleremote_status', '') =~# '^connecting'
      Warn('remote workspace still connecting; opening a local shell')
    endif
  endif
  return LocalSpec(argument)
enddef

def Text(value: any): string
  # A workspace field as text. SimpleRemote's own ids are numbers and its kind,
  # target and root are strings, but the documented type of what a
  # g:SimpleTerminalSpecProvider hands back is just `dict`, and Vim9 refuses to
  # compare a string with a number: a provider answering with a string id used
  # to take the whole User SimpleRemoteDisconnected handler down with E1030 the
  # moment its id met the numeric default, so the sessions were never detached.
  # Text is the one form every value has, and 7 and '7' still mean one id.
  return type(value) == v:t_string ? value : string(value)
enddef

def WorkspaceIdentity(workspace: any): dict<any>
  # What a session remembers about the workspace it was opened in. Enough to
  # recognise the same workspace again (kind, target, root) and to tell one
  # connection generation from the next (id); the rest of SimpleRemote's
  # snapshot is not ours to keep.
  if type(workspace) != v:t_dict || empty(workspace)
    return {}
  endif
  # The id is kept as it came -- it is only ever compared, never shown -- while
  # kind, target and root are the labels List() and Target() print and the keys
  # SameWorkspace() matches on, so they are stored as text once here.
  return {
    id: get(workspace, 'id', -1),
    kind: Text(get(workspace, 'kind', '')),
    target: Text(get(workspace, 'target', '')),
    root: Text(get(workspace, 'root', '')),
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

def IndexOfBuffer(bufnr: number): number
  # Index of the session owning this buffer in the *current* s_sessions, or -1.
  # Every place that has to keep s_current on the same terminal across a
  # rebuild of the list goes through here: an index is only ever valid for the
  # list it was taken from, so it is remembered as a buffer number and looked
  # up again afterwards.
  if bufnr <= 0
    return -1
  endif
  for index in range(len(s_sessions))
    if get(s_sessions[index], 'bufnr', -1) == bufnr
      return index
    endif
  endfor
  return -1
enddef

def Prune()
  var current_buf = CurrentBuffer()
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
  s_current = IndexOfBuffer(current_buf)
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
  return IndexOfBuffer(bufnr) >= 0
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
    border: ConfFlag('simpleterminal_border', true) ? [1, 1, 1, 1] : [0, 0, 0, 0],
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

def RefreshTitle(session: dict<any>)
  # A session's name can change after its popup was opened (see Detach()),
  # and the popup keeps the title it was created with. Only our own popup, and
  # only when it is showing this very session.
  if PopupAlive() && winbufnr(s_popup) == get(session, 'bufnr', -1)
    popup_setoptions(s_popup, {title: $' {get(session, "name", "terminal")} '})
  endif
enddef

def Start(argument: string, local: bool): number
  # Everything New() does, returning the new session's buffer number -- or -1
  # -- so that Run() can hand it to a caller.
  var spec = Spec(argument, local)
  if !ValidSpec(spec)
    Warn('could not build a terminal command')
    return -1
  endif
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
  if type(cwd) == v:t_string && !empty(cwd)
    if isdirectory(cwd)
      options.cwd = cwd
    else
      Warn('cwd is not a directory: ' .. cwd .. '; using the current directory')
    endif
  endif
  var buf = -1
  options.exit_cb = (job, status) => OnExit(buf, job, status)
  try
    buf = term_start(spec.command, options)
  catch
    Warn('term_start() failed: ' .. v:exception)
    return -1
  endtry
  if buf <= 0
    Warn('term_start() failed')
    return -1
  endif
  # Close the previous popup only after the new job exists: a failed New()
  # used to Hide() first and leave the user staring at an empty screen while
  # the still-running session sat hidden.
  Hide()
  var remote = !!get(spec, 'remote', false)
  var workspace = WorkspaceIdentity(get(spec, 'workspace', {}))
  # Buffer-local breadcrumbs so a sibling looking at a terminal buffer can
  # tell it is ours and where its shell runs, without going through State().
  setbufvar(buf, 'simpleterminal_remote', remote)
  setbufvar(buf, 'simpleterminal_workspace', workspace)
  add(s_sessions, {
    bufnr: buf,
    name: get(spec, 'name', 'terminal-' .. buf),
    cwd: cwd,
    remote: remote,
    workspace: workspace,
    detached: false,
    running: true,
    status: v:null,
  })
  s_current = len(s_sessions) - 1
  OpenPopup(s_sessions[s_current])
  return buf
enddef

export def New(argument: string = '', local: bool = false)
  # `local` is :SimpleTerminalNew!'s bang -- a shell on this machine even while
  # a remote workspace is ready. Without it the active workspace decides.
  Start(argument, local)
enddef

export def Run(command: string): number
  # For siblings that want to run something in the workspace terminal and keep
  # a handle on it: opens the popup like :SimpleTerminalNew {command} and
  # returns the terminal's buffer number, or -1 when no terminal was started.
  return Start(command, false)
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

def SetCurrent(index: number)
  # Make s_sessions[index] the current session and show it. Callers have
  # pruned already, so the index is into the live list.
  Hide()
  s_current = index
  Show()
enddef

export def Cycle(delta: number)
  Prune()
  if empty(s_sessions)
    New('')
    return
  endif
  var index = (s_current + delta) % len(s_sessions)
  if index < 0
    index += len(s_sessions)
  endif
  SetCurrent(index)
enddef

def BaseName(session: dict<any>): string
  return substitute(get(session, 'name', ''), ' (detached)$', '', '')
enddef

def FindSession(name: string): number
  # Index of the session called `name`, or -1. The name a session was opened
  # under still finds it after Detach() renamed it, and a bare buffer number is
  # accepted too, so a caller that kept Run()'s return value can come back.
  var wanted = trim(name)
  if empty(wanted)
    return -1
  endif
  for index in range(len(s_sessions))
    if s_sessions[index].name ==# wanted
      return index
    endif
  endfor
  for index in range(len(s_sessions))
    if BaseName(s_sessions[index]) ==# wanted
      return index
    endif
  endfor
  if wanted =~# '^\d\+$'
    for index in range(len(s_sessions))
      if s_sessions[index].bufnr == str2nr(wanted)
        return index
      endif
    endfor
  endif
  return -1
enddef

export def Select(name: string)
  # Switch to a session by name (or buffer number) instead of cycling to it.
  Prune()
  var index = FindSession(name)
  if index < 0
    Warn(empty(s_sessions) ? 'no terminal session' : 'no session named ' .. name)
    return
  endif
  SetCurrent(index)
enddef

export def Complete(arglead: string, _cmdline: string, _cursorpos: number): list<string>
  # Command-line completion for :SimpleTerminalSelect. Substring rather than
  # prefix, so 'host' finds 'ssh:host:proj'. No Prune() here: completion must
  # not wipe buffers behind the user's back.
  var names = mapnew(s_sessions, (_, session): string => session.name)
  for session in s_sessions
    var buf = string(get(session, 'bufnr', 0))
    if index(names, buf) < 0
      add(names, buf)
    endif
  endfor
  if !empty(arglead)
    filter(names, (_, name) => stridx(name, arglead) >= 0)
  endif
  return names
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

def Deliver(lines: list<string>): bool
  # Type each line, followed by Enter, into the current terminal. Reads
  # CurrentBuffer() *before* Prune() -- see there for why the order matters.
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
    return false
  endif
  for line in lines
    term_sendkeys(target, line .. "\<CR>")
  endfor
  return true
enddef

export def Send(text: string)
  Deliver([text])
enddef

export def SendRange(count: number, line1: number, line2: number, text: string)
  # :SimpleTerminalSend's entry point. With a range (or a count) the lines of
  # the current buffer go first, one Enter after each; any argument text
  # follows. `count` is 0 when neither was given, which is how a plain
  # :SimpleTerminalSend {text} keeps working.
  var lines: list<string> = []
  if count > 0
    lines = getline(line1, line2)
  endif
  if !empty(text)
    add(lines, text)
  endif
  if empty(lines)
    Warn('nothing to send')
    return
  endif
  Deliver(lines)
enddef

def Detach(session: dict<any>)
  # The workspace this shell was opened in is gone or no longer the active
  # one. The shell itself is an independent process and keeps running; only
  # the label changes so that Cycle() and List() no longer present it as the
  # active workspace's terminal.
  if get(session, 'detached', false)
    return
  endif
  session.detached = true
  session.name = BaseName(session) .. ' (detached)'
  RefreshTitle(session)
enddef

def Reattach(session: dict<any>, workspace: dict<any>)
  # The workspace came back (same kind, target and root); the shell was there
  # all along. Adopt the new connection generation and drop the label.
  session.workspace = WorkspaceIdentity(workspace)
  setbufvar(session.bufnr, 'simpleterminal_workspace', session.workspace)
  if get(session, 'detached', false)
    session.detached = false
    session.name = BaseName(session)
    RefreshTitle(session)
  endif
enddef

def SameWorkspace(session: dict<any>, workspace: dict<any>): bool
  var mine = get(session, 'workspace', {})
  if empty(mine) || empty(workspace)
    return false
  endif
  # Text() on both sides: `mine` is normalised, but `workspace` is whatever the
  # live snapshot or the event payload holds.
  return Text(get(mine, 'kind', '')) ==# Text(get(workspace, 'kind', ''))
    && Text(get(mine, 'target', '')) ==# Text(get(workspace, 'target', ''))
    && Text(get(mine, 'root', '')) ==# Text(get(workspace, 'root', ''))
enddef

def LiveWorkspace(): dict<any>
  var workspace = get(g:, 'simpleremote_workspace', {})
  return type(workspace) == v:t_dict ? workspace : {}
enddef

def Attributable(session: dict<any>): bool
  # Can the connection events say anything about this session? Only a remote
  # one that recorded a workspace identity at New() time. A provider hook that
  # reports remote: true without a workspace is running shells SimpleRemote
  # knows nothing about, and neither do we -- leave them alone.
  return get(session, 'remote', false) && !empty(get(session, 'workspace', {}))
enddef

def WorkspaceGone(session: dict<any>, event: dict<any>): bool
  # Did the Disconnected event take this session's workspace away? SimpleRemote
  # unlets g:simpleremote_workspace before it fires, so "still connected" can
  # only be told from the id the session stored at New() time. A payload that
  # names the workspace it dropped is trusted first; without one, no live
  # workspace with our id means ours is the one that went.
  # Ids are compared as text, see Text(): a provider is free to hand back one
  # that is not a number.
  var mine = Text(get(get(session, 'workspace', {}), 'id', -1))
  var dropped = get(event, 'workspace', {})
  if type(dropped) == v:t_dict && has_key(dropped, 'id')
    return Text(dropped.id) ==# mine
  endif
  return Text(get(LiveWorkspace(), 'id', -1)) !=# mine
enddef

export def OnRemoteDisconnected()
  # User SimpleRemoteDisconnected. A workspace switch fires this with reason
  # 'reconnect' before Connecting/Connected; nothing is decided until the new
  # workspace is known, see OnRemoteConnected(). For a real disconnect the
  # remote sessions of the workspace that went away are detached -- renamed by
  # default, stopped when g:simpleterminal_remote_on_disconnect is 'kill'.
  var event = get(g:, 'simpleremote_event', {})
  if type(event) != v:t_dict
    event = {}
  endif
  if get(event, 'reason', '') ==# 'reconnect'
    return
  endif
  var kill = DisconnectPolicy() ==# 'kill'
  # The terminal the user is on, as a buffer number, before the list is rebuilt.
  # s_current is an index into the list as it stands now, so dropping a session
  # that sits *before* it slides every later session one place forward and the
  # index quietly comes to name the wrong shell -- and Prune() below, which
  # re-derives s_current from s_sessions[s_current], would then anchor onto that
  # wrong shell rather than notice. :SimpleTerminalToggle and
  # :SimpleTerminalSend went to somebody else's terminal, which is the one thing
  # that must never happen quietly.
  var current_buf = CurrentBuffer()
  var kept: list<dict<any>> = []
  # Where the current session lands in the rebuilt list -- the position it
  # keeps, or, when it is the one being stopped, the neighbour that slides into
  # its place. Only used when its buffer is gone from the list.
  var fallback = -1
  for index in range(len(s_sessions))
    var session = s_sessions[index]
    if index == s_current
      fallback = len(kept)
    endif
    var gone = Attributable(session)
      && !get(session, 'detached', false)
      && WorkspaceGone(session, event)
    if !gone
      add(kept, session)
    elseif !kill
      Detach(session)
      add(kept, session)
    else
      var bufnr = get(session, 'bufnr', -1)
      if PopupAlive() && winbufnr(s_popup) == bufnr
        Hide()
      endif
      if bufexists(bufnr)
        var job = term_getjob(bufnr)
        if type(job) == v:t_job && job_status(job) ==# 'run'
          job_stop(job)
        endif
        add(s_orphans, bufnr)
      endif
    endif
  endfor
  s_sessions = kept
  s_current = IndexOfBuffer(current_buf)
  if s_current < 0 && !empty(s_sessions)
    s_current = min([max([fallback, 0]), len(s_sessions) - 1])
  endif
  Prune()
enddef

export def OnRemoteConnected()
  # User SimpleRemoteConnected. Nothing destructive: sessions opened in the
  # workspace that just came (back) up are re-adopted -- a plain reconnect
  # bumps the connection id, and a session detached by an earlier disconnect
  # loses the label -- while remote sessions of any other workspace are
  # labelled detached, so a switch between hosts leaves the old shell
  # recognisable in Cycle() and List().
  var workspace = LiveWorkspace()
  if empty(workspace)
    var event = get(g:, 'simpleremote_event', {})
    if type(event) == v:t_dict && has_key(event, 'kind')
      workspace = event
    endif
  endif
  if empty(workspace)
    return
  endif
  for session in s_sessions
    if !Attributable(session)
      continue
    endif
    if SameWorkspace(session, workspace)
      Reattach(session, workspace)
    else
      Detach(session)
    endif
  endfor
enddef

def Target(session: dict<any>): string
  if !get(session, 'remote', false)
    return 'local'
  endif
  var workspace = get(session, 'workspace', {})
  if empty(get(workspace, 'target', ''))
    return 'remote'
  endif
  return printf('%s:%s', get(workspace, 'kind', ''), workspace.target)
enddef

export def List()
  Prune()
  if empty(s_sessions)
    echomsg '[SimpleTerminal] no sessions'
    return
  endif
  for index in range(len(s_sessions))
    var session = s_sessions[index]
    echomsg printf('%s %d  %s  %s  %s  %s', index == s_current ? '*' : ' ',
      session.bufnr, get(session, 'remote', false) ? 'R' : 'L', session.name,
      Target(session), get(session, 'running', false) ? 'running' : 'exited')
  endfor
enddef

export def State(): dict<any>
  Prune()
  return {
    sessions: deepcopy(s_sessions),
    current: s_current,
    popup: PopupAlive() ? s_popup : 0,
  }
enddef

export def Health()
  Prune()
  echomsg 'SimpleTerminal health'
  echomsg $'  terminal: {has("terminal") ? "yes" : "no"}'
  echomsg $'  popupwin: {has("popupwin") ? "yes" : "no"}'
  echomsg $'  popup: {PopupAlive() ? "open" : "closed"}'
  echomsg $'  sessions: {len(s_sessions)}'
  echomsg $'  pending wipe: {len(filter(copy(s_orphans), (_, bufnr) => bufexists(bufnr)))}'
  var provider = exists('*g:SimpleRemoteTerminalSpec')
  echomsg $'  remote provider: {provider ? "available" : "absent"}'
  echomsg $'  remote status: {get(g:, "simpleremote_status", provider ? "unknown" : "n/a")}'
  var spec = 'n/a'
  if provider
    try
      spec = ValidSpec(g:SimpleRemoteTerminalSpec('')) ? 'ready' : 'not ready'
    catch
      spec = 'error: ' .. v:exception
    endtry
  endif
  echomsg $'  remote spec: {spec}'
  echomsg $'  prefer remote: {ConfFlag("simpleterminal_prefer_remote", true) ? "yes" : "no"}'
  echomsg $'  on disconnect: {DisconnectPolicy()}'
enddef
