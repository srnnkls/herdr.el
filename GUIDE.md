# The herdr.el guide

Every command, key, option and hook is listed in [REFERENCE.md](REFERENCE.md). This guide explains
how they work together, in the order you are likely to need them.

## Contents

- [How herdr.el works](#how-herdrel-works)
- [Servers and sessions](#servers-and-sessions)
- [Attaching terminals](#attaching-terminals)
- [Starting agents](#starting-agents)
- [The agent at hand](#the-agent-at-hand)
- [Writing to agents](#writing-to-agents)
- [The dashboard](#the-dashboard)
- [Changing the dashboard's columns](#changing-the-dashboards-columns)
- [Herds](#herds)
- [Editor workspaces](#editor-workspaces)
- [Building on herdr.el](#building-on-herdrel)
- [When something looks wrong](#when-something-looks-wrong)
- [Where to look next](#where-to-look-next)

## How herdr.el works

herdr keeps terminals alive in a server process, and herdr.el lets Emacs look into them. A few
terms carry the model:

- A *server* is a running herdr process. It owns every terminal, the processes in them, and the
  layout around them, and it keeps running when Emacs exits.
- A *session* is the name that selects a server. The `shared` session is the one a bare `herdr`
  command attaches to; every other name, such as `work`, runs a server of its own with its own
  socket.
- herdr arranges terminals in *workspaces*, which hold *tabs*, which hold *panes*. Each pane runs
  one terminal.
- An *agent* is a coding assistant herdr detects in a pane. herdr reports its name, its state
  (`idle`, `working`, `blocked` or `done`) and its working directory.
- A *harness* is the program an agent runs, such as `claude` or `codex`. herdr.el knows how to
  start, continue and resume each registered harness.
- An *attachment* is an Emacs buffer that shows a herdr terminal through a terminal emulator
  (Ghostel, vterm or Eat). The buffer runs `herdr terminal attach`; the terminal itself stays in
  the server.
- A *target* names one terminal across servers: the server's socket paired with the terminal's
  id. Lisp functions that act on an agent take a target.

Emacs talks to each server over its JSON socket. It reads snapshots of agents and panes, sends
prompts and keys, and subscribes to pane events so the dashboard and its own bookkeeping follow
what happens in herdr.

herdr stays in charge of process lifetime and terminal input. Killing an attached buffer, or
detaching it, never stops the process behind it. Only stopping an agent or closing its pane does.

## Servers and sessions

herdr.el talks to the server `herdr-session` names. The default, `shared`, is the server a bare
`herdr` attaches to, so agents you start from Emacs show up beside the ones you start in a
terminal. Setting it to `emacs` gives Emacs a server of its own, named by
`herdr-emacs-session-name`; a string names any other session.

Starting an agent starts its session's server when none answers, as `herdr server` detached from
Emacs, so the server outlives Emacs like one started from a shell. `herdr-auto-start-server` turns
that off, and `herdr-server-start-timeout` bounds the wait. Other commands start nothing: the
dashboard and the pickers skip a server that does not answer.

### Routing projects to sessions

Different projects can live on different servers. herdr.el picks the session for a directory in
this order:

1. An assignment for its project: `herdr-project-sessions` from your configuration, then the
   assignments stored in `herdr-state-file`. An assignment covers its project root and every
   directory below it.
2. The first rule in `herdr-session-alist` that matches. A rule matches a directory tree or
   calls a function with the directory.
3. `herdr-session`.

```elisp
(setq herdr-session-alist
      '(("~/work" . "work")
        ("~/src" . "private")))
```

`M-x herdr-assign-project-session` routes the current project and stores the choice in
`herdr-state-file`; with a prefix argument the assignment lasts only for this Emacs session. On
Doom, point `herdr-state-file` into `doom-state-dir`, since `locate-user-emacs-file` lands in the
cache directory there.

`herdr-project-root-function` decides what a project is. The default asks projectile, then
project.el.

### Which servers Emacs sees

Commands that look across servers, such as `herdr-jump` and the dashboard, cover every session
Emacs has been told about, plus every session whose socket exists on disk under
`~/.config/herdr/sessions/` (or `$XDG_CONFIG_HOME/herdr/sessions/`). A server started from a shell
with `herdr --session review` therefore shows up without any configuration.

## Attaching terminals

| Command | Offers |
| --- | --- |
| `herdr-attach-agent` | the agents on the session the current directory routes to |
| `herdr-attach-pane` | the panes on that session that run no agent |
| `herdr-attach-session` | every agent of a session you pick; with a prefix argument, every pane too |
| `herdr-jump` | every running agent on every server, attaching it if Emacs has no buffer for it |

An agent is attached through its lifecycle record, so Emacs remembers it as an agent and not only
as a terminal. A pane running no agent is attached as a plain terminal.

### Buffers and windows

A buffer's name leads with the project and git branch the terminal works in, as in
`*herdr: app@main review*`. A linked worktree is named after its main checkout, so every checkout
of a repository reads as one project. `herdr-buffer-name-function` names buffers differently. Two
terminals with the same label get a counter.

Attached terminals open in a side window on the right, each in its own slot so several sit side
by side. `herdr-window-side`, `herdr-window-width`, `herdr-window-height` and
`herdr-window-slot-base` shape the side window. Set `herdr-use-side-window` to nil to leave
placement to `display-buffer-alist` or a popup framework, or set `herdr-display-buffer-action` to
a `display-buffer` action of your own.

`herdr-terminal-backend` picks the terminal emulator. The default, `auto`, takes the first of
Ghostel, vterm and Eat that is installed.

### Input ownership and focus

Only one client at a time owns a terminal's input. With `herdr-attach-takeover` on, the default,
attaching claims it, and the other clients watch. `herdr-attach-session` attaches without
takeover, so a session someone else drives stays theirs; its buffers stay read-only while
another client holds the input.

With Ghostel, an Emacs window losing focus is not reported to the process by default, because
herdr's own client does not report focus again until its own focus changes, and the agent would
believe nobody is looking. `herdr-report-focus-loss` reports it anyway.

### When an attachment fails

With Ghostel, an attachment that ends with an error from the herdr CLI raises an Emacs warning
naming the session, the terminal and the reason. The last 16,384 characters of the terminal's
output are kept in `*herdr-errors*` before Ghostel deletes the buffer. Lines matching
`herdr-terminal-quiet-exit-regexps`, such as a detach or a pane whose process exited, end the
attachment without a warning.

A pane whose working directory no longer exists, such as a removed worktree, is attached with the
buffer's `default-directory` left where it was, and a message says so.

## Starting agents

`herdr-transient` offers three ways to start an agent, each reading a harness and a name:

| Key | Does |
| --- | --- |
| `N` | start a new session of the harness |
| `c` | continue the harness's most recent session |
| `r` | resume a session by the reference the harness uses |

A name is lowercase letters, digits, `-` and `_`, starting with a letter and at most 32
characters. An empty name becomes `agent`, and a name already in use gets a numeric suffix.

The agent starts in the current project on the session that project routes to. It gets a tab
labelled with its name, in the herdr workspace named by `herdr-workspace-label` for the project;
the workspace is created when it does not exist yet. Emacs attaches the terminal and shows it.

In the dashboard, `n` starts the harness of the row at point, or `herdr-status-new-harness` away
from a row, in that row's directory and session. `N` asks for the harness first. Neither waits for
the agent to be ready, so Emacs stays responsive while it boots.

From Lisp:

```elisp
(herdr-agent-start "claude" "review" :project-root "~/src/app/")
(herdr-agent-continue "codex" nil)
(herdr-agent-resume "claude" "api" "0b3f…")
```

### Harnesses

`herdr-agent-harnesses` lists the harnesses herdr.el can start: `claude` (Claude Code), `codex`,
`pi` and `omp` (Oh My Pi). Each descriptor maps the actions `start`, `continue` and `resume` to the
harness's own command-line arguments. Register another one with `herdr-agent-register-harness`:

```elisp
(herdr-agent-register-harness
 "aider"
 :label "Aider"
 :arguments '((start)
              (continue "--continue")
              (resume "--resume" :reference)))
```

`:reference` stands for the session reference `resume` reads. The herdr server must support the
harness too.

### Stopping and detaching

Detaching lets go of the terminal: Emacs kills the buffer and releases its own state, and the
agent keeps running. Stopping closes the agent's pane in herdr, which ends the agent.

| Action | Dashboard | Menu | Lisp |
| --- | --- | --- | --- |
| detach | `d` | | `herdr-agent-detach` |
| stop, after confirmation | `x` | | |
| stop | | `x` | `herdr-agent-stop` |
| close the pane at point, after confirmation | `K` | | |
| stop every agent on the current server | | `X` | `herdr-agent-stop-all` |

The menu's `x` and `X` act without asking.

## The agent at hand

Commands that do not ask which agent to use take the *foreground agent* of the current editor
workspace: the agent of this workspace you used most recently from Emacs, which selecting its
window counts as, then the one herdr has focused, then the first agent in the workspace. Where the
workspace runs no agent, the agent used most recently anywhere stands in, and failing that the
command asks.

| Command | Does |
| --- | --- |
| `herdr-toggle-agent` | show the workspace's agent, or hide the agent on screen |
| `herdr-switch-agent` | pick one of the workspace's agents and go to its prompt |
| `herdr-next-agent`, `herdr-previous-agent` | make the next or previous agent the foreground one |
| `herdr-message-send` | write to the foreground agent |
| `herdr-send` | send the context at point to the foreground agent |

`herdr-toggle-agent` hides an agent's window when one is on the frame and keeps its buffer. When
none is on screen, it shows the agent this workspace attached and used most recently. A workspace
holding no attached agent offers the agents running in it, or in the current project, or
anywhere; with no agent running at all, it offers to start a harness in the workspace. The
current workspace never changes: the agent comes to you. The terminal goes out through
`display-buffer`, so your editor's popup rules place it unless `herdr-toggle-agent-display-action`
says otherwise, and the cursor lands at the agent's prompt.

With a prefix argument, `herdr-toggle-agent`, `herdr-message-send` and `herdr-send` read the agent
instead, and `herdr-switch-agent` offers every running agent.

`herdr-next-agent` and `herdr-previous-agent` step through the workspace's agents in the order
herdr lists them and report which one is now in front; the next message goes there.

## Writing to agents

`herdr-message-send` reads a message and sends it with the context at point. In a file, the
context is the active region, or the current line:

````text
Please make this return early.

---
Emacs context
file: /home/you/src/app/server.py:40-52
mode: python-mode

```
def handle(request):
    ...
```
````

The message comes first, then a `---` barrier, then the context. A buffer that visits no file
contributes no context unless a function on `herdr-send-context-functions` provides some.

### Where the message is written

By default the message is read in the minibuffer, where `M-p` brings back earlier messages. Two
keys change what happens next:

| Key | Does |
| --- | --- |
| `C-c '` | move the draft to a `*herdr message*` buffer, where `C-c C-c` sends and `C-c C-k` discards |
| `C-<return>` | send without moving the cursor to the agent |

With [cera](https://github.com/srnnkls/cera) installed, set `herdr-message-read-function` to
`herdr-message-read-field` to write the message in a field directly under the region or line it
is about. `RET` or `C-c C-c` sends, `C-c C-k` or `C-g` cancels, and `C-<return>` sends in place.
The field is marked with the vendor glyph of the harness it writes to, in that harness's colour.
A buffer that a process writes into, such as a terminal, still uses the minibuffer.

After sending, `herdr-message-show-agent` decides what happens to the agent's terminal: `focus`,
the default, shows it and moves the cursor to its prompt, `t` shows it and keeps the cursor where
it was, and nil leaves it alone. A terminal Emacs has no buffer for is attached first.

### Keeping a half-written prompt

A prompt sent through herdr is appended to whatever the agent's input line already holds. When
Emacs has the agent's terminal attached and its input line holds a draft, herdr.el clears the
line, sends the message, and types the draft back afterwards. `herdr-agent-preserve-draft` turns
this off. `herdr-agent-prompt-marker` and `herdr-agent-prompt-rule` describe where a harness's
input line starts and ends on screen, and `herdr-agent-prompt-clear` and
`herdr-agent-prompt-submit` are the keys that clear and submit it.

### Sending context without a message

`herdr-send` sends the context at point to the foreground agent as it stands. Here any buffer
contributes its region or line, with a `buffer:` line in place of `file:` where no file is
visited.

### Picking the agent by scope

The scoped commands name where to pick the agent from. The ones that read offer completion even
for a single candidate; the `recent` ones take the agent used most recently in that scope without
asking.

| Scope | Message, pick | Message, most recent | Context only, pick | Context only, most recent |
| --- | --- | --- | --- | --- |
| every server | `herdr-message-send-session` | `herdr-message-send-recent-session` | `herdr-send-session` | `herdr-send-recent-session` |
| current project | `herdr-message-send-project-session` | `herdr-message-send-recent-project-session` | `herdr-send-project-session` | `herdr-send-recent-project-session` |
| current workspace | `herdr-message-send-workspace-session` | `herdr-message-send-recent-workspace-session` | `herdr-send-workspace-session` | `herdr-send-recent-workspace-session` |

Project scope compares the roots `herdr-project-root-function` returns, so linked worktrees are
separate projects here. Workspace scope compares `herdr-current-workspace-label` with the
`herdr-workspace-label` of each agent's directory, and also counts agents whose buffer belongs to
the current workspace.

### Primary agents

A *primary agent* is bound to a buffer, a project or an editor workspace, and
`herdr-message-send-primary-session` and `herdr-send-primary-session` write to it. The buffer's
binding wins over the project's, which wins over the workspace's. With no binding, the first use
reads an agent and binds it to the current project.

| Command | Binds |
| --- | --- |
| `herdr-associate-agent` | the current buffer |
| `herdr-associate-project-agent` | the current project |
| `herdr-associate-workspace-agent` | the current editor workspace |
| `herdr-dissociate-agent` | clears the buffer's binding; with a prefix argument, the project's and workspace's too |

Bindings last for the Emacs session and drop out when their agent is gone.

## The dashboard

`M-x herdr-status` opens a dashboard over every server Emacs sees. It takes over the selected
window the way `magit-status` does; `herdr-status-display-action` changes that. `M-x
herdr-project-status` opens the same dashboard limited to the current project, and `p` switches
between the two. The header line says which scope is showing.

The dashboard is built from sections, top to bottom:

| Section | Holds |
| --- | --- |
| sections other packages insert | for example limen's inbox |
| `Recent` | agents in the order you used them, when there are any |
| `Herds` | one collapsible entry per herd, when any agent is in one |
| `Agents` | the agent list, with its count, state summary, grouping, order and filters in the heading |
| `Panes` | panes that run no agent |
| `Sessions` | one entry per server: whether it answers, its socket, herdr version, protocol, and counts |

In the project view, every section keeps only entries working in the project, and `Sessions`
keeps only servers hosting one of them.

Sections work as in Magit: `TAB` toggles one, `S-TAB` cycles all of them, and `M-1` to `M-4` set
the level for the whole buffer. `n` and `p` belong to the dashboard, so move between sections with
`M-n` and `M-p`.

### Reading a row

```text
• ● api-review   claude  ▣ w1:p1  ▤ app  ⎇ feat/hooks  ◆ opus  ◔ 561k/1M  /src/app
  ○ docs         codex   ▣ w1:p2  ▤ app  ⎇ main                            /src/app
```

A row starts with `herdr-status-attached-glyph` when Emacs has a buffer for the agent, then the
state glyph in the state's colour (hollow for `idle`), the name, and the harness behind its vendor
mark. The session follows once more than one server is in play. Then come the pane, the herdr
workspace, the git branch, the model, the share of its context window the agent holds, and the
directory. A column no row has a value for takes no room.

The directory is herdr's `foreground_cwd` when it reports one, otherwise the directory the pane
opened in. An agent that moves itself into a worktree therefore moves its row, its project scope
and its buffer's `default-directory` with it. A directory an agent only enters inside a single
shell command stays invisible to herdr.

A name longer than `herdr-status-name-width` is cut; nil, the default, allows a third of the
window. Any cut field shows its whole value in the echo area when point crosses it.

### Expanding a row

`TAB` on a row expands it into a preview of what the agent last said: the tail of its recent
output, without the harness's rules, prompt, status bar and tool calls. `herdr-status-preview-lines`
lines are shown, and 0 turns previews off. With memex.el installed, previews render as markdown.
Rows of agents in a state listed in `herdr-status-expanded-states`, `working` by default, start
expanded, and `e` opens or closes all of them.

`t` also shows each expanded agent's metadata: its terminal, pane, workspace and tab, the name the
harness gave the session, and whatever fields the harness's adapter reports.

### Acting on a row

| Key | Does |
| --- | --- |
| `RET` | show the agent or pane, attaching it first; on a session row, attach the whole session |
| `C-u RET` | also move herdr's own focus to the agent's pane |
| `o` | show it in another window |
| `P` | send a prompt |
| `R` | rename an agent, or relabel a pane |
| `d` | detach: Emacs lets go of the terminal, the pane runs on |
| `x` | stop the agent, after confirmation |
| `K` | close the pane at point, after confirmation |
| `n`, `N` | start an agent where the row works |
| `h` | open the herd menu |

`?` opens a menu of these keys and `q` quits the dashboard.

### Filtering, ordering and grouping

`f` opens the filter menu: by harness, by state, to the current project, to the current editor
workspace, or to the agents Emacs has a buffer for. Harness and state offer the values of the
section at point, so filtering inside a herd asks about that herd. Filters combine, stay through
a refresh, and are listed in the `Agents` heading. `f -` drops one and `f DEL` clears them all.

Each filter is an entry of `herdr-status-predicates`, and adding an entry adds a filter, reachable
under `f x`:

```elisp
(add-to-list 'herdr-status-predicates
             (cons 'nameless
                   (lambda ()
                     (lambda (entry) (null (alist-get 'name entry))))))
```

The outer function runs when the filter is added and may prompt. It returns a predicate of one
entry, or nil to add nothing.

`O` orders the agent list by state, name, harness, pane, session or directory, or by any key in
`herdr-status-sorts` under `O x`; choosing the same column again reverses it. States sort in
`herdr-status-state-order`.

`u` draws the agent list in groups and `U` picks what to group by: project, directory, session,
harness, model or state, from `herdr-status-groups`. A collapsed group stays collapsed through a
refresh.

Filters, order and grouping belong to one dashboard buffer. With `herdr-status-buffer-name-function`
set to `herdr-status-workspace-buffer-name`, each editor workspace keeps a dashboard of its own.

### Refreshing

`g` fetches one snapshot per server and redraws. herdr events redraw a live dashboard after
`herdr-status-refresh-delay` seconds of idle time, and `herdr-status-auto-refresh` turns that off.
A preview costs one request per row and is reused for `herdr-status-preview-ttl` seconds; adapter
fields cost one request per row and are reused until the next fetch.

### The dashboard as a picker

Commands that read an agent, such as `herdr-attach-agent`, the message commands, and the menu,
offer the same rows the dashboard draws: state, name, harness with its mark, branch, and where
the agent works, written `project:checkout` for a linked worktree. The agent you used most
recently comes first. A name longer than `herdr-read-agent-name-width` is cut in the row and still
matches in full.

Run from inside the dashboard, these commands offer what point stands in: one herd's members, a
group, the recent agents, or an inserted section. Elsewhere in the dashboard they offer the agents
the scope and filters leave. `herdr-status-switch` reads an agent this way and shows it.

## Changing the dashboard's columns

The fields after the harness come from `herdr-status-columns`. Each entry names a field and says
how to compute it. This one appends a `host` column read from a token the pane reports:

```elisp
(add-to-list 'herdr-status-columns
             `(host :value ,(lambda (entry)
                              (alist-get 'host (alist-get 'tokens entry))))
             t)
```

- `:value` is a function of the entry, or of the entry and a plist whose `:workspaces` resolves a
  herdr workspace label. It returns the text, or nil for none.
- `:face` is the face the text is drawn in, `herdr-status-meta` by default.
- `:width` is `shared`, the default, to align the field across rows, or `own` to give each row the
  width of its own value.

Values come from three places. `pane` and `workspace` are fields herdr reports. `branch` and
`directory` are computed from the working directory. `model` and `context` are read from the
entry's `tokens`, the metadata any program reports to its pane through herdr's
`pane.report_metadata`; `herdr-status-model-token` and `herdr-status-context-token` name the
tokens. Any package that reaches the herdr socket can report tokens of its own for a column to
show.

| To change | Set |
| --- | --- |
| the widest a field may be | `herdr-status-column-widths`, an alist of `(FIELD . COLUMNS)` |
| the glyph leading a field | `herdr-status-field-glyphs`, candidates in order of preference |
| whether Nerd Font glyphs are used | `herdr-status-nerd-font` |
| the state glyph | `herdr-status-state-glyph` and `herdr-status-state-glyphs` |
| the harness marks | `herdr-status-harness-marks` |
| whether a cut value is echoed | `herdr-status-echo-cut-fields` |

A glyph setting lists candidates, and the first one the display can draw wins, so a frame without
a Nerd Font falls back to Unicode shapes and a terminal to ASCII. An empty candidate draws the
field without a glyph. On a graphical frame without a patched font, set `herdr-status-nerd-font`
to nil to avoid boxes.

## Herds

A *herd* is a named group of agents that know each other's names and reach one another with the
`herdr` CLI. `h` in the dashboard opens the herd menu:

| Key | Does |
| --- | --- |
| `a` | add the agent at point to a herd, or name a new one |
| `A` | add several: the rows the region covers, or agents picked from the session |
| `r` | take the agent at point out of its herd |
| `d` | dissolve a herd, leaving its agents running and named |
| `b` | send one prompt to every member that is not busy |
| `R` | send the roster again, after membership changed |

A joining agent receives `herdr-herd-protocol`, any paragraphs from
`herdr-herd-protocol-functions`, the path of the helper script, and the live roster. The members
already there get a one-line notice:

```text
[herd refactor] memex-index joined (claude, ~/src/memex). No reply needed.
```

Leaving sends the same kind of notice. A notice opens with `herdr-herd-notice-prefix`, so an agent
or a hook can tell it from a task. Nothing is written into the agent's project, so every harness
joins on the same terms.

An agent in a state listed in `herdr-herd-busy-states`, `working` or `blocked` by default, is
skipped and named instead of being interrupted mid-turn.

Members address each other by name. An agent without one is named when it joins, from its
repository and the task its terminal title shows, as in `memex-incremental-index`; the name is
offered for editing and made unique on its server. A linked worktree is named after its repository.

### A herd lives on one session

`herdr agent prompt` reaches one server, so a herd belongs to one session, and two herds with the
same name on two sessions are two herds, written `work/refactor` when the session is not
`shared`. Herd commands take the session from point: an agent row, a herd, or a session row.
Elsewhere they ask, listing each session beside its socket:

```text
Session (default shared):
shared   ~/.config/herdr/herdr.sock
work     ~/.config/herdr/sessions/work/herdr.sock
```

Adding an agent from another session is refused.

### Membership lives in herdr

A member's pane carries its herd in its manual label, as `herd:NAME` ahead of anything else the
label says. herdr keeps the label across restarts and reports it with the pane, so agents join,
leave and read herds with the same CLI they use for everything else, with no editor running:

```console
$ herdr pane rename w71:p1 "herd:refactor"      # join
$ herdr pane list | jq -r '.result.panes[].label'
$ herdr pane rename w71:p1 --clear              # leave
```

A herd exists as long as some live pane names it. herdr draws a pane's label only where the pane
has no terminal title, and agent panes always have one, so the label stays out of sight. Herd
commands keep the rest of the label intact. Other packages store their own per-pane settings in
the same label as further `PREFIX:VALUE` words, read with `herdr-herd-label-token` and written with
`herdr-herd-label-with-token`.

`bin/herdr-herd` wraps these calls for agents. Every pane argument defaults to `$HERDR_PANE_ID`,
so an agent talks about itself without arguments:

```console
$ herdr-herd join refactor
$ herdr-herd peers
$ herdr-herd say "rebased onto main, your turn"
```

The roster gives the script's absolute path, so agents need no `PATH` setup. `herdr-herd-command`
controls that path, and nil leaves agents only the plain `herdr` commands. The script needs
`python3` and refuses to run outside a herdr pane.

## Editor workspaces

herdr.el lines up herdr workspaces with the ones your editor keeps. Three functions carry the
mapping:

- `herdr-workspace-label-function` names the herdr workspace a directory's agents belong in. The
  default uses the directory's own name; an editor that groups work its own way returns the name
  of the workspace that owns the directory.
- `herdr-current-workspace-label-function` names the editor workspace you are in. The default uses
  the current project.
- `herdr-agent-workspace-buffer-predicate` says whether a buffer belongs to the current editor
  workspace. The default asks `persp-mode`, which Doom's workspaces are built on, where it is
  loaded, and counts every buffer otherwise.

`herdr-attach-session` attaches a whole session in groups. With
`herdr-attach-session-workspace-policy` at `mirror`, the default, each herdr workspace is one
group; `merge` joins the agents whose directories share a `herdr-workspace-label`.
`herdr-workspace-open-function` opens an editor workspace for each group before its terminals are
attached, and its return value is bound to `herdr-attach-session-workspace` while they are.

Plain Emacs can use tab-bar tabs as workspaces:

```elisp
(setq herdr-attach-session-workspace-policy 'merge
      herdr-workspace-open-function
      (lambda (_workspace directory)
        (let ((name (herdr-workspace-label directory)))
          (tab-bar-switch-to-tab name)
          name)))
```

`tab-bar-switch-to-tab` selects the tab of that name, or creates it.

## Building on herdr.el

### Adapters

An adapter customizes how one harness runs under Emacs, for example to hand it editor context or
a transport of its own. Register one function per harness:

```elisp
(herdr-agent-register-adapter "claude" #'my-claude-adapter)
(herdr-agent-adapter "claude")                     ; the registered function
(herdr-agent-unregister-adapter "claude" #'my-claude-adapter)
```

The adapter is called with the agent's session record, a phase, and the phase's context:

| Phase | Called | Returns |
| --- | --- | --- |
| `:prepare` | before the pane is created | environment entries for the pane, or nil |
| `:arguments` | with the harness's complete argument list | a replacement list, or nil |
| `:adopted` | with the herdr agent record, when Emacs takes up a running agent | ignored |
| `:attached` | once the terminal is attached locally, before herdr confirms anything | ignored |
| `:status` | when the agent's status is asked for | an alist of extra fields, or nil |
| `:detach` | when Emacs lets go of the agent | ignored |

`:detach` releases only what the adapter owns and must be safe to call again. A session keeps the
adapter it first ran with until it is cleaned up. Registering the same function again does
nothing, registering a different one for the same harness signals an error, and unregistering
refuses while a live session holds the adapter. Keep adapter state on the session with
`herdr-agent-set-adapter-state`; herdr.el does not look at it.

Adapters reach the host through `herdr-agent-resolve-session`, `herdr-agent-list`,
`herdr-agent-send-text`, `herdr-agent-prompt`, `herdr-agent-adopt` and the `herdr-agent-session-`
accessors. `herdr-agent-event-functions` sees every pane event after herdr.el has updated its own
records.

### Hooks and extension points

| To | Use |
| --- | --- |
| provide the context a message carries | `herdr-send-context-functions` |
| build the prompt a message becomes | `herdr-message-compose-functions` |
| claim an entry before it is attached as a plain terminal | `herdr-attach-functions` |
| act on every buffer that starts showing a terminal | `herdr-buffer-functions` |
| run code once point is at a terminal's prompt | `herdr-terminal-focus-functions` |
| add text to completion annotations | `herdr-entry-annotation-functions` |
| add a section to the dashboard | `herdr-status-sections-functions` |
| act after the dashboard redraws | `herdr-status-refresh-hook` |
| hold off a redraw while something covers the dashboard | `herdr-status-redraw-inhibit-functions` |
| add paragraphs to the herd protocol | `herdr-herd-protocol-functions` |
| observe prompts herd commands send | `herdr-herd-sent-functions` |

A section function receives the agent entries, the column widths, and the tab and workspace
indexes of the redraw. It draws agents on the dashboard's columns with `herdr-status-agent-row`,
and inserts nothing when it has nothing to show. When its data changes it calls
`herdr-status-request-refresh`, which schedules one coalesced redraw.

`herdr-status-entry-at-point` returns the agent or pane row at point, so a command of your own can
act on it, for example to attach into a workspace of your choosing. `herdr-status-cached-agents`
and `herdr-status-visible-agents` return the entries of the last redraw without another request.

`herdr-api.el` wraps every method of the herdr socket API, one function per method, for anything
the commands do not cover.

## When something looks wrong

- `no terminal backend: install ghostel, vterm or eat`: install one of them, or set
  `herdr-terminal-backend`.
- `No herdr server on …` or `no herdr server answering on …`: start that session's server with
  `herdr --session NAME server`, or leave `herdr-auto-start-server` on so starting an agent starts
  it. `herdr executable not found` means `herdr-executable` names nothing on `PATH`.
- The `Sessions` heading lists a session as `unreachable`: its socket exists but no server
  answers. Start that session's server, or remove the stale socket.
- An attached terminal is read-only: another client owns its input. Attach again with
  `herdr-attach-takeover` on; `herdr-attach-session` attaches without it.
- An agent stays unfocused in herdr after its window lost focus in Emacs: keep
  `herdr-report-focus-loss` nil.
- An attachment closed with a warning: read `*herdr-errors*` for the CLI's reason and the output
  that preceded it.
- Boxes appear instead of glyphs in the dashboard: set `herdr-status-nerd-font` to nil, or
  install a Nerd Font.
- A message arrived glued to text already in the agent's prompt: Emacs only preserves a draft for
  a terminal it has attached. Attach the agent, or clear its prompt first.
- An agent is missing from the project view: its working directory belongs to another
  repository or project. Switch to the global view with `p`.

## Where to look next

- [REFERENCE.md](REFERENCE.md) lists every command, key, option, face and hook.
- [README.md](README.md) has installation and a first session.
- The herdr documentation at [herdr.dev](https://herdr.dev) covers the server, its CLI and its
  socket API.
