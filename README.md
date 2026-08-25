# herdr.el

Emacs client for [herdr](https://herdr.dev), the terminal workspace manager for
coding agents. Talks to herdr's newline-delimited JSON socket API, attaches
server-owned terminals into Emacs terminal buffers, and bridges herdr sessions
with `claude-code-ide.el` in both directions.

## Layers

| File | What it is |
| --- | --- |
| `herdr-core.el` | socket client — `herdr-request`, `herdr-subscribe`, errors, customs |
| `herdr-api.el` | one wrapper per API method, generated from the installed herdr's schema |
| `herdr.el` | attaching terminals, completion, interactive commands |
| `herdr-claude-code-ide.el` | claude-code-ide bridge |

## Install

```elisp
(use-package herdr
  :load-path "~/projects/herdr.el"
  :commands (herdr-attach-agent herdr-attach-pane))

(use-package herdr-claude-code-ide
  :after claude-code-ide
  :config (herdr-claude-code-ide-mode 1))
```

Terminal buffers use ghostel, vterm or eat — whichever is installed, or set
`herdr-terminal-backend`.

## Attaching a terminal

`M-x herdr-attach-agent` lists the agents herdr is running and opens the chosen
one in an Emacs terminal buffer. `M-x herdr-attach-pane` does the same for any
pane. Input goes straight to the herdr terminal; killing the buffer detaches
and leaves the process running.

With the claude-code-ide bridge loaded, picking a claude agent opens a real
claude-code-ide session around it instead of a bare terminal. Anything else in
`herdr-attach-functions` gets the same chance to claim an entry first; the plain
terminal attach runs when they all decline.

Attached terminals open in a dedicated side window (`herdr-window-side`,
`herdr-window-width`, `herdr-window-height`), each in its own slot so several
of them sit next to each other. Slots start at `herdr-window-slot-base`, high
enough to stay clear of other side-window users such as claude-code-ide. Set
`herdr-display-buffer-action` for a different placement, or
`herdr-use-side-window` to nil to hand placement over to `display-buffer-alist`
or a popup framework.

Only one writable client owns a terminal at a time, so attaching takes input
ownership by default (`herdr-attach-takeover`). The herdr UI keeps rendering
the same terminal, read-only, until it takes ownership back.

## One herdr server, or one of your own

`herdr-session` picks which server Emacs talks to:

| Value | Meaning |
| --- | --- |
| `shared` (default) | the session a bare `herdr` attaches to, so Emacs sessions sit next to hand-run agents in the herdr UI |
| `emacs` | a session of its own, named by `herdr-emacs-session-name` — reach it from a terminal with `herdr --session emacs` |
| a string | that session by name |

A session is a whole server namespace: its own socket, state directory and
persistence. Emacs passes the choice to every herdr command it runs, so an
attached terminal reaches the same server the API calls do. `herdr-socket-path`
overrides the lot with a raw socket path when you know exactly which server you
mean.

Sessions of your own start empty, and tabs need a workspace, so `herdr-new-tab`
opens one in a session that has none.

## Jumping between sessions

`M-x herdr-jump` completes over everything running — herdr's agents plus the
claude-code-ide sessions this Emacs owns — and shows the one you pick, attaching
its terminal first if no buffer has it yet. Entries are grouped by kind and
annotated with agent, status and directory. One terminal appears once: an agent
that already has a buffer wins over the bare herdr entry.

`herdr-session-functions` collects the entries, so other session sources can add
themselves.

## Integration points

| Hook / variable | Use |
| --- | --- |
| `herdr-attach-functions` | claim an entry before the plain terminal attach |
| `herdr-buffer-functions` | see every buffer that starts showing a terminal |
| `herdr-terminal-id` | buffer-local id of the terminal a buffer shows |
| `herdr-terminal-buffer` | find the live buffer for a terminal id |
| `herdr-session-functions` | contribute entries to `herdr-jump` |
| `herdr-entry-annotation-functions` | add fields to completion annotations |

Together they are enough to bind sessions to an editor-side notion of place —
pinning each terminal to the workspace its project owns, say, and following that
pin when jumping.

## claude-code-ide bridge

With `herdr-claude-code-ide-mode` on, `M-x claude-code-ide` creates a herdr tab
in the project directory, starts the Claude CLI there, and attaches the
claude-code-ide buffer to it. No session escapes that route:
`herdr-claude-code-ide-require-herdr` refuses to start one when herdr cannot be
reached rather than falling back to an Emacs-owned CLI, and
`herdr-auto-start-server` starts a headless herdr server first when none is
running (detached, so it outlives Emacs). Set the first to nil to allow the
plain claude-code-ide behaviour as a fallback. The CLI inherits `CLAUDE_CODE_SSE_PORT`, so MCP —
ediff, at-mentions, diagnostics — works exactly as it does with a locally
spawned CLI. The conversation survives Emacs restarts and shows up in the herdr
UI alongside every other agent.

The other direction — a claude that herdr already runs becomes a session:

- attaching it (`herdr-attach-agent`, `herdr-attach-pane`) adopts it, unless
  `herdr-claude-code-ide-adopt-on-attach` is nil.
- `M-x herdr-claude-code-ide-adopt` does the same on demand.
- `herdr-claude-code-ide-auto-adopt-mode` adopts every claude herdr detects
  whose directory is a project Emacs knows
  (`herdr-claude-code-ide-auto-adopt-predicate`).

The session is named after the herdr agent — its rename, else its terminal
title (`herdr-claude-code-ide-instance-name-function`) — so several agents in
one project become `*claude-code[project:name]*` buffers without prompting.
Adopting the same terminal twice reuses the session it already has.

An adopted CLI started before its MCP server existed, so it is not connected to
Emacs yet. `herdr-claude-code-ide-connect-on-adopt` sends `/ide` for you while
the agent is idle (the default), always, or never; `M-x
herdr-claude-code-ide-connect-ide` does it on demand. Claude answers with its
IDE picker — pick the Emacs entry there.

Caveat worth knowing: `claude-code-ide-stop` and killing the buffer end the
*attachment*, not the CLI. Close the herdr tab to end the conversation.

## API wrappers

Every method of the socket API has a function — `herdr-api-pane-split`,
`herdr-api-agent-prompt`, `herdr-api-workspace-create`, and 86 more. Required
parameters are positional, the rest are keywords; nil keywords are omitted from
the request, and `:false` sends a literal false.

```elisp
(herdr-api-tab-create :cwd "~/src/app" :label "tests" :env '((CI . "1")))
(herdr-api-pane-send-text "w1:p2" "cargo test\n")
(herdr-subscribe '("pane.agent_status_changed") #'my-handler)
```

Calls that wait on the server (`herdr-api-agent-wait`,
`herdr-api-pane-wait-for-output`) need a longer `herdr-request-timeout` bound
around them.

Regenerate the wrappers after a herdr upgrade:

```bash
herdr api schema --json > /tmp/herdr-api.schema.json
emacs -Q --batch -l tools/herdr-api-gen.el \
      --eval '(herdr-api-gen "/tmp/herdr-api.schema.json" "herdr-api.el")'
```

## Tests

```bash
emacs -Q --batch -L . -l herdr-tests.el -f ert-run-tests-batch-and-exit
```

The socket tests run against a fake server; the one test that needs a real
herdr skips itself when none is running.
