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
;;
;; `herdr-status-predicates' is the filter extension point.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eieio)
(require 'magit-section)
(require 'transient)
(require 'herdr-agent)

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
  '((t :inherit warning))
  "Face for an agent that is working."
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

(defface herdr-status-kind-claude
  '((((class color) (min-colors 88)) :foreground "#d97757")
    (t :inherit warning))
  "Face for the mark drawn beside a Claude Code agent."
  :group 'herdr-status)

(defface herdr-status-kind-codex
  '((((background dark)) :foreground "white")
    (((background light)) :foreground "black")
    (t :inherit default))
  "Face for the mark drawn beside a Codex agent."
  :group 'herdr-status)

(defface herdr-status-kind-glyph
  '((t :height 1.0))
  "Face lending the vendor marks their size, over their own colour.
A line is as tall as the tallest glyph on it, and nothing shrinks it
again, so a mark scaled past 1.0 spreads the whole list."
  :group 'herdr-status)

(defcustom herdr-status-kind-marks
  '(("claude" "✳" . herdr-status-kind-claude)
    ("codex" "⌬" . herdr-status-kind-codex))
  "Marks drawn before an agent's harness kind, keyed by that kind.
Each entry gives the glyph and the face it is drawn in.  A kind without
one is drawn blank, so kind names stay in the same column either way,
and a glyph wider than one column pushes them out of it."
  :type '(alist :key-type string
                :value-type (cons (string :tag "Glyph") (face :tag "Face")))
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
that show no other mark of it."
  :type 'string
  :group 'herdr-status)

(defcustom herdr-status-state-glyphs '(("idle" . "○"))
  "Glyphs replacing `herdr-status-state-glyph', keyed by agent state.
An agent waiting for work is drawn hollow; a state without an entry here
takes the solid bullet in its own colour."
  :type '(alist :key-type string :value-type string)
  :group 'herdr-status)

(defcustom herdr-status-preview-spacing 3
  "Pixels of air above a preview.
The space is asked of the preview's own first line, so a folded row
keeps none of it.  Terminal frames measure in whole lines and draw none
of it either way."
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

(defcustom herdr-status-attached-glyph "▎"
  "String marking an agent or pane Emacs has a buffer for.
Rows without a buffer are blank there, so it should be one column wide."
  :type 'string
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

(defvar-local herdr-status--servers nil
  "Server records collected by the last refresh.")

(defvar-local herdr-status--entries nil
  "Session entries collected by the last refresh.")

(defvar-local herdr-status--filters nil
  "Active filters, each a cons of a name and a predicate.")

(defvar-local herdr-status--details nil
  "Adapter status alists already fetched since the last refresh.")

(defvar-local herdr-status--previews nil
  "Output previews already fetched since the last refresh.")

(defvar herdr-status--timer nil
  "Idle timer coalescing event-driven redraws.")

;;;; Collection

(defun herdr-status--server-record (session)
  "Return the dashboard record for SESSION's herdr server."
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

(defun herdr-status--collect-servers ()
  "Return one record per session in `herdr-all-sessions'."
  (mapcar #'herdr-status--server-record (herdr-all-sessions)))

(defun herdr-status--collect-entries ()
  "Return every session entry, ignoring an unreachable server."
  (condition-case nil
      (herdr-sessions)
    (herdr-error nil)))

(defun herdr-status--snapshot-index (field key servers)
  "Return a table of SERVERS' FIELD records, keyed by server and KEY.
SERVERS are the records `herdr-status--collect-servers' produced."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (server servers table)
      (dolist (record (alist-get field (alist-get 'snapshot server)))
        (puthash (cons (alist-get 'key server) (alist-get key record))
                 record table)))))

(defun herdr-status--entry-server (entry)
  "Return the canonical server key ENTRY belongs to."
  (or (alist-get 'server_key entry) (herdr-server-key)))

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
        (puthash (cons (herdr-status--entry-server entry) pane) t claimed)))
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
PROMPT asks for the value among those the dashboard currently shows."
  (let ((value (herdr-status--read-field prompt field herdr-status--entries)))
    (lambda (entry) (equal (alist-get field entry) value))))

(defun herdr-status--project-predicate ()
  "Return a predicate keeping agents rooted in the current project."
  (let ((root (funcall herdr-project-root-function default-directory)))
    (unless root
      (user-error "No project for %s" (abbreviate-file-name default-directory)))
    (lambda (entry)
      (when-let* ((cwd (herdr-entry-directory entry))
                  (entry-root (funcall herdr-project-root-function cwd)))
        (herdr--same-directory-p root entry-root)))))

(defun herdr-status--workspace-predicate ()
  "Return a predicate keeping agents in the current editor workspace."
  (let ((label (herdr-current-workspace-label)))
    (lambda (entry)
      (when-let* ((cwd (herdr-entry-directory entry)))
        (equal label (herdr-workspace-label cwd))))))

(defvar herdr-status-predicates
  `((agent-kind . ,(lambda ()
                     (herdr-status--field-predicate "Agent kind: " 'agent)))
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
    ("kind" . herdr-status--kind-key)
    ("pane" . herdr-status--pane-key)
    ("session" . herdr-status--session-name)
    ("directory" . herdr-status--directory-key))
  "Keys the agent list can be ordered by, named after the column they read.
Each value is a function of one entry answering with the string it sorts
under.  `herdr-status-sort-by' offers these names."
  :type '(alist :key-type string :value-type function)
  :group 'herdr-status)

(defvar-local herdr-status--sort nil
  "The column the agent list is ordered by, and whether that is reversed.
Nil leaves the order herdr reports the agents in.")

(defun herdr-status--label-key (entry)
  "Return ENTRY's name, downcased for ordering."
  (downcase (or (herdr--entry-label entry) "")))

(defun herdr-status--kind-key (entry)
  "Return ENTRY's harness kind."
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
  "Return the marker saying whether Emacs has a buffer for ENTRY."
  (if (herdr--entry-buffer entry)
      (propertize herdr-status-attached-glyph
                  'font-lock-face 'herdr-status-attached)
    (make-string (string-width herdr-status-attached-glyph) ?\s)))

(defun herdr-status--working-p (entry)
  "Return non-nil when ENTRY's agent is working."
  (equal (herdr-status--state entry) "working"))

(defun herdr-status--state-column (entry)
  "Return the glyph standing for ENTRY's state, in that state's face."
  (let ((state (herdr-status--state entry)))
    (propertize (or (cdr (assoc state herdr-status-state-glyphs))
                    herdr-status-state-glyph)
                'font-lock-face (herdr-status--state-face state))))

(defun herdr-status--label-column (entry width)
  "Return ENTRY's name padded to WIDTH, lit where Emacs holds its buffer."
  (propertize (herdr-status--pad (herdr--entry-label entry) width)
              'font-lock-face (if (herdr--entry-buffer entry)
                                  'herdr-status-label
                                'herdr-status-label-quiet)))

(defun herdr-status--location-column (entry workspaces)
  "Return where ENTRY runs: its pane, then the workspace WORKSPACES names."
  (propertize (string-join
               (delq nil (list (alist-get 'pane_id entry)
                               (herdr-status--workspace-label entry
                                                              workspaces)))
               " · ")
              'font-lock-face 'herdr-status-meta))

(defun herdr-status--kind-mark (entry)
  "Return the glyph and face marking ENTRY's harness kind, or nil."
  (cdr (assoc (alist-get 'agent entry) herdr-status-kind-marks)))

(defun herdr-status--kind-face (entry)
  "Return the face ENTRY's harness kind is drawn in."
  (or (cdr (herdr-status--kind-mark entry)) 'herdr-status-meta))

(defun herdr-status--kind-column (entry width)
  "Return ENTRY's harness kind padded to WIDTH, behind its vendor mark."
  (let ((mark (herdr-status--kind-mark entry))
        (kind (alist-get 'agent entry)))
    (concat (if mark
                (propertize (car mark) 'font-lock-face
                            (list 'herdr-status-kind-glyph (cdr mark)))
              " ")
            " "
            (propertize (herdr-status--pad kind width)
                        'font-lock-face (herdr-status--kind-face entry)))))

(defun herdr-status--width (entries function minimum)
  "Return the widest FUNCTION of ENTRIES, never below MINIMUM."
  (apply #'max minimum
         (mapcar (lambda (entry)
                   (string-width (or (funcall function entry) "")))
                 entries)))

(defun herdr-status--workspace-label (entry workspaces)
  "Return the label of ENTRY's workspace, looked up in WORKSPACES."
  (let ((record (gethash (cons (herdr-status--entry-server entry)
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
  (when (cdr herdr-status--servers)
    (herdr-status--pad (herdr-status--session-name entry) width)))

(defun herdr-status--row (entry widths workspaces)
  "Return the single line drawn for ENTRY.
WIDTHS holds the label, kind, and session column widths, and WORKSPACES
resolves the workspace label."
  (concat
   (herdr-status--attached-column entry)
   (herdr-status--state-column entry) " "
   (string-join
    (delq nil
          (list (herdr-status--label-column entry (nth 0 widths))
                (herdr-status--kind-column entry (nth 1 widths))
                (herdr-status--session-column entry (nth 2 widths))
                (herdr-status--location-column entry workspaces)
                (when-let* ((directory (herdr-status--directory entry)))
                  (propertize directory 'font-lock-face 'herdr-status-path))))
    "  ")))

(defun herdr-status--widths (entries)
  "Return the column widths fitting ENTRIES."
  (list (herdr-status--width entries #'herdr--entry-label 8)
        (herdr-status--width entries (lambda (entry) (alist-get 'agent entry)) 6)
        (herdr-status--width entries #'herdr-status--session-name 6)))

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
   "tab" (alist-get 'label (gethash (cons (herdr-status--entry-server entry)
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
                                          (herdr-status--kind-face entry))
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
  "Lift the line beginning at START off the one above it.
The space is a glyph on that line rather than a property of the newline
above it, so a hidden line takes the space away with it."
  (when (and (> herdr-status-preview-spacing 0) (< start (point-max)))
    (put-text-property
     start (1+ start) 'display
     `(space :width 1
             :height (,(+ (default-line-height) herdr-status-preview-spacing))
             :ascent 100))))

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

(defun herdr-status--insert-agent (entry widths tabs workspaces)
  "Insert ENTRY as one collapsible row.
WIDTHS aligns the columns, and TABS and WORKSPACES resolve its labels."
  (magit-insert-section (herdr-status-agent
                         entry (not (herdr-status--working-p entry)))
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
  "Return the servers that answered nothing, or nil where all of them did."
  (when-let* ((down (seq-remove (lambda (server) (alist-get 'reachable server))
                                herdr-status--servers)))
    (propertize (format "  · %s unreachable"
                        (string-join (mapcar #'herdr-status--session-name down)
                                     " "))
                'font-lock-face 'herdr-status-state-blocked)))

(defun herdr-status--insert-servers ()
  "Insert one collapsible entry per known herdr server."
  (magit-insert-section (herdr-status-servers nil t)
    (magit-insert-heading
      (concat (propertize (format "Servers %d" (length herdr-status--servers))
                          'font-lock-face 'magit-section-heading)
              (herdr-status--unreachable-summary)))
    (dolist (server herdr-status--servers)
      (let ((snapshot (alist-get 'snapshot server)))
        (magit-insert-section (herdr-status-server (alist-get 'key server) t)
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

(defun herdr-status--insert-recent (widths tabs workspaces)
  "Insert the recently used agents, most recent first.
WIDTHS, TABS, and WORKSPACES are passed through to each row."
  (let ((entries (delq nil
                       (mapcar (lambda (target)
                                 (cl-find target
                                          (herdr-status--agents
                                           herdr-status--entries)
                                          :key #'herdr--entry-target
                                          :test #'equal))
                               herdr--recent-session-targets))))
    (when entries
      (magit-insert-section (herdr-status-recent)
        (magit-insert-heading (format "Recent %d" (length entries)))
        (dolist (entry entries)
          (herdr-status--insert-agent entry widths tabs workspaces))))))

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
                (herdr-status--sort-summary)
                (herdr-status--filter-summary)))
      (if (null visible)
          (insert "  No agent matches.\n")
        (dolist (entry visible)
          (herdr-status--insert-agent entry widths tabs workspaces))))))

(defun herdr-status--insert-panes (workspaces)
  "Insert the panes running no agent, labelled through WORKSPACES."
  (let ((panes (herdr-status--orphan-panes herdr-status--servers
                                           herdr-status--entries)))
    (when panes
      (magit-insert-section (herdr-status-panes nil t)
        (magit-insert-heading (format "Panes %d" (length panes)))
        (dolist (pane panes)
          (let* ((id (or (alist-get 'pane_id pane) "?"))
                 (label (herdr--entry-label pane))
                 (label (unless (equal label id) label)))
            (magit-insert-section (herdr-status-pane pane t)
              (magit-insert-heading
                (string-join
                 (delq nil (list (concat (herdr-status--attached-column pane)
                                         " "
                                         (herdr-status--pad id 10))
                                 label
                                 (herdr-status--workspace-label pane
                                                                workspaces)))
                 "  "))
              (magit-insert-section-body
                (herdr-status--insert-body
                 pane nil
                 (lambda (indent)
                   (herdr-status--insert-alist
                    pane '(server_key session) indent)))))))))))

;;;; Mode

(autoload 'herdr-transient "herdr-transient" nil t)

(defvar-keymap herdr-status-mode-map
  :doc "Keymap for `herdr-status-mode'."
  :parent magit-section-mode-map
  "?" #'herdr-transient
  "RET" #'herdr-status-visit
  "o" #'herdr-status-visit-other-window
  "s" #'herdr-status-switch
  "P" #'herdr-status-prompt
  "R" #'herdr-status-rename
  "k" #'herdr-status-stop
  "D" #'herdr-status-detach
  "f" #'herdr-status-filter
  "S" #'herdr-status-sort
  "d" #'herdr-status-toggle-details
  "g" #'herdr-status-refresh
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
              (lambda (&rest _) (herdr-status-refresh)))
  (when herdr-status-visibility-indicators
    (setq-local magit-section-visibility-indicators
                herdr-status-visibility-indicators))
  (when (characterp (car (magit-section-visibility-indicator)))
    (setq-local left-margin-width 2))
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

(defun herdr-status--redraw ()
  "Re-fetch and redraw the dashboard in the current buffer."
  (let ((herdr-status--refreshing t)
        (inhibit-read-only t)
        (line (line-number-at-pos))
        (starts (mapcar (lambda (window) (cons window (window-start window)))
                        (get-buffer-window-list nil nil t))))
    (setq herdr-status--servers (herdr-status--collect-servers)
          herdr-status--entries (herdr-status--collect-entries)
          herdr-status--details nil)
    (herdr--prune-session-targets herdr-status--entries)
    (let ((tabs (herdr-status--snapshot-index
                 'tabs 'tab_id herdr-status--servers))
          (workspaces (herdr-status--snapshot-index
                       'workspaces 'workspace_id herdr-status--servers))
          (widths (herdr-status--widths
                   (herdr-status--agents herdr-status--entries))))
      (erase-buffer)
      (magit-insert-section (herdr-status-root)
        (herdr-status--insert-recent widths tabs workspaces)
        (herdr-status--insert-agents widths tabs workspaces)
        (herdr-status--insert-panes workspaces)
        (herdr-status--insert-servers))
      (let ((magit-section-cache-visibility nil))
        (magit-section-show magit-root-section)))
    (goto-char (point-min))
    (forward-line (1- line))
    (pcase-dolist (`(,window . ,start) starts)
      (when (window-live-p window)
        (set-window-start window (min start (point-max)) t)))))

(defun herdr-status-toggle-details ()
  "Show or hide the metadata under the expanded agents of this dashboard."
  (interactive)
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (setq-local herdr-status-show-details (not herdr-status-show-details))
  (herdr-status-refresh)
  (message "Agent details %s"
           (if herdr-status-show-details "shown" "hidden")))

;;;###autoload
(defun herdr-status ()
  "Show the herdr dashboard: servers, agents, recent agents, and panes."
  (interactive)
  (let ((buffer (get-buffer-create herdr-status-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-status-mode)
        (herdr-status-mode))
      (herdr-status-refresh))
    (let ((display-buffer-overriding-action herdr-status-display-action))
      (pop-to-buffer buffer))))

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

(defun herdr-status--on-event (&rest _)
  "Schedule a redraw after a herdr lifecycle event."
  (when (and herdr-status-auto-refresh
             (null herdr-status--timer)
             (herdr-status--buffers))
    (setq herdr-status--timer
          (run-with-idle-timer herdr-status-refresh-delay nil
                               #'herdr-status--refresh-buffers))))

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

(defun herdr-status--server-at-point ()
  "Return the server record of the section at point, or nil."
  (when-let* ((section (magit-current-section))
              ((eq (oref section type) 'herdr-status-server)))
    (cl-find (oref section value) herdr-status--servers
             :key (lambda (server) (alist-get 'key server))
             :test #'equal)))

(defun herdr-status-visit ()
  "Show whatever the section at point stands for.
An agent or pane is attached when nothing shows it yet; a server attaches
its whole session through `herdr-attach-session'."
  (interactive)
  (if-let* ((server (herdr-status--server-at-point)))
      (prog1 (herdr-attach-session (alist-get 'session server))
        (herdr-status-refresh))
    (herdr-visit (herdr-status--attachable-at-point))))

(defun herdr-status-visit-other-window ()
  "Show the agent at point in another window."
  (interactive)
  (let ((display-buffer-overriding-action
         '(display-buffer-use-some-window (inhibit-same-window . t))))
    (herdr-status-visit)))

(defun herdr-status-switch ()
  "Focus the agent at point in herdr and show its buffer."
  (interactive)
  (herdr-agent-switch (herdr-status--target-at-point)))

(defun herdr-status-prompt (text)
  "Send TEXT to the agent at point."
  (interactive (list (read-string "Prompt: ")))
  (herdr-agent-prompt (herdr-status--target-at-point) text)
  (herdr-status-refresh))

(defun herdr-status-rename (name)
  "Rename the agent at point to NAME."
  (interactive (list (read-string "Agent name: ")))
  (herdr-agent-rename (herdr-status--target-at-point) name)
  (herdr-status-refresh))

(defun herdr-status-stop ()
  "Stop the agent at point after confirmation."
  (interactive)
  (let ((entry (herdr-status--entry-at-point)))
    (when (yes-or-no-p (format "Stop %s? " (herdr--entry-label entry)))
      (herdr-agent-stop (herdr--entry-target entry))
      (herdr-status-refresh))))

(defun herdr-status-detach ()
  "Detach the agent at point from Emacs, leaving its herdr pane alone."
  (interactive)
  (herdr-agent-detach
   (herdr-agent-resolve-session (herdr-status--target-at-point)))
  (herdr-status-refresh))

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

(defun herdr-status-filter-by-kind ()
  "Keep only agents of one harness kind."
  (interactive)
  (herdr-status--push-filter 'agent-kind))

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
    ("k" "kind" (lambda () (interactive) (herdr-status-sort-by "kind")))]
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
    ("k" "kind" herdr-status-filter-by-kind)
    ("S" "state" herdr-status-filter-by-state)]
   ["Scope"
    ("p" "project" herdr-status-filter-by-project)
    ("w" "workspace" herdr-status-filter-by-workspace)
    ("a" "attached" herdr-status-filter-attached)]
   ["Manage"
    ("x" "custom" herdr-status-add-filter)
    ("-" "drop one" herdr-status-remove-filter)
    ("DEL" "clear" herdr-status-clear-filters)]])

(provide 'herdr-status)
;;; herdr-status.el ends here
