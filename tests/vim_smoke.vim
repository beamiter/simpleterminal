vim9script

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleterminal.vim')

def TestSpec(_argument: string): dict<any>
  return {
    command: ['sh', '-c', 'printf simpleterminal-ready; sleep 2'],
    cwd: '/tmp',
    name: 'test-shell',
    remote: false,
  }
enddef
g:SimpleTerminalSpecProvider = TestSpec

simpleterminal#New('')
var state = simpleterminal#State()
assert_equal(1, len(state.sessions))
assert_equal('test-shell', state.sessions[0].name)
assert_true(state.popup > 0)
simpleterminal#Hide()
assert_equal(0, simpleterminal#State().popup)
simpleterminal#Show()
assert_true(simpleterminal#State().popup > 0)
simpleterminal#Kill()
assert_equal(0, len(simpleterminal#State().sessions))

assert_equal(2, exists(':SimpleTerminalToggle'))
assert_match('simpleterminal', maparg('<Plug>(simpleterminal-toggle)', 'n'))
if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif
qa!
