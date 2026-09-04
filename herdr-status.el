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

(defface herdr-status-path
  '((t :inherit font-lock-comment-face))
  "Face for a directory in the dashboard."
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
  '((t :inherit font-lock-builtin-face))
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
  '((t :inherit font-lock-comment-face))
  "Face for an agent that finished."
  :group 'herdr-status)

(defface herdr-status-state-unknown
  '((t :inherit shadow))
  "Face for an agent state herdr did not report."
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
  "String drawn before an agent's state."
  :type 'string
  :group 'herdr-status)

(defcustom herdr-status-attached-glyph "▌"
  "String marking an agent or pane Emacs has a buffer for.
Rows without a buffer are blank in that column, so the glyph should be
one column wide."
  :type 'string
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

(defcustom herdr-status-preview-lines 3
  "How many lines of an agent's recent output an expanded row shows.
Zero shows none, and asks herdr for nothing."
  :type 'integer
  :group 'herdr-status)

(defcustom herdr-status-preview-read-lines 40
  "How many lines the dashboard reads to find `herdr-status-preview-lines'.
The chrome a harness draws around its output is discarded first, so this
is larger than the number of lines shown."
  :type 'integer
  :group 'herdr-status)

(defcustom herdr-status-preview-ignore-regexps
  '("\\`[[:space:]]*\\'"
    "\\`[[:space:]]*[─━═╌—-]\\{4,\\}"
    "\\`[[:space:]]*[❯>$][[:space:]]*\\'"
    "-- \\(?:INSERT\\|NORMAL\\|VISUAL\\) --"
    "⏵⏵"
    "[0-9]+/[0-9]+ ([0-9]+%)")
  "Lines a preview drops before taking its last few.
Each element is a regexp matched against one line of the agent's recent
output.  The defaults drop blank lines, rules, an empty prompt, and the
status bar a terminal harness paints, so what is left is what the agent
last said."
  :type '(repeat regexp)
  :group 'herdr-status)

(defcustom herdr-status-auto-refresh t
  "Whether herdr lifecycle events redraw a live dashboard."
  :type 'boolean
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
          (push (cons (cons 'server_key (alist-get 'key server)) pane) panes))))))

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

(defun herdr-status--visible-agents ()
  "Return the agents left by the active filters."
  (cl-remove-if-not
   (lambda (entry)
     (cl-every (lambda (filter) (funcall (cdr filter) entry))
               herdr-status--filters))
   (herdr-status--agents herdr-status--entries)))

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

(defun herdr-status--state-column (entry width)
  "Return ENTRY's state padded to WIDTH, glyph included."
  (let ((state (herdr-status--state entry)))
    (propertize (concat herdr-status-state-glyph " "
                        (herdr-status--pad state width))
                'font-lock-face (herdr-status--state-face state))))

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
WIDTHS holds the state, label, kind, pane, and session column widths,
and WORKSPACES resolves the workspace label."
  (concat
   (herdr-status--attached-column entry) " "
   (string-join
    (delq nil
          (list (herdr-status--state-column entry (nth 0 widths))
                (propertize (herdr-status--pad (herdr--entry-label entry)
                                               (nth 1 widths))
                            'font-lock-face 'herdr-status-label)
                (herdr-status--pad (alist-get 'agent entry) (nth 2 widths))
                (herdr-status--pad (alist-get 'pane_id entry) (nth 3 widths))
                (herdr-status--session-column entry (nth 4 widths))
                (herdr-status--workspace-label entry workspaces)
                (when-let* ((directory (herdr-status--directory entry)))
                  (propertize directory 'font-lock-face 'herdr-status-path))))
    "  ")))

(defun herdr-status--widths (entries)
  "Return the column widths fitting ENTRIES."
  (list (herdr-status--width entries #'herdr-status--state 6)
        (herdr-status--width entries #'herdr--entry-label 8)
        (herdr-status--width entries (lambda (entry) (alist-get 'agent entry)) 6)
        (herdr-status--width entries
                             (lambda (entry) (alist-get 'pane_id entry)) 4)
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

(defun herdr-status--insert-field (name value)
  "Insert the detail line pairing NAME with VALUE, unless VALUE is empty."
  (when (and value (not (equal value "")))
    (insert (format "    %s %s\n"
                    (propertize (herdr-status--pad name
                                                   herdr-status--detail-width)
                                'font-lock-face 'herdr-status-detail-key)
                    value))))

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

(defun herdr-status--insert-alist (alist skip)
  "Insert every pair of ALIST whose key is absent from SKIP."
  (dolist (pair alist)
    (unless (memq (car pair) skip)
      (herdr-status--insert-field (symbol-name (car pair))
                                  (herdr-status--format-value (cdr pair))))))

(defun herdr-status--insert-details (entry tabs workspaces)
  "Insert ENTRY's own metadata, resolving labels through TABS and WORKSPACES."
  (dolist (field herdr-status--detail-fields)
    (herdr-status--insert-field
     (symbol-name field)
     (herdr-status--format-value (alist-get field entry))))
  (herdr-status--insert-field
   "workspace" (herdr-status--workspace-label entry workspaces))
  (herdr-status--insert-field
   "tab" (alist-get 'label (gethash (cons (herdr-status--entry-server entry)
                                          (alist-get 'tab_id entry))
                                    tabs)))
  (herdr-status--insert-field
   "buffer" (when-let* ((buffer (herdr--entry-buffer entry)))
              (buffer-name buffer))))

(defun herdr-status--preview-lines (text)
  "Return the last lines of TEXT worth showing as a preview.
Lines matching `herdr-status-preview-ignore-regexps' are dropped first."
  (let ((lines (cl-remove-if
                (lambda (line)
                  (cl-some (lambda (regexp) (string-match-p regexp line))
                           herdr-status-preview-ignore-regexps))
                (split-string (or text "") "\n"))))
    (mapcar #'string-trim (last lines herdr-status-preview-lines))))

(defun herdr-status--read-preview (entry)
  "Return ENTRY's recent output as preview lines, asking herdr for it."
  (when-let* ((pane (alist-get 'pane_id entry)))
    (condition-case nil
        (herdr-with-session (alist-get 'session entry)
          (let ((result (herdr-api-agent-read
                         "recent" pane
                         :lines herdr-status-preview-read-lines
                         :strip-ansi t)))
            (herdr-status--preview-lines
             (alist-get 'text (alist-get 'read result)))))
      (error nil))))

(defun herdr-status--preview (entry)
  "Return ENTRY's preview lines, fetching them at most once per refresh."
  (when (> herdr-status-preview-lines 0)
    (let ((key (or (alist-get 'pane_id entry) (alist-get 'terminal_id entry))))
      (when key
        (if-let* ((cached (assoc key herdr-status--previews)))
            (cdr cached)
          (let ((lines (herdr-status--read-preview entry)))
            (push (cons key lines) herdr-status--previews)
            lines))))))

(defun herdr-status--insert-preview (entry)
  "Insert the last thing ENTRY's agent said."
  (when-let* ((lines (herdr-status--preview entry)))
    (herdr-status--insert-field "preview" (car lines))
    (dolist (line (cdr lines))
      (herdr-status--insert-field "" line))))

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

(defun herdr-status--insert-adapter (entry)
  "Insert the fields ENTRY's adapter reports beyond the entry itself."
  (when-let* ((status (herdr-status--adapter-status entry)))
    (herdr-status--insert-alist status (mapcar #'car entry))))

(defun herdr-status--insert-agent (entry widths tabs workspaces)
  "Insert ENTRY as one collapsible row.
WIDTHS aligns the columns, and TABS and WORKSPACES resolve its labels."
  (magit-insert-section (herdr-status-agent entry t)
    (magit-insert-heading (herdr-status--row entry widths workspaces))
    (magit-insert-section-body
      (herdr-status--insert-details entry tabs workspaces)
      (herdr-status--insert-preview entry)
      (herdr-status--insert-adapter entry))))

(defun herdr-status--filter-summary ()
  "Return the active filters rendered for the agents heading."
  (when herdr-status--filters
    (concat "  "
            (propertize (string-join (mapcar (lambda (filter)
                                               (symbol-name (car filter)))
                                             (reverse herdr-status--filters))
                                     " ")
                        'font-lock-face 'herdr-status-active-filter))))

(defun herdr-status--insert-servers ()
  "Insert one collapsible entry per known herdr server."
  (magit-insert-section (herdr-status-servers)
    (magit-insert-heading (format "Servers (%d)" (length herdr-status--servers)))
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
               (number-to-string (length (alist-get field snapshot)))))))))
    (insert "\n")))

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
        (magit-insert-heading (format "Recent (%d)" (length entries)))
        (dolist (entry entries)
          (herdr-status--insert-agent entry widths tabs workspaces))
        (insert "\n")))))

(defun herdr-status--insert-agents (widths tabs workspaces)
  "Insert the filtered agent list.
WIDTHS, TABS, and WORKSPACES are passed through to each row."
  (let ((visible (herdr-status--visible-agents))
        (total (length (herdr-status--agents herdr-status--entries))))
    (magit-insert-section (herdr-status-agents)
      (magit-insert-heading
        (concat (format "Agents (%d/%d)" (length visible) total)
                (herdr-status--filter-summary)))
      (if (null visible)
          (insert "  No agent matches.\n")
        (dolist (entry visible)
          (herdr-status--insert-agent entry widths tabs workspaces)))
      (insert "\n"))))

(defun herdr-status--insert-panes (workspaces)
  "Insert the panes running no agent, labelled through WORKSPACES."
  (let ((panes (herdr-status--orphan-panes herdr-status--servers
                                           herdr-status--entries)))
    (when panes
      (magit-insert-section (herdr-status-panes)
        (magit-insert-heading (format "Panes (%d)" (length panes)))
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
                (herdr-status--insert-alist pane '(server_key))))))
        (insert "\n")))))

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
  "g" #'herdr-status-refresh
  "q" #'quit-window)

(defun herdr-status--widen-fringe ()
  "Give every window showing the dashboard its own left fringe."
  (when (and herdr-status-left-fringe-width (display-graphic-p))
    (dolist (window (get-buffer-window-list nil nil t))
      (let ((fringes (window-fringes window)))
        (unless (eq (car fringes) herdr-status-left-fringe-width)
          (set-window-fringes window herdr-status-left-fringe-width
                              (nth 1 fringes)))))))

(define-derived-mode herdr-status-mode magit-section-mode "Herdr"
  "Major mode for the herdr status dashboard."
  :group 'herdr-status
  (setq-local revert-buffer-function
              (lambda (&rest _) (herdr-status-refresh)))
  (add-hook 'window-configuration-change-hook
            #'herdr-status--widen-fringe nil t))

(defun herdr-status-refresh ()
  "Re-fetch every known herdr server and redraw the dashboard."
  (interactive)
  (unless (derived-mode-p 'herdr-status-mode)
    (user-error "Not a herdr status buffer"))
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (setq herdr-status--servers (herdr-status--collect-servers)
          herdr-status--entries (herdr-status--collect-entries)
          herdr-status--details nil
          herdr-status--previews nil)
    (herdr--prune-session-targets herdr-status--entries)
    (let ((tabs (herdr-status--snapshot-index
                 'tabs 'tab_id herdr-status--servers))
          (workspaces (herdr-status--snapshot-index
                       'workspaces 'workspace_id herdr-status--servers))
          (widths (herdr-status--widths
                   (herdr-status--agents herdr-status--entries))))
      (erase-buffer)
      (magit-insert-section (herdr-status-root)
        (herdr-status--insert-servers)
        (herdr-status--insert-recent widths tabs workspaces)
        (herdr-status--insert-agents widths tabs workspaces)
        (herdr-status--insert-panes workspaces))
      (let ((magit-section-cache-visibility nil))
        (magit-section-show magit-root-section)))
    (goto-char (point-min))
    (forward-line (1- line))))

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
