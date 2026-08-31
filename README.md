# herdr.el

`herdr.el` is an Emacs 29.1+ client for [Herdr](https://herdr.dev), the persistent terminal workspace manager. Herdr owns agent processes, terminals, tabs, and workspaces. Emacs owns attached terminal buffers and, for Claude, a loopback Emacs endpoint with buffer, diagnostic, context, and diff operations.

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

## emacsctl

`emacsctl` is an Emacs interface for agents. Claude, Codex, Pi, and other local harnesses can compose its operations through their existing shell access:

```text
emacsctl operations
emacsctl call buffer.list
emacsctl call buffer.open '{"path":"src/example.el","line":20}'
emacsctl skill
```

`call` also accepts `-` and reads one JSON object from standard input. Normal output is one compact versioned JSON object; `skill` prints Markdown generated from the installed command contract and live operation registry.

The base registry exposes buffer listing/opening, window listing, and visited-buffer Flymake diagnostics. Additional Emacs configuration can register coarse operations without changing Herdr:

```elisp
(emacsctl-register-operation
 "workspace.list" #'+my-workspace-list
 :description "List Emacs workspaces."
 :effect 'read
 :parameters nil)
```

`elisp.eval` is absent and rejected unless `emacsctl-enable-elisp-eval` is non-nil. This gate limits accidental use and command discovery; it is not a sandbox. A same-user process with shell and Emacs-server access can already run arbitrary code through `emacsclient -e` or another local runtime. Actual isolation requires separate OS users, processes, or server-socket permissions.

## Claude Emacs integration

Every adopted Claude session gets its own loopback WebSocket MCP endpoint and discovery lockfile under `~/.claude/ide`, or `$CLAUDE_CONFIG_DIR/ide` when configured. The generic agent lifecycle invokes the Claude adapter; there is no second attach route.

`herdr-claude-connect-on-adopt` controls when Herdr sends `/ide`: `idle` connects an idle agent, `t` always requests connection, and nil requires `M-x herdr-claude-connect`. `M-x herdr-claude-auto-adopt-mode` adopts matching agents according to `herdr-claude-auto-adopt-predicate`.

`M-x herdr-claude-at-mention` sends the current file or active region to the initialized Claude connection for that project. The endpoint also provides selection updates, visited-buffer diagnostics, buffer opening/release, and editable Ediff-backed diffs.

Claude’s fixed compatibility catalog contains `openFile`, `getDiagnostics`, `close_tab`, `openDiff`, and `closeAllDiffTabs`. Those external names stay at the wire boundary; internal operations use `buffer.*`, `diagnostic.*`, and `diff.*`. Newly registered `emacsctl` operations never appear in MCP automatically. Raw payload logging is disabled by default; enable `herdr-claude-protocol-logging` only while debugging and inspect it with `M-x herdr-claude-debug-open-log`.

## Ownership and security

Herdr remains authoritative for process lifetime and terminal input. Emacs owns terminal buffers, Claude endpoints, project buffers, diagnostics, and diffs. Killing an Emacs buffer or detaching a session never stops the Herdr agent; use `herdr-agent-stop` to end it.

Claude endpoints bind only to loopback. Discovery files are mode `0600`, operation paths stay inside the caller’s project root, and raw logging is opt-in. `emacsctl` sends Base64-framed JSON through a fixed local `emacsclient` expression so caller data never becomes Elisp source.

## Platforms

| Platform | Emacs | Status |
| --- | --- | --- |
| Ubuntu | 29.1, 30.1 | Supported |
| macOS | 29.1, 30.1 | Supported |
| Windows | 29.1, 30.1 | Supported; the `emacsctl` launcher uses Git Bash. |

CI also runs an experimental, soft-failing Ubuntu snapshot job.

## Troubleshooting

- `no terminal backend`: install Ghostel, vterm, or Eat, or set `herdr-terminal-backend`.
- `No herdr server`: start Herdr, or allow `herdr-auto-start-server` for the selected session.
- Claude does not connect: run `M-x herdr-claude-connect` and confirm the agent is idle.
- Claude has no Emacs context: confirm the connection initialized and the current file belongs to the adopted project.
- A terminal is read-only: enable `herdr-attach-takeover` when attaching to transfer input ownership.
- A diff remains: reject or accept it, or detach the Claude integration; the Herdr pane remains alive.

## License and attribution

herdr.el is GPL-3.0-or-later; see [LICENSE](LICENSE). Earlier versions included material adapted from [manzaltu/claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el), also GPL-3.0-or-later. That external bridge is absent from the runtime implementation.
