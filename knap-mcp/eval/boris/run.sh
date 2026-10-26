#!/bin/sh
# Lane B3 gate: boris_ask against its oracle, boris_check against labels.
#
# usage: knap-mcp/eval/boris/run.sh [runs]
#
# (a) For each line of queries.tsv (`<limit>\t<query>`, limit `-` = default),
#     diffs `knap-mcp boris-ask <query> [--limit n]` results against
#     `boris-site/ask.sh [-k n] <query>` live, line for line.
# (b) For each entry of claims.json, runs `knap-mcp boris-check <claim>` and
#     compares answer, polarity and matched claim id. Entries marked
#     `known_miss` are expected to be wrong and do not fail the gate.
# (c) Median wall time per call over `runs` (default 30), spawn included.
#
# Needs jq and perl; builds knap-mcp first. Honors KNAP_BORIS_SITE (the
# oracle then runs from that site too).
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../../.." && pwd)
site=${KNAP_BORIS_SITE:-$root/boris-site}
bin=$root/knap-mcp/zig-out/bin/knap-mcp
runs=${1:-30}

(cd "$root/knap-mcp" && zig build)
export KNAP_BORIS_SITE="$site"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# (a) boris-ask vs ask.sh
n=0 ok=0
tab=$(printf '\t')
while IFS="$tab" read -r limit query; do
  n=$((n + 1))
  if [ "$limit" = - ]; then
    "$bin" boris-ask "$query" >"$tmp/out.json"
    "$site/ask.sh" "$query" >"$tmp/want"
  else
    "$bin" boris-ask "$query" --limit "$limit" >"$tmp/out.json"
    "$site/ask.sh" -k "$limit" "$query" >"$tmp/want"
  fi
  jq -c '.results[]' "$tmp/out.json" >"$tmp/got"
  if jq -e --arg q "$query" '.query == $q' "$tmp/out.json" >/dev/null && cmp -s "$tmp/got" "$tmp/want"; then
    ok=$((ok + 1))
    printf 'ask   ok    k=%-2s %3s hits  %s\n' "$limit" "$(wc -l <"$tmp/want" | tr -d ' ')" "$query"
  else
    fail=1
    printf 'ask   FAIL  k=%-2s %s\n' "$limit" "$query"
    diff "$tmp/want" "$tmp/got" | sed 's/^/      /' || true
  fi
done <"$here/queries.tsv"
echo "boris-ask: $ok/$n queries identical to ask.sh"

# (b) boris-check vs labels
total=$(jq length "$here/claims.json")
i=0 ok=0 misses=0
while [ "$i" -lt "$total" ]; do
  jq -c ".[$i]" "$here/claims.json" >"$tmp/case"
  claim=$(jq -r .claim "$tmp/case")
  "$bin" boris-check "$claim" >"$tmp/got"
  verdict=$(jq -r --slurpfile c "$tmp/case" '
    $c[0] as $c
    | [ (.answer == $c.answer),
        ($c | has("polarity") | not) or (.polarity == $c.polarity),
        ($c | has("matched") | not) or (.matched.id // null) == $c.matched ]
    | if all then "ok" else "wrong" end' "$tmp/got")
  summary=$(jq -r '"\(.answer) (\(.polarity // "-"), coverage \(.coverage), \(.matched.title // "no match"))"' "$tmp/got")
  if jq -e '.known_miss // false' "$tmp/case" >/dev/null; then
    misses=$((misses + 1))
    [ "$verdict" = ok ] && label="FIXED" || label="known"
    printf 'check %-5s %-46s -> %s\n' "$label" "$claim" "$summary"
  elif [ "$verdict" = ok ]; then
    ok=$((ok + 1))
    printf 'check ok    %-46s -> %s\n' "$claim" "$summary"
  else
    fail=1
    printf 'check FAIL  %-46s -> %s; want %s\n' "$claim" "$summary" "$(jq -c 'del(.claim, .note)' "$tmp/case")"
  fi
  i=$((i + 1))
done
echo "boris-check: $ok/$((total - misses)) labeled claims right; $misses known misses listed"

# (c) latency
BIN=$bin RUNS=$runs TMP=$tmp perl -MTime::HiRes=gettimeofday,tv_interval -e '
use strict; use warnings;
my ($bin, $runs) = @ENV{qw(BIN RUNS)};
sub series {
  my ($label, @cmd) = @_;
  my @ms;
  for (1 .. $runs) {
    my $t0 = [gettimeofday];
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) { open STDOUT, ">", "/dev/null"; exec @cmd or exit 127; }
    waitpid($pid, 0);
    die "$label: exit " . ($? >> 8) . "\n" if $?;
    push @ms, tv_interval($t0) * 1000;
  }
  my @s = sort { $a <=> $b } @ms;
  my $n = @s;
  my $med = $n % 2 ? $s[$n / 2] : ($s[$n / 2 - 1] + $s[$n / 2]) / 2;
  printf "latency %-44s median %5.1f ms  min %5.1f  max %5.1f  (%d runs)\n", $label, $med, $s[0], $s[-1], $n;
}
series("process floor: knap-mcp --version", $bin, "--version");
series("boris-ask \"managed backups\"", $bin, "boris-ask", "managed backups");
series("boris-ask \"acmedb\" --limit 20", $bin, "boris-ask", "acmedb", "--limit", "20");
series("boris-check \"Does AcmeDB have managed backups?\"", $bin, "boris-check", "Does AcmeDB have managed backups?");
series("boris-check \"AcmeDB supports SQL\"", $bin, "boris-check", "AcmeDB supports SQL");

# In process: one `serve` session of N tools/call requests minus one of N
# pings. Every call loads both artifact files and ranks; nothing is cached.
my $calls = 200;
sub session {
  my ($line) = @_;
  my $file = "$ENV{TMP}/session.jsonl";
  open my $fh, ">", $file or die "$file: $!";
  print $fh sprintf($line, $_), "\n" for 1 .. $calls;
  close $fh;
  my @ms;
  for (1 .. 5) {
    my $t0 = [gettimeofday];
    system("\"$bin\" serve <\"$file\" >/dev/null") == 0 or die "serve failed\n";
    push @ms, tv_interval($t0) * 1000;
  }
  my @s = sort { $a <=> $b } @ms;
  return $s[2];
}
my $ping = session(q({"jsonrpc":"2.0","id":%d,"method":"ping"}));
for my $c (["boris_ask", q({"query":"managed backups"})],
           ["boris_check", q({"claim":"Does AcmeDB have managed backups?"})]) {
  my $t = session(sprintf(q({"jsonrpc":"2.0","id":%%d,"method":"tools/call","params":{"name":"%s","arguments":%s}}), @$c));
  printf "latency %-44s median %5.2f ms per call (load + rank, in process; %d-call session minus %d pings)\n",
    "$c->[0] via MCP serve", ($t - $ping) / $calls, $calls, $calls;
}
'

[ "$fail" -eq 0 ] && echo "boris gate: ok" || { echo "boris gate: FAIL"; exit 1; }
