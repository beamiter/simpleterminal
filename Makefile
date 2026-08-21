.PHONY: check defcompile test lifecycle remote config doc-tags

check: doc-tags defcompile test lifecycle remote config

# Vim help uses *word* as a global tag definition, not Markdown emphasis.
# Generate tags in a scratch directory so the gate catches accidental prose
# tags.  doc/tags is installation output in this repository and is ignored.
doc-tags:
	@tmp=$$(mktemp -d) && cp doc/*.txt $$tmp/ && \
	vim -Nu NONE -n -i NONE -es -c "helptags $$tmp" -c 'qa!' </dev/null && \
	status=0; \
	foreign=$$(awk -F'\t' '$$1 !~ /^(simpleterminal|g:simpleterminal|g:SimpleTerminal|:SimpleTerminal|<Plug>\(simpleterminal)/ { print $$1 }' $$tmp/tags); \
	if [ -n "$$foreign" ]; then \
	  echo "doc: *word* in prose defined a global help tag: $$foreign" >&2; status=1; fi; \
	rm -rf $$tmp; \
	[ $$status -eq 0 ] && echo "doc: help tags are valid and plugin-scoped"

defcompile:
	vim -N -u NONE -n -i NONE -es -S tests/defcompile.vim

test:
	vim -N -u NONE -n -i NONE -es -S tests/vim_smoke.vim

lifecycle:
	vim -N -u NONE -n -i NONE -es -S tests/lifecycle.vim

remote:
	vim -N -u NONE -n -i NONE -es -S tests/remote.vim

config:
	vim -N -u NONE -n -i NONE -es -S tests/config.vim
