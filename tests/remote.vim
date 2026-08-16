vim9script

# SimpleRemote collaboration, with SimpleRemote itself nowhere on the
# runtimepath. What the plugin sees of it is a global g:SimpleRemoteTerminalSpec
# function, g:simpleremote_workspace / g:simpleremote_status and the User
# events it fires with g:simpleremote_event set -- all of which a stub can
# supply. Covers:
#
#   1. a ready workspace: sessions record remote/workspace identity
#   2. :SimpleTerminalNew! forces a local shell past provider and workspace
#   3. SimpleRemoteDisconnected: 'reconnect' is ignored, a real disconnect
#      detaches (renames) the workspace's sessions and leaves local ones alone
#   4. SimpleRemoteConnected: the same workspace re-adopts its sessions, a
#      different one labels them detached; never kills
#   5. g:simpleterminal_remote_on_disconnect = 'kill'
#   6. SendRange(): a range types each line, plain text still works
#   7. Select() by name / base name / bufnr, Complete()
#   8. Run() returns the new terminal's buffer number
#   9. Spec() warns when a shell falls back to local while still connecting
#  10. Health() reports the SimpleRemote state
#  11. a kill on disconnect keeps the user on the same terminal
#  12. a workspace id that is not a number

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleterminal.vim')

# --- the SimpleRemote stub ---------------------------------------------------
var stub_ready = true
var stub_workspace = {id: 7, kind: 'ssh', target: 'host', root: '/srv/proj',
  mode: 'virtual', uri: 'remote:///srv/proj'}
var stub_calls: list<string> = []

def g:SimpleRemoteTerminalSpec(argument: string = ''): dict<any>
  add(stub_calls, argument)
  if !stub_ready
    return {}
  endif
  return {
    command: ['sh', '-c', 'sleep 30'],
    cwd: '',
    name: printf('%s:%s:%s', stub_workspace.kind, stub_workspace.target,
      fnamemodify(stub_workspace.root, ':t')),
    remote: true,
    workspace: copy(stub_workspace),
  }
enddef

def Connect(workspace: dict<any>)
  stub_workspace = workspace
  stub_ready = true
  g:simpleremote_workspace = copy(workspace)
  g:simpleremote_status = workspace.kind .. ':' .. workspace.target
  g:simpleremote_event = {event: 'SimpleRemoteConnected', status: g:simpleremote_status,
    time: localtime()}
  extend(g:simpleremote_event, workspace, 'keep')
  doautocmd <nomodeline> User SimpleRemoteConnected
enddef

def Disconnect(reason: string)
  stub_ready = false
  unlet! g:simpleremote_workspace
  g:simpleremote_status = 'disconnected'
  g:simpleremote_event = {event: 'SimpleRemoteDisconnected', reason: reason,
    status: 'disconnected', time: localtime()}
  doautocmd <nomodeline> User SimpleRemoteDisconnected
enddef

# --- helpers (as in lifecycle.vim) --------------------------------------------
def Sessions(): list<dict<any>>
  return simpleterminal#State().sessions
enddef

def SessionBuffers(): list<number>
  return mapnew(Sessions(), (_, session) => session.bufnr)
enddef

def SessionByBuffer(bufnr: number): dict<any>
  for session in Sessions()
    if session.bufnr == bufnr
      return session
    endif
  endfor
  return {}
enddef

def NewestBuffer(): number
  var sessions = Sessions()
  return empty(sessions) ? -1 : sessions[-1].bufnr
enddef

def CurrentBuffer(): number
  # The buffer of the session :SimpleTerminalToggle/Send/Kill would act on.
  var state = simpleterminal#State()
  return state.current >= 0 && state.current < len(state.sessions)
    ? state.sessions[state.current].bufnr : -1
enddef

def KillAll()
  var guard = 0
  while !empty(Sessions()) && guard < 20
    simpleterminal#Kill()
    guard += 1
  endwhile
  assert_equal([], SessionBuffers(), 'sessions left over from an earlier section')
enddef

def JobRunning(bufnr: number): bool
  if !bufexists(bufnr)
    return false
  endif
  var job = term_getjob(bufnr)
  return type(job) == v:t_job && job_status(job) ==# 'run'
enddef

def WaitExited(bufnr: number): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < 10.0
    if !JobRunning(bufnr)
      return true
    endif
    sleep 20m
  endwhile
  return false
enddef

def TerminalShows(bufnr: number, needle: string): bool
  if !bufexists(bufnr)
    return false
  endif
  for lnum in range(1, term_getsize(bufnr)[0])
    if term_getline(bufnr, lnum) =~# needle
      return true
    endif
  endfor
  return false
enddef

def WaitForText(bufnr: number, needle: string): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < 5.0
    if TerminalShows(bufnr, needle)
      return true
    endif
    sleep 20m
  endwhile
  return false
enddef

def Captured(F: func): string
  var out = ''
  redir => out
  silent! F()
  redir END
  return out
enddef

def Bail()
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
enddef

# --- 1. A ready workspace ---------------------------------------------------
# Connected before any terminal exists: OnRemoteConnected() with no sessions
# must be a no-op rather than an error.
Connect({id: 7, kind: 'ssh', target: 'host', root: '/srv/proj'})
assert_equal([], SessionBuffers())

simpleterminal#New('')
var remote_buf = NewestBuffer()
assert_true(remote_buf > 0, 'New() with a ready workspace registered no session')
if remote_buf <= 0
  Bail()
endif
assert_equal([''], stub_calls, 'the workspace spec was not consulted with the argument')
var remote_session = SessionByBuffer(remote_buf)
assert_equal('ssh:host:proj', remote_session.name)
assert_true(remote_session.remote, 'session opened in the workspace is not marked remote')
assert_false(remote_session.detached)
assert_equal({id: 7, kind: 'ssh', target: 'host', root: '/srv/proj'}, remote_session.workspace,
  'session did not record the workspace identity')
assert_equal(true, getbufvar(remote_buf, 'simpleterminal_remote'))
assert_equal(7, getbufvar(remote_buf, 'simpleterminal_workspace').id)
assert_equal(remote_buf, winbufnr(simpleterminal#State().popup))
assert_equal(' ssh:host:proj ', popup_getoptions(simpleterminal#State().popup).title)

# --- 2. :SimpleTerminalNew! forces a local shell ------------------------------
# A provider hook is installed as well: the bang must bypass both it and the
# workspace, or a user with SimpleRemote connected has no way to a local shell
# short of editing globals.
def Provider(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30'], cwd: '/tmp', name: 'provided', remote: false}
enddef
g:SimpleTerminalSpecProvider = Provider
g:simpleterminal_shell = 'sh'
stub_calls = []

execute 'SimpleTerminalNew! sleep 30'
var local_buf = NewestBuffer()
assert_true(local_buf > 0 && local_buf != remote_buf, 'SimpleTerminalNew! registered no session')
if local_buf <= 0 || local_buf == remote_buf
  Bail()
endif
var local_session = SessionByBuffer(local_buf)
assert_false(local_session.remote, 'SimpleTerminalNew! opened a remote shell')
assert_match('^local:', local_session.name, 'SimpleTerminalNew! did not build the local spec')
assert_notequal('provided', local_session.name, 'SimpleTerminalNew! went through the provider')
assert_equal({}, local_session.workspace)
assert_equal([], stub_calls, 'SimpleTerminalNew! consulted the workspace spec')
assert_equal(false, getbufvar(local_buf, 'simpleterminal_remote'))
assert_match('simpleterminal#New', maparg('<Plug>(simpleterminal-new-local)', 'n'))

# Without the bang the provider wins again, as before.
execute 'SimpleTerminalNew sleep 30'
var provided_buf = NewestBuffer()
assert_equal('provided', SessionByBuffer(provided_buf).name, 'the provider hook lost precedence')
simpleterminal#Kill()
assert_equal([remote_buf, local_buf], SessionBuffers())
unlet g:SimpleTerminalSpecProvider

# --- 3. SimpleRemoteDisconnected ---------------------------------------------
# A workspace switch fires Disconnected with reason 'reconnect' first; nothing
# may happen to the sessions until Connected says where we landed.
Disconnect('reconnect')
assert_equal('ssh:host:proj', SessionByBuffer(remote_buf).name,
  'a reconnect Disconnected touched the remote session')
assert_false(SessionByBuffer(remote_buf).detached)

# The real thing. The remote session is renamed, keeps running, keeps its
# workspace identity; the local session is untouched; the popup title follows.
simpleterminal#Select('ssh:host:proj')
assert_equal(remote_buf, winbufnr(simpleterminal#State().popup))
Disconnect('disconnect')
remote_session = SessionByBuffer(remote_buf)
assert_equal('ssh:host:proj (detached)', remote_session.name, 'disconnect did not detach the remote session')
assert_true(remote_session.detached)
assert_true(remote_session.remote)
assert_equal(7, remote_session.workspace.id, 'detaching lost the workspace identity')
assert_true(JobRunning(remote_buf), 'keep policy killed the remote shell')
assert_equal(' ssh:host:proj (detached) ', popup_getoptions(simpleterminal#State().popup).title,
  'popup title was not refreshed on detach')
local_session = SessionByBuffer(local_buf)
assert_false(local_session.detached, 'disconnect detached a local session')
assert_match('^local:', local_session.name)

# Detaching twice must not stack labels.
Disconnect('disconnect')
assert_equal('ssh:host:proj (detached)', SessionByBuffer(remote_buf).name, 'detached label stacked')

# A provider's remote shell that carries no workspace identity is not
# SimpleRemote's to detach -- neither event may touch it.
def ForeignProvider(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30'], cwd: '/tmp', name: 'foreign', remote: true}
enddef
g:SimpleTerminalSpecProvider = ForeignProvider
simpleterminal#New('')
var foreign_buf = NewestBuffer()
unlet g:SimpleTerminalSpecProvider
assert_true(SessionByBuffer(foreign_buf).remote)
assert_equal({}, SessionByBuffer(foreign_buf).workspace)
Disconnect('disconnect')
assert_equal('foreign', SessionByBuffer(foreign_buf).name,
  'a remote session without a workspace identity was detached')
Connect({id: 7, kind: 'ssh', target: 'host', root: '/srv/proj'})
assert_equal('foreign', SessionByBuffer(foreign_buf).name,
  'Connected relabelled a remote session without a workspace identity')
assert_equal('ssh:host:proj', SessionByBuffer(remote_buf).name)
Disconnect('disconnect')
assert_equal('ssh:host:proj (detached)', SessionByBuffer(remote_buf).name)
simpleterminal#Select('foreign')
assert_equal(foreign_buf, winbufnr(simpleterminal#State().popup))
simpleterminal#Kill()
assert_equal(sort([remote_buf, local_buf]), sort(SessionBuffers()))

# List() shows the R/L column and the target.
var listing = Captured(simpleterminal#List)
assert_match('R  ssh:host:proj (detached)  ssh:host  running', listing, 'List() lacks the remote row')
assert_match('L  local:\S*  local  running', listing, 'List() lacks the local row')

# --- 4. SimpleRemoteConnected ------------------------------------------------
# Same kind/target/root under a new connection id: the shell was there all
# along, so the session is adopted back and the label dropped.
Connect({id: 8, kind: 'ssh', target: 'host', root: '/srv/proj'})
remote_session = SessionByBuffer(remote_buf)
assert_equal('ssh:host:proj', remote_session.name, 'reconnecting to the same workspace did not re-adopt')
assert_false(remote_session.detached)
assert_equal(8, remote_session.workspace.id, 'workspace id was not refreshed on re-adopt')
assert_equal(8, getbufvar(remote_buf, 'simpleterminal_workspace').id)
assert_false(SessionByBuffer(local_buf).remote)

# A different workspace: the old shell is labelled, nothing is stopped.
Connect({id: 9, kind: 'docker', target: 'box', root: '/work'})
remote_session = SessionByBuffer(remote_buf)
assert_equal('ssh:host:proj (detached)', remote_session.name, 'switching workspaces did not detach the old shell')
assert_true(JobRunning(remote_buf), 'Connected killed a session')
assert_equal(7 + 1, remote_session.workspace.id, 'a foreign workspace overwrote the stored identity')

# ... and a new terminal now belongs to the new workspace.
simpleterminal#New('')
var docker_buf = NewestBuffer()
assert_true(docker_buf > 0 && docker_buf != local_buf && docker_buf != remote_buf)
assert_equal('docker:box:work', SessionByBuffer(docker_buf).name)
assert_equal(9, SessionByBuffer(docker_buf).workspace.id)

# Switching back re-adopts the ssh shell and detaches the docker one.
Connect({id: 10, kind: 'ssh', target: 'host', root: '/srv/proj'})
assert_equal('ssh:host:proj', SessionByBuffer(remote_buf).name)
assert_equal(10, SessionByBuffer(remote_buf).workspace.id)
assert_equal('docker:box:work (detached)', SessionByBuffer(docker_buf).name)

# --- 5. 'kill' policy ---------------------------------------------------------
# Only sessions of the workspace that went away are stopped; the docker one is
# already detached (its workspace is long gone) and stays -- and the local
# shell is never in question.
#
# The user is parked on the local shell, which sits *behind* the ssh one in the
# list: stopping a session shifts every later one a place forward, so the
# current session has to be followed by buffer number and not by index --
# otherwise :SimpleTerminalToggle and :SimpleTerminalSend quietly move on to
# the next terminal.
assert_equal([remote_buf, local_buf, docker_buf], SessionBuffers(),
  'this check needs the doomed ssh session to sit before the current one')
simpleterminal#Select(string(local_buf))
assert_equal(local_buf, CurrentBuffer())
g:simpleterminal_remote_on_disconnect = 'kill'
Disconnect('disconnect')
assert_true(WaitExited(remote_buf), 'kill policy left the remote shell running')
assert_equal(sort([local_buf, docker_buf]), sort(SessionBuffers()),
  'kill policy removed the wrong sessions')
assert_equal(local_buf, CurrentBuffer(),
  'stopping an earlier session moved the current one')
# The user-visible symptom of getting this wrong: the next
# :SimpleTerminalToggle comes back on whatever session s_current now names.
simpleterminal#Hide()
simpleterminal#Show()
assert_equal(local_buf, winbufnr(simpleterminal#State().popup),
  ':SimpleTerminalToggle came back on the wrong session after a kill')
simpleterminal#Hide()
simpleterminal#State()
assert_false(bufexists(remote_buf), 'killed remote terminal buffer leaked')
assert_true(JobRunning(docker_buf), 'kill policy stopped an already detached session')
assert_true(JobRunning(local_buf), 'kill policy stopped a local shell')
g:simpleterminal_remote_on_disconnect = 'keep'

# --- 6. SendRange() -----------------------------------------------------------
simpleterminal#Select(string(local_buf))
assert_equal(local_buf, winbufnr(simpleterminal#State().popup), 'Select() by bufnr failed')
# A terminal popup is the current window for as long as it is up (see
# |popup-terminal|), so this is also how a user gets at :'<,'>SimpleTerminalSend:
# hide the popup, select the lines, send them into the session picked above.
simpleterminal#Hide()
new
setline(1, ['echo range-line-one', 'echo range-line-two', 'echo not-this-line'])
execute ':1,2SimpleTerminalSend'
assert_true(WaitForText(local_buf, 'range-line-one'), 'range send delivered no first line')
assert_true(WaitForText(local_buf, 'range-line-two'), 'range send delivered no second line')
assert_false(TerminalShows(local_buf, 'not-this-line'), 'range send delivered a line outside the range')
assert_false(TerminalShows(docker_buf, 'range-line-one'), 'range send reached the wrong terminal')
execute 'SimpleTerminalSend echo plain-text-send'
assert_true(WaitForText(local_buf, 'plain-text-send'), 'plain :SimpleTerminalSend stopped working')
simpleterminal#SendRange(0, 1, 1, 'echo api-send')
assert_true(WaitForText(local_buf, 'api-send'), 'SendRange() with text only delivered nothing')
simpleterminal#Send('echo old-send')
assert_true(WaitForText(local_buf, 'old-send'), 'Send() stopped working')
var nothing = Captured(() => simpleterminal#SendRange(0, 1, 1, ''))
assert_match('nothing to send', nothing, 'an empty :SimpleTerminalSend was not refused')
bwipeout!

# --- 7. Select() and Complete() ---------------------------------------------
simpleterminal#Select('docker:box:work (detached)')
assert_equal(docker_buf, winbufnr(simpleterminal#State().popup), 'Select() by full name failed')
simpleterminal#Select('local:' .. fnamemodify(SessionByBuffer(local_buf).cwd, ':t'))
assert_equal(local_buf, winbufnr(simpleterminal#State().popup), 'Select() by local name failed')
simpleterminal#Select('docker:box:work')
assert_equal(docker_buf, winbufnr(simpleterminal#State().popup),
  'Select() by the name before detaching failed')
var missing = Captured(() => simpleterminal#Select('no-such-session'))
assert_match('no session named no-such-session', missing, 'Select() of an unknown name was silent')
assert_equal(docker_buf, winbufnr(simpleterminal#State().popup), 'a failed Select() moved the current session')
execute 'SimpleTerminalSelect ' .. SessionByBuffer(local_buf).name
assert_equal(local_buf, winbufnr(simpleterminal#State().popup), ':SimpleTerminalSelect failed')

var completions = simpleterminal#Complete('', 'SimpleTerminalSelect ', 21)
assert_equal(sort(['docker:box:work (detached)', SessionByBuffer(local_buf).name]), sort(completions))
assert_equal(['docker:box:work (detached)'], simpleterminal#Complete('box', '', 0))
assert_equal(['docker:box:work (detached)'], getcompletion('SimpleTerminalSelect box', 'cmdline'))

# --- 8. Run() ---------------------------------------------------------------
Connect({id: 10, kind: 'ssh', target: 'host', root: '/srv/proj'})
var run_buf = simpleterminal#Run('sleep 30')
assert_true(run_buf > 0, 'Run() returned no buffer')
assert_equal(run_buf, NewestBuffer(), 'Run() did not return the new session buffer')
assert_equal('ssh:host:proj', SessionByBuffer(run_buf).name, 'Run() did not use the workspace')
assert_equal('sleep 30', stub_calls[-1], 'Run() did not pass its command to the spec')
assert_equal(run_buf, winbufnr(simpleterminal#State().popup))

# --- 9. Local fallback while still connecting ------------------------------
Disconnect('disconnect')
g:simpleremote_status = 'connecting ssh:host'
var connecting = Captured(() => simpleterminal#New('sleep 30'))
assert_match('still connecting; opening a local shell', connecting,
  'the local fallback during connecting was silent')
var fallback_buf = NewestBuffer()
assert_match('^local:', SessionByBuffer(fallback_buf).name)
assert_false(SessionByBuffer(fallback_buf).remote)
# The bang path says nothing: the user asked for local.
var quiet = Captured(() => simpleterminal#New('sleep 30', true))
assert_notmatch('still connecting', quiet, 'SimpleTerminalNew! warned about a fallback it did not take')
g:simpleremote_status = 'disconnected'

# --- 10. Health() -----------------------------------------------------------
var health = Captured(simpleterminal#Health)
assert_match('remote provider: available', health)
assert_match('remote status: disconnected', health, 'Health() does not report g:simpleremote_status')
assert_match('remote spec: not ready', health, 'Health() does not report the spec state')
assert_match('on disconnect: keep', health)
Connect({id: 11, kind: 'ssh', target: 'host', root: '/srv/proj'})
health = Captured(simpleterminal#Health)
assert_match('remote status: ssh:host', health)
assert_match('remote spec: ready', health)

# --- 11. A kill that takes the current session with it -----------------------
# The other half of the same bookkeeping: when the shell the user is on is the
# one the disconnect stops, the session that slides into its place takes over
# and nothing is left pointing past the end of the list.
KillAll()
Connect({id: 12, kind: 'ssh', target: 'host', root: '/srv/proj'})
simpleterminal#New('sleep 30', true)
var first_local = NewestBuffer()
simpleterminal#New('')
var doomed_buf = NewestBuffer()
simpleterminal#New('sleep 30', true)
var last_local = NewestBuffer()
assert_equal([first_local, doomed_buf, last_local], SessionBuffers())
simpleterminal#Select(string(doomed_buf))
assert_equal(doomed_buf, CurrentBuffer())
g:simpleterminal_remote_on_disconnect = 'kill'
Disconnect('disconnect')
assert_true(WaitExited(doomed_buf), 'kill policy left the remote shell running')
assert_equal([first_local, last_local], SessionBuffers(),
  'kill policy removed the wrong sessions')
assert_equal(last_local, CurrentBuffer(),
  'stopping the current session did not fall through to its neighbour')
g:simpleterminal_remote_on_disconnect = 'keep'
simpleterminal#Show()
assert_equal(last_local, winbufnr(simpleterminal#State().popup),
  'the popup did not follow the session that took over')

# --- 12. A workspace id that is not a number ---------------------------------
# What a g:SimpleTerminalSpecProvider returns is documented as a dict; nothing
# says the workspace id has to be a number. Vim9 refuses to compare a string
# with a number, so an id like this used to throw E1030 out of the User
# SimpleRemoteDisconnected autocmd and no session was detached at all.
KillAll()
def StringIdProvider(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30'], cwd: '/tmp', name: 'strid', remote: true,
    workspace: {id: 'ws-x', kind: 'ssh', target: 'host', root: '/srv'}}
enddef
g:SimpleTerminalSpecProvider = StringIdProvider
simpleterminal#New('')
var strid_buf = NewestBuffer()
assert_true(strid_buf > 0, 'the string-id provider registered no session')
assert_equal('ws-x', SessionByBuffer(strid_buf).workspace.id, 'the string id was not recorded')
Disconnect('disconnect')
assert_equal('strid (detached)', SessionByBuffer(strid_buf).name,
  'a session with a string workspace id was not detached on disconnect')
assert_true(JobRunning(strid_buf), 'keep policy killed the string-id shell')

# The workspace comes back under a new string id: same kind/target/root, so the
# shell is adopted again.
Connect({id: 'ws-y', kind: 'ssh', target: 'host', root: '/srv'})
assert_equal('strid', SessionByBuffer(strid_buf).name,
  'the same workspace under a string id did not re-adopt its session')
assert_equal('ws-y', SessionByBuffer(strid_buf).workspace.id)

# And a Disconnected payload that names the dropped workspace by string id.
stub_ready = false
unlet! g:simpleremote_workspace
g:simpleremote_status = 'disconnected'
g:simpleremote_event = {event: 'SimpleRemoteDisconnected', reason: 'disconnect',
  status: 'disconnected', time: localtime(), workspace: {id: 'ws-y'}}
doautocmd <nomodeline> User SimpleRemoteDisconnected
assert_equal('strid (detached)', SessionByBuffer(strid_buf).name,
  'a payload naming the dropped string id did not detach its session')
unlet g:SimpleTerminalSpecProvider

# --- Nothing left behind ------------------------------------------------------
while !empty(Sessions())
  var before = len(Sessions())
  simpleterminal#Kill()
  if len(Sessions()) >= before
    assert_report('Kill() did not shrink the session list')
    break
  endif
endwhile
assert_equal([], SessionBuffers())

if !empty(v:errors)
  Bail()
endif
qa!
