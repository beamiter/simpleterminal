.PHONY: check defcompile test lifecycle

check: defcompile test lifecycle

defcompile:
	vim -N -u NONE -n -es -S tests/defcompile.vim

test:
	vim -N -u NONE -n -es -S tests/vim_smoke.vim

lifecycle:
	vim -N -u NONE -n -es -S tests/lifecycle.vim
