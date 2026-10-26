#!/bin/sh
# Latency of the boris checks behind knap_publish_check.
#
# usage: bench.sh <clean-doc.md> <bad-doc.md> [runs]
#
# Prints median / min / p90 / max wall time in ms over `runs` (default 20)
# for each case. Timing uses perl's Time::HiRes around fork+exec, so every
# number includes process spawn, as it will for knap-mcp.
set -eu

[ $# -ge 2 ] || { echo "usage: bench.sh <clean-doc.md> <bad-doc.md> [runs]" >&2; exit 2; }
site=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BORIS=${BORIS:-boris}
BORIS=$(command -v "$BORIS")
runs=${3:-20}

stage=$("$site/stage-check.sh" --keep "$1" 2>&1 >/dev/null | sed -n 's/^stage-check: kept //p')
[ -d "$stage" ] || { echo "bench.sh: staging failed" >&2; exit 1; }
trap 'rm -rf "$stage"' EXIT

echo "boris: $BORIS ($("$BORIS" --version)); runs: $runs; host: $(uname -sm)"
BORIS=$BORIS SITE=$site STAGE=$stage CLEAN=$1 BAD=$2 RUNS=$runs perl -MTime::HiRes=gettimeofday,tv_interval -e '
use strict; use warnings;
my ($boris, $site, $stage, $clean, $bad, $runs) = @ENV{qw(BORIS SITE STAGE CLEAN BAD RUNS)};
# Reports go to the staging dir so the frozen site is never written.
my @check = ($boris, "check", "--input", "content", "--format", "json", "--report", "$stage/report.json", "--quiet");
my @validate = ($boris, "validate", "--input", "content", "--report", "$stage/report.json", "--quiet");

sub timed {
  my ($dir, @cmd) = @_;
  my $t0 = [gettimeofday];
  my $pid = fork() // die "fork: $!";
  if ($pid == 0) {
    chdir $dir or exit 126;
    open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
    exec @cmd or exit 127;
  }
  waitpid($pid, 0);
  return (tv_interval($t0) * 1000, $? >> 8);
}

sub fresh {
  my $dir = `mktemp -d "\${TMPDIR:-/tmp}/boris-bench.XXXXXX"`; chomp $dir;
  system("cp", "-R", "$stage/content", "$stage/themes", $dir) == 0 or die "cp failed";
  return $dir;
}

sub report {
  my ($label, $rcs, @ms) = @_;
  my @s = sort { $a <=> $b } @ms;
  my $n = @s;
  my $med = $n % 2 ? $s[$n / 2] : ($s[$n / 2 - 1] + $s[$n / 2]) / 2;
  my $p90 = $s[int(0.9 * ($n - 1) + 0.5)];
  printf "%-44s exit %-3s first %6.1f  median %6.1f  min %6.1f  p90 %6.1f  max %6.1f\n",
    $label, $rcs, $ms[0], $med, $s[0], $p90, $s[-1];
}

sub series {
  my ($label, $setup, @cmd) = @_;
  my (@ms, %rc);
  for (1 .. $runs) {
    my $dir = $setup->();
    my ($t, $rc) = timed($dir, @cmd);
    push @ms, $t; $rc{$rc} = 1;
    system("rm", "-rf", $dir) if $dir =~ m{/boris-bench\.};
  }
  report($label, join("/", sort keys %rc), @ms);
}

printf "%-44s %-8s %s\n", "case", "", "wall ms";
series("process floor: boris --version", sub { $stage }, $boris, "--version");
series("check, frozen site, warm", sub { $site }, @check);
series("check, staged clean doc, warm", sub { $stage }, @check);
series("check, staged clean doc, cold (fresh copy)", \&fresh, @check);
series("validate, staged clean doc, warm", sub { $stage }, @validate);
series("validate, staged clean doc, cold", \&fresh, @validate);
series("stage-check.sh clean doc (end to end)", sub { $stage }, "$site/stage-check.sh", $clean);
series("stage-check.sh bad doc (end to end)", sub { $stage }, "$site/stage-check.sh", $bad);
series("stage-check.sh --validate clean doc", sub { $stage }, "$site/stage-check.sh", "--validate", $clean);
'
