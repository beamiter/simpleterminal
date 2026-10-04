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

def g:SimpleRemoteTerminalSpec(_argument: string = ''): dict<any>
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
assert_equal(1, len(simpleterminal#State().sessions),
  'a broken provider still falls back to a local terminal')
simpleterminal#Kill()

def EmptyArgumentProvider(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30', ''], name: 'empty-argument'}
enddef
g:SimpleTerminalSpecProvider = EmptyArgumentProvider
simpleterminal#New('')
assert_equal('empty-argument', simpleterminal#State().sessions[0].name,
  'an empty non-executable argv item remains a valid provider argument')
simpleterminal#Kill()

unlet g:SimpleTerminalSpecProvider
delfunction g:SimpleRemoteTerminalSpec

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

def BadCwd(_argument: string): dict<any>
  return {command: ['sh', '-c', 'sleep 30'], cwd: '/etc/hostname',
    name: 'bad-cwd', remote: false}
enddef
g:SimpleTerminalSpecProvider = BadCwd
var cwdmsg = execute('silent simpleterminal#New("")')
assert_match('cwd is not a directory', cwdmsg)
assert_equal('bad-cwd', simpleterminal#State().sessions[0].name)
simpleterminal#Kill()
unlet g:SimpleTerminalSpecProvider

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
