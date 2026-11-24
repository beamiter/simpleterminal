vim9script

# Real Vim jobs and popup terminals. The remote provider identity is a fixture;
# its command runs a local shell to observe exactly which job receives input.
set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
runtime plugin/simpleterminal.vim

const TMP = tempname()
mkdir(TMP, 'p')
var seq = 0
var session_name = 'remote:proj'
var workspace = {id: 1, kind: 'ssh', target: 'fixture', root: '/srv/project'}
def g:SimpleRemoteTerminalSpec(_argument: string = ''): dict<any>
  seq += 1
  var path = TMP .. '/' .. seq
  var script = 'while IFS= read -r line; do printf "%s\\n" "$line" >> ' .. shellescape(path) .. '; done'
  return {command: ['sh', '-c', script], remote: true, name: session_name, workspace: copy(workspace)}
enddef

def PopupBuffer(): number
  return winbufnr(simpleterminal#State().popup)
enddef

def Captured(Action: func): string
  var messages = ''
  redir => messages
  silent Action()
  redir END
  return messages
enddef

def WaitFor(path: string): list<string>
  for _ in range(100)
    if filereadable(path)
      var rows = readfile(path)
      if !empty(rows)
        return rows
      endif
    endif
    sleep 10m
  endfor
  return []
enddef

try
  g:simpleremote_workspace = copy(workspace)
  var one = simpleterminal#Run('')
  assert_true(one > 0, 'first shell did not start')
  SimpleTerminalAlias @tests
  assert_equal(' @tests · remote:proj ', popup_getoptions(simpleterminal#State().popup).title)
  var two = simpleterminal#Run('')
  assert_true(two > 0 && two != one, 'second shell did not start')
  var ambiguous = Captured(() => simpleterminal#Select('remote:proj'))
  assert_match('ambiguous session name', ambiguous)
  assert_equal(two, PopupBuffer(), 'duplicate name silently selected a different shell')
  assert_false(index(simpleterminal#Complete('', '', 0), 'remote:proj') >= 0)
  var duplicate = Captured(() => simpleterminal#SetAlias('@tests'))
  assert_match('alias already in use', duplicate)
  assert_match('must be @', Captured(() => simpleterminal#SetAlias('@bad name')))
  assert_match('must be @', Captured(() => simpleterminal#SetAlias('@1bad')))
  assert_match('must be @', Captured(() => simpleterminal#SetAlias('@' .. repeat('x', 33))))
  SimpleTerminalAlias @julia
  assert_equal(['@julia'], getcompletion('SimpleTerminalSelect @j', 'cmdline'))
  var listing = Captured(simpleterminal#List)
  assert_match(printf('%d  R  remote:proj  ssh:fixture  running  @tests  /srv/project', one), listing)
  assert_match(printf('%d  R  remote:proj  ssh:fixture  running  @julia  /srv/project', two), listing)

  SimpleTerminalSelect @tests
  assert_equal(one, PopupBuffer())
  SimpleTerminalSend only-first
  assert_equal(['only-first'], WaitFor(TMP .. '/1'))
  assert_false(filereadable(TMP .. '/2'), 'wrong shell received payload')
  execute 'SimpleTerminalSelect ' .. two
  assert_equal(two, PopupBuffer())
  SimpleTerminalSend only-second
  assert_equal(['only-second'], WaitFor(TMP .. '/2'))
  assert_equal(['only-first'], readfile(TMP .. '/1'))

  # Both names remain ambiguous after detaching. An explicit alias still
  # refers to the same terminal without altering its workbench policy.
  g:simpleremote_event = extend({event: 'SimpleRemoteDisconnected'}, workspace, 'keep')
  unlet g:simpleremote_workspace
  doautocmd <nomodeline> User SimpleRemoteDisconnected
  assert_match('ambiguous session name', Captured(() => simpleterminal#Select('remote:proj')))
  assert_match('ambiguous session name', Captured(() => simpleterminal#Select('remote:proj (detached)')))
  SimpleTerminalSelect @tests
  assert_equal(one, PopupBuffer())
  assert_equal({}, simpleterminal#WorkbenchTarget('', workspace))
  assert_equal(' @tests · remote:proj (detached) ', popup_getoptions(simpleterminal#State().popup).title)
  workspace.id = 2
  g:simpleremote_workspace = copy(workspace)
  g:simpleremote_event = extend({event: 'SimpleRemoteConnected'}, workspace, 'keep')
  doautocmd <nomodeline> User SimpleRemoteConnected
  assert_equal({buffer: one}, simpleterminal#WorkbenchTarget('', workspace))
  assert_equal(' @tests · remote:proj ', popup_getoptions(simpleterminal#State().popup).title)
  SimpleTerminalAlias
  assert_equal([], getcompletion('SimpleTerminalSelect @tests', 'cmdline'))
  assert_match('no session named @tests', Captured(() => simpleterminal#Select('@tests')))
  assert_equal(one, PopupBuffer())
  SimpleTerminalSelect @julia
  assert_equal(two, PopupBuffer())
  SimpleTerminalKill
  assert_equal([], getcompletion('SimpleTerminalSelect @julia', 'cmdline'))
  execute 'SimpleTerminalSelect ' .. one
  SimpleTerminalAlias @julia
  assert_equal(['@julia'], getcompletion('SimpleTerminalSelect @julia', 'cmdline'))
  var last = simpleterminal#Run('')
  var dead_job = term_getjob(last)
  job_stop(dead_job)
  for _ in range(100)
    if job_status(dead_job) ==# 'dead'
      break
    endif
    sleep 10m
  endfor
  assert_equal('dead', job_status(dead_job))
  # Pruning can move the logical current slot while Vim still displays the
  # old terminal. Do not attach the requested label to its live neighbour.
  simpleterminal#State()
  assert_equal(last, PopupBuffer())
  assert_match('no live current terminal to label', Captured(() => simpleterminal#SetAlias('@wrong')))
  assert_equal(['@julia'], getcompletion('SimpleTerminalSelect @', 'cmdline'))
  SimpleTerminalSelect @julia
  SimpleTerminalKill
  assert_match('no live current terminal to label', Captured(() => simpleterminal#SetAlias('@none')))
finally
  delete(TMP, 'rf')
endtry

if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
