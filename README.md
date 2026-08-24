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

## claude-code-ide bridge

With `herdr-claude-code-ide-mode` on, `M-x claude-code-ide` creates a herdr tab
in the project directory, starts the Claude CLI there, and attaches the
claude-code-ide buffer to it. The CLI inherits `CLAUDE_CODE_SSE_PORT`, so MCP —
ediff, at-mentions, diagnostics — works exactly as it does with a locally
spawned CLI. The conversation survives Emacs restarts and shows up in the herdr
UI alongside every other agent.

The other direction:

- `M-x herdr-claude-code-ide-adopt` wraps a claude that is already running in
  herdr in a claude-code-ide session.
- `herdr-claude-code-ide-auto-adopt-mode` does that for every claude herdr
  detects whose directory is a project Emacs knows
  (`herdr-claude-code-ide-auto-adopt-predicate`).
- An adopted CLI started before its MCP server existed, so it is not connected
  yet: `M-x herdr-claude-code-ide-connect-ide` sends `/ide` to it, and you pick
  the Emacs entry in Claude's picker.

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
