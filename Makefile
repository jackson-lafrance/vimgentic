.PHONY: test

test:
	nvim -l tests/run.lua
	node --test tests/*_spec.js
