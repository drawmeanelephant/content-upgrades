.PHONY: all test eval clean

all:
	cd knap-mcp && zig build

test:
	cd knap-mcp && zig build test

eval: all
	cd knap-mcp && zig-out/bin/knap-mcp eval --corpus eval/seeds.json

clean:
	rm -rf knap-mcp/zig-out knap-mcp/.zig-cache knap-mcp/.knap-mcp
