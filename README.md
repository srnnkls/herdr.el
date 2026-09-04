# herdr.el

`herdr.el` is an Emacs 29.1+ client for [Herdr](https://herdr.dev), the persistent terminal workspace manager. Herdr owns agent processes, terminals, tabs, and workspaces; Emacs attaches terminal buffers to that state.

## Install

Install `transient` 0.9.0+ from a configured package archive. Terminal attachment also requires one of Ghostel, vterm, or Eat.

```elisp
(use-package herdr
  :load-path "~/src/herdr.el"
  :commands (herdr-attach-agent herdr-attach-pane herdr-jump))

(use-package herdr-transient
  :load-path "~/src/herdr.el"
  :commands herdr-transient
  :bind (("C-c h" . herdr-transient)))
```

Attached buffers are named after the project and git branch the terminal works in, as in `*herdr: app@main claude*`, with linked worktrees named after their main checkout; set `herdr-buffer-name-function` to name them differently. Set `herdr-terminal-backend` when automatic backend selection is unsuitable. The package installs no global keybinding itself.

## Agent workflows

`herdr-agent.el` provides one lifecycle for Claude Code, Codex, and Pi.

| Operation | Meaning |
| --- | --- |
| start | Create a Herdr tab and start a new harness session. |
| continue | Continue the harness's latest session in a new tab. |
| resume | Resume a named harness session reference in a new tab. |
| adopt | Attach an already-running Herdr agent without starting another CLI. |
| detach | Release Emacs state while keeping the Herdr pane and agent alive. |
| stop | Close one agent's Herdr pane. |
| stop all | Close every reported agent pane on the selected server. |

Use `herdr-agent-start`, `herdr-agent-continue`, and `herdr-agent-resume` from Lisp. `herdr-agent-stop` takes a composite `(server-key . terminal-id)` target. Existing work is available through `herdr-attach-agent`, `herdr-attach-pane`, `herdr-attach-session`, and `herdr-jump`.

`herdr-attach-session-workspace-policy` defaults to `mirror`, which preserves Herdr workspace groups. Set it to `merge` to accumulate entries with the same `herdr-workspace-label` in one editor workspace.

Vanilla Emacs can use built-in tab-bar workspaces:

```elisp
(setq herdr-attach-session-workspace-policy 'merge
      herdr-workspace-open-function
      (lambda (_workspace directory)
        (let ((name (herdr-workspace-label directory)))
          (tab-bar-switch-to-tab name)
          name)))
```

`tab-bar-switch-to-tab` selects an existing tab by name or creates it when missing.

### Sending context

These commands send the active region, or the current line when no region is active, through the agent prompt API. The default message includes the file or buffer name and line range.

| Scope | Select with completion | Use the last active agent |
| --- | --- | --- |
| All sessions | `herdr-send-session` | `herdr-send-last-session` |
| Current project | `herdr-send-project-session` | `herdr-send-last-project-session` |
| Current editor workspace | `herdr-send-workspace-session` | `herdr-send-last-workspace-session` |

Selection commands always open completion, including for one candidate. Last-active commands use Emacs's global Herdr agent MRU and never open completion.

Project scope compares roots returned by `herdr-project-root-function`; linked worktrees therefore remain separate projects. Workspace scope compares `herdr-current-workspace-label` with each session directory's `herdr-workspace-label`, so an editor integration may deliberately group worktrees.

Functions in `herdr-send-context-functions` receive the selected session entry. The first non-nil string replaces the default region-or-line message, which lets optional editor integrations provide richer context without becoming a Herdr dependency.

A harness descriptor owns its display label and native start, continue, and resume arguments:

```elisp
(herdr-agent-register-harness
 "aider"
 :label "Aider"
 :arguments '((start)
              (continue "--continue")
              (resume "--resume" :reference)))
```

The Herdr server must support the registered kind.

## Adapter contract

Optional integrations inject one adapter per registered harness kind:

```elisp
(herdr-agent-adapter KIND)
(herdr-agent-register-adapter KIND ADAPTER)
(herdr-agent-unregister-adapter KIND ADAPTER)
```

`ADAPTER` receives `(session phase context)` through this lifecycle:

```elisp
(adapter session :prepare nil)
(adapter session :arguments complete-argv)
(adapter session :adopted agent)
(adapter session :attached nil)
(adapter session :status nil)
(adapter session :detach nil)
```

`:prepare` may return pane environment entries. `:arguments` may transform the complete native argument list. `:status` may return an alist. `:detach` must release only adapter-owned state and remain safe to retry.

A session captures its adapter before the first phase and keeps that exact function through cleanup. `herdr-agent-adapter` reads the current registration. Registration is idempotent for the same function; conflicts signal. Unregistration requires the same function and refuses while a live session has captured it. Adapter data belongs in the session's opaque state through `herdr-agent-set-adapter-state`; Herdr does not inspect it.

Host access for adapters stays within the public `herdr-agent-resolve-session`, `herdr-agent-list`, `herdr-agent-send-text`, `herdr-agent-prompt`, `herdr-agent-adopt`, and `herdr-agent-session-*` interfaces. `herdr-agent-event-functions` observes lifecycle events after Herdr updates its indexes.

## Transient

`M-x herdr-transient` opens the canonical Herdr menu:

```text
Session:  s start       c continue      r resume
Agent:    j switch      p prompt        n rename
          e escape      RET return      k stop       K stop all
Attach:   a agent       P pane          A session
          J jump        R route project
Status:   i dashboard   I one line     C customize
```

Opening the menu starts no process. Every agent command reads its target
from the status dashboard when the menu is opened there, and prompts
otherwise — so `?` in the dashboard is the menu scoped to the row at
point.

## Status dashboard

`M-x herdr-status` opens a Magit-style dashboard over every herdr server
`herdr-all-sessions` finds — the configured ones plus any session whose
socket is on disk, so a server started with `herdr --session NAME` shows
up without being assigned to a project first. It claims the selected
window the way `magit-status` does; `herdr-status-display-action` is the
`display-buffer` action it uses, bound so popup rules cannot divert it.
Sections collapse with `TAB` and `S-TAB`, and `M-1` through `M-4` set the
level for the whole buffer.  `herdr-status-left-fringe-width` widens the
fringe the collapse arrows are drawn in, so they clear the headings.

| Section | Contents |
| --- | --- |
| `Servers` | One entry per known session: reachability, socket, herdr version, protocol, and object counts |
| `Recent` | Agents in most-recently-used order, omitted when none |
| `Agents` | The filterable list, headed by the visible-of-total count and the active filters |
| `Panes` | Panes running no agent, grouped under their workspace |

An agent row opens with `herdr-status-attached-glyph` when Emacs has a
buffer for it, then its state, name, harness, pane id, server,
workspace, and working directory:

```text
▌ ● busy    api-review   claude   %1   shared   herdr.el   ~/projects/herdr.el
  ● idle    docs         codex    %2   shared   herdr.el   ~/projects/herdr.el
```

Pane rows carry the same marker. The server column appears once a second
session is in play, the way the completion annotations do.

The directory is `herdr-entry-directory`: herdr's `foreground_cwd` when it
has one, falling back to the `cwd` the pane opened in. An agent that moves
itself into a worktree moves only the former, and workspace routing,
project scope, and the attached buffer's `default-directory` all follow it.
A directory an agent only visits inside a single shell command is invisible
to herdr, since no process ever changes directory.

Expanding a row shows the terminal, pane, workspace, and tab identity
herdr reports — including `terminal_title_stripped`, the name the harness
gave the session — then a preview of what the agent last said, then
whatever fields the harness adapter contributes through its `:status`
phase.

The preview is the tail of the agent's recent output with the harness's
own chrome removed: `herdr-status-preview-ignore-regexps` drops rules,
the prompt, and the status bar, and the last
`herdr-status-preview-lines` lines of what survives are shown. Setting
that to 0 turns the preview off and asks herdr for nothing.

A refresh fetches one snapshot per server and no per-agent request. The
preview and the adapter fields each cost one request per agent, both
issued when a row is first expanded and reused until the next refresh. Herdr lifecycle events
redraw a live dashboard on a short idle delay, which
`herdr-status-auto-refresh` turns off.

| Key | Action |
| --- | --- |
| `?` | `herdr-transient`, acting on the agent at point |
| `RET` / `o` | Show the agent or pane, attaching it when nothing does yet; on a server, attach that whole session |
| `s` | Focus the agent in herdr |
| `P` | Send a prompt |
| `R` | Rename |
| `k` | Stop, after confirmation |
| `D` | Detach from Emacs, leaving the herdr pane alone |
| `f` | Filter menu |
| `g` | Refresh |

`herdr-status-entry-at-point` returns the agent or pane row under point,
or nil elsewhere, so an editor integration can add a binding that attaches
into a workspace of its own choosing.

Filters compose conjunctively and survive a refresh. `herdr-status-filter`
offers harness kind, agent state, current project, current editor
workspace, and attached-only. Every one of them is an entry in
`herdr-status-predicates`, which is also where a custom filter goes:

```elisp
(add-to-list 'herdr-status-predicates
             (cons 'nameless
                   (lambda ()
                     (lambda (entry) (null (alist-get 'name entry))))))
```

Each element maps a symbol to a function of no arguments. That function
may prompt and returns a predicate of one session entry, or nil to add no
filter. `herdr-status-add-filter` completes over the registry, so a
custom predicate is available under `f x` without further wiring.

## Agent-facing Emacs integration

[Limen](https://github.com/srnnkls/limen) optionally injects editor operations, context, diffs, and native Claude Code, Codex, and Pi transports through the adapter contract. Herdr runs all three harnesses without Limen.

## Ownership

Herdr remains authoritative for process lifetime and terminal input. Killing an Emacs buffer or detaching a session never stops the Herdr agent; use `herdr-agent-stop` to end it.

## Platforms

| Platform | Emacs | Status |
| --- | --- | --- |
| Ubuntu | 29.1, 30.1, 31.1 | Supported |
| macOS | 29.1, 30.1, 31.1 | Supported |
| Windows | 29.1, 30.1, 31.1 | Supported |

CI also runs an experimental, soft-failing Ubuntu snapshot job.

## Troubleshooting

- `no terminal backend`: install Ghostel, vterm, or Eat, or set `herdr-terminal-backend`.
- `No herdr server`: start Herdr, or allow `herdr-auto-start-server` for the selected session.
- A terminal is read-only: enable `herdr-attach-takeover` when attaching to transfer input ownership.

## License

herdr.el is GPL-3.0-or-later; see [LICENSE](LICENSE).
