.PHONY: test

test:
	nvim -l tests/run.lua
	node --test tests/session_log_spec.js
