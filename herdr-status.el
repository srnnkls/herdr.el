;;; herdr-status.el --- Herdr status dashboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A Magit-style dashboard over every herdr server Emacs knows about.
;; Sections collapse, the agent list filters, and each agent expands into
;; the metadata herdr and its adapters report for it.
;;
;;   M-x herdr-status
;;   M-x herdr-project-status
;;
;; `herdr-status-predicates' is the filter extension point.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eieio)
(require 'magit-section)
(require 'transient)
(require 'herdr-agent)
(require 'herdr-herd)

;;;; Appearance

(defgroup herdr-status nil
  "The herdr status dashboard."
  :group 'herdr)

(defface herdr-status-label
  '((t :inherit font-lock-function-name-face))
  "Face for an agent's name in the dashboard."
  :group 'herdr-status)

(defface herdr-status-label-quiet
  '((t :inherit default))
  "Face for the name of an entry Emacs has no buffer for."
  :group 'herdr-status)

(defface herdr-status-path
  '((t :inherit font-lock-comment-face))
  "Face for a directory in the dashboard."
  :group 'herdr-status)

(defface herdr-status-meta
  '((t :inherit shadow))
  "Face for the pane, workspace, and separators trailing a row."
  :group 'herdr-status)

(defface herdr-status-preview-status
  '((t :inherit (italic shadow)))
  "Face for the harness status line heading a preview."
  :group 'herdr-status)

(defface herdr-status-detail-key
  '((t :inherit font-lock-constant-face))
  "Face for a field name in an expanded agent."
  :group 'herdr-status)

(defface herdr-status-active-filter
  '((t :inherit font-lock-keyword-face))
  "Face for the active filters shown in the agents heading."
  :group 'herdr-status)

(defface herdr-status-attached
  '((t :inherit herdr-status-label))
  "Face for the marker on an entry Emacs has a buffer for."
  :group 'herdr-status)

(defface herdr-status-state-idle
  '((t :inherit success))
  "Face for an agent waiting for work."
  :group 'herdr-status)

(defface herdr-status-state-working
  '((((class color) (min-colors 88) (background light)) :foreground "#e8973a")
    (((class color) (min-colors 88) (background dark)) :foreground "#f5a04a")
    (t :inherit warning))
  "Face for an agent that is working.
A theme's `warning' is often the dull yellow of a compiler note, which
reads as brown beside the other states, so the colour is its own."
  :group 'herdr-status)

(defface herdr-status-state-blocked
  '((t :inherit error))
  "Face for an agent waiting on the user."
  :group 'herdr-status)

(defface herdr-status-state-done
  '((((class color) (min-colors 88)) :foreground "#5b9dd9")
    (t :inherit link))
  "Face for an agent that finished."
  :group 'herdr-status)

(defface herdr-status-state-unknown
  '((t :inherit shadow))
  "Face for an agent state herdr did not report."
  :group 'herdr-status)

(defface herdr-status-harness-claude
  '((((class color) (min-colors 88)) :foreground "#d97757")
    (t :inherit warning))
  "Face for the mark drawn beside a Claude Code agent."
  :group 'herdr-status)

(defface herdr-status-harness-codex
  '((((class color) (min-colors 88) (background dark)) :foreground "#ededed")
    (((class color) (min-colors 88) (background light)) :foreground "#3c3c3c")
    (t :inherit default))
  "Face for the mark drawn beside a Codex agent."
  :group 'herdr-status)

(defface herdr-status-nerd-glyph
  '((t :height 0.75))
  "Face lending every Nerd Font glyph its size, over its own colour.
The patched glyphs are drawn larger than the text around them, so they
are taken down to sit with it.  A line is as tall as the tallest glyph
on it, and nothing shrinks it again, so a glyph scaled past 1.0 spreads
the whole list."
  :group 'herdr-status)

(defcustom herdr-status-nerd-font 'auto
  "Whether a glyph may be drawn from a Nerd Font.
`auto' draws one on a graphical frame and leaves a terminal the Unicode
shape behind it.  Emacs answers that a Private Use Area character is
displayable whether or not a font holds it, so a graphical frame without
a patched font draws tofu until this is set to nil.  Non-nil asks for
the glyph on any display, and nil never draws one."
  :type '(choice (const :tag "Where a font covers it" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'herdr-status)

(defcustom herdr-status-harness-marks
  '(("claude" ("\uec82" "✳") . herdr-status-harness-claude)
    ("codex" ("\uec81" "⌬") . herdr-status-harness-codex))
  "Marks drawn before an agent's harness, keyed by that harness.
Each entry gives the glyph and the face it is drawn in.  A harness
without one is drawn blank, so harness names stay in the same column
either way,
and a glyph wider than one column pushes them out of it.

A glyph may be a list of candidates in order of preference, of which the
first the display can show is drawn: the vendor logos
\\='nf-cod-claude\\=' and \\='nf-cod-openai\\=' come first and the
Unicode marks behind them, and `herdr-status-nerd-font' says whether the
logos are considered at all."
  :type '(alist :key-type string
                :value-type (cons (choice (string :tag "Glyph")
                                          (repeat (string :tag "Candidate")))
                                  (face :tag "Face")))
  :group 'herdr-status)

(defcustom herdr-status-state-faces
  '(("idle" . herdr-status-state-idle)
    ("working" . herdr-status-state-working)
    ("blocked" . herdr-status-state-blocked)
    ("done" . herdr-status-state-done))
  "Faces keyed by the agent state herdr reports.
A state without an entry falls back to `herdr-status-state-unknown', so
a state herdr gains later still renders."
  :type '(alist :key-type string :value-type face)
  :group 'herdr-status)

(defcustom herdr-status-state-glyph "●"
  "String standing for an agent's state.
Drawn in the state's own face, so the glyph carries the state on rows
that show no other mark of it.  A list gives candidates in order of
preference, of which the first the display can show is drawn."
  :type '(choice (string :tag "Glyph") (repeat (string :tag "Candidate")))
  :group 'herdr-status)

(defcustom herdr-status-field-glyphs
  '((pane "\uea85" "▣" "#")
    (workspace "\ueae3" "▤" "")
    (branch "\uf126" "\ue0a0" "⎇" "@")
    (model "\ueb26" "◆" "*")
    (directory "\uea83" "/" ""))
  "Glyphs leading the fields that trail a row, keyed by field.
Each entry lists candidates in order of preference and the first one the
display can show is drawn, so a font without the Nerd Font glyphs falls
back to the Unicode ones and a terminal without any of them to `@'.  An
empty candidate draws the field bare, and `herdr-status-nerd-font' says
whether the Nerd Font candidates are considered at all."
  :type '(alist :key-type symbol :value-type (repeat string))
  :group 'herdr-status)

(defcustom herdr-status-state-glyphs '(("idle" . "○"))
  "Glyphs replacing `herdr-status-state-glyph', keyed by agent state.
An agent waiting for work is drawn hollow; a state without an entry here
takes the solid bullet in its own colour.  A value takes the same
candidates `herdr-status-state-glyph' does."
  :type '(alist :key-type string
                :value-type (choice (string :tag "Glyph")
                                    (repeat (string :tag "Candidate"))))
  :group 'herdr-status)

(defcustom herdr-status-name-width nil
  "How many columns the name may take before it is cut short.
An agent named after the prompt it was given runs long enough to push
the columns after it off the line.  Nil gives the name a third of the
window instead, so a narrow one keeps what follows in view."
  :type '(choice (const :tag "A third of the window" nil) natnum)
  :group 'herdr-status)

(defcustom herdr-status-preview-spacing 3
  "Pixels of air above a preview.
The space is asked of the preview's first line as a total height, the
only form that adds room above a line.  A collapsed row keeps a little
of it.  Terminal frames measure in whole lines and draw none of it."
  :type 'natnum
  :group 'herdr-status)

(defcustom herdr-status-show-details nil
  "Whether an expanded agent shows its metadata under its preview.
`herdr-status-toggle-details' turns it on and off for one dashboard."
  :type 'boolean
  :group 'herdr-status)

(defcustom herdr-status-preview-markdown t
  "Whether a preview is drawn through a markdown renderer where there is one.
`memex-markdown-render' is the renderer looked for, and a machine
without memex draws the harness's own lines as they came."
  :type 'boolean
  :group 'herdr-status)

(defcustom herdr-status-preview-status-regexp
  "\\`[[:space:]]*[✻✽✢·✳]\\|\\`[[:space:]]*\\(?:Thought\\|Worked\\|Ran\\) for "
  "Regexp matching the lines a harness prints about itself.
They report how long the agent has been at it rather than saying
anything, so they are drawn in `herdr-status-preview-status'."
  :type 'regexp
  :group 'herdr-status)

(defcustom herdr-status-preview-rule "┃"
  "String drawn down the left of a preview, in its agent's own colour."
  :type 'string
  :group 'herdr-status)

(defcustom herdr-status-attached-glyph "•"
  "String marking an agent or pane Emacs has a buffer for.
Rows without a buffer are blank there, so it should be one column wide.
Nil draws no marker column at all, leaving `herdr-status-label' and
`herdr-status-label-quiet' to say which rows Emacs holds a buffer for."
  :type '(choice (const :tag "None, the name's own colour says it" nil)
                 (string :tag "Glyph"))
  :group 'herdr-status)

(defcustom herdr-status-visibility-indicators nil
  "How the dashboard says a section can be expanded or collapsed.
Nil leaves `magit-section-visibility-indicators' as it is, which is
magit's fringe bitmaps and its terminal ellipsis.  Any other value is
bound in the dashboard's buffer instead; its two elements cover
graphical and terminal frames, and a pair of characters such as
\\='((?▸ . ?▾) (?▸ . ?▾)) draws arrows in the left margin."
  :type 'sexp
  :group 'herdr-status)

(defcustom herdr-status-left-fringe-width 13
  "Width in pixels of the dashboard's left fringe on a graphical frame.
The collapse arrows `magit-section-visibility-indicators' draws are eight
pixels wide, so a wider fringe is what separates them from the headings.
Nil keeps the frame's own width."
  :type '(choice (const :tag "Frame default" nil) integer)
  :group 'herdr-status)

(defcustom herdr-status-buffer-name "*herdr-status*"
  "Name of the dashboard buffer."
  :type 'string
  :group 'herdr-status)

(defun herdr-status-default-buffer-name ()
  "Return `herdr-status-buffer-name', one dashboard for the whole Emacs."
  herdr-status-buffer-name)

(defun herdr-status-workspace-buffer-name ()
  "Return a dashboard name belonging to the current editor workspace.
Scope, filters, order and grouping are each local to their dashboard's
buffer, so a workspace with a dashboard of its own keeps its own."
  (if-let* ((label (herdr-current-workspace-label)))
      (format "%s: %s*"
              (string-remove-suffix "*" herdr-status-buffer-name) label)
    herdr-status-buffer-name))

(defcustom herdr-status-buffer-name-function #'herdr-status-default-buffer-name
  "Function answering with the dashboard buffer a command should show.
`herdr-status-workspace-buffer-name' gives every editor workspace a
dashboard of its own, which is one fetch per dashboard per refresh."
  :type '(choice (const :tag "One dashboard" herdr-status-default-buffer-name)
                 (const :tag "One per editor workspace"
                        herdr-status-workspace-buffer-name)
                 function)
  :group 'herdr-status)

(defcustom herdr-status-display-action
  '((display-buffer-reuse-window display-buffer-same-window))
  "How `herdr-status' displays the dashboard.
The value is a `display-buffer' action, bound as
`display-buffer-overriding-action' so a popup framework's
`display-buffer-alist' rules do not divert the dashboard into a side
window.  The default claims the selected window, the way `magit-status'
does.  Set it to nil to let those rules decide."
  :type 'sexp
  :group 'herdr-status)

(defcustom herdr-status-preview-lines 16
  "How many lines of an agent's recent output an expanded row shows.
Zero shows none, and asks herdr for nothing."
  :type 'integer
  :group 'herdr-status)

(defcustom herdr-status-preview-read-lines 160
  "How many lines the dashboard reads to find `herdr-status-preview-lines'.
The chrome a harness draws around its output is discarded first, so this
is larger than the number of lines shown."
  :type 'integer
  :group 'herdr-status)

(defcustom herdr-status-preview-ignore-regexps
  '("\\`[[:space:]]*[─━═╌—-]\\{4,\\}"
    "\\`[[:space:]]*[❯›>$][[:space:]]*\\'"
    "\\`[[:space:]]*›[[:space:]]+\\(?:Ask\\|Send\\)"
    "-- \\(?:INSERT\\|NORMAL\\|VISUAL\\) --"
    "⏵⏵"
    "[0-9]+/[0-9]+ ([0-9]+%)"
    "\\`[[:space:]]*[⏺•*][[:space:]]+[A-Z][[:alnum:]_-]*("
    "\\`[[:space:]]*•[[:space:]]+Ran\\b"
    "\\`[[:space:]]*[⎿└├│][[:space:]]"
    "[─━═╌—]\\{8,\\}"
    "\\`[[:space:]]*[^ ]+ \\(?:minimal\\|low\\|medium\\|high\\) · ")
  "Lines a preview drops before taking its last few.
Each element is a regexp matched against one line of the agent's recent
output.  The defaults drop blank lines, rules, an empty prompt, the
status bar a terminal harness paints, and the calls a harness makes
along with what they answered, so what is left is what was said."
  :type '(repeat regexp)
  :group 'herdr-status)

(defcustom herdr-status-auto-refresh t
  "Whether herdr lifecycle events redraw a live dashboard."
  :type 'boolean
  :group 'herdr-status)

(defcustom herdr-status-preview-ttl 5
  "Seconds a preview stays good before the pane is read again.
Every read is a request, so a dashboard redrawn on every lifecycle event
would otherwise ask each visible pane what it says several times a
second."
  :type 'number
  :group 'herdr-status)

(defcustom herdr-status-refresh-delay 0.4
  "Seconds of idle time before an event-driven redraw runs.
A burst of events collapses into one redraw."
  :type 'number
  :group 'herdr-status)

;;;; State

(defvar-local herdr-status--session-records nil
  "Server records in the dashboard's scope at the last refresh.")

(defvar-local herdr-status--entries nil
  "Session entries in the dashboard's scope at the last refresh.")

(defvar-local herdr-status--panes nil
  "Agentless panes in the dashboard's scope at the last refresh.")

(defvar-local herdr-status--project-root nil
  "Project root limiting this dashboard, or nil for all projects.")

(defvar-local herdr-status--filters nil
  "Active filters, each a cons of a name and a predicate.")

(defvar-local herdr-status--details nil
  "Adapter status alists already fetched since the last refresh.")

(defvar-local herdr-status--previews nil
  "Output previews already fetched since the last refresh.")

(defvar-local herdr-status--collapsed nil
  "The herds and groups collapsed in this dashboard, as (TYPE . VALUE).
A redraw re-expands every section, so this is what carries a collapsed
one across the refresh an agent event triggers.")

(defvar herdr-status--timer nil
  "Idle timer coalescing event-driven redraws.")

;;;; Collection

(defun herdr-status--session-record (session)
  "Return the dashboard record of SESSION and the server answering for it."
  (let ((herdr-socket-path (if (equal session herdr-session)
                               herdr-socket-path
                             nil))
        (herdr-session (or session herdr-session)))
    (let ((key (herdr-server-key)))
      (if (not (herdr-available-p))
          `((key . ,key) (session . ,session) (reachable))
        (condition-case err
            `((key . ,key)
              (session . ,session)
              (reachable . t)
              (snapshot . ,(herdr-snapshot)))
          (herdr-error
           `((key . ,key)
             (session . ,session)
             (reachable . t)
             (error . ,(error-message-string err)))))))))

(defun herdr-status--collect-sessions ()
  "Return one record per session in `herdr-all-sessions'."
  (mapcar #'herdr-status--session-record (herdr-all-sessions)))

(defun herdr-status--collect-entries ()
  "Return every session entry, ignoring an unreachable server."
  (condition-case nil
      (herdr-sessions)
    (herdr-error nil)))

(defun herdr-status--snapshot-index (field key servers)
  "Return a table of SERVERS' FIELD records, keyed by server and KEY.
SERVERS are the records `herdr-status--collect-sessions' produced."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (server servers table)
      (dolist (record (alist-get field (alist-get 'snapshot server)))
        (puthash (cons (alist-get 'key server) (alist-get key record))
                 record table)))))

(defun herdr-status--agents (entries)
  "Return the ENTRIES that are running an agent."
  (cl-remove-if-not (lambda (entry) (alist-get 'agent entry)) entries))

(defun herdr-status--orphan-panes (servers entries)
  "Return SERVERS' panes that no agent in ENTRIES occupies.
Each pane is returned stamped with its server key."
  (let ((claimed (make-hash-table :test #'equal))
        panes)
    (dolist (entry entries)
      (when-let* ((pane (alist-get 'pane_id entry)))
        (puthash (cons (herdr--entry-server entry) pane) t claimed)))
    (dolist (server servers (nreverse panes))
      (dolist (pane (alist-get 'panes (alist-get 'snapshot server)))
        (unless (gethash (cons (alist-get 'key server) (alist-get 'pane_id pane))
                         claimed)
          (push (append (list (cons 'server_key (alist-get 'key server))
                              (cons 'session (alist-get 'session server)))
                        pane)
                panes))))))

;;;; Filters

(defun herdr-status--read-field (prompt field entries)
  "Read one FIELD value present in ENTRIES, asking with PROMPT."
  (let ((values (delete-dups
                 (delq nil (mapcar (lambda (entry) (alist-get field entry))
                                   entries)))))
    (unless values
      (user-error "No agent reports a %s to filter on" field))
    (completing-read prompt values nil t)))

(defun herdr-status--field-predicate (prompt field)
  "Return a predicate keeping entries whose FIELD matches a read value.
PROMPT asks for the value among those the section at point shows, so
filtering from inside a herd offers that herd's harnesses and states
rather than every one the dashboard holds."
  (let ((value (herdr-status--read-field prompt field
                                         (herdr-status--entries-in-scope))))
    (lambda (entry) (equal (alist-get field entry) value))))

(defun herdr-status--project-root (directory)
  "Return DIRECTORY's project root, or nil when it cannot be read.
A repository is one project however many checkouts of it are open, so a
linked worktree answers with the checkout it was made from and scoping
to a project takes its worktrees along.  Outside a repository the
project is whatever `herdr-project-root-function' says.  An agent left
in a directory Emacs may not open - one moved to the trash, say -
answers for no project rather than taking the dashboard down."
  (when directory
    (condition-case nil
        (or (herdr-repository-root directory)
            (funcall herdr-project-root-function directory))
      (file-error nil))))

(defun herdr-status--project-predicate (&optional root)
  "Return a predicate keeping entries in ROOT, defaulting to this project."
  (let ((root (or root (herdr-status--project-root default-directory))))
    (unless root
      (user-error "No project for %s" (abbreviate-file-name default-directory)))
    (lambda (entry)
      (when-let* ((cwd (herdr-entry-directory entry))
                  (entry-root (herdr-status--project-root cwd)))
        (herdr--same-directory-p root entry-root)))))

(defun herdr-status--workspace-predicate ()
  "Return a predicate keeping agents in the current editor workspace."
  (let ((label (herdr-current-workspace-label)))
    (lambda (entry)
      (when-let* ((cwd (herdr-entry-directory entry)))
        (equal label (herdr-workspace-label cwd))))))

(defvar herdr-status-predicates
  `((agent-harness . ,(lambda ()
                     (herdr-status--field-predicate "Harness: " 'agent)))
    (agent-state . ,(lambda ()
                      (herdr-status--field-predicate "Agent state: "
                                                     'agent_status)))
    (project . ,#'herdr-status--project-predicate)
    (workspace . ,#'herdr-status--workspace-predicate)
    (attached . ,(lambda () (lambda (entry) (herdr--entry-buffer entry)))))
  "Named filters the dashboard offers.
Each element maps a symbol to a function of no arguments.  That function
may prompt and returns a predicate of one session entry, or nil to add
no filter.  Adding an element makes a custom filter available to
`herdr-status-add-filter' and the filter transient.")

(defun herdr-status--push-filter (name)
  "Build the filter registered as NAME and apply it."
  (let ((constructor (alist-get name herdr-status-predicates)))
    (unless constructor
      (user-error "No herdr status predicate named %s" name))
    (when-let* ((predicate (funcall constructor)))
      (setq herdr-status--filters
            (cons (cons name predicate)
                  (assq-delete-all name herdr-status--filters)))
      (herdr-status-refresh))))

(defcustom herdr-status-sorts
  '(("state" . herdr-status--state-key)
    ("name" . herdr-status--label-key)
    ("harness" . herdr-status--harness-key)
    ("pane" . herdr-status--pane-key)
    ("session" . herdr-status--session-name)
    ("model" . herdr-status--model-key)
    ("directory" . herdr-status--directory-key))
  "Keys the agent list can be ordered by, named after the column they read.
Each value is a function of one entry answering with the string it sorts
under.  `herdr-status-sort-by' offers these names."
  :type '(alist :key-type string :value-type function)
  :group 'herdr-status)

(defvar-local herdr-status--sort nil
  "The column the agent list is ordered by, and whether that is reversed.
Nil leaves the order herdr reports the agents in.")

(defun herdr-status--project-group (entry)
  "Return the name of the project ENTRY works in."
  (when-let* ((cwd (herdr-entry-directory entry))
              (root (herdr-status--project-root cwd)))
    (file-name-nondirectory (directory-file-name root))))

(defcustom herdr-status-groups
  '(("project" . herdr-status--project-group)
    ("directory" . herdr-status--directory-key)
    ("session" . herdr-status--session-name)
    ("harness" . herdr-status--harness-key)
    ("model" . herdr-status--model)
    ("state" . herdr-status--state))
  "Units the agent list can be grouped by, named after what they group by.
Each value is a function of one entry answering with the group it belongs
in.  An entry the function answers nil for is grouped under `none'.
`herdr-status-group-by' offers these names."
  :type '(alist :key-type string :value-type function)
  :group 'herdr-status)

(defvar-local herdr-status--group-unit nil
  "The unit the agent list groups by, or nil for the first one offered.")

(defvar-local herdr-status--grouping nil
  "Whether the agent list is drawn in groups rather than as one list.")

(defun herdr-status-group-unit ()
  "Return the unit the agent list groups by."
  (or herdr-status--group-unit (car (car herdr-status-groups))))

(defun herdr-status--grouped (entries)
  "Return ENTRIES as an alist of group and members, in the order met."
  (let ((key (alist-get (herdr-status-group-unit) herdr-status-groups
                        nil nil #'equal))
        (groups nil))
    (dolist (entry entries)
      (let* ((name (or (and key (funcall key entry)) "none"))
             (cell (assoc name groups)))
        (if cell
            (setcdr cell (cons entry (cdr cell)))
          (push (cons name (list entry)) groups))))
    (mapcar (lambda (cell) (cons (car cell) (nreverse (cdr cell))))
            (nreverse groups))))

(defun herdr-status--label-key (entry)
  "Return ENTRY's name, downcased for ordering."
  (downcase (or (herdr--entry-label entry) "")))

(defun herdr-status--harness-key (entry)
  "Return ENTRY's harness."
  (or (alist-get 'agent entry) ""))

(defun herdr-status--pane-key (entry)
  "Return ENTRY's pane, padded so pane 9 comes before pane 10."
  (let ((pane (or (alist-get 'pane_id entry) "")))
    (if (string-match "\\([^0-9]*\\)\\([0-9]+\\)\\'" pane)
        (format "%s%08d" (match-string 1 pane)
                (string-to-number (match-string 2 pane)))
      pane)))

(defun herdr-status--directory-key (entry)
  "Return the directory ENTRY works in."
  (or (herdr-entry-directory entry) ""))

(defun herdr-status--model-key (entry)
  "Return the model ENTRY sorts under, the ones reporting none last."
  (or (herdr-status--model entry) ""))

(defcustom herdr-status-state-order '("working" "blocked" "idle" "done")
  "The order states sort in, the ones wanting attention first.
A state left out of the list sorts after the ones in it, by name."
  :type '(repeat string)
  :group 'herdr-status)

(defun herdr-status--state-key (entry)
  "Return ENTRY's state behind the rank `herdr-status-state-order' gives it."
  (let* ((state (herdr-status--state entry))
         (rank (or (cl-position state herdr-status-state-order :test #'equal)
                   (length herdr-status-state-order))))
    (format "%02d%s" rank state)))

(defun herdr-status--sorted (entries)
  "Return ENTRIES in the order `herdr-status--sort' asks for."
  (if-let* ((sort herdr-status--sort)
            (key (alist-get (car sort) herdr-status-sorts nil nil #'equal)))
      (let ((ordered (sort (copy-sequence entries)
                           (lambda (a b)
                             (string-lessp (funcall key a) (funcall key b))))))
        (if (cdr sort) (nreverse ordered) ordered))
    entries))

(defun herdr-status--section-agents (section)
  "Return the agents the rows drawn under SECTION stand for, in their order.
Every part of the dashboard is a set of its own - one herd's members, a
project's group, the recently used - and this reads that set off what is
on screen, so a section another package inserted answers like the rest."
  (let (entries)
    (cl-labels ((walk (node)
                  (if (eq (eieio-oref node 'type) 'herdr-status-agent)
                      (push (eieio-oref node 'value) entries)
                    (mapc #'walk (eieio-oref node 'children)))))
      (when section (walk section)))
    (nreverse entries)))

(defun herdr-status--entries-in-scope ()
  "Return the agents the part of the dashboard at point lists.
A command reading agents means the section it was invoked over: one
herd, one group, the recently used, or one another package inserted.
Point on a row means the section holding it rather than that row alone.
The agent list and the dashboard at large answer with the agents the
project scope and the active filters leave, read afresh rather than off
the screen, so a filter applies the moment it is added."
  (let ((section (magit-current-section)))
    (while (and section (eq (eieio-oref section 'type) 'herdr-status-agent))
      (setq section (eieio-oref section 'parent)))
    (or (and section
             (not (memq (eieio-oref section 'type)
                        '(herdr-status-root herdr-status-agents)))
             (herdr-status--section-agents section))
        (herdr-status--visible-agents))))

(defun herdr-status--visible-agents ()
  "Return the agents left by the active filters, in the order asked for."
  (herdr-status--sorted
   (cl-remove-if-not
    (lambda (entry)
      (cl-every (lambda (filter) (funcall (cdr filter) entry))
                herdr-status--filters))
    (herdr-status--agents herdr-status--entries))))

;;;; Rendering

(defun herdr-status--state (entry)
  "Return ENTRY's agent state."
  (or (alist-get 'agent_status entry) "unknown"))

(defun herdr-status--state-face (state)
  "Return the face drawing STATE."
  (or (cdr (assoc state herdr-status-state-faces))
      'herdr-status-state-unknown))

(defun herdr-status--pad (value width)
  "Return VALUE, or the empty string, padded on the right to WIDTH."
  (let ((text (or value "")))
    (concat text (make-string (max 0 (- width (string-width text))) ?\s))))

(defun herdr-status--attached-column (entry)
  "Return the marker saying whether Emacs has a buffer for ENTRY.
The marker carries the space separating it from the state glyph, so a nil
`herdr-status-attached-glyph' takes the whole column back."
  (cond
   ((null herdr-status-attached-glyph) "")
   ((herdr--entry-buffer entry)
    (concat (propertize herdr-status-attached-glyph
                        'font-lock-face 'herdr-status-attached)
            " "))
   (t (make-string (1+ (string-width herdr-status-attached-glyph)) ?\s))))

(defun herdr-status--state-column (entry)
  "Return the glyph standing for ENTRY's state, in that state's face.
A pane running no agent has no state to report and is left blank there."
  (let* ((state (herdr-status--state entry))
         (glyph (herdr-status-glyph
                 (or (cdr (assoc state herdr-status-state-glyphs))
                     herdr-status-state-glyph))))
    (if (not (alist-get 'agent entry))
        (make-string (string-width glyph) ?\s)
      (propertize glyph
                  'font-lock-face (herdr-status--state-face state)))))

(defun herdr-status--name-width (entries)
  "Return the columns ENTRIES' names take, never past what fits.
The widest name wins where it fits; `herdr-status-name-width' is the
ceiling, and nil makes that a third of the window the dashboard is in."
  (min (herdr-status--width entries #'herdr--entry-label 8)
       (or herdr-status-name-width
           (max 12 (/ (if-let* ((window (get-buffer-window nil t)))
                          (window-body-width window)
                        (frame-width))
                      3)))))

(defun herdr-status--label-column (entry width)
  "Return ENTRY's name in WIDTH columns, lit where Emacs holds its buffer.
A name too long for WIDTH is cut short, since what follows it says which
agent this is as much as the tail of a name does."
  (propertize (herdr-status--pad
               (truncate-string-to-width (or (herdr--entry-label entry) "")
                                         width nil nil t)
               width)
              'font-lock-face (if (herdr--entry-buffer entry)
                                  'herdr-status-label
                                'herdr-status-label-quiet)))

(defun herdr-status--nerd-glyph-p (glyph)
  "Return non-nil if GLYPH is drawn from a Private Use Area a Nerd Font patches."
  (seq-some (lambda (char)
              (or (<= #xe000 char #xf8ff) (<= #xf0000 char #xffffd)))
            glyph))

(defun herdr-status--glyph-shown-p (glyph)
  "Return non-nil if this display can draw GLYPH."
  (and (or (not (herdr-status--nerd-glyph-p glyph))
           (if (eq herdr-status-nerd-font 'auto)
               (display-graphic-p)
             herdr-status-nerd-font))
       (seq-every-p #'char-displayable-p glyph)))

(defun herdr-status--glyph-faces (glyph face)
  "Return the faces GLYPH is drawn in, FACE among them.
A glyph out of a Nerd Font is drawn larger than the text beside it, so
it takes `herdr-status-nerd-glyph' over its own colour; a Unicode shape
is already the size of the text and takes FACE alone."
  (if (herdr-status--nerd-glyph-p glyph)
      (cons 'herdr-status-nerd-glyph (ensure-list face))
    face))

(defun herdr-status--glyph-gap (glyph face)
  "Return the space drawn after GLYPH in FACE.
A patched glyph is drawn from a font of its own and scaled down, so it
is not the width of a text column and the fields behind it would sit a
fraction off the rows that have none.  The space takes back whatever the
glyph does not use, which holds the pair at two columns however wide the
glyph is drawn.  A terminal measures in whole columns and needs none of
it."
  (if (not (display-graphic-p))
      " "
    (let* ((shown (propertize glyph 'face (herdr-status--glyph-faces glyph face)))
           (rest (- (* 2 (default-font-width)) (string-pixel-width shown))))
      (if (> rest 0)
          (propertize " " 'display (list 'space :width (list rest)))
        " "))))

(defun herdr-status-glyph (glyph)
  "Return the string GLYPH is drawn as.
GLYPH is one string or a list of candidates, of which the first the
display can show wins.  Where none can, the last is drawn anyway: a
column of tofu still says something was there."
  (let ((candidates (if (listp glyph) glyph (list glyph))))
    (or (seq-find #'herdr-status--glyph-shown-p candidates)
        (car (last candidates))
        "")))

(defun herdr-status--field-glyph (field)
  "Return the glyph drawn before FIELD, or the empty string."
  (herdr-status-glyph (alist-get field herdr-status-field-glyphs)))

(defun herdr-status--field-column (field value width &optional face)
  "Return VALUE behind FIELD's glyph, padded to WIDTH, in FACE.
A nil VALUE keeps the column's width in blanks so the rows stay aligned,
and a zero WIDTH means no row has the field, so nothing is drawn."
  (unless (zerop width)
    (let* ((glyph (herdr-status--field-glyph field))
           (face (or face 'herdr-status-meta))
           (lead (if (string-empty-p glyph)
                     ""
                   (concat (propertize glyph 'font-lock-face
                                       (herdr-status--glyph-faces glyph face))
                           (herdr-status--glyph-gap glyph face)))))
      (if value
          (concat lead (propertize (herdr-status--pad value width)
                                   'font-lock-face face))
        (make-string (+ (string-width lead) width) ?\s)))))

(defun herdr-status--branch (entry)
  "Return the git branch ENTRY's directory is on, or nil outside a repository."
  (herdr-directory-branch (herdr-entry-directory entry)))

(defcustom herdr-status-model-token "model"
  "Metadata token naming the model an agent is currently answering with.
Herdr carries whatever a pane reports of itself, so the model arrives
the way any other self-reported field does, and the column is blank for
a harness that reports none."
  :type 'string
  :group 'herdr-status)

(defun herdr-status--model (entry)
  "Return the model ENTRY reports itself running, or nil."
  (when-let* ((model (alist-get (intern herdr-status-model-token)
                                (alist-get 'tokens entry)))
              ((stringp model))
              ((not (string-empty-p model))))
    model))

(defun herdr-status--trailing-columns (entry widths workspaces)
  "Return the cells that follow ENTRY's session column, on WIDTHS.
WORKSPACES resolves the workspace label.  The pane, workspace, branch and
model keep their columns; the directory comes last, being the one field
whose length varies from row to row."
  (list (herdr-status--field-column 'pane (alist-get 'pane_id entry)
                                    (nth 3 widths))
        (herdr-status--field-column 'workspace
                                    (herdr-status--workspace-label entry workspaces)
                                    (nth 4 widths))
        (herdr-status--field-column 'branch (herdr-status--branch entry)
                                    (nth 5 widths))
        (herdr-status--field-column 'model (herdr-status--model entry)
                                    (nth 6 widths))
        (when-let* ((directory (herdr-status--directory entry)))
          (herdr-status--field-column 'directory directory
                                      (string-width directory)
                                      'herdr-status-path))))

(defun herdr-status--harness-mark (entry)
  "Return the glyph and face marking ENTRY's harness, or nil."
  (cdr (assoc (alist-get 'agent entry) herdr-status-harness-marks)))

(defun herdr-status--harness-face (entry)
  "Return the face ENTRY's harness is drawn in."
  (or (cdr (herdr-status--harness-mark entry)) 'herdr-status-meta))

(defun herdr-status-mark (glyph face &optional property)
  "Return GLYPH in FACE with the gap holding it to two columns.
GLYPH is what `herdr-status-glyph' takes, one string or a list of
candidates.  The glyph carries its faces under PROPERTY, `face' by
default; a buffer that fontifies its own text passes `font-lock-face'."
  (let ((glyph (herdr-status-glyph glyph)))
    (concat (propertize glyph (or property 'face)
                        (herdr-status--glyph-faces glyph face))
            (herdr-status--glyph-gap glyph face))))

(defun herdr-status-harness-glyph (harness &optional property)
  "Return HARNESS's vendor mark and the gap holding it to two columns, or nil.
The glyph carries its faces under PROPERTY, as `herdr-status-mark' takes it."
  (when-let* ((mark (cdr (assoc harness herdr-status-harness-marks))))
    (herdr-status-mark (car mark) (cdr mark) property)))

(defun herdr-status--harness-column (entry width)
  "Return ENTRY's harness padded to WIDTH, behind its vendor mark."
  (let ((harness (alist-get 'agent entry)))
    (concat (or (herdr-status-harness-glyph harness 'font-lock-face) "  ")
            (propertize (herdr-status--pad harness width)
                        'font-lock-face (herdr-status--harness-face entry)))))

(defun herdr-status--width (entries function minimum)
  "Return the widest FUNCTION of ENTRIES, never below MINIMUM."
  (apply #'max minimum
         (mapcar (lambda (entry)
                   (string-width (or (funcall function entry) "")))
                 entries)))

(defun herdr-status--workspace-label (entry workspaces)
  "Return the label of ENTRY's workspace, looked up in WORKSPACES."
  (let ((record (gethash (cons (herdr--entry-server entry)
                               (alist-get 'workspace_id entry))
                         workspaces)))
    (or (alist-get 'label record)
        (alist-get 'workspace_id entry))))

(defun herdr-status--directory (entry)
  "Return ENTRY's working directory, shortened for display."
  (when-let* ((cwd (herdr-entry-directory entry)))
    (abbreviate-file-name cwd)))

(defun herdr-status--session-name (entry)
  "Return the name of the herdr session ENTRY lives on."
  (or (herdr-session-name (alist-get 'session entry)) "shared"))

(defun herdr-status--session-column (entry width)
  "Return ENTRY's session name padded to WIDTH, or nil for a lone server."
  (when (cdr herdr-status--session-records)
    (herdr-status--pad (herdr-status--session-name entry) width)))

(defun herdr-status--row (entry widths workspaces)
  "Return the single line drawn for ENTRY.
WIDTHS holds the label, harness, session, pane, workspace and branch column
widths, and WORKSPACES resolves the workspace label."
  (concat
   (herdr-status--attached-column entry)
   (herdr-status--state-column entry) " "
   (string-join
    (delq nil
          (append
           (list (herdr-status--label-column entry (nth 0 widths))
                 (herdr-status--harness-column entry (nth 1 widths))
                 (herdr-status--session-column entry (nth 2 widths)))
           (herdr-status--trailing-columns entry widths workspaces)))
    "  ")))

(defun herdr-status-agent-row (entry widths workspaces)
  "Return the dashboard line for agent ENTRY on WIDTHS, labelled via WORKSPACES.
Sections other packages insert through `herdr-status-sections-functions'
draw an agent on the same columns as the agent list with this."
  (herdr-status--row entry widths workspaces))

(defun herdr-status--widths (entries workspaces)
  "Return the column widths fitting ENTRIES, labelled via WORKSPACES.
Label, harness and session keep a floor; pane, workspace, branch and
model take exactly the widest value, and zero when no entry has one."
  (list (herdr-status--name-width entries)
        (herdr-status--width entries (lambda (entry) (alist-get 'agent entry)) 6)
        (herdr-status--width entries #'herdr-status--session-name 6)
        (herdr-status--width entries (lambda (entry) (alist-get 'pane_id entry)) 0)
        (herdr-status--width entries
                             (lambda (entry)
                               (herdr-status--workspace-label entry workspaces))
                             0)
        (herdr-status--width entries #'herdr-status--branch 0)
        (herdr-status--width entries #'herdr-status--model 0)))

(defconst herdr-status--detail-fields
  '(server_key session terminal_id pane_id workspace_id tab_id agent
               agent_status terminal_title_stripped cwd foreground_cwd title
               terminal_title focused revision state_labels tokens
               interactive_ready launch_pending)
  "Entry fields shown, in order, when an agent is expanded.")

(defconst herdr-status--detail-width
  (apply #'max (mapcar (lambda (field) (length (symbol-name field)))
                       herdr-status--detail-fields))
  "Width of the key column in an expanded agent, from the longest field.")

(defun herdr-status--insert-field (name value &optional indent)
  "Insert the detail line pairing NAME with VALUE, unless VALUE is empty.
INDENT is how far the line is set in, four columns by default."
  (when (and value (not (equal value "")))
    (insert (make-string (or indent 4) ?\s)
            (propertize (herdr-status--pad name herdr-status--detail-width)
                        'font-lock-face 'herdr-status-detail-key)
            " " value "\n")))

(defun herdr-status--format-value (value)
  "Return VALUE rendered for a detail line."
  (cond
   ((null value) nil)
   ((eq value t) "yes")
   ((eq value :false) "no")
   ((stringp value) value)
   ((numberp value) (number-to-string value))
   ((and (consp value) (consp (car value)))
    (string-join (mapcar (lambda (pair)
                           (format "%s=%s" (car pair)
                                   (herdr-status--format-value (cdr pair))))
                         value)
                 " "))
   (t (format "%s" value))))

(defun herdr-status--insert-alist (alist skip &optional indent)
  "Insert every pair of ALIST whose key is absent from SKIP, set in by INDENT."
  (dolist (pair alist)
    (unless (memq (car pair) skip)
      (herdr-status--insert-field (symbol-name (car pair))
                                  (herdr-status--format-value (cdr pair))
                                  indent))))

(defun herdr-status--insert-details (entry tabs workspaces &optional indent)
  "Insert ENTRY's own metadata, resolving labels through TABS and WORKSPACES.
INDENT is how far the lines are set in."
  (dolist (field herdr-status--detail-fields)
    (herdr-status--insert-field
     (symbol-name field)
     (herdr-status--format-value (alist-get field entry))
     indent))
  (herdr-status--insert-field
   "workspace" (herdr-status--workspace-label entry workspaces) indent)
  (herdr-status--insert-field
   "tab" (alist-get 'label (gethash (cons (herdr--entry-server entry)
                                          (alist-get 'tab_id entry))
                                    tabs))
   indent)
  (herdr-status--insert-field
   "buffer" (when-let* ((buffer (herdr--entry-buffer entry)))
              (buffer-name buffer))
   indent))

(defun herdr-status--blank-p (line)
  "Return non-nil when LINE holds nothing but space."
  (string-match-p "\\`[[:space:]]*\\'" line))

(defun herdr-status--squeeze-blanks (lines)
  "Return LINES with runs of blank lines cut to one and none at either end.
The blank between two paragraphs is what tells them apart, so it stays;
the run a dropped tool call leaves behind does not."
  (let ((kept nil))
    (dolist (line lines)
      (unless (and (herdr-status--blank-p line)
                   (or (null kept) (herdr-status--blank-p (car kept))))
        (push line kept)))
    (while (and kept (herdr-status--blank-p (car kept)))
      (pop kept))
    (nreverse kept)))

(defun herdr-status--preview-lines (text)
  "Return the last lines of TEXT worth showing as a preview.
Lines matching `herdr-status-preview-ignore-regexps' are dropped first,
and the blank lines that survive keep the paragraphs apart."
  (let* ((lines (cl-remove-if
                 (lambda (line)
                   (cl-some (lambda (regexp) (string-match-p regexp line))
                            herdr-status-preview-ignore-regexps))
                 (split-string (or text "") "\n")))
         (lines (herdr-status--squeeze-blanks (mapcar #'string-trim lines))))
    (herdr-status--squeeze-blanks
     (last lines herdr-status-preview-lines))))

(defun herdr-status--read-preview (entry)
  "Return ENTRY's recent output as preview lines, asking herdr for it."
  (when-let* ((pane (alist-get 'pane_id entry)))
    (condition-case nil
        (herdr-with-session (alist-get 'session entry)
          (let ((result (if (alist-get 'agent entry)
                            (herdr-api-agent-read
                             "recent" pane
                             :lines herdr-status-preview-read-lines
                             :strip-ansi t)
                          (herdr-api-pane-read
                           pane "recent_unwrapped"
                           :lines herdr-status-preview-read-lines
                           :strip-ansi t))))
            (herdr-status--preview-lines
             (alist-get 'text (alist-get 'read result)))))
      (error nil))))

(defun herdr-status--preview (entry)
  "Return ENTRY's preview lines, read again once they are stale.
A redraw an event asks for comes in bursts, and reading every visible
pane again in each of them is what makes the dashboard crawl, so what
was read stays good for `herdr-status-preview-ttl' seconds."
  (when (> herdr-status-preview-lines 0)
    (when-let* ((key (or (alist-get 'pane_id entry)
                         (alist-get 'terminal_id entry))))
      (let ((cached (assoc key herdr-status--previews)))
        (if (and cached
                 (< (float-time (time-since (cadr cached)))
                    herdr-status-preview-ttl))
            (cddr cached)
          (let ((lines (herdr-status--read-preview entry)))
            (setq herdr-status--previews
                  (cons (cons key (cons (current-time) lines))
                        (assoc-delete-all key herdr-status--previews)))
            lines))))))

(declare-function memex-markdown-render "memex-markdown" (markdown &optional code))

(defun herdr-status--markdown-renderer ()
  "Return the markdown renderer to draw previews with, or nil for none.
memex carries one and herdr does not require it, so it is looked for at
draw time and loaded where it is installed."
  (and herdr-status-preview-markdown
       (or (and (fboundp 'memex-markdown-render) #'memex-markdown-render)
           (and (locate-library "memex-markdown")
                (require 'memex-markdown nil t)
                #'memex-markdown-render))))

(defun herdr-status--render-preview (lines)
  "Return LINES as a renderer draws them, or unchanged without one."
  (if-let* ((render (herdr-status--markdown-renderer))
            (text (condition-case nil
                      (funcall render (string-join lines "\n"))
                    (error nil))))
      (herdr-status--squeeze-blanks
       (split-string (string-trim-right text) "\n"))
    lines))

(defun herdr-status--insert-preview (entry &optional rule)
  "Insert the last thing ENTRY showed, each line behind RULE.
A RULE marks the lines as an agent's own words, drawn in that harness's
colour; without one the lines are set in by its width instead, which is
what a plain pane's scrollback gets.  A line the harness prints about
itself is drawn apart from the words around it."
  (when-let* ((lines (herdr-status--preview entry)))
    (let ((first (point))
          (prefix (if rule
                      (concat " "
                              (propertize rule 'font-lock-face
                                          (herdr-status--harness-face entry))
                              " ")
                    (make-string (+ 2 (string-width
                                       herdr-status-preview-rule))
                                 ?\s))))
      (dolist (line (herdr-status--render-preview lines))
        (insert prefix
                (if (string-match-p herdr-status-preview-status-regexp line)
                    (propertize line 'font-lock-face
                                'herdr-status-preview-status)
                  line)
                "\n"))
      (herdr-status--air-above first))))

(defun herdr-status--air-above (start)
  "Lift the line beginning at START off the one above it."
  (when (> herdr-status-preview-spacing 0)
    (when-let* ((end (save-excursion
                       (goto-char start)
                       (and (search-forward "\n" nil t) (point)))))
      (put-text-property (1- end) end 'line-height
                         (list (+ (default-line-height)
                                  herdr-status-preview-spacing)
                               0)))))

(defun herdr-status--insert-body (entry rule details)
  "Insert ENTRY's preview behind RULE, then its DETAILS when asked for.
DETAILS is called with the indent its lines take, and only where
`herdr-status-show-details' is on, so every row opens on what its
terminal last showed and nothing else.  Only an agent writes markdown,
so a bare pane's scrollback is drawn as the lines it came in."
  (let ((herdr-status-preview-markdown
         (and herdr-status-preview-markdown (alist-get 'agent entry) t)))
    (herdr-status--insert-preview entry rule))
  (when herdr-status-show-details
    (funcall details 2)))

(defun herdr-status--adapter-status (entry)
  "Return the adapter fields for ENTRY, fetching them at most once."
  (let ((target (herdr--entry-target entry)))
    (when target
      (if-let* ((cached (assoc target herdr-status--details)))
          (cdr cached)
        (let ((status (condition-case nil
                          (herdr-agent-status target)
                        (error nil))))
          (push (cons target status) herdr-status--details)
          status)))))

(defun herdr-status--insert-adapter (entry &optional indent)
  "Insert the fields ENTRY's adapter reports beyond the entry itself.
INDENT is how far the lines are set in."
  (when-let* ((status (herdr-status--adapter-status entry)))
    (herdr-status--insert-alist status (mapcar #'car entry) indent)))

(defcustom herdr-status-expanded-states '("working")
  "Agent states whose rows start expanded, showing the agent's preview.
Rows in any other state start collapsed and open with `TAB'.  Nil starts
every row collapsed."
  :type '(repeat string)
  :group 'herdr-status)

(defun herdr-status--insert-agent (entry widths tabs workspaces)
  "Insert ENTRY as one collapsible row.
WIDTHS aligns the columns, and TABS and WORKSPACES resolve its labels."
  (magit-insert-section (herdr-status-agent
                         entry (not (member (herdr-status--state entry)
                                            herdr-status-expanded-states)))
    (magit-insert-heading (herdr-status--row entry widths workspaces))
    (magit-insert-section-body
      (herdr-status--insert-body
       entry herdr-status-preview-rule
       (lambda (indent)
         (herdr-status--insert-details entry tabs workspaces indent)
         (herdr-status--insert-adapter entry indent))))))

(defcustom herdr-status-counted-states '("working" "blocked")
  "The states the agents heading counts, in the order it says them.
An agent in one of these is waiting on someone: the rest are counted
only by the heading's own total."
  :type '(repeat string)
  :group 'herdr-status)

(defun herdr-status--state-summary (entries)
  "Return how many of ENTRIES are in each state worth counting."
  (when-let* ((counts (delq nil
                            (mapcar
                             (lambda (state)
                               (let ((count (cl-count state entries
                                                      :key #'herdr-status--state
                                                      :test #'equal)))
                                 (when (> count 0)
                                   (format "%d %s" count state))))
                             herdr-status-counted-states))))
    (propertize (concat "  · " (string-join counts " · "))
                'font-lock-face 'herdr-status-meta)))

(defun herdr-status--sort-summary ()
  "Return the order the agents are in, rendered for their heading."
  (when herdr-status--sort
    (propertize (format "  · by %s%s" (car herdr-status--sort)
                        (if (cdr herdr-status--sort) " ↑" " ↓"))
                'font-lock-face 'herdr-status-meta)))

(defun herdr-status--group-summary ()
  "Return the unit the agents are grouped by, rendered for their heading."
  (when herdr-status--grouping
    (propertize (format "  · in %s" (herdr-status-group-unit))
                'font-lock-face 'herdr-status-meta)))

(defun herdr-status--filter-summary ()
  "Return the active filters rendered for the agents heading."
  (when herdr-status--filters
    (concat "  "
            (propertize (string-join (mapcar (lambda (filter)
                                               (symbol-name (car filter)))
                                             (reverse herdr-status--filters))
                                     " ")
                        'font-lock-face 'herdr-status-active-filter))))

(defun herdr-status--unreachable-summary ()
  "Return the sessions whose server answered nothing, or nil where all did."
  (when-let* ((down (seq-remove (lambda (server) (alist-get 'reachable server))
                                herdr-status--session-records)))
    (propertize (format "  · %s unreachable"
                        (string-join (mapcar #'herdr-status--session-name down)
                                     " "))
                'font-lock-face 'herdr-status-state-blocked)))

(defun herdr-status--insert-sessions ()
  "Insert one collapsible entry per herdr session in the dashboard's scope."
  (magit-insert-section (herdr-status-sessions nil t)
    (magit-insert-heading
      (concat (propertize (format "Sessions %d" (length herdr-status--session-records))
                          'font-lock-face 'magit-section-heading)
              (herdr-status--unreachable-summary)))
    (dolist (server herdr-status--session-records)
      (let ((snapshot (alist-get 'snapshot server)))
        (magit-insert-section (herdr-status-session (alist-get 'key server) t)
          (magit-insert-heading
            (format "%s  %s"
                    (herdr-status--session-name server)
                    (propertize (abbreviate-file-name (alist-get 'key server))
                                'font-lock-face 'herdr-status-path)))
          (magit-insert-section-body
            (herdr-status--insert-field
             "reachable" (if (alist-get 'reachable server) "yes" "no"))
            (herdr-status--insert-field "error" (alist-get 'error server))
            (herdr-status--insert-field "version" (alist-get 'version snapshot))
            (herdr-status--insert-field
             "protocol"
             (herdr-status--format-value (alist-get 'protocol snapshot)))
            (dolist (field '(workspaces tabs panes agents))
              (herdr-status--insert-field
               (symbol-name field)
               (number-to-string (length (alist-get field snapshot)))))))))))

(defun herdr-status-recent-agents ()
  "Return the dashboard's agents in most-recently-used order."
  (delq nil
        (mapcar (lambda (target)
                  (cl-find target
                           (herdr-status--agents herdr-status--entries)
                           :key #'herdr--entry-target :test #'equal))
                herdr--recent-session-targets)))

(defun herdr-status--insert-recent (widths tabs workspaces)
  "Insert the recently used agents, most recent first.
WIDTHS, TABS, and WORKSPACES are passed through to each row."
  (let ((entries (herdr-status-recent-agents)))
    (when entries
      (magit-insert-section (herdr-status-recent)
        (magit-insert-heading (format "Recent %d" (length entries)))
        (dolist (entry entries)
          (herdr-status--insert-agent entry widths tabs workspaces))))))

(defun herdr-status--members-heading (label members)
  "Return the heading of a section holding MEMBERS under LABEL."
  (concat (propertize label 'font-lock-face 'herdr-status-label)
          (propertize (format "  · %d member%s" (length members)
                              (if (= 1 (length members)) "" "s"))
                      'font-lock-face 'herdr-status-meta)))

(defun herdr-status--insert-herds (widths tabs workspaces)
  "Insert one collapsible section per herd the listed agents form.
WIDTHS, TABS, and WORKSPACES draw a member on the same columns as the
agent list.  Nothing is drawn where no agent names a herd."
  (when-let* ((herds (herdr-herds (herdr-status--agents herdr-status--entries))))
    (magit-insert-section (herdr-status-herds nil t)
      (magit-insert-heading
        (propertize (format "Herds %d" (length herds))
                    'font-lock-face 'magit-section-heading))
      (pcase-dolist (`(,herd . ,members) herds)
        (magit-insert-section (herdr-status-herd herd)
          (magit-insert-heading
            (herdr-status--members-heading (herdr-herd-label herd) members))
          (magit-insert-section-body
            (dolist (entry members)
              (herdr-status--insert-agent entry widths tabs workspaces))))))))

(defun herdr-status--insert-agents (widths tabs workspaces)
  "Insert the filtered agent list.
WIDTHS, TABS, and WORKSPACES are passed through to each row."
  (let ((visible (herdr-status--visible-agents))
        (total (length (herdr-status--agents herdr-status--entries))))
    (magit-insert-section (herdr-status-agents)
      (magit-insert-heading
        (concat (propertize (if (= (length visible) total)
                                (format "Agents %d" total)
                              (format "Agents %d/%d" (length visible) total))
                            'font-lock-face 'magit-section-heading)
                (herdr-status--state-summary visible)
                (herdr-status--group-summary)
                (herdr-status--sort-summary)
                (herdr-status--filter-summary)))
      (cond
       ((null visible) (insert "  No agent matches.\n"))
       (herdr-status--grouping
        (pcase-dolist (`(,name . ,members) (herdr-status--grouped visible))
          (magit-insert-section (herdr-status-group name)
            (magit-insert-heading (herdr-status--members-heading name members))
            (magit-insert-section-body
              (dolist (entry members)
                (herdr-status--insert-agent entry widths tabs workspaces))))))
       (t
        (dolist (entry visible)
          (herdr-status--insert-agent entry widths tabs workspaces)))))))

(defun herdr-status--insert-panes (widths workspaces)
  "Insert the panes running no agent, labelled through WORKSPACES.
WIDTHS holds the same column widths the agents are drawn on, so a pane
lines up with them."
  (let ((panes herdr-status--panes))
    (when panes
      (magit-insert-section (herdr-status-panes nil t)
        (magit-insert-heading (format "Panes %d" (length panes)))
        (dolist (pane panes)
          (magit-insert-section (herdr-status-pane pane t)
            (magit-insert-heading (herdr-status--row pane widths workspaces))
            (magit-insert-section-body
              (herdr-status--insert-body
               pane nil
               (lambda (indent)
                 (herdr-status--insert-alist
                  pane '(server_key session) indent))))))))))

;;;; Mode

(autoload 'herdr-memex-search "herdr-memex" nil t)
(autoload 'herdr-memex-dispatch "herdr-memex" nil t)
(autoload 'herdr-memex-available-p "herdr-memex")
(autoload 'herdr-memex-install-keys "herdr-memex")

(defvar-keymap herdr-status-mode-map
  :doc "Keymap for `herdr-status-mode'.
The search keys `s' and `S' are installed by `herdr-memex-install-keys'
where memex.el is on the load path, and are unbound where it is not."
  :parent magit-section-mode-map
  "?" #'herdr-status-dispatch
  "RET" #'herdr-status-visit
  "o" #'herdr-status-visit-other-window
  "P" #'herdr-status-prompt
  "R" #'herdr-status-rename
  "K" #'herdr-status-close-pane
  "d" #'herdr-status-detach
  "x" #'herdr-status-stop
  "f" #'herdr-status-filter
  "O" #'herdr-status-sort
  "h" #'herdr-herd-dispatch
  "n" #'herdr-status-new-agent
  "N" #'herdr-status-new-agent-of-harness
  "e" #'herdr-status-toggle-expanded
  "u" #'herdr-status-toggle-grouping
  "U" #'herdr-status-group-by
  "t" #'herdr-status-toggle-details
  "g" #'herdr-status-refresh
  "p" #'herdr-status-toggle-project
  "q" #'quit-window)

(defun herdr-status--widen-fringe ()
  "Give every window showing the dashboard its own left fringe and margin."
  (dolist (window (get-buffer-window-list nil nil t))
    (when (and herdr-status-left-fringe-width (display-graphic-p))
      (let ((fringes (window-fringes window)))
        (unless (eq (car fringes) herdr-status-left-fringe-width)
          (set-window-fringes window herdr-status-left-fringe-width
                              (nth 1 fringes)))))
    (when (and (> left-margin-width 0)
               (not (eq (or (car (window-margins window)) 0)
                        left-margin-width)))
      (set-window-margins window left-margin-width
                          (cdr (window-margins window))))))

(define-derived-mode herdr-status-mode magit-section-mode "Herdr"
  "Major mode for the herdr status dashboard."
  :group 'herdr-status
  (setq-local revert-buffer-function
              (lambda (&rest _) (herdr-status-refresh))
              herdr-entries-in-scope-function #'herdr-status--entries-in-scope)
  (when herdr-status-visibility-indicators
    (setq-local magit-section-visibility-indicators
                herdr-status-visibility-indicators))
  (when (characterp (car (magit-section-visibility-indicator)))
    (setq-local left-margin-width 2))
  (herdr-memex-install-keys)
  (add-hook 'window-configuration-change-hook
            #'herdr-status--widen-fringe nil t))

(defvar herdr-status--refreshing nil
  "Non-nil while a redraw is running anywhere.
Every request waits in `accept-process-output', which runs the timers
that fall due meanwhile, and the redraw timer is one of them.  Without
this a redraw calls itself from inside its own requests until Emacs
runs out of stack.")

(defun herdr-status-refresh ()
  "Re-fetch every known herdr server and redraw the dashboard."
  (interactive)
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (unless herdr-status--refreshing
    (herdr-status--redraw)))

(defun herdr-status--sections (section)
  "Return SECTION and every section under it."
  (cons section (mapcan #'herdr-status--sections
                        (copy-sequence (oref section children)))))

(defconst herdr-status--collapsible-types
  '(herdr-status-herd herdr-status-group)
  "Section types whose collapsed state outlives a redraw.")

(defun herdr-status--collapsible-p (section)
  "Return SECTION's (TYPE . VALUE) when its collapsed state is kept."
  (when (memq (oref section type) herdr-status--collapsible-types)
    (cons (oref section type) (oref section value))))

(defun herdr-status--collapsed-sections ()
  "Return the sections collapsed in this dashboard, as (TYPE . VALUE)."
  (when magit-root-section
    (delq nil
          (mapcar (lambda (section)
                    (and (oref section hidden)
                         (herdr-status--collapsible-p section)))
                  (herdr-status--sections magit-root-section)))))

(defun herdr-status--restore-collapsed-sections ()
  "Collapse the herds and groups that were collapsed before the redraw."
  (dolist (section (herdr-status--sections magit-root-section))
    (when-let* ((key (herdr-status--collapsible-p section)))
      (when (member key herdr-status--collapsed)
        (magit-section-hide section)))))

(defvar herdr-status-sections-functions nil
  "Functions inserting sections at the top of the dashboard.
Each is called inside the root section, before the recent agents, with
the agent entries, the column widths, the tab index, and the workspace
index the redraw computed, and inserts nothing when it has nothing to
show.")

(defun herdr-status--redraw (&optional cached)
  "Re-fetch and redraw the dashboard in the current buffer.
With CACHED, redraw from the records the last fetch left instead."
  (let ((herdr-status--refreshing t)
        (inhibit-read-only t)
        (line (line-number-at-pos))
        (starts (mapcar (lambda (window) (cons window (window-start window)))
                        (get-buffer-window-list nil nil t))))
    (setq herdr-status--collapsed (herdr-status--collapsed-sections))
    (unless cached
      (setq herdr-status--session-records (herdr-status--collect-sessions)
            herdr-status--entries (herdr-status--collect-entries)
            herdr-status--details nil))
    (herdr--prune-session-targets herdr-status--entries)
    (setq herdr-status--panes
          (herdr-status--orphan-panes herdr-status--session-records
                                      herdr-status--entries))
    (when herdr-status--project-root
      (let ((predicate (herdr-status--project-predicate herdr-status--project-root)))
        (setq herdr-status--entries
              (seq-filter predicate herdr-status--entries)
              herdr-status--panes
              (seq-filter predicate herdr-status--panes)))
      (let ((servers (mapcar #'herdr--entry-server
                             (append herdr-status--entries herdr-status--panes))))
        (setq herdr-status--session-records
              (seq-filter (lambda (server)
                            (member (alist-get 'key server) servers))
                          herdr-status--session-records))))
    (setq-local header-line-format
                (concat " Herdr · "
                        (if herdr-status--project-root
                            (abbreviate-file-name herdr-status--project-root)
                          "Global")))
    (let* ((tabs (herdr-status--snapshot-index
                  'tabs 'tab_id herdr-status--session-records))
           (workspaces (herdr-status--snapshot-index
                        'workspaces 'workspace_id herdr-status--session-records))
           (widths (herdr-status--widths
                    (append (herdr-status--agents herdr-status--entries)
                            herdr-status--panes)
                    workspaces)))
      (erase-buffer)
      (magit-insert-section (herdr-status-root)
        (run-hook-with-args 'herdr-status-sections-functions
                            (herdr-status--agents herdr-status--entries)
                            widths tabs workspaces)
        (herdr-status--insert-recent widths tabs workspaces)
        (herdr-status--insert-herds widths tabs workspaces)
        (herdr-status--insert-agents widths tabs workspaces)
        (herdr-status--insert-panes widths workspaces)
        (herdr-status--insert-sessions))
      (let ((magit-section-cache-visibility nil))
        (magit-section-show magit-root-section))
      (herdr-status--restore-collapsed-sections))
    (goto-char (point-min))
    (forward-line (1- line))
    (pcase-dolist (`(,window . ,start) starts)
      (when (window-live-p window)
        (set-window-start window (min start (point-max)) t)))))

(defun herdr-status--expanded-sections ()
  "Return the agent rows `herdr-status-expanded-states' speaks for.
An empty list speaks for every agent row, so the toggle still has
something to open once the states have been cleared."
  (seq-filter
   (lambda (section)
     (and (eq (oref section type) 'herdr-status-agent)
          (or (null herdr-status-expanded-states)
              (member (herdr-status--state (oref section value))
                      herdr-status-expanded-states))))
   (herdr-status--sections magit-root-section)))

(defun herdr-status-toggle-expanded ()
  "Open every row `herdr-status-expanded-states' names, or close them all.
Closes them when none of them is closed already."
  (interactive)
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (let* ((sections (herdr-status--expanded-sections))
         (closed (seq-some (lambda (section) (oref section hidden)) sections)))
    (unless sections
      (user-error "No agent row to open"))
    (dolist (section sections)
      (if closed (magit-section-show section) (magit-section-hide section)))
    (message "%s %d agent row%s" (if closed "Opened" "Closed")
             (length sections) (if (= 1 (length sections)) "" "s"))))

(defun herdr-status-toggle-details ()
  "Show or hide the metadata under the expanded agents of this dashboard."
  (interactive)
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (setq-local herdr-status-show-details (not herdr-status-show-details))
  (herdr-status-refresh)
  (message "Agent details %s"
           (if herdr-status-show-details "shown" "hidden")))

(defun herdr-status--show (&optional project-root)
  "Show the dashboard scoped to PROJECT-ROOT, or globally when nil."
  (let ((directory (or project-root default-directory))
        (buffer (get-buffer-create
                 (funcall herdr-status-buffer-name-function))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-status-mode)
        (herdr-status-mode))
      (setq default-directory (file-name-as-directory (expand-file-name directory))
            herdr-status--project-root project-root)
      (herdr-status-refresh))
    (let ((display-buffer-overriding-action herdr-status-display-action))
      (pop-to-buffer buffer))))

;;;###autoload
(defun herdr-status ()
  "Show the global herdr dashboard across every project.
Use `herdr-project-status' to show only the current project's entries."
  (interactive)
  (herdr-status--show))

;;;###autoload
(defun herdr-project-status ()
  "Show the herdr dashboard for the current project.
Scope agents, recent agents, herds, and panes to the project returned by
`herdr-project-root-function'.  Signal a user error outside a project."
  (interactive)
  (let ((root (herdr-status--project-root default-directory)))
    (unless root
      (user-error "No project for %s" (abbreviate-file-name default-directory)))
    (herdr-status--show (file-name-as-directory (expand-file-name root)))))

;;;###autoload
(defun herdr-status-toggle-project ()
  "Switch between the global and project dashboards.
Outside a dashboard, open the current project's dashboard."
  (interactive)
  (if (and (derived-mode-p 'herdr-status-mode) herdr-status--project-root)
      (herdr-status)
    (herdr-project-status)))

;;;; Refreshing on herdr events

(defun herdr-status--buffers ()
  "Return every live dashboard buffer."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer (derived-mode-p 'herdr-status-mode)))
   (buffer-list)))

(defun herdr-status--refresh-buffers ()
  "Redraw every live dashboard buffer."
  (setq herdr-status--timer nil)
  (dolist (buffer (herdr-status--buffers))
    (with-current-buffer buffer
      (condition-case nil
          (herdr-status-refresh)
        (herdr-error nil)))))

(defun herdr-status-cached-agents ()
  "Return the agent entries this dashboard drew from its last fetch."
  (herdr-status--agents herdr-status--entries))

(defun herdr-status-redraw-cached (&optional ready-p)
  "Redraw every live dashboard from its last fetched records, now.
A change that lives only in Emacs needs no round trip to herdr, so this
costs a few milliseconds where a fetched refresh costs hundreds and waits
for idle time first.  With READY-P, a dashboard where it returns nil is
scheduled for a fetched refresh instead.  Return non-nil when every
dashboard redrew.  Honours `herdr-status-auto-refresh'."
  (let ((complete t))
    (when herdr-status-auto-refresh
      (dolist (buffer (herdr-status--buffers))
        (with-current-buffer buffer
          (cond
           (herdr-status--refreshing nil)
           ((or (null ready-p) (funcall ready-p))
            (herdr-status--redraw t))
           (t
            (setq complete nil)
            (herdr-status-request-refresh))))))
    complete))

(defun herdr-status-request-refresh ()
  "Schedule a redraw of every live dashboard buffer.
Redraws coalesce on one idle timer, so calling this often is cheap."
  (when (and herdr-status-auto-refresh
             (null herdr-status--timer)
             (herdr-status--buffers))
    (setq herdr-status--timer
          (run-with-idle-timer herdr-status-refresh-delay nil
                               #'herdr-status--refresh-buffers))))

(defun herdr-status--on-event (&rest _)
  "Schedule a redraw after a herdr lifecycle event."
  (herdr-status-request-refresh))

(add-hook 'herdr-agent-event-functions #'herdr-status--on-event)

;;;; Commands

(defun herdr-status--entry-at-point ()
  "Return the agent entry of the section at point."
  (let ((section (magit-current-section)))
    (or (and section
             (memq (oref section type) '(herdr-status-agent))
             (oref section value))
        (user-error "No agent at point"))))

(defun herdr-status-entry-at-point ()
  "Return the agent or pane entry at point in the dashboard, or nil.
Commands outside the dashboard use this to act on the row at point
instead of prompting."
  (when-let* (((derived-mode-p 'herdr-status-mode))
              (section (magit-current-section))
              ((memq (oref section type)
                     '(herdr-status-agent herdr-status-pane))))
    (oref section value)))

(defun herdr-status--attachable-at-point ()
  "Return the agent or pane entry of the section at point."
  (or (herdr-status-entry-at-point)
      (user-error "No agent or pane at point")))

(defun herdr-status-target-at-point ()
  "Return the composite target of the dashboard agent at point, or nil.
Commands outside the dashboard use this to act on what it shows instead
of prompting."
  (when-let* (((derived-mode-p 'herdr-status-mode))
              (section (magit-current-section))
              ((eq (oref section type) 'herdr-status-agent)))
    (herdr--entry-target (oref section value))))

(defun herdr-status--target-at-point ()
  "Return the composite target of the agent at point."
  (or (herdr--entry-target (herdr-status--entry-at-point))
      (user-error "The agent at point has no terminal")))

(defun herdr-status--session-at-point ()
  "Return the session record of the section at point, or nil."
  (when-let* ((section (magit-current-section))
              ((eq (oref section type) 'herdr-status-session)))
    (cl-find (oref section value) herdr-status--session-records
             :key (lambda (server) (alist-get 'key server))
             :test #'equal)))

(defun herdr-status-visit (&optional focus)
  "Show whatever the section at point stands for.
An agent or pane is attached when nothing shows it yet; a session row
attaches the whole of it through `herdr-attach-session'.

FOCUS, the prefix argument, moves herdr itself to the agent's pane as
well, so the terminal and Emacs end up on the same agent."
  (interactive "P")
  (if-let* ((server (herdr-status--session-at-point)))
      (prog1 (herdr-attach-session (alist-get 'session server))
        (herdr-status-refresh))
    (if focus
        (herdr-agent-switch (herdr-status--target-at-point))
      (herdr-visit (herdr-status--attachable-at-point)))))

(defun herdr-status-visit-other-window ()
  "Show the agent at point in another window."
  (interactive)
  (let ((display-buffer-overriding-action
         '(display-buffer-use-some-window (inhibit-same-window . t))))
    (herdr-status-visit)))

(defun herdr-status-switch-agents ()
  "Return the running agents a switch reads from.
A dashboard offers the agents it shows, so its filters and project scope
narrow the prompt to what is on screen; anywhere else offers every agent
the servers in scope report."
  (herdr-status--agents (herdr-entries-in-scope)))

(defcustom herdr-read-agent-name-width 0.4
  "How much of the frame an agent's name may take while one is read.
A float is that share of the frame, an integer that many columns, and
either way the names take only what the longest of them needs.  What is
left over is cut, so the columns saying where an agent works stay in
view however an agent was named."
  :type '(choice (float :tag "Share of the frame")
                 (natnum :tag "Columns"))
  :group 'herdr-status)

(defun herdr-status--agent-place (entry)
  "Return where ENTRY works, as its project, or PROJECT:CHECKOUT.
A linked worktree carries its repository's name as well as its own, so
two checkouts of one project read apart; anything else is its own name."
  (when-let* ((directory (herdr-entry-directory entry))
              (own (file-name-nondirectory
                    (directory-file-name (expand-file-name directory)))))
    (let ((project (herdr-directory-project directory)))
      (if (and project (not (equal project own)))
          (concat project ":" own)
        (or project own)))))

(defun herdr-status--read-agent-width (entries)
  "Return the columns ENTRIES' names may take while one is read."
  (let ((ceiling (if (floatp herdr-read-agent-name-width)
                     (max 12 (round (* (frame-width) herdr-read-agent-name-width)))
                   herdr-read-agent-name-width)))
    (min ceiling (herdr-status--width entries #'herdr--entry-label 8))))

(defun herdr-status--shown-faces (string)
  "Return STRING with its `font-lock-face' properties restated as `face'.
The dashboard's columns are drawn for a font-locked buffer, and the
minibuffer renders `face' while ignoring the other, so a row reused
there arrives colourless without this."
  (let ((shown (copy-sequence string))
        (position 0))
    (while (< position (length shown))
      (let ((next (or (next-single-property-change position 'font-lock-face shown)
                      (length shown)))
            (face (get-text-property position 'font-lock-face shown)))
        (when face (put-text-property position next 'face face shown))
        (setq position next)))
    shown))

(defun herdr-status--read-agent-affixation (entries)
  "Return the function drawing one of ENTRIES as a row to pick from.
It is called with a candidate and its entry and answers with the name to
show, what goes before it and what goes after.  The state leads, the
name is cut to the width the longest one is allowed, and the harness,
branch and working directory follow it in columns.  The pane and
workspace the dashboard shows are left out: nobody picks an agent by
them."
  (let ((name (herdr-status--read-agent-width entries))
        (harness (herdr-status--width entries
                                      (lambda (entry) (alist-get 'agent entry)) 6))
        (branch (herdr-status--width entries #'herdr-status--branch 0))
        (session (herdr-status--width entries #'herdr-status--session-name 6))
        (many (cdr (herdr-known-sessions))))
    (lambda (candidate entry)
      (let ((shown (truncate-string-to-width candidate name nil nil t)))
        (list
         shown
         (herdr-status--shown-faces
          (concat (herdr-status--attached-column entry)
                  (herdr-status--state-column entry) " "))
         (herdr-status--shown-faces
          (concat
           (make-string (max 2 (- (+ name 2) (string-width shown))) ?\s)
           (string-join
            (delq nil
                  (list (herdr-status--harness-column entry harness)
                        (when many
                          (propertize (herdr-status--pad
                                       (herdr-status--session-name entry) session)
                                      'font-lock-face 'herdr-status-meta))
                        (when (> branch 0)
                          (propertize (herdr-status--pad
                                       (herdr-status--branch entry) branch)
                                      'font-lock-face 'herdr-status-meta))
                        (when-let* ((place (herdr-status--agent-place entry)))
                          (propertize place 'font-lock-face 'herdr-status-path))))
            "  "))))))))

;;;###autoload
(defun herdr-status-switch (entry &optional focus)
  "Show the running agent ENTRY, read with completion.
FOCUS, the prefix argument, moves herdr itself to the agent's pane
instead, the way it does for `herdr-status-visit'."
  (interactive (list (herdr-read-agent "Switch to agent: ")
                     current-prefix-arg))
  (if focus
      (herdr-agent-switch (herdr--entry-target entry))
    (herdr-visit entry)))

(defcustom herdr-status-new-harness "claude"
  "Harness a new agent runs when nothing at point names one."
  :type 'string
  :group 'herdr-status)

(defun herdr-status--new-harness ()
  "Return the harness a new agent runs without being asked for one.
The row at point names one; away from a row `herdr-status-new-harness'
does."
  (or (alist-get 'agent (herdr-status-entry-at-point))
      herdr-status-new-harness))

(defun herdr-status-new-agent (&optional kind)
  "Open a herdr pane and start KIND in it.
The row at point says which directory to work in and which herdr session
to open the pane on; away from a row the dashboard's own project scope
answers.  KIND defaults to the harness at point, then to
`herdr-status-new-harness'."
  (interactive)
  (let* ((entry (herdr-status-entry-at-point))
         (kind (or kind (herdr-status--new-harness)))
         (root (or (and entry (herdr-entry-directory entry))
                   herdr-status--project-root
                   default-directory))
         (session (if entry (alist-get 'session entry) herdr-session)))
    (herdr-with-session session
      (herdr-agent-start kind nil :project-root root))
    (herdr-status-refresh)
    (message "Started %s in %s" kind (abbreviate-file-name root))))

(defun herdr-status-new-agent-of-harness (kind)
  "Open a herdr pane and start the harness KIND in it, read with completion."
  (interactive
   (list (completing-read "Harness: " (mapcar #'car herdr-agent-harnesses)
                          nil t nil nil (herdr-status--new-harness))))
  (herdr-status-new-agent kind))

(defun herdr-status-prompt (text)
  "Send TEXT to the agent at point."
  (interactive (list (read-string "Prompt: ")))
  (herdr-agent-prompt (herdr-status--target-at-point) text)
  (herdr-status-refresh))

(defun herdr-status-rename (name &optional entry)
  "Rename what point stands for to NAME, or ENTRY when one is given.
An agent has a name of its own, which herdr's agent API sets.  A plain
pane has the label its row reads by instead, and that is what is set."
  (interactive
   (let ((entry (herdr-status--attachable-at-point)))
     (list (read-string (if (alist-get 'agent entry) "Agent name: " "Pane name: "))
           entry)))
  (let ((entry (or entry (herdr-status--attachable-at-point))))
    (if (alist-get 'agent entry)
        (herdr-agent-rename (herdr--entry-target entry) name)
      (herdr-with-session (alist-get 'session entry)
        (herdr-api-pane-rename (alist-get 'pane_id entry) :label name))))
  (herdr-status-refresh))

(defun herdr-status-close-pane ()
  "Close the pane at point, after confirmation.
An agent in that pane goes with it; `herdr-status-stop' is the same
close said from the agent's side, and `herdr-status-detach' is the one
that lets go without closing anything."
  (interactive)
  (let* ((entry (herdr-status--attachable-at-point))
         (label (or (herdr--entry-label entry) (alist-get 'pane_id entry))))
    (when (yes-or-no-p (format "Close pane %s? " label))
      (when-let* ((session (ignore-error user-error
                             (herdr-agent-resolve-session
                              (herdr--entry-target entry)))))
        (herdr-agent-detach session))
      (herdr-with-session (alist-get 'session entry)
        (herdr-api-pane-close (alist-get 'pane_id entry)))
      (herdr-status-refresh)
      (message "Closed pane %s" label))))

(defun herdr-status--attachment-at-point ()
  "Return the Emacs session attached to the agent at point, or nil."
  (ignore-error user-error
    (herdr-agent-resolve-session (herdr-status--target-at-point))))

(defun herdr-status-stop ()
  "Close the herdr pane of the agent at point, after confirmation.
Emacs lets go of the terminal and its buffer first, so the pane and the
buffer go together; `herdr-status-detach' is the one that leaves the pane
running."
  (interactive)
  (let* ((entry (herdr-status--entry-at-point))
         (label (herdr--entry-label entry)))
    (when (yes-or-no-p (format "Stop %s? " label))
      (when-let* ((session (herdr-status--attachment-at-point)))
        (herdr-agent-detach session))
      (herdr-agent-stop (herdr--entry-target entry))
      (herdr-status-refresh)
      (message "Stopped %s" label))))

(defun herdr-status-detach ()
  "Let go of the agent at point, leaving its herdr pane running.
Emacs releases the terminal and its buffer; the agent in that pane carries
on, and attaching again picks it back up."
  (interactive)
  (let ((label (herdr--entry-label (herdr-status--entry-at-point))))
    (if-let* ((session (herdr-status--attachment-at-point)))
        (progn (herdr-agent-detach session)
               (herdr-status-refresh)
               (message "Detached %s, its pane left running" label))
      (message "Emacs holds no attachment to %s" label))))

(defun herdr-status-add-filter (name)
  "Add the filter registered as NAME."
  (interactive
   (list (intern (completing-read
                  "Filter: "
                  (mapcar #'car herdr-status-predicates) nil t))))
  (herdr-status--push-filter name))

(defun herdr-status-remove-filter (name)
  "Drop the active filter called NAME."
  (interactive
   (list (intern (completing-read
                  "Drop filter: "
                  (mapcar (lambda (filter) (symbol-name (car filter)))
                          herdr-status--filters)
                  nil t))))
  (setq herdr-status--filters (assq-delete-all name herdr-status--filters))
  (herdr-status-refresh))

(defun herdr-status-clear-filters ()
  "Drop every active filter."
  (interactive)
  (setq herdr-status--filters nil)
  (herdr-status-refresh))

(defun herdr-status-filter-by-harness ()
  "Keep only agents of one harness."
  (interactive)
  (herdr-status--push-filter 'agent-harness))

(defun herdr-status-filter-by-state ()
  "Keep only agents in one state."
  (interactive)
  (herdr-status--push-filter 'agent-state))

(defun herdr-status-filter-by-project ()
  "Keep only agents rooted in the current project."
  (interactive)
  (herdr-status--push-filter 'project))

(defun herdr-status-filter-by-workspace ()
  "Keep only agents in the current editor workspace."
  (interactive)
  (herdr-status--push-filter 'workspace))

(defun herdr-status-filter-attached ()
  "Keep only the agents an Emacs buffer already displays."
  (interactive)
  (herdr-status--push-filter 'attached))

(defun herdr-status-sort-by (column)
  "Order the agent list by COLUMN, reversing it when it already sorts by it."
  (interactive
   (list (completing-read "Sort by: " (mapcar #'car herdr-status-sorts)
                          nil t)))
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (setq-local herdr-status--sort
              (if (equal (car-safe herdr-status--sort) column)
                  (cons column (not (cdr herdr-status--sort)))
                (cons column nil)))
  (herdr-status-refresh))

(defun herdr-status-group-by (unit)
  "Group the agent list by UNIT and draw the groups."
  (interactive
   (list (completing-read "Group by: " (mapcar #'car herdr-status-groups)
                          nil t nil nil (herdr-status-group-unit))))
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (unless (assoc unit herdr-status-groups)
    (user-error "No herdr status group unit named %s" unit))
  (setq-local herdr-status--group-unit unit
              herdr-status--grouping t)
  (herdr-status-refresh))

(defun herdr-status-toggle-grouping ()
  "Draw the agent list in groups, or as the one flat list it is otherwise."
  (interactive)
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (setq-local herdr-status--grouping (not herdr-status--grouping))
  (herdr-status-refresh)
  (message "Agents %s" (if herdr-status--grouping
                           (format "grouped by %s" (herdr-status-group-unit))
                         "in one list")))

(defun herdr-status-sort-reverse ()
  "Turn the agent list's order around."
  (interactive)
  (unless herdr-status--sort
    (user-error "The agent list is in herdr's own order"))
  (setq-local herdr-status--sort (cons (car herdr-status--sort)
                                       (not (cdr herdr-status--sort))))
  (herdr-status-refresh))

(defun herdr-status-sort-clear ()
  "Return the agent list to the order herdr reports."
  (interactive)
  (setq-local herdr-status--sort nil)
  (herdr-status-refresh))

;;;###autoload
(transient-define-prefix herdr-status-sort ()
  "Order the herdr dashboard's agent list."
  [["Column"
    ("s" "state" (lambda () (interactive) (herdr-status-sort-by "state")))
    ("n" "name" (lambda () (interactive) (herdr-status-sort-by "name")))
    ("h" "harness" (lambda () (interactive) (herdr-status-sort-by "harness")))]
   ["Where"
    ("p" "pane" (lambda () (interactive) (herdr-status-sort-by "pane")))
    ("S" "session" (lambda () (interactive) (herdr-status-sort-by "session")))
    ("d" "directory"
     (lambda () (interactive) (herdr-status-sort-by "directory")))]
   ["Order"
    ("r" "reverse" herdr-status-sort-reverse)
    ("x" "column" herdr-status-sort-by)
    ("DEL" "clear" herdr-status-sort-clear)]])

;;;###autoload
(transient-define-prefix herdr-status-filter ()
  "Filter the herdr dashboard's agent list."
  [["Field"
    ("h" "harness" herdr-status-filter-by-harness)
    ("S" "state" herdr-status-filter-by-state)]
   ["Scope"
    ("p" "project" herdr-status-filter-by-project)
    ("w" "workspace" herdr-status-filter-by-workspace)
    ("a" "attached" herdr-status-filter-attached)]
   ["Manage"
    ("x" "custom" herdr-status-add-filter)
    ("-" "drop one" herdr-status-remove-filter)
    ("DEL" "clear" herdr-status-clear-filters)]])

(defun herdr-status--details-description ()
  "Return the label of the detail toggle, carrying its state."
  (format "details (%s)" (if herdr-status-show-details "on" "off")))

;;;###autoload
(transient-define-prefix herdr-status-dispatch ()
  "Show the herdr dashboard's own keys.
Every suffix here is bound directly in `herdr-status-mode-map' as well."
  [:description
   (lambda () (format "herdr dashboard  ·  %d agents"
                      (length (herdr-status--agents herdr-status--entries))))
   ["Visit"
    ("RET" "visit" herdr-status-visit)
    ("o" "other window" herdr-status-visit-other-window)]
   ["Agent"
    ("n" herdr-status-new-agent
     :description (lambda () (format "new %s" (herdr-status--new-harness))))
    ("N" "new, choosing the harness" herdr-status-new-agent-of-harness)
    ("P" "prompt" herdr-status-prompt)
    ("R" "rename" herdr-status-rename)
    ("d" "detach, pane runs on" herdr-status-detach)
    ("x" "stop, pane closes" herdr-status-stop)]
   ["List"
    ("f" "filter" herdr-status-filter)
    ("O" "sort" herdr-status-sort)
    ("p" herdr-status-toggle-project
     :description (lambda () (if herdr-status--project-root
                                 "global view"
                               "project view")))
    ("e" "open or close rows" herdr-status-toggle-expanded)
    ("u" herdr-status-toggle-grouping
     :description (lambda () (if herdr-status--grouping "one list" "group")))
    ("U" "group unit" herdr-status-group-by)
    ("t" herdr-status-toggle-details
     :description herdr-status--details-description)
    ("g" "refresh" herdr-status-refresh)]
   ["Pane"
    ("R" "rename" herdr-status-rename)
    ("K" "close" herdr-status-close-pane)]
   ["Herd"
    ("h" "herds" herdr-herd-dispatch)]
   ["Search"
    :if herdr-memex-available-p
    ("s" "search" herdr-memex-search)
    ("S" "memex" herdr-memex-dispatch)]]
  [:class transient-row
          ("?" "close" transient-quit-one)
          ("q" "quit dashboard" quit-window)])

(provide 'herdr-status)
;;; herdr-status.el ends here
