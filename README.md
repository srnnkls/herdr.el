# herdr.el

Control persistent [herdr](https://herdr.dev) terminal workspaces from Emacs.

## About

herdr.el is an Emacs client for herdr, the persistent terminal workspace manager. The herdr server
owns processes, terminals, tabs and workspaces; Emacs attaches terminal buffers to them. A herdr
pane and its Emacs buffer are two views of one process, so killing the buffer, detaching, or
restarting Emacs leaves the process running, and attaching again picks it up where it was.

On top of attachment, herdr.el manages coding agents such as Claude Code, Codex, Pi and Oh My Pi.
It starts, continues and resumes them in herdr tabs, sends them messages that carry the region or
line at point, tracks the agent you work with in each editor workspace, and lists every agent on
every herdr server in a Magit-style dashboard. Agents can also form a *herd*, a named group whose
members know each other and talk through the `herdr` CLI.

Reach for it when agents or long-running terminals should outlive your Emacs session, when several
agents run across projects and you want one place to see and steer them, or when you want to hand
an agent the code in front of you without copying it.

## Installation

herdr.el needs Emacs 29.1 or newer and the `herdr` executable, from [herdr.dev](https://herdr.dev),
on `PATH` or named by `herdr-executable`. It attaches through whichever of Ghostel, vterm or Eat
you have installed, and the `bin/herdr-herd` helper that herd members run needs `python3`.

On Emacs 30 or newer, install it with `use-package`:

```elisp
(use-package herdr
  :vc (:url "https://github.com/srnnkls/herdr.el" :rev :newest)
  :bind (("C-c h" . herdr-transient)))
```

On Emacs 29, run `M-x package-vc-install RET https://github.com/srnnkls/herdr.el RET`.

On Doom Emacs, add this to `packages.el`; `bin` carries the helper herd members run:

```elisp
(package! herdr :recipe (:host github :repo "srnnkls/herdr.el" :files (:defaults "bin")))
```

herdr.el itself binds no global key. The agent commands work best on keys of their own, for example:

```elisp
(keymap-global-set "s-c" #'herdr-toggle-agent)
(keymap-global-set "s-m" #'herdr-message-send)
```

## Getting started

Open a file in a git project and run `M-x herdr-project-status`. The dashboard lists the agents
herdr reports for this project, and there are none yet.

Press `N` and pick `claude`, or another harness you have installed. herdr.el starts a herdr server
if none is running, opens a tab in a herdr workspace named after the project, and starts the agent
there. Emacs attaches the agent's terminal and shows it in a side window, in a buffer named
`*herdr: app@main agent*`: the project, its branch, and the agent's name. The dashboard redraws,
and the agent appears under `Agents` with its state, harness, pane, workspace, branch and
directory.

Select a few lines in a source file and run `herdr-message-send`. It reads a message in the
minibuffer and sends it with the file name, the line range and the selected lines. The agent's
terminal comes up with the cursor at its prompt.

`herdr-toggle-agent` hides the terminal and shows it again. Kill the buffer, or quit Emacs, and the
agent keeps running in herdr; `herdr-toggle-agent` offers it again and attaches it. In the
dashboard, `d` on the agent's row lets go of its terminal and leaves it running, and `x` stops it.

## Commands

The menu `herdr-transient` reaches most of these. The last column gives the dashboard's key.

| Command | Does | Dashboard |
| --- | --- | --- |
| [`herdr-status`](REFERENCE.md#dashboard) | open the dashboard over every herdr server | |
| [`herdr-project-status`](REFERENCE.md#dashboard) | open the dashboard for the current project | `p` |
| [`herdr-transient`](REFERENCE.md#the-herdr-menu) | open the menu of herdr commands | |
| [`herdr-toggle-agent`](REFERENCE.md#the-agent-at-hand) | show this workspace's agent, or hide the one on screen | |
| [`herdr-switch-agent`](REFERENCE.md#the-agent-at-hand) | pick an agent of this workspace and go to its prompt | |
| [`herdr-message-send`](REFERENCE.md#messages-and-context) | write to the agent at hand, with the context at point | |
| [`herdr-send`](REFERENCE.md#messages-and-context) | send the context at point to the agent at hand | |
| [`herdr-attach-agent`](REFERENCE.md#attaching) | attach a running agent's terminal | `RET` |
| [`herdr-attach-pane`](REFERENCE.md#attaching) | attach a pane that runs no agent | `RET` |
| [`herdr-attach-session`](REFERENCE.md#attaching) | attach every agent of a herdr session | `RET` on a session |
| [`herdr-jump`](REFERENCE.md#attaching) | go to any running agent on any server, attaching it if needed | |
| [`herdr-assign-project-session`](REFERENCE.md#sessions-and-routing) | route the current project to a herdr session | |
| [`herdr-herd-dispatch`](REFERENCE.md#herds) | put agents in herds and prompt a herd | `h` |

[REFERENCE.md](REFERENCE.md) lists every command, key, option, face and hook.

## Concepts

| Term | Meaning |
| --- | --- |
| *server* | a running herdr process; it owns the terminals and outlives Emacs |
| *session* | the name that selects a server: `shared` is the default, every other name runs its own |
| *workspace*, *tab*, *pane* | herdr's layout: a workspace holds tabs, a tab holds panes, a pane runs one terminal |
| *agent* | a coding assistant herdr detects in a pane, with a name and a state such as `idle` or `working` |
| *harness* | the program an agent runs: `claude`, `codex`, `pi` or `omp` out of the box |
| *attachment* | an Emacs buffer showing a herdr terminal; closing it leaves the pane running |
| *editor workspace* | the unit your editor groups buffers in, such as a perspective or a tab |
| *foreground agent* | the agent a workspace writes to without asking: the one used most recently |
| *primary agent* | an agent bound to a buffer, project or workspace for the `-primary-session` commands |
| *herd* | a named group of agents on one session that know each other's names |

[GUIDE.md](GUIDE.md#how-herdrel-works) explains how these fit together.

## Works with

Each of these is optional, and herdr.el runs without any of them.

- [cera](https://github.com/srnnkls/cera), write into a temporary field in another buffer. With
  `herdr-message-read-function` set to `herdr-message-read-field`, a message is written in a field
  under the lines it is about.
- [memex.el](https://github.com/srnnkls/memex.el), search indexed agent conversation history. It
  binds `s` (search) and `m` (memex menu) in the dashboard, adds `v` (transcript) to
  `herdr-transient`, and renders agent previews as markdown.
- [limen](https://github.com/srnnkls/limen), an Emacs interface for agents. It registers
  [adapters](GUIDE.md#adapters) that give agents editor context, and adds an inbox section to the
  dashboard.
- [scholia](https://github.com/srnnkls/scholia), annotations as work items. It sends annotations
  to herdr agents and panes.

## Documentation

- [GUIDE.md](GUIDE.md) covers attaching, starting and messaging agents, the dashboard, herds and
  editor workspaces, starting at [How herdr.el works](GUIDE.md#how-herdrel-works).
- [REFERENCE.md](REFERENCE.md) lists every command, key, user option, face, hook and Lisp entry
  point.

## Development

```sh
eask install-deps --dev
eask compile
eask run script test            # every ERT suite
eask lint checkdoc --strict
scripts/compile-and-test.sh     # compile and test with plain Emacs
bin/herdr-herd-tests.sh         # tests for the herd helper
```

CI runs the suites on Ubuntu and macOS with Emacs 29.1, 30.1 and 31.1, plus a soft-failing Emacs
snapshot, and runs Eask's `checkdoc`, `declare`, `package`, `indent`, `regexps` and `keywords`
lints with `--strict`.

Where the code lives:

- `herdr-core.el`: the socket client, session routing, and starting a server.
- `herdr-api.el`: one wrapper per herdr socket API method, generated by `tools/herdr-api-gen.el`
  from herdr protocol 17. Regenerate it after a herdr upgrade instead of editing it.
- `herdr.el`: attaching terminals, buffer names and windows, reading entries, attaching sessions.
- `herdr-terminal.el`: reading and driving an attached terminal, per backend.
- `herdr-agent.el`: the agent lifecycle, adapters, messages, context, and the agent at hand.
- `herdr-status.el`: the dashboard.
- `herdr-herd.el` and `bin/herdr-herd`: herds.
- `herdr-transient.el`: the `herdr-transient` menu.

## License

herdr.el is GPL-3.0-or-later; see [LICENSE](LICENSE).
