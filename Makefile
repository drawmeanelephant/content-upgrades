.PHONY: all test eval engines clean

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

engines:
	@scripts/engines.sh

clean:
	rm -rf knap-mcp/zig-out knap-mcp/.zig-cache knap-mcp/.knap-mcp
