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
"pane rename")
	shift 2
	printf 'pane rename %s\n' "$*" >>"$STUB_STATE/calls.log"
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

# state PANE-LABEL-PAIRS... — each argument is PANE=LABEL, an empty LABEL
# meaning the pane carries none. Agents are named after their pane.
state() {
	: >"$work/calls.log"
	printf '{"result":{"panes":[' >"$work/panes.json"
	printf '{"result":{"agents":[' >"$work/agents.json"
	sep=
	for pair in "$@"; do
		pane=${pair%%=*}
		rest=${pair#*=}
		label=${rest%%|*}
		status=${rest#*|}
		[ "$status" != "$rest" ] || status=idle
		printf '%s{"pane_id":"%s"' "$sep" "$pane" >>"$work/panes.json"
		[ -z "$label" ] || printf ',"label":"%s"' "$label" >>"$work/panes.json"
		printf '}' >>"$work/panes.json"
		printf '%s{"pane_id":"%s","agent":"claude","agent_status":"%s","name":"a-%s"}' \
			"$sep" "$pane" "$status" "$pane" >>"$work/agents.json"
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

state "w1:p1=herd:refactor" "w1:p2=herd:refactor notes" "w1:p3="

check "of reads this pane's herd" \
	"refactor" "$(run w1:p1 of)"
check "of is empty for an unlabelled pane" \
	"" "$(run w1:p3 of)"
check "peers leave out the caller" \
	"a-w1:p2" "$(run w1:p1 peers)"
check "members list the whole herd" \
	"a-w1:p1
a-w1:p2" "$(run w1:p1 members refactor)"
check "list groups members under their herd" \
	"refactor
  a-w1:p1                  idle
  a-w1:p2                  idle" "$(run w1:p1 list)"

run w1:p3 join refactor >/dev/null
check "join labels a pane that had none" \
	"pane rename w1:p3 herd:refactor" "$(cat "$work/calls.log")"

state "w1:p1=my own label"
run w1:p1 join refactor >/dev/null
check "join keeps the label a pane already had" \
	"pane rename w1:p1 herd:refactor my own label" "$(cat "$work/calls.log")"

state "w1:p1=herd:refactor my own label"
run w1:p1 leave >/dev/null
check "leave keeps the rest of a label" \
	"pane rename w1:p1 my own label" "$(cat "$work/calls.log")"

state "w1:p1=herd:refactor"
run w1:p1 leave >/dev/null
check "leave clears a label that said nothing else" \
	"pane rename w1:p1 --clear" "$(cat "$work/calls.log")"

state "w1:p1=herd:refactor" "w1:p2=herd:refactor|working" "w1:p3=herd:refactor"
run w1:p1 say hello >/dev/null 2>&1
check "say reaches the idle peers only" \
	"agent prompt a-w1:p3 [refactor] a-w1:p1: hello" "$(cat "$work/calls.log")"

# A refusal exits non-zero, which `set -e' would otherwise make fatal here.
status() {
	code=0
	"$@" >/dev/null 2>&1 || code=$?
	printf '%s' "$code"
}

state "w1:p1=herd:refactor"
check "a herd name with whitespace is refused" \
	"1" "$(status run w1:p1 join 'two words')"
check "a refused join renames nothing" "" "$(cat "$work/calls.log")"

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
