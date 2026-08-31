# herdr.el

`herdr.el` is an Emacs 29.1+ client for [Herdr](https://herdr.dev), the persistent terminal workspace manager. Herdr owns agent processes, terminals, tabs, and workspaces. Emacs owns attached terminal views and, for Claude, a loopback editor endpoint with file, diagnostic, context, and diff operations.

## Install

Install `websocket` 1.12+ and `transient` 0.9.0+ from a configured package archive. Terminal attachment also requires one of Ghostel, vterm, or Eat.

```elisp
(use-package herdr
  :load-path "~/src/herdr.el"
  :commands (herdr-attach-agent herdr-attach-pane herdr-jump))

(use-package herdr-transient
  :load-path "~/src/herdr.el"
  :commands herdr-transient
  :bind (("C-c h" . herdr-transient)))
```

Set `herdr-terminal-backend` when automatic backend selection is unsuitable. The package installs no global keybinding itself.

## Agent workflows

`herdr-agent.el` provides one lifecycle for Claude Code, Codex, and Pi.

| Operation | Meaning |
| --- | --- |
| start | Create a Herdr tab and start a new harness session. |
| continue | Continue the harness's latest session in a new tab. |
| resume | Resume a named harness session reference in a new tab. |
| adopt | Attach an already-running Herdr agent without starting another CLI. |
| detach | Release the Emacs terminal and integration state; keep the Herdr pane and agent alive. |
| stop | Close one agent's Herdr pane. |
| stop all | Close every reported agent pane on the selected server. |

Use `herdr-agent-start`, `herdr-agent-continue`, and `herdr-agent-resume` from Lisp. `herdr-agent-stop` takes a composite `(server-key . terminal-id)` target. Existing work is available through `herdr-attach-agent`, `herdr-attach-pane`, `herdr-attach-session`, and `herdr-jump`.

A harness is one registry entry: its display label, native start/continue/resume arguments, and an optional phase-aware adapter.

```elisp
(herdr-agent-register-harness
 "aider"
 :label "Aider"
 :arguments '((start)
              (continue "--continue")
              (resume "--resume" :reference)))
```

The adapter contract is `(session phase &optional context)`. Generic harnesses need no adapter. The Herdr server must support the registered kind.

## Transient

`C-c h` opens the canonical Herdr menu:

```text
Session:  s start       c continue      r resume
Agent:    j switch      p prompt        n rename
          e escape      RET return      k stop       K stop all
Attach:   a agent       P pane          A session
          J jump        R route project
Status:   i status      C customize     I Claude
```

`C-c h I` opens Claude actions for adoption, explicit connection, auto-adoption, at-mention, status, and protocol logging. Opening either menu starts no process or transport and does not load the Claude protocol stack.

## Claude editor integration

Every adopted Claude session gets its own loopback WebSocket MCP endpoint and discovery lockfile under `~/.claude/ide`, or `$CLAUDE_CONFIG_DIR/ide` when configured. The generic agent lifecycle invokes the Claude adapter; there is no second attach route.

`herdr-claude-connect-on-adopt` controls when Herdr sends `/ide`: `idle` connects an idle agent, `t` always requests connection, and nil requires `M-x herdr-claude-connect`. `M-x herdr-claude-auto-adopt-mode` adopts matching agents according to `herdr-claude-auto-adopt-predicate`.

`M-x herdr-claude-at-mention` sends the current file or active region to the initialized Claude connection for that project. The endpoint also provides selection updates, visited-buffer diagnostics, file opening, tab closing, and editable Ediff-backed diffs.

`executeCode` evaluates Emacs Lisp only when `herdr-claude-enable-elisp-tool` is non-nil. Keep it disabled for untrusted sessions. Raw payload logging is also disabled by default; enable `herdr-claude-protocol-logging` only while debugging and inspect it with `M-x herdr-claude-debug-open-log`.

## Ownership and security

Herdr remains authoritative for process lifetime and terminal input. Emacs owns terminal buffers, Claude endpoints, editor views, diagnostics, and diffs. Killing an Emacs buffer or detaching a session never stops the Herdr agent; use `herdr-agent-stop` to end it.

Claude endpoints bind only to loopback. Discovery files are mode `0600`. Editor paths stay inside the adopted project root, raw logging is opt-in, and Elisp execution is opt-in.

## Platforms

| Platform | Emacs | Status |
| --- | --- | --- |
| Ubuntu | 29.1, 30.1 | Supported |
| macOS | 29.1, 30.1 | Supported |
| Windows | 29.1, 30.1 | Supported |

CI also runs an experimental, soft-failing Ubuntu snapshot job.

## Troubleshooting

- `no terminal backend`: install Ghostel, vterm, or Eat, or set `herdr-terminal-backend`.
- `No herdr server`: start Herdr, or allow `herdr-auto-start-server` for the selected session.
- Claude does not connect: run `M-x herdr-claude-connect` and confirm the agent is idle.
- Claude has no editor context: confirm the connection initialized and the current file belongs to the adopted project.
- A terminal is read-only: enable `herdr-attach-takeover` when attaching to transfer input ownership.
- A diff remains: reject or accept it, or detach the Claude integration; the Herdr pane remains alive.

## License and attribution

herdr.el is GPL-3.0-or-later; see [LICENSE](LICENSE). Earlier versions included material adapted from [manzaltu/claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el), also GPL-3.0-or-later. That external bridge is absent from the runtime implementation.
