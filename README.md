# herdr.el

`herdr.el` is an Emacs 29.1+ client for [herdr](https://herdr.dev), the persistent terminal workspace manager. Herdr owns the agent process, terminal, tab, and workspace; Emacs attaches a terminal view and, for Claude, provides the native IDE protocol endpoint.

## Install

Install `websocket` 1.12+ and `transient` 0.9.0+ from GNU ELPA or another configured archive, then load the package directory:

```elisp
(use-package herdr
  :load-path "~/src/herdr.el"
  :commands (herdr-attach-agent herdr-attach-pane herdr-jump))

(use-package herdr-agent-transient
  :after herdr
  :commands herdr-agent-transient)

(use-package herdr-claude-code-ide
  :after herdr
  :demand t
  :commands (herdr-claude-code-ide-adopt
             herdr-claude-code-ide-auto-adopt-mode
             herdr-claude-code-ide-connect-ide))
```

Terminal attachment requires one of `ghostel`, `vterm`, or `eat`; set `herdr-terminal-backend` when automatic selection is not suitable.

## Agent workflows

`herdr-agent.el` is the lifecycle surface for Claude Code, Pi, and Codex. `M-x herdr-agent-transient` provides the same operations interactively.

| Operation | Meaning |
| --- | --- |
| start | Creates a herdr tab and starts a new Claude, Pi, or Codex agent. |
| continue | Starts the harness's most recent session in a new herdr tab. |
| resume | Starts the named harness session reference in a new herdr tab. |
| adopt | Attaches an already-running herdr agent to Emacs without starting a second CLI. Claude adoption also prepares its native IDE endpoint. |
| detach | Killing an attached terminal buffer releases only the Emacs attachment. The herdr pane and agent continue. |
| stop | Closes one agent's herdr pane, ending that agent. |
| stop all | Closes every reported agent pane on the selected herdr server. |

Use `herdr-agent-start`, `herdr-agent-continue`, and `herdr-agent-resume` from Lisp. `herdr-agent-stop` requires an explicit target; `herdr-agent-stop-all` operates on the current server. `herdr-attach-agent`, `herdr-attach-pane`, and `herdr-jump` attach existing work. `herdr-attach-takeover` controls whether Emacs claims terminal input.

## Claude IDE

Loading `herdr-claude-code-ide` installs the Claude attachment adapter. A Claude entry with a working directory and terminal ID is adopted through `herdr-claude-code-ide-adopt`; set `herdr-claude-code-ide-adopt-on-attach` to nil to retain a plain generic attachment. Enable `herdr-claude-code-ide-auto-adopt-mode` to adopt detected Claude agents whose directories pass `herdr-claude-code-ide-auto-adopt-predicate`.

Each adopted Claude session gets a loopback WebSocket MCP endpoint and discovery lockfile under `~/.claude/ide`. `herdr-claude-code-ide-connect-on-adopt` controls whether `/ide` is sent while the terminal is owned by Emacs: `idle` is the default, `t` always requests connection, and nil never does. `M-x herdr-claude-code-ide-connect-ide` requests it later.

The endpoint exposes editor context, selected-file mentions, diagnostics, file opening, and editable diffs. Diff tabs remain Emacs-owned; closing or accepting them does not stop the agent. The optional loopback HTTP MCP service is available through `herdr-claude-code-ide-mcp-server` and `herdr-claude-code-ide-emacs-tools`; it only accepts `127.0.0.1` contexts.

`executeCode` evaluates Emacs Lisp only when explicitly enabled by the package's tools configuration. It should remain disabled for untrusted sessions. Raw protocol logging is opt-in through `herdr-claude-code-ide-raw-protocol-logging`; its buffer can expose prompts, selected text, paths, diagnostics, and tool payloads. Disable it after debugging and do not share its contents casually.

## Ownership boundaries

Herdr is the authority for process lifetime and terminal input ownership. Emacs owns attached buffers, MCP transport, editor context, and diff views. Detaching or closing an Emacs buffer never stops a herdr agent; use stop to end it. Claude IDE modules adapt the generic lifecycle and do not launch or manage an Emacs-owned fallback CLI.

## Platforms

| Platform | Emacs | Status |
| --- | --- | --- |
| Ubuntu | 29.1, 30.1 | Supported |
| macOS | 29.1, 30.1 | Supported |
| Windows | 29.1, 30.1 | Supported |

CI also runs an experimental, soft-failing Ubuntu snapshot job.

## Troubleshooting

- `no terminal backend`: install `ghostel`, `vterm`, or `eat`, or configure `herdr-terminal-backend`.
- `No herdr server`: start herdr, or allow `herdr-auto-start-server` for the selected session.
- Claude does not connect: confirm the agent is idle or set `herdr-claude-code-ide-connect-on-adopt` to `t`, then run `herdr-claude-code-ide-connect-ide`.
- Claude has no editor context: verify the discovery directory is writable and that the loopback endpoint is not blocked.
- A terminal is read-only: attach with `herdr-attach-takeover` enabled, understanding that this transfers input ownership.
- A diff or protocol buffer remains after work: close its Emacs buffer; this only releases editor-side state.

## License and attribution

herdr.el is GPL-3.0-or-later; see [LICENSE](LICENSE). Earlier versions included material adapted from [manzaltu/claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el), also GPL-3.0-or-later. That external bridge has been removed from the runtime implementation.
