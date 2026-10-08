#!/bin/sh
# Tests for bin/herdr-herd against a stub herdr, so no server is contacted.
#
# Run with: sh bin/herdr-herd-tests.sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$root/bin/herdr-herd
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

failures=0

# The stub answers pane list and agent list from files the tests write, and
# records every mutating call in calls.log.
cat >"$work/herdr" <<'STUB'
#!/bin/sh
case "$1 ${2:-}" in
"pane list") cat "$STUB_STATE/panes.json" ;;
"agent list") cat "$STUB_STATE/agents.json" ;;
"pane report-metadata")
	shift 2
	printf 'pane report-metadata %s\n' "$*" >>"$STUB_STATE/calls.log"
	printf '{}\n'
	;;
"agent prompt")
	shift 2
	printf 'agent prompt %s\n' "$*" >>"$STUB_STATE/calls.log"
	printf '{}\n'
	;;
*)
	printf 'stub herdr: unexpected %s\n' "$*" >&2
	exit 64
	;;
esac
STUB
chmod +x "$work/herdr"

# state PANES... — each argument is PANE=HERD|STATUS. An empty HERD means
# the pane carries no herd token; STATUS defaults to idle. Agents are named
# after their pane, except p9, which has only a terminal title.
state() {
	: >"$work/calls.log"
	printf '{"result":{"panes":[' >"$work/panes.json"
	printf '{"result":{"agents":[' >"$work/agents.json"
	sep=
	for pair in "$@"; do
		pane=${pair%%=*}
		rest=${pair#*=}
		herd=${rest%%|*}
		status=${rest#*|}
		[ "$status" != "$rest" ] || status=idle
		printf '%s{"pane_id":"%s"' "$sep" "$pane" >>"$work/panes.json"
		[ -z "$herd" ] || printf ',"tokens":{"herd":"%s"}' "$herd" >>"$work/panes.json"
		printf '}' >>"$work/panes.json"
		if [ "$pane" = w1:p9 ]; then
			name='"terminal_title_stripped":"Fix the parser"'
		else
			name="\"name\":\"a-${pane#*:}\""
		fi
		printf '%s{"pane_id":"%s","agent":"claude","agent_status":"%s",%s}' \
			"$sep" "$pane" "$status" "$name" >>"$work/agents.json"
		sep=,
	done
	printf ']}}\n' >>"$work/panes.json"
	printf ']}}\n' >>"$work/agents.json"
}

run() {
	pane=$1
	shift
	PATH="$work:$PATH" STUB_STATE="$work" HERDR_ENV=1 HERDR_PANE_ID="$pane" \
		HERDR_BIN_PATH="$work/herdr" "$script" "$@"
}

check() {
	label=$1
	want=$2
	got=$3
	if [ "$want" = "$got" ]; then
		printf 'ok   %s\n' "$label"
	else
		printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$label" "$want" "$got"
		failures=$((failures + 1))
	fi
}

state "w1:p1=refactor" "w1:p2=refactor" "w1:p9=refactor" "w1:p3="

check "of reads this pane's herd" \
	"refactor" "$(run w1:p1 of)"
check "of is empty for a pane in no herd" \
	"" "$(run w1:p3 of)"
check "peers leave out the caller" \
	"w1:p2      a-p2
w1:p9      Fix the parser" "$(run w1:p1 peers)"
check "members list the whole herd" \
	"w1:p1      a-p1
w1:p2      a-p2
w1:p9      Fix the parser" "$(run w1:p1 members refactor)"
check "list groups members under their herd" \
	"refactor
  w1:p1      a-p1                             idle
  w1:p2      a-p2                             idle
  w1:p9      Fix the parser                   idle" "$(run w1:p1 list)"

run w1:p3 join refactor >/dev/null
check "join sets the herd token" \
	"pane report-metadata w1:p3 --source herdr-herd --token herd=refactor" \
	"$(cat "$work/calls.log")"

state "w1:p1=refactor"
run w1:p1 leave >/dev/null
check "leave clears the herd and any leftover id" \
	"pane report-metadata w1:p1 --source herdr-herd --clear-token herd --clear-token herd_id" \
	"$(cat "$work/calls.log")"

state "w1:p1=refactor" "w1:p2=refactor|working" "w1:p3=refactor"
run w1:p1 say hello >/dev/null 2>&1
check "say reaches the idle peers only, by pane" \
	"agent prompt w1:p3 [refactor] w1:p1: hello" "$(cat "$work/calls.log")"

state "w1:p1=refactor" "w1:p2=other" "w1:p3=refactor"
run w1:p1 tell w1:p3 hi there >/dev/null
check "tell prompts a member of the caller's herd" \
	"agent prompt w1:p3 hi there" "$(cat "$work/calls.log")"

# A refusal exits non-zero, which `set -e' would otherwise make fatal here.
status() {
	code=0
	"$@" >/dev/null 2>&1 || code=$?
	printf '%s' "$code"
}

state "w1:p1=refactor" "w1:p2=other"
check "a herd name with whitespace is refused" \
	"1" "$(status run w1:p1 join 'two words')"
check "a refused join reports nothing" "" "$(cat "$work/calls.log")"
check "telling a pane of another herd is refused" "1" "$(status run w1:p1 tell w1:p2 hi)"
check "a refused tell prompts nobody" "" "$(cat "$work/calls.log")"

state "w1:p1="
check "leaving no herd is refused" "1" "$(status run w1:p1 leave)"

check "an unknown command is refused" "1" "$(status run w1:p1 stampede)"

outside() {
	PATH="$work:$PATH" STUB_STATE="$work" HERDR_ENV=0 "$script" of
}
check "a pane outside herdr is refused" "1" "$(status outside)"

if [ "$failures" -eq 0 ]; then
	printf '\nall checks passed\n'
else
	printf '\n%d check(s) failed\n' "$failures"
	exit 1
fi
