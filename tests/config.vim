vim9script

set nocompatible nomore
var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)

g:simpleterminal_width = 50.0
g:simpleterminal_height = -10
g:simpleterminal_border = 'yes'
g:simpleterminal_prefer_remote = []
g:simpleterminal_shell = {}
g:simpleterminal_remote_on_disconnect = 'explode'
execute 'source ' .. fnameescape(root .. '/plugin/simpleterminal.vim')

assert_equal(50, g:simpleterminal_width)
assert_equal(20, g:simpleterminal_height)
assert_equal(1, g:simpleterminal_border)
assert_equal(1, g:simpleterminal_prefer_remote)
assert_equal('', g:simpleterminal_shell)
assert_equal('keep', g:simpleterminal_remote_on_disconnect)

var remote_invalid = false
def g:SimpleRemoteTerminalSpec(_argument: string = ''): dict<any>
  if remote_invalid
    return {command: []}
  endif
  throw 'remote provider exploded'
enddef
var health = execute('silent simpleterminal#Health()')
assert_match('remote spec: error: .*remote provider exploded', health)

def BrokenProvider(_argument: string): dict<any>
  throw 'custom provider exploded'
enddef
g:SimpleTerminalSpecProvider = BrokenProvider
g:simpleterminal_prefer_remote = 0
g:simpleterminal_shell = {}
var output = execute("silent simpleterminal#New('sleep 30')")
assert_match('terminal spec provider failed: .*custom provider exploded', output)
assert_equal(0, len(simpleterminal#State().sessions),
  'a broken provider must not fall back to a local terminal')
simpleterminal#New('sleep 30', true)
assert_equal(1, len(simpleterminal#State().sessions), 'explicit local bypass failed')
simpleterminal#Kill()

def EmptyArgumentProvider(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30', ''], name: 'empty-argument'}
enddef
g:SimpleTerminalSpecProvider = EmptyArgumentProvider
simpleterminal#New('')
assert_equal('empty-argument', simpleterminal#State().sessions[0].name,
  'an empty non-executable argv item remains a valid provider argument')
simpleterminal#Kill()

def InvalidProvider(_argument: string): dict<any>
  return {command: []}
enddef
g:SimpleTerminalSpecProvider = InvalidProvider
assert_equal(-1, simpleterminal#Run('sleep 30'))
assert_equal([], simpleterminal#State().sessions)
unlet g:SimpleTerminalSpecProvider
g:simpleterminal_prefer_remote = 1
assert_equal(-1, simpleterminal#Run('sleep 30'), 'throwing remote provider ran locally')
assert_equal([], simpleterminal#State().sessions)
remote_invalid = true
assert_equal(-1, simpleterminal#Run('sleep 30'), 'invalid remote provider ran locally')
assert_equal([], simpleterminal#State().sessions)
delfunction g:SimpleRemoteTerminalSpec
# A missing provider cannot erase an active remote workspace either.
g:simpleremote_status = 'connecting ssh:host'
assert_equal(-1, simpleterminal#Run('sleep 30'))
unlet g:simpleremote_status

def g:VimrcProjectRoot(): any
  throw 'project root exploded'
enddef
var exploded = execute('silent simpleterminal#New("sleep 30")')
assert_notmatch('project root exploded', exploded)
assert_equal(1, len(simpleterminal#State().sessions),
  'a throwing VimrcProjectRoot() took New() down')
simpleterminal#Kill()
delfunction g:VimrcProjectRoot

def g:VimrcProjectRoot(): any
  return 12
enddef
simpleterminal#New('sleep 30')
assert_equal(1, len(simpleterminal#State().sessions),
  'a numeric VimrcProjectRoot() took New() down')
simpleterminal#Kill()
delfunction g:VimrcProjectRoot

# A requested working directory is part of the command's execution target.
# Refusing a bad cwd must leave the existing terminal and popup untouched.
var cwd_fixture = tempname()
mkdir(cwd_fixture, 'p')
var output_path = cwd_fixture .. '/ran.txt'
writefile(['not a directory'], cwd_fixture .. '/plain-file')
var requested_cwd = ''
def CwdProvider(_argument: string): dict<any>
  return {command: ['sh', '-c', 'pwd > ' .. shellescape(output_path) .. '; sleep 30'],
    cwd: requested_cwd, name: 'cwd-check', remote: false}
enddef
simpleterminal#New('sleep 30', true)
var original = simpleterminal#State()
g:SimpleTerminalSpecProvider = CwdProvider
for bad_cwd in [cwd_fixture .. '/missing', cwd_fixture .. '/plain-file']
  requested_cwd = bad_cwd
  var result = 0
  var cwdmsg = execute('result = simpleterminal#Run("")')
  assert_equal(-1, result, 'invalid cwd started a command in another directory')
  assert_match('cwd is not a directory.*refusing to start', cwdmsg)
  sleep 50m
  assert_false(filereadable(output_path), 'command ran despite invalid cwd')
  var after = simpleterminal#State()
  assert_equal(original.sessions, after.sessions, 'failed start changed sessions')
  assert_equal(original.current, after.current, 'failed start changed current')
  assert_equal(original.popup, after.popup, 'failed start replaced the popup')
  # Also reap any wrongly-created job when testing the old implementation.
  if result > 0
    simpleterminal#Kill()
    simpleterminal#Show()
    original = simpleterminal#State()
    delete(output_path)
  endif
endfor
simpleterminal#Kill()

# Valid directories with spaces and an explicitly empty cwd still work.
mkdir(cwd_fixture .. '/with spaces', 'p')
for good_cwd in [cwd_fixture .. '/with spaces', '']
  requested_cwd = good_cwd
  var result = simpleterminal#Run('')
  assert_true(result > 0, 'valid cwd was refused')
  for attempt in range(100)
    if filereadable(output_path) && !empty(readfile(output_path))
      break
    endif
    sleep 10m
  endfor
  assert_true(filereadable(output_path))
  if filereadable(output_path)
    assert_equal([empty(good_cwd) ? getcwd() : good_cwd], readfile(output_path))
  endif
  simpleterminal#Kill()
  delete(output_path)
endfor
unlet g:SimpleTerminalSpecProvider
delete(cwd_fixture, 'rf')

g:simpleterminal_width = 50.0
g:simpleterminal_height = 40.0
def FloatSpec(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30'], cwd: '/tmp', name: 'float-size',
    remote: false}
enddef
g:SimpleTerminalSpecProvider = FloatSpec
try
  simpleterminal#New('')
catch
  assert_report('float width/height threw: ' .. v:exception)
endtry
assert_equal('float-size', simpleterminal#State().sessions[0].name)
simpleterminal#Kill()
unlet g:SimpleTerminalSpecProvider
g:simpleterminal_width = 82
g:simpleterminal_height = 76

# Unix shellcmdflag may contain separate flags, not one combined argument.
# Run a real shell and verify the complete command (including quoted spaces)
# survives as one argv item after those flags.
if has('unix')
  var saved_shell = &shell
  var saved_flags = &shellcmdflag
  var result_file = tempname()
  &shell = '/bin/sh'
  g:simpleterminal_shell = ''
  for flags in ['-c', "  -e\t-c  "]
    &shellcmdflag = flags
    var command = "printf '%s\n' 'two words' 'literal; value' > "
      .. shellescape(result_file) .. '; sleep 30'
    simpleterminal#New(command, true)
    for attempt in range(100)
      if filereadable(result_file)
          && readfile(result_file) == ['two words', 'literal; value']
        break
      endif
      sleep 10m
    endfor
    assert_true(filereadable(result_file), 'shell flags failed: ' .. flags)
    if filereadable(result_file)
      assert_equal(['two words', 'literal; value'], readfile(result_file))
    endif
    simpleterminal#Kill()
    delete(result_file)
  endfor
  &shell = saved_shell
  &shellcmdflag = saved_flags
endif

g:simpleterminal_remote_on_disconnect = 'KILL'
var health_kill = execute('silent simpleterminal#Health()')
assert_match('on disconnect: kill', health_kill)
g:simpleterminal_remote_on_disconnect = 'keep'

if !empty(v:errors)
  writefile(v:errors, root .. '/tests/config-errors.log')
  cquit!
endif
delete(root .. '/tests/config-errors.log')
qall!
