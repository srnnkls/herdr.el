# herdr.el reference

Every command, key, user option, face, hook and Lisp entry point. For how they fit together, read
[GUIDE.md](GUIDE.md).

herdr.el binds no global key. Keys below belong to the dashboard, the menus, or the message
buffers.

## Contents

- [Commands](#commands)
- [Keys](#keys)
- [User options](#user-options)
- [Faces](#faces)
- [Hooks](#hooks)
- [Variables](#variables)
- [Lisp interface](#lisp-interface)
- [Files and buffers](#files-and-buffers)

## Commands

A prefix argument is written `C-u`.

### Attaching

| Command | Does |
| --- | --- |
| `herdr-attach-agent` | attach an agent of the session the current directory routes to |
| `herdr-attach-pane` | attach a pane of that session that runs no agent |
| `herdr-attach-session` | attach every agent of a session in editor workspace groups; `C-u` attaches plain panes too; attaches without input takeover |
| `herdr-jump` | show any running agent on any server, attaching it when Emacs has no buffer for it |

### Sessions and routing

| Command | Does |
| --- | --- |
| `herdr-assign-project-session` | route the current project to a session and store it in `herdr-state-file`; `C-u` skips storing |

### The agent at hand

| Command | Does |
| --- | --- |
| `herdr-toggle-agent` | show the current workspace's agent at its prompt, or hide the agent window on the frame; `C-u` reads the agent |
| `herdr-switch-agent` | read one of the workspace's agents and show it at its prompt; `C-u` offers every agent |
| `herdr-next-agent` | make the next agent of the workspace the foreground one; a numeric prefix steps further |
| `herdr-previous-agent` | make the previous agent the foreground one; a numeric prefix steps further |

### Messages and context

`herdr-message-...` commands read a message and send it with the context at point;
`herdr-send-...` commands send the context alone. Commands with `recent` take the agent used most
recently in their scope without asking.

| Command | Agent |
| --- | --- |
| `herdr-message-send` | the foreground agent; `C-u` reads one |
| `herdr-message-send-session` | read from every server |
| `herdr-message-send-recent-session` | most recent on any server |
| `herdr-message-send-project-session` | read from the current project |
| `herdr-message-send-recent-project-session` | most recent in the current project |
| `herdr-message-send-workspace-session` | read from the current editor workspace |
| `herdr-message-send-recent-workspace-session` | most recent in the current editor workspace |
| `herdr-message-send-primary-session` | the primary agent; binds one to the project on first use |
| `herdr-send` | the foreground agent; `C-u` reads one |
| `herdr-send-session` | read from every server |
| `herdr-send-recent-session` | most recent on any server |
| `herdr-send-project-session` | read from the current project |
| `herdr-send-recent-project-session` | most recent in the current project |
| `herdr-send-workspace-session` | read from the current editor workspace |
| `herdr-send-recent-workspace-session` | most recent in the current editor workspace |
| `herdr-send-primary-session` | the primary agent; binds one to the project on first use |

While a message is being written:

| Command | Does |
| --- | --- |
| `herdr-message-edit-from-minibuffer` | move the draft from the minibuffer to a `*herdr message*` buffer |
| `herdr-message-send-in-place` | send without moving the cursor to the agent |
| `herdr-message-commit` | send the `*herdr message*` buffer |
| `herdr-message-cancel` | discard the `*herdr message*` buffer |

### Primary agents

| Command | Does |
| --- | --- |
| `herdr-associate-agent` | bind an agent to the current buffer |
| `herdr-associate-project-agent` | bind an agent to the current project |
| `herdr-associate-workspace-agent` | bind an agent to the current editor workspace |
| `herdr-dissociate-agent` | clear the buffer's binding; `C-u` also clears the project's and workspace's |

### Dashboard

| Command | Key | Does |
| --- | --- | --- |
| `herdr-status` | | show the dashboard over every server |
| `herdr-project-status` | | show the dashboard for the current project |
| `herdr-status-toggle-project` | `p` | switch between the global and project dashboards |
| `herdr-status-switch` | | read a running agent and show it; `C-u` moves herdr's focus to it instead |
| `herdr-status-refresh` | `g` | fetch every server and redraw |
| `herdr-status-visit` | `RET` | show the row's agent or pane, attaching it; attach the whole session on a session row; `C-u` also moves herdr's focus to the agent |
| `herdr-status-visit-other-window` | `o` | show the row's agent or pane in another window |
| `herdr-status-new-agent` | `n` | start the harness at point, or `herdr-status-new-harness`, where the row works |
| `herdr-status-new-agent-of-harness` | `N` | as `n`, reading the harness |
| `herdr-status-prompt` | `P` | send a prompt to the agent at point |
| `herdr-status-rename` | `R` | rename the agent at point, or relabel the pane at point |
| `herdr-status-detach` | `d` | let go of the agent's terminal and buffer; the pane runs on |
| `herdr-status-stop` | `x` | stop the agent at point, after confirmation |
| `herdr-status-close-pane` | `K` | close the pane at point and any agent in it, after confirmation |
| `herdr-status-toggle-expanded` | `e` | open every row `herdr-status-expanded-states` names, or close them all |
| `herdr-status-toggle-details` | `t` | show or hide agent metadata under expanded rows |
| `herdr-status-toggle-grouping` | `u` | draw the agent list in groups, or as one list |
| `herdr-status-group-by` | `U` | pick what the agent list groups by |
| `herdr-status-filter` | `f` | open the filter menu |
| `herdr-status-add-filter` | `f x` | add any filter in `herdr-status-predicates` |
| `herdr-status-remove-filter` | `f -` | drop one filter |
| `herdr-status-clear-filters` | `f DEL` | drop every filter |
| `herdr-status-filter-by-harness` | `f h` | keep one harness |
| `herdr-status-filter-by-state` | `f S` | keep one state |
| `herdr-status-filter-by-project` | `f p` | keep the current project |
| `herdr-status-filter-by-workspace` | `f w` | keep the current editor workspace |
| `herdr-status-filter-attached` | `f a` | keep agents Emacs has a buffer for |
| `herdr-status-sort` | `O` | open the order menu |
| `herdr-status-sort-by` | `O x` | order by any key in `herdr-status-sorts`; again to reverse |
| `herdr-status-sort-by-state` | `O s` | order by state |
| `herdr-status-sort-by-name` | `O n` | order by name |
| `herdr-status-sort-by-harness` | `O h` | order by harness |
| `herdr-status-sort-by-pane` | `O p` | order by pane |
| `herdr-status-sort-by-session` | `O S` | order by session |
| `herdr-status-sort-by-directory` | `O d` | order by directory |
| `herdr-status-sort-reverse` | `O r` | reverse the order |
| `herdr-status-sort-clear` | `O DEL` | return to herdr's order |
| `herdr-status-dispatch` | `?` | open the dashboard menu |

### Herds

| Command | Key | Does |
| --- | --- | --- |
| `herdr-herd-dispatch` | `h` | open the herd menu |
| `herdr-herd-add` | `h a` | add the agent at point, or agents picked from the session, to a herd |
| `herdr-herd-add-many` | `h A` | add the rows the region covers, or agents picked from the session |
| `herdr-herd-remove` | `h r` | take the agent at point out of its herd and tell the others |
| `herdr-herd-dissolve` | `h d` | take every member out of a herd, after confirmation |
| `herdr-herd-broadcast` | `h b` | send a prompt to every member that is not busy |
| `herdr-herd-announce` | `h R` | send every member the current roster |

### The herdr menu

`herdr-transient` opens a menu of herdr commands. Opened in the dashboard, its agent commands act
on the agent at point; elsewhere they read one.

| Key | Does | Key | Does |
| --- | --- | --- | --- |
| `N` | start a harness, reading its name | `R` | rename an agent |
| `c` | continue a harness's latest session | `j` | focus an agent in herdr and show it |
| `r` | resume a harness session by reference | `e` | send `Escape` to an agent |
| `P` | send a prompt | `RET` | send `Return` to an agent |
| `m` | `herdr-message-send` | `x` | stop an agent, without confirmation |
| `M` | `herdr-message-send-project-session` | `X` | stop every agent on the current server, without confirmation |
| `b` | `herdr-message-send-primary-session` | `a` | `herdr-attach-agent` |
| `=` | `herdr-associate-agent` | `p` | `herdr-attach-pane` |
| `i` | `herdr-status` | `A` | `herdr-attach-session` |
| `I` | show an agent's harness and state in the echo area | `J` | `herdr-jump` |
| `t` | `herdr-status-toggle-details`, in the dashboard only | `o` | `herdr-assign-project-session` |

`P`, `R`, `x` and `t` do what the same keys do in the dashboard.

## Keys

### Dashboard keys

`herdr-status-mode-map` inherits from `magit-section-mode-map`, so `TAB`, `C-<tab>`, `S-TAB`, `^`,
`M-n`, `M-p`, `1` to `4` and `M-1` to `M-4` work as in Magit. `n` and `p` are the dashboard's own.

| Key | Command |
| --- | --- |
| `?` | `herdr-status-dispatch` |
| `RET` | `herdr-status-visit` |
| `o` | `herdr-status-visit-other-window` |
| `n` | `herdr-status-new-agent` |
| `N` | `herdr-status-new-agent-of-harness` |
| `P` | `herdr-status-prompt` |
| `R` | `herdr-status-rename` |
| `d` | `herdr-status-detach` |
| `x` | `herdr-status-stop` |
| `K` | `herdr-status-close-pane` |
| `e` | `herdr-status-toggle-expanded` |
| `t` | `herdr-status-toggle-details` |
| `f` | `herdr-status-filter` |
| `O` | `herdr-status-sort` |
| `u` | `herdr-status-toggle-grouping` |
| `U` | `herdr-status-group-by` |
| `h` | `herdr-herd-dispatch` |
| `g` | `herdr-status-refresh` |
| `p` | `herdr-status-toggle-project` |
| `q` | `quit-window` |

`s` and `m` are left free for memex.el, which binds them to its search and its menu when it is
installed. `herdr-status-dispatch` mirrors the keys above and closes on `?`.

### Message keys

| Where | Key | Does |
| --- | --- | --- |
| minibuffer (`herdr-message-minibuffer-map`) | `M-p`, `M-n` | earlier and later messages |
| | `C-c '` | `herdr-message-edit-from-minibuffer` |
| | `C-<return>` | `herdr-message-send-in-place` |
| `*herdr message*` (`herdr-message-mode-map`) | `C-c C-c` | `herdr-message-commit` |
| | `C-c C-k` | `herdr-message-cancel` |
| | `C-<return>` | `herdr-message-send-in-place` |
| cera field (`herdr-message-field-map` over cera's keys) | `RET`, `C-c C-c` | send |
| | `C-c C-k`, `C-g` | cancel |
| | `C-<return>` | `herdr-message-send-in-place` |

## User options

### Server and session options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-executable` | string | `"herdr"` | the herdr executable |
| `herdr-session` | `shared`, `emacs` or string | `shared` | the session Emacs talks to by default |
| `herdr-emacs-session-name` | string | `"emacs"` | the session `herdr-session` set to `emacs` uses |
| `herdr-socket-path` | file or nil | nil | the API socket; nil derives it from the session |
| `herdr-project-sessions` | alist of `(ROOT . SESSION)` | nil | projects assigned to sessions in your configuration |
| `herdr-session-alist` | alist of `(MATCHER . SESSION)` | nil | rules for unassigned projects; MATCHER is a directory or a function of one |
| `herdr-state-file` | file | `herdr/project-sessions.eld` under `user-emacs-directory` | where `herdr-assign-project-session` stores assignments |
| `herdr-project-root-function` | function | `herdr-project-root` | returns a directory's project root; the default asks projectile, then project.el |
| `herdr-auto-start-server` | boolean | t | start a server when none answers |
| `herdr-server-start-timeout` | number | 15.0 | seconds to wait for a started server |
| `herdr-request-timeout` | number | 5.0 | seconds to wait for a socket response |

The socket of the `shared` session is `$XDG_CONFIG_HOME/herdr/herdr.sock`, and a named session's
is `$XDG_CONFIG_HOME/herdr/sessions/NAME/herdr.sock`; `XDG_CONFIG_HOME` defaults to `~/.config`.

### Terminal and window options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-terminal-backend` | `auto`, `ghostel`, `vterm` or `eat` | `auto` | the emulator; `auto` takes the first installed |
| `herdr-attach-takeover` | boolean | t | whether attaching claims input ownership |
| `herdr-buffer-name-function` | function | `herdr-default-buffer-name` | names a buffer from the terminal's label and directory |
| `herdr-use-side-window` | boolean | t | show attached terminals in a side window |
| `herdr-window-side` | `left`, `right`, `top` or `bottom` | `right` | the side window's side |
| `herdr-window-width` | integer | 100 | body width of a left or right side window |
| `herdr-window-height` | integer | 20 | height of a top or bottom side window |
| `herdr-window-slot-base` | integer | 100 | first side-window slot attached terminals take |
| `herdr-display-buffer-action` | `display-buffer` action or nil | nil | replaces the side window when set |
| `herdr-report-focus-loss` | boolean | nil | report Emacs focus-out to Ghostel terminals |
| `herdr-terminal-quiet-exit-regexps` | list of regexps | detach and exited-terminal lines | CLI lines that end an attachment without a warning |
| `herdr-entry-label-decorations` | list of regexps | Oh My Pi's title preamble | taken off the front of a terminal title used as a label |

### Editor workspace options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-workspace-label-function` | function | `herdr-default-workspace-label` | the herdr workspace label for a directory; the default is its name |
| `herdr-current-workspace-label-function` | function | `herdr-default-current-workspace-label` | the current editor workspace's label; the default labels the current project |
| `herdr-agent-workspace-buffer-predicate` | function | `herdr-agent-workspace-buffer-p` | whether a buffer is in the current workspace; the default asks `persp-mode` |
| `herdr-attach-session-workspace-policy` | `mirror` or `merge` | `mirror` | group `herdr-attach-session` by herdr workspace, or by `herdr-workspace-label` |
| `herdr-workspace-open-function` | function or nil | nil | opens an editor workspace for each group `herdr-attach-session` attaches |

### Agent options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-toggle-agent-display-action` | `display-buffer` action or nil | nil | where `herdr-toggle-agent` shows a terminal; nil leaves it to `display-buffer-alist` |
| `herdr-agent-preserve-draft` | boolean | t | keep a draft in an attached agent's prompt across a message |
| `herdr-agent-prompt-marker` | regexp | a line opening with `❯`, `›`, `▌` or `>` | the start of an agent's input line on screen |
| `herdr-agent-prompt-rule` | regexp | a rule of eight or more dashes | what closes an agent's input box |
| `herdr-agent-prompt-clear` | string | `"\C-u"` | sent to clear an agent's input line |
| `herdr-agent-prompt-submit` | string | `"\r"` | sent to submit an agent's input line |
| `herdr-agent-key-delay` | number | 0.05 | seconds `herdr-agent-type-keys` waits after each key |

### Message options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-message-read-function` | function | `herdr-message-read-minibuffer` | where a message is written; `herdr-message-read-field` writes it in a cera field |
| `herdr-message-show-agent` | `focus`, t or nil | `focus` | after sending: show the agent and go to its prompt, show it, or leave it |

### Dashboard options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-status-buffer-name` | string | `"*herdr-status*"` | the dashboard buffer's name |
| `herdr-status-buffer-name-function` | function | `herdr-status-default-buffer-name` | picks the dashboard buffer; `herdr-status-workspace-buffer-name` gives one per editor workspace |
| `herdr-status-display-action` | `display-buffer` action | reuse a window, else the selected one | how the dashboard is shown; nil defers to `display-buffer-alist` |
| `herdr-status-auto-refresh` | boolean | t | redraw on herdr events |
| `herdr-status-refresh-delay` | number | 0.4 | idle seconds before an event-driven redraw |
| `herdr-status-new-harness` | string | `"claude"` | the harness `n` starts away from a row |
| `herdr-status-expanded-states` | list of strings | `("working")` | states whose rows start expanded; nil starts all collapsed |
| `herdr-status-show-details` | boolean | nil | show metadata under expanded rows |
| `herdr-status-counted-states` | list of strings | `("working" "blocked")` | states the `Agents` heading counts |
| `herdr-status-state-order` | list of strings | `("working" "blocked" "idle" "done")` | the order states sort in |
| `herdr-status-sorts` | alist of `(NAME . FUNCTION)` | state, name, harness, pane, session, model, context, directory | keys `herdr-status-sort-by` offers |
| `herdr-status-groups` | alist of `(NAME . FUNCTION)` | project, directory, session, harness, model, state | units `herdr-status-group-by` offers |
| `herdr-status-preview-lines` | integer | 16 | lines of recent output a preview shows; 0 turns previews off |
| `herdr-status-preview-read-lines` | integer | 160 | lines read to find them |
| `herdr-status-preview-ignore-regexps` | list of regexps | rules, prompts, status bars, tool calls | lines a preview drops |
| `herdr-status-preview-ttl` | number | 5 | seconds a preview is reused |
| `herdr-status-preview-markdown` | boolean | t | render previews with memex's markdown renderer where installed |
| `herdr-status-preview-status-regexp` | regexp | harness status and timing lines | lines drawn in `herdr-status-preview-status` |
| `herdr-status-preview-rule` | string | `"┃"` | drawn down a preview's left edge in the agent's colour |
| `herdr-status-preview-spacing` | natnum | 3 | pixels of space above a preview |
| `herdr-status-model-token` | string | `"model"` | the pane metadata token the model column reads |
| `herdr-status-context-token` | string | `"context"` | the pane metadata token the context column reads |
| `herdr-read-agent-name-width` | float or natnum | 0.4 | how wide a name may be while an agent is read: a share of the frame, or columns |

### Dashboard appearance

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-status-columns` | alist of `(FIELD . PLIST)` | pane, workspace, branch, model, context, directory | the fields after the harness; plist keys `:value`, `:face`, `:width` |
| `herdr-status-column-widths` | alist of `(FIELD . COLUMNS)` | `((workspace . 20) (branch . 20))` | the widest a field may be before it is cut |
| `herdr-status-name-width` | natnum or nil | nil | the widest a name may be; nil allows a third of the window |
| `herdr-status-echo-cut-fields` | boolean | t | echo a cut field's whole value as point crosses it |
| `herdr-status-field-glyphs` | alist of `(FIELD CANDIDATE...)` | Nerd Font, then Unicode, then ASCII | glyphs leading each field |
| `herdr-status-nerd-font` | `auto`, t or nil | `auto` | whether Nerd Font glyphs are used; `auto` on graphical frames only |
| `herdr-status-harness-marks` | alist of `(HARNESS GLYPHS . FACE)` | marks for `claude`, `codex`, `omp` | the vendor mark before a harness |
| `herdr-status-state-glyph` | string or list | `"●"` | the state glyph |
| `herdr-status-state-glyphs` | alist of `(STATE . GLYPH)` | `(("idle" . "○"))` | per-state replacements for the state glyph |
| `herdr-status-state-faces` | alist of `(STATE . FACE)` | the four state faces | faces per state; others use `herdr-status-state-unknown` |
| `herdr-status-attached-glyph` | string or nil | `"•"` | marks rows Emacs has a buffer for; nil drops the column |
| `herdr-status-visibility-indicators` | sexp | nil | replaces `magit-section-visibility-indicators` in the dashboard |
| `herdr-status-left-fringe-width` | integer or nil | 13 | left fringe width in pixels on graphical frames |

### Herd options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `herdr-herd-label-prefix` | string | `"herd:"` | marks the herd at the head of a pane label |
| `herdr-herd-notice-prefix` | string | `"[herd "` | opens a notice to members |
| `herdr-herd-busy-states` | list of strings | `("working" "blocked")` | states herd commands do not prompt into |
| `herdr-herd-protocol` | string | the protocol text | what a joining agent is told |
| `herdr-herd-command` | function, file or nil | finds `bin/herdr-herd` beside the package | the helper path agents are told; nil tells them none |
| `herdr-herd-name-stopwords` | list of strings | articles, prepositions, commit-type words | words dropped when a name is derived from a title |
| `herdr-herd-name-title-words` | natnum | 2 | title words a derived name keeps |

## Faces

| Face | Draws |
| --- | --- |
| `herdr-status-label` | an agent's name when Emacs has a buffer for it |
| `herdr-status-label-quiet` | a name Emacs has no buffer for |
| `herdr-status-attached` | the attached marker |
| `herdr-status-path` | directories |
| `herdr-status-meta` | pane, workspace, branch and other trailing fields |
| `herdr-status-detail-key` | field names in expanded metadata |
| `herdr-status-active-filter` | active filters in the `Agents` heading |
| `herdr-status-preview-status` | a harness's status lines in a preview |
| `herdr-status-state-idle` | `idle` |
| `herdr-status-state-working` | `working` |
| `herdr-status-state-blocked` | `blocked`, and unreachable sessions |
| `herdr-status-state-done` | `done` |
| `herdr-status-state-unknown` | any other state |
| `herdr-status-harness-claude` | the Claude Code mark |
| `herdr-status-harness-codex` | the Codex mark |
| `herdr-status-harness-omp` | the Oh My Pi mark |
| `herdr-status-nerd-glyph` | the size of Nerd Font glyphs, 0.75 by default |

## Hooks

| Hook | Called with | Runs |
| --- | --- | --- |
| `herdr-buffer-functions` | the buffer | when a buffer starts showing a herdr terminal |
| `herdr-attach-functions` | the entry | before an entry is attached as a plain terminal; the first to return a buffer claims it |
| `herdr-terminal-focus-functions` | nothing, in the terminal buffer | once point is at the terminal's prompt |
| `herdr-entry-annotation-functions` | the entry | when a completion annotation is built; return a string to append |
| `herdr-session-functions` | nothing | to list the entries of the session in scope; default `herdr-agent-sessions` |
| `herdr-agent-event-functions` | server key, event type, event data | after each pane event |
| `herdr-send-context-functions` | the agent entry | to provide context; the first string wins |
| `herdr-message-compose-functions` | target, message, context | to build the prompt; the first string wins |
| `herdr-status-sections-functions` | agents, widths, tab index, workspace index | inside the dashboard, above `Recent` |
| `herdr-status-refresh-hook` | nothing, in the dashboard | after a redraw |
| `herdr-status-redraw-inhibit-functions` | nothing, in the dashboard | before a redraw; any non-nil answer defers it |
| `herdr-herd-protocol-functions` | the herd | when a member joins; return a paragraph to add |
| `herdr-herd-sent-functions` | the entry, the text | after each prompt a herd command sends |

## Variables

| Variable | Holds |
| --- | --- |
| `herdr-agent-harnesses` | harness descriptors keyed by kind: `claude`, `codex`, `pi`, `omp` |
| `herdr-status-predicates` | the dashboard's named filters: `agent-harness`, `agent-state`, `project`, `workspace`, `attached` |
| `herdr-message-history` | messages sent to agents, most recent first |
| `herdr-attach-session-workspace` | the value `herdr-workspace-open-function` returned, while a group is attached |
| `herdr-entries-in-scope-function` | returns the entries a command reads a target from; the dashboard binds it to what it shows |
| `herdr-current-agent` | the current buffer's primary agent target, buffer-local |
| `herdr-terminal-id`, `herdr-terminal-session`, `herdr-terminal-server-key` | the terminal an attached buffer shows, buffer-local |

## Lisp interface

A *target* is `(SERVER-KEY . TERMINAL-ID)`. Functions that take a target resolve a nil one to the
agent attached to the current buffer, then a visible agent of the project, then the project's most
recent one.

### Agent functions

| Function | Does |
| --- | --- |
| `herdr-agent-start` | start a harness: `(KIND NAME &key server-key project-root workspace attach timeout-ms wait)` |
| `herdr-agent-continue` | continue a harness's latest session: `(KIND NAME &key ...)` |
| `herdr-agent-resume` | resume a session: `(KIND NAME REFERENCE &key ...)` |
| `herdr-agent-start-session` | start with explicit arguments: `(KIND NAME &key ... args)` |
| `herdr-agent-start-in-pane` | start in an existing pane: `(KIND NAME PANE &key ...)` |
| `herdr-agent-adopt` | take up a running agent: `(AGENT &key session server-key attach display)` |
| `herdr-agent-detach` | let go of a session record, leaving the pane running |
| `herdr-agent-stop`, `herdr-agent-stop-all` | close an agent's pane, or every agent's on the current server |
| `herdr-agent-switch` | focus a target in herdr and show it |
| `herdr-agent-rename` | rename a target |
| `herdr-agent-status` | a target's herdr record plus its adapter's `:status` fields |
| `herdr-agent-prompt` | send text as a prompt, keeping a draft where it can |
| `herdr-agent-send-text`, `herdr-agent-paste` | write text to the target's pane, raw or as a paste |
| `herdr-agent-send-keys`, `herdr-agent-type-keys` | send key names at once, or one at a time |
| `herdr-agent-escape`, `herdr-agent-newline` | send `Escape` or `Return` |
| `herdr-agent-read`, `herdr-agent-draft` | a target's visible screen, or the draft in its prompt |
| `herdr-agent-list` | the agents a server reports |
| `herdr-agent-find`, `herdr-agent-resolve-session` | the session record for a target |
| `herdr-agent-register-harness` | add or replace a harness descriptor |
| `herdr-agent-register-adapter`, `herdr-agent-unregister-adapter`, `herdr-agent-adapter` | manage adapters |
| `herdr-agent-set-adapter-state` | store an adapter's own state on a session |

### Entries, sessions and terminals

| Function | Does |
| --- | --- |
| `herdr-sessions` | the entries `herdr-session-functions` report on every server, agents by default |
| `herdr-read-agent`, `herdr-read-entry`, `herdr-read-session` | read an agent, an entry or a session with completion |
| `herdr-visit` | show an entry, attaching it first |
| `herdr-attach-entry`, `herdr-attach-terminal` | attach an entry, or a terminal id |
| `herdr-terminal-buffer` | the live buffer showing a terminal |
| `herdr-entry-label`, `herdr-entry-directory` | an entry's name and working directory |
| `herdr-session-for` | the session a directory routes to |
| `herdr-assign-project` | assign a project root to a session from Lisp |
| `herdr-with-session` | run code against another session |
| `herdr-all-sessions` | every session Emacs knows of or finds a socket for |
| `herdr-terminal-goto-prompt`, `herdr-terminal-screen` | go to an attached terminal's prompt, or read its screen |
| `herdr-terminal-send`, `herdr-terminal-paste` | type or paste into an attached terminal |
| `herdr-request`, `herdr-subscribe` | call a socket method, or subscribe to events |

`herdr-api.el` defines one `herdr-api-` function per herdr socket API method.

### Dashboard and herds

| Function | Does |
| --- | --- |
| `herdr-status-entry-at-point`, `herdr-status-target-at-point` | the row at point, as an entry or a target |
| `herdr-status-agent-row` | draw an agent on the dashboard's columns |
| `herdr-status-request-refresh` | schedule a coalesced redraw of every dashboard |
| `herdr-status-redraw-cached` | redraw every dashboard from its last fetch |
| `herdr-status-cached-agents`, `herdr-status-visible-agents` | the last redraw's agents, all or filtered |
| `herdr-status-harness-glyph` | a harness's vendor mark |
| `herdr-herds`, `herdr-herd-member-entries`, `herdr-herd-of-entry` | herds and their members |
| `herdr-herd-notice` | a one-line notice to a herd member |
| `herdr-herd-label-token`, `herdr-herd-label-with-token` | read and write `PREFIX:VALUE` words in a pane label |

## Files and buffers

| Path or buffer | Holds |
| --- | --- |
| `herdr-state-file` | project-to-session assignments stored by `herdr-assign-project-session` |
| `bin/herdr-herd` | the helper herd members run: `list`, `members`, `peers`, `of`, `join`, `leave`, `say`, `tell` |
| `*herdr-status*` | the dashboard, named by `herdr-status-buffer-name` |
| `*herdr message*` | a message being written in full |
| `*herdr-errors*` | CLI errors and output from failed Ghostel attachments |
| `*herdr: PROJECT@BRANCH LABEL*` | an attached terminal |
