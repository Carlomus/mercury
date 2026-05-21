.PHONY: test test-lua test-python test-file lint

NVIM ?= nvim
PYTHON ?= python3

# Run the full suite — lua specs via plenary, then python specs via unittest.
test: test-lua test-python

test-lua:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
	  -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua', sequential = true })" \
	  -c "qa!"

# Bridge tests are pure-stdlib unittests; no jupyter_client or ipykernel
# needed because the worker / kernel client are stubbed.
test-python:
	$(PYTHON) -m unittest discover -s tests/python -t . -v

test-file:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedFile $(FILE)" \
	  -c "qa!"

lint:
	@stylua --check . || true
	@luacheck . --globals vim || true
