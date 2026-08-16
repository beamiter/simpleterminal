.PHONY: check defcompile test lifecycle remote

check: defcompile test lifecycle remote

defcompile:
	vim -N -u NONE -n -es -S tests/defcompile.vim

test:
	vim -N -u NONE -n -es -S tests/vim_smoke.vim

lifecycle:
	vim -N -u NONE -n -es -S tests/lifecycle.vim

remote:
	vim -N -u NONE -n -es -S tests/remote.vim
