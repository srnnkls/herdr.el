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
| message | Send a typed message plus the context at point to an agent. |
| associate | Bind a primary agent to the current buffer, project, or workspace. |

Use `herdr-agent-start`, `herdr-agent-continue`, and `herdr-agent-resume` from Lisp. `herdr-agent-stop` takes a composite `(server-key . terminal-id)` target. Existing work is available through `herdr-attach-agent`, `herdr-attach-pane`, `herdr-attach-session`, and `herdr-jump`.

`herdr-message-session` and its project, workspace, `last`, and `primary` variants read a message with completion over earlier messages and send it followed by a `---` barrier and the context at point: a `file:` or `buffer:` line with the line range, `mode:`, and the region or current line in a fenced block for file-visiting buffers, or whatever a provider on `herdr-send-context-functions` returns. `C-c '` in the minibuffer moves the draft to a `*herdr message*` buffer where `C-c C-c` sends and `C-c C-k` discards. `herdr-associate-agent`, `herdr-associate-project-agent`, and `herdr-associate-workspace-agent` bind a primary agent; `herdr-message-primary-session` and `herdr-send-primary-session` resolve buffer, then project, then workspace, and bind the project on first use when nothing is set.

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
Launch:  N new         c continue      r resume
Agent:   P prompt      R rename        j switch
         e escape      RET return      x stop        X stop all
Attach:  a agent       p pane          A session
         J jump        o route project
Find:    s search      S search menu   i dashboard
         I one line    t details
```

An action the dashboard also offers is on the key the dashboard binds it
to — `P`, `R`, `x`, `t`, `s`, `S` — so the two menus read as one. A test
pins that agreement.

Opening the menu starts no process. Every agent command reads its target
from the status dashboard when the menu is opened there, and prompts
otherwise. The dashboard has its own menu on `?`, `herdr-status-dispatch`,
mirroring the keys it binds directly.

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
| `Sessions` | One entry per known session: reachability, socket, herdr version, protocol, and object counts |
| `Recent` | Agents in most-recently-used order, omitted when none |
| `Herds` | One collapsible entry per herd the listed agents name, omitted when none does |
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

A refresh fetches one snapshot per session and no per-agent request. The
preview and the adapter fields each cost one request per agent, both
issued when a row is first expanded and reused until the next refresh. Herdr lifecycle events
redraw a live dashboard on a short idle delay, which
`herdr-status-auto-refresh` turns off.

| Key | Action |
| --- | --- |
| `RET` / `o` | Show the agent or pane, attaching it when nothing does yet; on a session row, attach the whole of it. With a prefix argument, move herdr itself to the agent's pane as well |
| `P` | Send a prompt |
| `R` | Rename |
| `d` | Detach — Emacs lets go of the terminal and its buffer, the pane runs on |
| `x` | Stop — the pane closes and the buffer goes with it, after confirmation |
| `f` | Filter menu |
| `O` | Order menu |
| `t` | Show or hide agent metadata |
| `h` | Herd menu |
| `s` | Search agent history, narrowed by the section at point |
| `S` | Search menu |
| `g` | Refresh |
| `?` | `herdr-status-dispatch`, a menu of these same keys |

Every action has a direct key; `?` opens a menu that mirrors them and
closes on a second `?`. `s` and `S` are bound only where
[memex.el](https://github.com/srnnkls/memex.el) is on the load path, and
are absent otherwise — the same keys `memex-status` searches under.

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

## Herds

A herd is a named set of agents that know each other's names and know the
`herdr` CLI is how they reach one another. `h` in the dashboard opens the
menu:

| Key | Action |
| --- | --- |
| `a` | Add the agent at point to a herd, naming a new one if you like |
| `A` | Add several — the rows the region covers, else pick from the session's agents |
| `r` | Take the agent at point out of its herd |
| `d` | Dissolve a herd, leaving its agents running and named |
| `b` | Send one prompt to every idle member |
| `R` | Send the roster again after membership changed |

Joining sends the member `herdr-herd-protocol` followed by the live
roster, through `herdr agent prompt`. Nothing is written into the project
the agent works in, so Codex and Pi members join on the same terms as
Claude. An agent that is `working` or `blocked` is skipped and named
rather than interrupted mid-turn; `herdr-herd-busy-states` is that list.

Members address each other by name only. An agent that already has one
keeps it; one that has none is named at join from the repository it works
in and the task its terminal title shows — `memex-incremental-index`,
`sira-unified-kv` — offered as an editable default and passed through
herdr's own uniqueness check. A linked worktree is named after the
repository it was cut from, not its own directory.

A herd belongs to one session. `herdr agent prompt` reaches one server,
so agents on different sessions can neither reach each other nor be
reached, and two alike labels on two sessions are two herds — written
`cmw/refactor` where the session is named. Every herd command takes the
session from what point is on: an agent row, a herd, or a session row.
Where point names none it asks, listing each session beside the socket it
stands for:

```text
Session (default shared):
shared   ~/.config/herdr/herdr.sock
cmw      ~/.config/herdr/sessions/cmw/herdr.sock
gf       ~/.config/herdr/sessions/gf/herdr.sock
```

Adding an agent from another session is refused by name rather than
quietly making a herd that cannot talk to itself.

### Membership lives in herdr

A member's pane carries its herd in the pane's own manual label, as
`herd:NAME` ahead of whatever else the label says:

```console
$ herdr pane rename w71:p1 "herd:refactor"      # join
$ herdr pane list | jq -r '.result.panes[].label'
$ herdr pane rename w71:p1 --clear              # leave
```

Emacs is therefore not the entry point. Herdr persists that label across
a restart and reports it with the pane, so an agent joins, leaves, and
reads a herd with the same `herdr` CLI it already uses for everything
else, and needs no editor running. Emacs only reads and writes the same
field. A herd exists exactly as long as some live pane names it; nothing
is stored outside herdr.

The label is drawn only where a pane has no terminal title — which every
agent pane sets — so on an agent it stays invisible. Text a pane label
already carried survives every herd command: joining prepends `herd:NAME`
and leaving takes it away again.

`bin/herdr-herd` wraps those calls for agents. It defaults every pane
argument to `$HERDR_PANE_ID`, so an agent talks about itself with no
arguments:

```console
$ herdr-herd join refactor
$ herdr-herd peers
$ herdr-herd say "rebased onto main, your turn"
```

The roster an agent receives names the script's absolute path, so no
`PATH` setup is needed; `herdr-herd-command` controls that, and nil
leaves agents the plain `herdr` commands alone. The script needs
`python3` to read herdr's JSON and refuses outside a herdr pane.

## Searching agent history

With [memex.el](https://github.com/srnnkls/memex.el) installed, `s`
searches the transcripts memex indexed, narrowed to what point stands
for: one agent on an agent row, a herd's members inside a herd, every
listed agent elsewhere in the dashboard, and everything outside it. `S`
opens the menu, which adds the search modes and, for the agent at point,
its transcript and a resume into a fresh tab.

Without memex.el neither key is bound and nothing is loaded.

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
- An agent stays "unfocused" in Herdr after its Emacs buffer left the screen: keep `herdr-report-focus-loss` nil so only Herdr reports focus loss.

## License

herdr.el is GPL-3.0-or-later; see [LICENSE](LICENSE).
