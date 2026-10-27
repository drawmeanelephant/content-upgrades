.PHONY: all test eval ratchet-eval voice-eval demo engines clean

# Pinned engine binaries; the pins live in scripts/engines.sh. Override for
# one run with `make eval KNAP_K4O_PATH=...`.
export KNAP_K4O_PATH := $(shell scripts/engines.sh path k4o)
export KNAP_DOGBED_PATH := $(shell scripts/engines.sh path dogbed)

all:
	cd knap-mcp && zig build

test:
	cd knap-mcp && zig build test

eval: all engines
	cd knap-mcp && zig-out/bin/knap-mcp eval --corpus eval/seeds.json
	cd knap-mcp && zig-out/bin/knap-mcp eval --corpus eval/seeds.2nap.json

ratchet-eval: all engines
	cd knap-mcp && zig-out/bin/knap-mcp ratchet-eval

voice-eval: all engines
	knap-mcp/eval/voice/run.sh

# Every storyboard beat as one scripted run on the mock backend; transcript
# and artifacts land in demo/out/demo/ (see demo/run.sh).
demo: all engines
	demo/run.sh

engines:
	@scripts/engines.sh

clean:
	rm -rf knap-mcp/zig-out knap-mcp/.zig-cache knap-mcp/.knap-mcp
