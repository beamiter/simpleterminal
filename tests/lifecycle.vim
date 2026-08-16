vim9script

# Session-lifecycle regressions. All of them live in the stretch between "the
# shell exited" and "the plugin noticed":
#
#   1. term_start() was passed term_finish: 'noclose', which is not one of the
#      two values that option takes, so it threw E475 and every New() died
#      before it ever registered a session.
#   2. With that fixed, an exited shell's buffer keeps buftype=terminal for the
#      rest of the Vim session, and SessionAlive() tested only bufexists() plus
#      buftype -- so dead shells stayed in the list and <F7> walked the user
#      through them, while their buffers piled up unreachable.
#   3. Once dead sessions are pruned, s_current slides onto a live neighbour --
#      so :SimpleTerminalKill and :SimpleTerminalSend, aimed at the dead shell
#      on screen, would hit somebody else's running one instead.

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleterminal.vim')

var spec_command = ['sh', '-c', 'sleep 30']
var spec_name = 'long-shell'

def TestSpec(_argument: string): dict<any>
  return {
    command: spec_command,
    cwd: '/tmp',
    name: spec_name,
    remote: false,
  }
enddef
g:SimpleTerminalSpecProvider = TestSpec

# Wait on the job itself, not on session.running. exit_cb only runs once Vim is
# back in its main loop, so in a script like this one session.running is still
# true long after the shell is gone -- which is precisely the staleness that
# makes the job, not the flag, the thing SessionAlive() has to ask.
def WaitExited(bufnr: number): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < 10.0
    var job = term_getjob(bufnr)
    if type(job) != v:t_job || job_status(job) !=# 'run'
      return true
    endif
    sleep 20m
  endwhile
  return false
enddef

def NewestBuffer(): number
  var sessions = simpleterminal#State().sessions
  return empty(sessions) ? -1 : sessions[-1].bufnr
enddef

# Assert on the whole buffer list rather than indexing into it. When one of
# these regressions comes back the session list is the wrong length, and
# sessions[0] would throw E684 and abort the run before v:errors ever reached
# errors.log -- a failing gate with nothing in it to read.
def SessionBuffers(): list<number>
  return mapnew(simpleterminal#State().sessions, (_, session) => session.bufnr)
enddef

# The pty echoes whatever is written to it, so anything Send() delivered shows
# up on that terminal's own screen -- which is how a misdirected Send() is
# caught in the act.
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

# --- 1. New() actually registers a session --------------------------------
# Guards the E475. Catch it rather than let it abort the run: an uncaught error
# in -es mode kills Vim before v:errors can be written out, so the gate failed
# with an empty errors.log and nothing to read -- which is how this bug stayed
# invisible in the first place.
try
  simpleterminal#New('')
catch
  assert_report('New() threw: ' .. v:exception)
endtry
var long_buf = NewestBuffer()
assert_true(long_buf > 0, 'New() registered no session')
assert_equal([long_buf], SessionBuffers())
if long_buf <= 0
  # Everything below needs a live session to say anything at all, and the next
  # New() would throw again and abort before the report was written. Stop here
  # while there is still something to report.
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif

# --- 2. A session whose job has exited is pruned, not cycled to -----------
# The shell sleeps first so that its bufnr can be read back before it dies:
# State() prunes, so a shell that exits instantly would already be gone by the
# time the test could name it, and the test would race instead of assert.
spec_command = ['sh', '-c', 'sleep 1']
spec_name = 'short-shell'
simpleterminal#New('')
var short_buf = NewestBuffer()
assert_true(short_buf > 0, 'short-lived session was not registered')
assert_true(short_buf != long_buf, 'short-lived session was pruned too early')
assert_equal([long_buf, short_buf], SessionBuffers())

assert_true(WaitExited(short_buf), 'short shell never exited')

# The buffer outlives its job -- that is why bufexists() could not be trusted
# as a liveness test in the first place.
assert_true(bufexists(short_buf), 'terminal buffer vanished with its job')
assert_equal('terminal', getbufvar(short_buf, '&buftype'))

simpleterminal#Cycle(1)
assert_equal([long_buf], SessionBuffers(), 'dead session was not pruned')
assert_equal(0, simpleterminal#State().current)

# ... and the dead shell's buffer is reclaimed, not left to accumulate.
assert_false(bufexists(short_buf), 'dead terminal buffer leaked')

# Keep cycling. This is the symptom as the user meets it: with the dead session
# still in the list, <F7> shows the live shell first and the dead one on the
# next press, forever. Check the buffer the popup is really showing, not just
# the bookkeeping -- a single press can land on the live shell by arithmetic
# accident even when nothing was pruned at all.
assert_equal(long_buf, winbufnr(simpleterminal#State().popup))
for _ in range(3)
  simpleterminal#Cycle(1)
  assert_equal(long_buf, winbufnr(simpleterminal#State().popup),
    'cycled onto a terminal whose shell had exited')
endfor

# --- 3. Kill() acts on the terminal the user is looking at ----------------
# s_current names the dead shell here; pruning slides it onto the live
# long-running one, so a Kill() that consults the pruned state stops the wrong
# terminal -- the one still doing the user's work.
spec_command = ['sh', '-c', 'sleep 1']
spec_name = 'doomed-shell'
simpleterminal#New('')
var doomed_buf = NewestBuffer()
assert_true(doomed_buf != long_buf, 'doomed session was pruned too early')
assert_true(WaitExited(doomed_buf), 'doomed shell never exited')
simpleterminal#Kill()
assert_true(bufexists(long_buf), 'Kill() stopped the live shell instead')
assert_equal([long_buf], SessionBuffers(), 'Kill() left the wrong session behind')

# --- 4. A shell that dies while its popup is still up ---------------------
# This is the ordinary way a shell exits: the popup is up, showing whatever it
# printed on the way out. :bwipeout cannot touch a buffer on screen in a popup,
# so the session must be dropped at once while the buffer waits -- and the wait
# must be retried, not abandoned, or the buffer leaks with nothing pointing at
# it any more.
spec_command = ['sh', '-c', 'sleep 1']
spec_name = 'onscreen-shell'
simpleterminal#New('')
var onscreen_buf = NewestBuffer()
assert_true(onscreen_buf != long_buf, 'on-screen session was pruned too early')
assert_equal(onscreen_buf, winbufnr(simpleterminal#State().popup))
assert_true(WaitExited(onscreen_buf), 'on-screen shell never exited')

assert_equal([long_buf], SessionBuffers(), 'session on screen was not pruned')
assert_true(bufexists(onscreen_buf), 'buffer was wiped out from under the popup')

simpleterminal#Hide()
simpleterminal#State()
assert_false(bufexists(onscreen_buf), 'exited shell buffer was never reclaimed')

# --- 5. Send() is not redirected onto a live shell ------------------------
# Two sends, in order: the first while the current shell is dead (it must land
# nowhere), the second once pruning has moved on (it must land on the live
# shell). Waiting for the second to appear is what makes the first one's absence
# meaningful -- a misdirected send would have reached the same screen first.
spec_command = ['sh', '-c', 'sleep 1']
spec_name = 'stray-shell'
simpleterminal#New('')
var stray_buf = NewestBuffer()
assert_true(stray_buf != long_buf, 'stray session was pruned too early')
assert_true(WaitExited(stray_buf), 'stray shell never exited')

# The refusal has to be audible, and this is the assertion that says so. The
# popup is still up showing the dead shell, so Reap() cannot wipe its buffer and
# bufexists() is still true for it -- a Send() guarded on bufexists() hands the
# command to term_sendkeys() on a pty nobody is reading. It vanishes silently:
# it reaches no terminal, so the two assertions below still pass, and the user
# gets no warning either. Only capturing the message catches that.
var refusal = ''
redir => refusal
silent! simpleterminal#Send('sentinel-must-not-arrive')
redir END
assert_match('current terminal has exited', refusal,
  'Send() silently swallowed the command instead of reporting the exited terminal')

simpleterminal#Send('sentinel-must-arrive')
assert_true(WaitForText(long_buf, 'sentinel-must-arrive'),
  'Send() reached no terminal at all')
assert_false(TerminalShows(long_buf, 'sentinel-must-not-arrive'),
  'Send() typed into the live shell after the current one had exited')

# --- 6. Hide()/Show() with no popup must not throw ------------------------
simpleterminal#Hide()
assert_equal(0, simpleterminal#State().popup)
try
  simpleterminal#Hide()
catch
  assert_report('Hide() with no popup threw: ' .. v:exception)
endtry
assert_equal(0, simpleterminal#State().popup)

try
  simpleterminal#Show()
catch
  assert_report('Show() with no popup threw: ' .. v:exception)
endtry
assert_true(simpleterminal#State().popup > 0, 'Show() opened no popup')

# A popup closed behind the plugin's back leaves s_popup naming nothing. Hide()
# must survive the stale id and clear it, and Toggle() must read that same id
# the same way -- otherwise it flips the wrong way and closes what is not open.
var stale = simpleterminal#State().popup
popup_close(stale)
assert_equal(-1, index(popup_list(), stale))
try
  simpleterminal#Hide()
catch
  assert_report('Hide() with a stale popup id threw: ' .. v:exception)
endtry
assert_equal(0, simpleterminal#State().popup, 'stale popup id was not cleared')

simpleterminal#Toggle()
assert_true(simpleterminal#State().popup > 0, 'Toggle() failed to reopen')
simpleterminal#Toggle()
assert_equal(0, simpleterminal#State().popup, 'Toggle() failed to close')

# The same stale id, but reaching Toggle() directly this time -- no Hide() in
# between to clear it. A test that only asks "is s_popup non-zero" concludes the
# popup is up and closes it, leaving the user pressing <F8> at a screen where
# nothing happens. State() only reads, so the stale id survives the lookup.
simpleterminal#Show()
var stranded = simpleterminal#State().popup
assert_true(stranded > 0, 'Show() opened no popup to strand')
popup_close(stranded)
simpleterminal#Toggle()
assert_true(simpleterminal#State().popup > 0,
  'Toggle() closed a popup that was already gone')

# --- 7. Every exported entry point is compiled ----------------------------
# :def bodies compile lazily, so a type error in a branch nobody has walked
# stays hidden until a user walks it. tests/defcompile.vim does not reach these:
# a bare :defcompile only compiles functions defined in the script that runs it,
# so nothing under autoload/ is ever touched by it (measured -- a deliberate
# type error inside Reap() sails straight through `make defcompile`). Calling
# them is what forces the compile, so call the two nothing else here does, on
# both sides of the branch that matters: with a session and without.
silent simpleterminal#List()
silent simpleterminal#Health()

# --- 8. Nothing left behind ------------------------------------------------
simpleterminal#Kill()
assert_equal([], SessionBuffers())
assert_false(bufexists(long_buf), 'Kill() left the terminal buffer behind')

silent simpleterminal#List()
silent simpleterminal#Health()

# The other side of Send()'s warning branch, which nothing above reaches: with
# no sessions left at all the message must be the one about there being none,
# not the one about the current terminal having exited. Both spellings are cold
# branches that only a user ever walks, and :def bodies compile lazily.
var no_session = ''
redir => no_session
silent! simpleterminal#Send('sentinel-after-kill')
redir END
assert_match('no terminal session', no_session,
  'Send() with no sessions reported the wrong reason')

if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif
qa!
