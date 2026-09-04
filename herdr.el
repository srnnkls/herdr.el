;;; herdr.el --- Control persistent herdr terminal workspaces -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.13.0") (magit-section "4.0.0"))
;; Keywords: terminals, tools, processes
;; URL: https://github.com/srnnkls/herdr.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Herdr runs a persistent server that owns terminals and exposes a
;; newline-delimited JSON socket API.  This package speaks that API and
;; attaches server-owned terminals into Emacs terminal buffers, so a herdr
;; pane and an Emacs buffer are two views of one process.
;;
;;   M-x herdr-attach-agent   attach a running agent's terminal
;;   M-x herdr-attach-pane    attach any pane's terminal
;;
;; Every API method has a wrapper in herdr-api.el.

;;; Code:

(require 'cl-lib)

(defconst herdr-version "0.1.0"
  "Herdr package version.")
(require 'subr-x)
(require 'herdr-core)
(require 'herdr-api)

(declare-function ghostel-exec "ext:ghostel" (buffer program &optional args identity))
(declare-function eat-mode "ext:eat" ())
(declare-function eat-exec "ext:eat" (buffer name command startfile switches))
(declare-function vterm "ext:vterm" (&optional buffer-name))
(defvar vterm-shell)
(defvar vterm-buffer-name)
(defvar eat-term-name)

(defcustom herdr-terminal-backend 'auto
  "Terminal emulator used for attached herdr terminals.
`auto' picks the first of ghostel, vterm or eat that is available."
  :type '(choice (const :tag "Auto-detect" auto)
                 (const ghostel)
                 (const vterm)
                 (const eat))
  :group 'herdr)

(defcustom herdr-attach-takeover t
  "Whether attaching claims input ownership of the terminal.
Only one writable direct-attach client owns input per terminal, so
attaching without takeover leaves the Emacs buffer read-only while
another client holds it."
  :type 'boolean
  :group 'herdr)

(defcustom herdr-buffer-name-function #'herdr-default-buffer-name
  "Function naming the Emacs buffer of an attached terminal.
Called with the terminal's label and the directory it works in, which
may be nil."
  :type 'function
  :group 'herdr)

(defcustom herdr-use-side-window t
  "Whether attached terminals are shown in a side window.
Nil shows them like any other buffer, which leaves the placement to
`display-buffer-alist' or a popup framework."
  :type 'boolean
  :group 'herdr)

(defcustom herdr-window-side 'right
  "Side of the frame attached terminals are shown on."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'herdr)

(defcustom herdr-window-width 100
  "Body width of attached terminal windows on the left or right side."
  :type 'integer
  :group 'herdr)

(defcustom herdr-window-height 20
  "Height of attached terminal windows on the top or bottom side."
  :type 'integer
  :group 'herdr)

(defcustom herdr-window-slot-base 100
  "First side-window slot attached terminals may claim.
Other packages should use distinct side-window slots to avoid
replacing attached terminals."
  :type 'integer
  :group 'herdr)

(defcustom herdr-display-buffer-action nil
  "Display action used when a command shows an attached terminal buffer.
When set it replaces the side window built from `herdr-window-side'
and friends."
  :type '(choice (const :tag "Side window" nil) sexp)
  :group 'herdr)

;;;; Snapshot helpers

(defun herdr-agents ()
  "Return the list of herdr agents."
  (alist-get 'agents (herdr-api-agent-list)))

(defun herdr-panes ()
  "Return the list of herdr panes."
  (alist-get 'panes (herdr-api-pane-list)))

(defun herdr-tabs ()
  "Return the list of herdr tabs."
  (alist-get 'tabs (herdr-api-tab-list)))

(defun herdr-workspaces ()
  "Return the list of herdr workspaces."
  (alist-get 'workspaces (herdr-api-workspace-list)))

(defun herdr-snapshot ()
  "Return the full herdr session snapshot."
  (alist-get 'snapshot (herdr-api-session-snapshot)))

(defcustom herdr-workspace-label-function #'herdr-default-workspace-label
  "Function returning the herdr workspace a directory's sessions belong in.
It is called with a directory and returns the workspace's label.  An
editor that groups work into workspaces of its own should return the
name of the one owning the directory, so the two line up."
  :type 'function
  :group 'herdr)

(defun herdr-default-workspace-label (directory)
  "Return the herdr workspace label for DIRECTORY: its own name."
  (file-name-nondirectory (directory-file-name (expand-file-name directory))))

(defun herdr-workspace-label (directory)
  "Return the herdr workspace label DIRECTORY's sessions belong in."
  (funcall herdr-workspace-label-function directory))

(defun herdr-default-current-workspace-label ()
  "Return the workspace label for the current buffer's project."
  (let* ((directory (or (and buffer-file-name
                             (file-name-directory buffer-file-name))
                        default-directory))
         (project (condition-case nil
                      (funcall herdr-project-root-function directory)
                    (file-error nil))))
    (herdr-workspace-label (or project directory))))

(defcustom herdr-current-workspace-label-function
  #'herdr-default-current-workspace-label
  "Function returning the current editor workspace label."
  :type 'function
  :group 'herdr)

(defun herdr-current-workspace-label ()
  "Return the current editor workspace label."
  (funcall herdr-current-workspace-label-function))

(defun herdr-workspace-id (label)
  "Return the id of the herdr workspace labelled LABEL, or nil."
  (when label
    (alist-get 'workspace_id
               (cl-find-if (lambda (workspace)
                             (equal (alist-get 'label workspace) label))
                           (herdr-workspaces)))))

(defvar herdr--open-tab-cleanup-failed-function nil)

(cl-defun herdr-open-tab (&key cwd label workspace env focus)
  "Open a tab labelled LABEL in the herdr workspace labelled WORKSPACE.
CWD is its working directory.  Creates that workspace when it does not
exist yet, and labels the tab it comes with rather than leaving an empty
one behind.  Without a WORKSPACE the tab goes to the focused workspace,
or to a new one when the session has none.  The reply carries
`root_pane' and `tab'."
  (let ((id (herdr-workspace-id workspace)))
    (if (or id (and (not workspace) (herdr-workspaces)))
        (herdr-api-tab-create :cwd cwd :label label :env env
                              :workspace-id id :focus focus)
      (let ((created (herdr-api-workspace-create
                      :cwd cwd :label (or workspace label) :env env :focus focus)))
        (condition-case err
            (progn
              (when-let* ((label label)
                          (tab (alist-get 'tab created)))
                (herdr-api-tab-rename label (alist-get 'tab_id tab)))
              created)
          (error
           (when-let* ((workspace-id
                        (or (alist-get 'workspace_id (alist-get 'workspace created))
                            (alist-get 'workspace_id (alist-get 'tab created))
                            (alist-get 'workspace_id (alist-get 'root_pane created))
                            (when-let* ((tab-id (alist-get 'tab_id (alist-get 'tab created))))
                              (car (split-string tab-id ":" t))))))
             (condition-case nil
                 (herdr-api-workspace-close workspace-id)
               (error
                (when herdr--open-tab-cleanup-failed-function
                  (funcall herdr--open-tab-cleanup-failed-function created)))))
           (signal (car err) (cdr err))))))))

(defun herdr-pane-text (pane-id &optional source lines)
  "Return terminal output of PANE-ID.
SOURCE is one of `visible' (default), `recent', `recent_unwrapped'
or `detection'.  LINES limits how many lines are returned."
  (alist-get 'text
             (alist-get 'read
                        (herdr-api-pane-read pane-id (symbol-name (or source 'visible))
                                             :lines lines))))

;;;; Attaching terminals

(defun herdr--backend ()
  "Return the terminal backend used for attached terminals."
  (if (eq herdr-terminal-backend 'auto)
      (cond ((or (featurep 'ghostel) (locate-library "ghostel")) 'ghostel)
            ((or (featurep 'vterm) (locate-library "vterm")) 'vterm)
            ((or (featurep 'eat) (locate-library "eat")) 'eat)
            (t (signal 'herdr-error
                       (list "no terminal backend: install ghostel, vterm or eat"))))
    herdr-terminal-backend))

(defun herdr-attach-command (terminal-id &optional takeover)
  "Return the command list attaching to TERMINAL-ID.
TAKEOVER claims input ownership from any other attached client."
  `(,herdr-executable ,@(herdr-global-args)
                      "terminal" "attach" ,terminal-id
                      ,@(when takeover '("--takeover"))))

(defun herdr--terminal-exec (buffer program args)
  "Run PROGRAM with ARGS inside BUFFER and return the buffer used."
  (let ((process-environment (herdr-process-environment)))
    (herdr--terminal-exec-1 buffer program args)))

(defun herdr--terminal-exec-1 (buffer program args)
  "Run PROGRAM with ARGS inside BUFFER using the configured backend."
  (pcase (herdr--backend)
    ('ghostel
     (require 'ghostel)
     (ghostel-exec buffer program args)
     buffer)
    ('vterm
     (require 'vterm)
     (let ((vterm-buffer-name (buffer-name buffer))
           (vterm-shell (mapconcat #'shell-quote-argument (cons program args) " ")))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (save-window-excursion (vterm vterm-buffer-name))))
    ('eat
     (require 'eat)
     (with-current-buffer buffer
       (let ((eat-term-name "xterm-256color"))
         (unless (derived-mode-p 'eat-mode) (eat-mode))
         (eat-exec buffer (buffer-name buffer) program nil args)))
     buffer)))

(defun herdr--git-line (directory &rest arguments)
  "Return the single line git prints for ARGUMENTS in DIRECTORY, or nil."
  (when (and directory (file-directory-p directory))
    (let ((default-directory (file-name-as-directory directory)))
      (with-temp-buffer
        (when (eq 0 (ignore-errors (apply #'process-file "git" nil t nil arguments)))
          (let ((line (string-trim (buffer-string))))
            (unless (string-empty-p line) line)))))))

(defun herdr-directory-branch (directory)
  "Return the git branch checked out in DIRECTORY, or its commit when detached."
  (or (herdr--git-line directory "symbolic-ref" "--quiet" "--short" "HEAD")
      (herdr--git-line directory "rev-parse" "--short" "HEAD")))

(defun herdr-directory-project (directory)
  "Return the name of the project DIRECTORY belongs to.
Inside a git repository that is the main checkout's directory name, so
a linked worktree is named after the project rather than after itself.
Elsewhere it is the `herdr-workspace-label' of DIRECTORY."
  (if-let* ((common (herdr--git-line directory "rev-parse" "--git-common-dir")))
      (file-name-nondirectory
       (directory-file-name
        (file-name-directory
         (directory-file-name
          (expand-file-name common (file-name-as-directory directory))))))
    (herdr-workspace-label directory)))

(defun herdr-default-buffer-name (label &optional directory)
  "Return the buffer name for a terminal named LABEL working in DIRECTORY.
The name leads with the project and its git branch, so the terminal
reads as *herdr: app@main LABEL*."
  (let ((place (when directory
                 (concat (herdr-directory-project directory)
                         (when-let* ((branch (herdr-directory-branch directory)))
                           (concat "@" branch))))))
    (format "*herdr: %s*" (string-join (delq nil (list place label)) " "))))

;;;; Windows

(defvar-local herdr--window-slot nil
  "Side-window slot this attached terminal owns.")

(defun herdr--window-slot (buffer)
  "Return the side-window slot BUFFER owns, claiming a free one if needed."
  (or (buffer-local-value 'herdr--window-slot buffer)
      (let ((taken (delq nil (mapcar (lambda (other)
                                       (buffer-local-value 'herdr--window-slot other))
                                     (buffer-list))))
            (slot herdr-window-slot-base))
        (while (memq slot taken) (cl-incf slot))
        (with-current-buffer buffer (setq herdr--window-slot slot)))))

(defun herdr-display-buffer (buffer)
  "Show BUFFER and return its window.
Attached terminals go to their own slot of the `herdr-window-side'
side window, so several of them sit next to each other instead of
replacing one another."
  (cond
   (herdr-display-buffer-action (display-buffer buffer herdr-display-buffer-action))
   ((not herdr-use-side-window)
    (let ((window (display-buffer buffer)))
      (when window (select-window window))
      window))
   (t
    (let* ((display-buffer-alist
            `((,(regexp-quote (buffer-name buffer))
               (display-buffer-in-side-window)
               (side . ,herdr-window-side)
               (slot . ,(herdr--window-slot buffer))
               ,@(if (memq herdr-window-side '(left right))
                     `((window-width
                        . ,(lambda (window)
                             (let ((delta (- herdr-window-width
                                             (window-body-width window))))
                               (unless (zerop delta)
                                 (ignore-errors (window-resize window delta t)))))))
                   `((window-height . ,herdr-window-height)))
               (window-parameters . ((no-delete-other-windows . t))))))
           (window (display-buffer buffer)))
      (when window
        (set-window-dedicated-p window t)
        (select-window window))
      window))))

(defvar-local herdr-terminal-id nil
  "Id of the herdr terminal this buffer shows.")
(put 'herdr-terminal-id 'permanent-local t)

(defvar-local herdr-terminal-session nil
  "Session designator of the herdr server this buffer's terminal lives on.")
(put 'herdr-terminal-session 'permanent-local t)

(defvar-local herdr-terminal-server-key nil
  "Canonical server key of the herdr terminal this buffer shows.")
(put 'herdr-terminal-server-key 'permanent-local t)

(defcustom herdr-report-focus-loss nil
  "Whether attached terminals report Emacs focus loss to their process.
Herdr's own client also reports focus for the pane, but only speaks
again when its focus changes, so a focus-out from Emacs leaves the
process believing nobody is looking.  Nil drops the focus-out: Emacs
reports focus-in only, and the process otherwise follows herdr."
  :type 'boolean
  :group 'herdr)

(defvar ghostel--focus-state)

(defun herdr--ghostel-focus-event (function term gained)
  "Call FUNCTION with TERM and GAINED unless it reports focus loss to herdr.
Resets `ghostel--focus-state' for a dropped focus-out so the next
focus-in still goes through."
  (if (or gained herdr-report-focus-loss (not herdr-terminal-id))
      (funcall function term gained)
    (setq ghostel--focus-state nil)
    nil))

(with-eval-after-load 'ghostel
  (advice-add 'ghostel--focus-event :around #'herdr--ghostel-focus-event))

(defvar herdr-buffer-functions nil
  "Functions called with each buffer that starts showing a herdr terminal.
Runs for plain attachments and for the buffers other integrations build
around a terminal, so an environment can claim the buffer - pinning it
to a workspace, say - in one place.")

(defun herdr-claim-buffer (buffer terminal-id &optional session)
  "Mark BUFFER as showing TERMINAL-ID on SESSION's server.
SESSION defaults to the one in scope.  `herdr-buffer-functions' then
sees the buffer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq herdr-terminal-id terminal-id
            herdr-terminal-session (or session herdr-session)
            herdr-terminal-server-key (herdr-server-key)))
    (run-hook-with-args 'herdr-buffer-functions buffer)
    buffer))

(defun herdr-terminal-buffer (terminal-id &optional server-key)
  "Return the live buffer showing TERMINAL-ID on SERVER-KEY, if there is one."
  (when terminal-id
    (let ((server-key (or server-key (herdr-server-key))))
      (cl-find-if (lambda (buffer)
                    (and (equal (buffer-local-value 'herdr-terminal-id buffer) terminal-id)
                         (equal (buffer-local-value 'herdr-terminal-server-key buffer)
                                server-key)
                         (get-buffer-process buffer)))
                  (buffer-list)))))

(defun herdr--free-buffer-name (label terminal-id &optional server-key directory)
  "Return a buffer name for LABEL that no other terminal answers to.
SERVER-KEY identifies the server terminal identity belongs to and
DIRECTORY is where the terminal works.  Tab labels repeat across herdr
workspaces, so a taken name gets a counter.  Signals when TERMINAL-ID
is the one already there."
  (let ((name (funcall herdr-buffer-name-function label directory))
        (server-key (or server-key (herdr-server-key)))
        (counter 1))
    (while (when-let* ((buffer (get-buffer name))
                       ((get-buffer-process buffer)))
             (when (and (equal (buffer-local-value 'herdr-terminal-id buffer) terminal-id)
                        (equal (buffer-local-value 'herdr-terminal-server-key buffer)
                               server-key))
               (user-error "Buffer %s is already attached" name))
             (setq name (funcall herdr-buffer-name-function
                                 (format "%s<%d>" label (cl-incf counter))
                                 directory))))
    name))

(cl-defun herdr-attach-terminal (terminal-id &key label directory takeover display)
  "Attach herdr terminal TERMINAL-ID to an Emacs terminal buffer.
LABEL names the buffer, DIRECTORY sets its `default-directory',
TAKEOVER claims input ownership, and DISPLAY shows the buffer when
non-nil.  Returns the buffer."
  (let ((name (herdr--free-buffer-name (or label terminal-id) terminal-id
                                       (herdr-server-key) directory)))
    (when-let* ((existing (get-buffer name)))
      (kill-buffer existing))
    (let ((buffer (get-buffer-create name))
          (command (herdr-attach-command terminal-id takeover)))
      (with-current-buffer buffer
        (when directory (setq default-directory (file-name-as-directory directory))))
      (setq buffer (herdr--terminal-exec buffer (car command) (cdr command)))
      (herdr-claim-buffer buffer terminal-id)
      (when display (herdr-display-buffer buffer))
      buffer)))

;;;; Completion

(defun herdr--entry-label (entry)
  "Return a short label for pane or agent ENTRY."
  (or (alist-get 'name entry)
      (alist-get 'label entry)
      (alist-get 'terminal_title_stripped entry)
      (alist-get 'agent entry)
      (alist-get 'pane_id entry)))

(defun herdr-entry-directory (entry)
  "Return the directory pane or agent ENTRY is working in.
Herdr reports both where the pane was opened and where its foreground
process actually sits, and an agent that moves itself — into a worktree,
say — only moves the latter."
  (let ((foreground (alist-get 'foreground_cwd entry))
        (start (alist-get 'cwd entry)))
    (cond ((and (stringp foreground) (not (string-empty-p foreground)))
           foreground)
          ((and (stringp start) (not (string-empty-p start))) start))))

(defvar herdr-entry-annotation-functions nil
  "Functions adding annotation fields to a session entry.
Each is called with the entry and returns a string to append to the
completion annotation, or nil.")

(defun herdr--entry-buffer (entry)
  "Return the live buffer showing ENTRY, if any."
  (let ((buffer (alist-get 'buffer entry)))
    (if (buffer-live-p buffer)
        buffer
      (herdr-terminal-buffer (alist-get 'terminal_id entry)
                             (alist-get 'server_key entry)))))

(defun herdr--entry-key (entry)
  "Return the identity ENTRY is deduplicated by."
  (cons (or (alist-get 'server_key entry) (herdr-server-key))
        (or (alist-get 'terminal_id entry)
            (alist-get 'pane_id entry)
            (herdr--entry-label entry))))

(defun herdr--entry-session-label (entry)
  "Return the session ENTRY lives on, once more than one is in play."
  (when (cdr (herdr-known-sessions))
    (or (herdr-session-name (alist-get 'session entry)) "shared")))

(defun herdr--entry-annotation (entry)
  "Return the completion annotation for pane or agent ENTRY."
  (string-join
   (delq nil (append (list (herdr--entry-session-label entry)
                           (alist-get 'agent entry)
                           (alist-get 'agent_status entry)
                           (when-let* ((cwd (herdr-entry-directory entry)))
                             (abbreviate-file-name cwd)))
                     (mapcar (lambda (fn) (funcall fn entry))
                             herdr-entry-annotation-functions)))
   "  "))

(defun herdr--candidates (entries)
  "Return an alist of completion candidates for ENTRIES."
  (let ((candidates nil))
    (dolist (entry entries (nreverse candidates))
      (let ((candidate (herdr--entry-label entry)))
        (when (assoc candidate candidates)
          (setq candidate (format "%s (%s)" candidate (herdr--entry-key entry))))
        (push (cons candidate entry) candidates)))))

(cl-defun herdr-read-entry (prompt entries &key require-agent)
  "Read one of ENTRIES with PROMPT and return its alist.
REQUIRE-AGENT keeps only entries running that agent kind."
  (let* ((entries (if require-agent
                      (cl-remove-if-not
                       (lambda (entry) (equal (alist-get 'agent entry) require-agent))
                       entries)
                    entries))
         (candidates (herdr--candidates entries))
         (annotation (lambda (candidate)
                       (when-let* ((entry (cdr (assoc candidate candidates))))
                         (concat "   " (herdr--entry-annotation entry)))))
         (group (lambda (candidate transform)
                  (if transform
                      candidate
                    (when-let* ((entry (cdr (assoc candidate candidates))))
                      (or (alist-get 'kind entry) "herdr"))))))
    (unless candidates
      (user-error "No matching herdr %s" (or require-agent "sessions")))
    (let ((choice (completing-read
                   prompt
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         `(metadata (annotation-function . ,annotation)
                                    (group-function . ,group)
                                    (category . herdr-entry))
                       (complete-with-action action candidates string predicate)))
                   nil t)))
      (cdr (assoc choice candidates)))))

;;;; Sessions

(defvar herdr-session-functions '(herdr-agent-sessions)
  "Functions returning lists of session entries for `herdr-jump'.
Entries are alists; `kind' names the group they appear under and
`buffer' points at the Emacs buffer showing them, when one exists.")

(defun herdr-agent-sessions ()
  "Return the agents of the herdr session in scope as session entries."
  (mapcar (lambda (agent)
            (append `((kind . "herdr")
                      (session . ,herdr-session)
                      (server_key . ,(herdr-server-key)))
                    agent))
          (herdr-agents)))

(defun herdr--session-entries ()
  "Return the entries of every session in `herdr-all-sessions'.
Sessions whose server does not answer are skipped rather than started."
  (apply #'append
         (mapcar
          (lambda (session)
            (let ((herdr-socket-path (if (equal session herdr-session)
                                         herdr-socket-path
                                       nil))
                  (herdr-session (or session herdr-session)))
              (when (herdr-available-p)
                (let ((entries (apply #'append (mapcar #'funcall herdr-session-functions))))
                  (mapcar (lambda (entry)
                            (let ((entry (copy-tree entry)))
                              (if (assq 'server_key entry)
                                  (when (null (alist-get 'server_key entry))
                                    (setf (alist-get 'server_key entry) (herdr-server-key)))
                                (setf (alist-get 'server_key entry) (herdr-server-key)))
                              entry))
                          entries)))))
          (herdr-all-sessions))))

(defun herdr-sessions ()
  "Return every running session, one entry per terminal.
Entries that already have an Emacs buffer win over bare ones."
  (let ((seen (make-hash-table :test 'equal))
        (order nil))
    (dolist (entry (herdr--session-entries))
      (let* ((key (herdr--entry-key entry))
             (previous (gethash key seen)))
        (cond
         ((null previous)
          (puthash key entry seen)
          (push key order))
         ((and (herdr--entry-buffer entry) (not (herdr--entry-buffer previous)))
          (puthash key entry seen)))))
    (mapcar (lambda (key) (gethash key seen)) (nreverse order))))

(defvar herdr--recent-session-targets nil
  "Session targets ordered from most to least recently used.")

(defun herdr--entry-target (entry)
  "Return ENTRY's composite server and terminal target, or nil."
  (when-let* ((server-key (alist-get 'server_key entry))
              (terminal-id (alist-get 'terminal_id entry)))
    (cons server-key terminal-id)))

(defun herdr--record-session-target (target)
  "Move composite session TARGET to the front of the recent list."
  (when target
    (setq herdr--recent-session-targets
          (cons target (delete target herdr--recent-session-targets))))
  target)

(defun herdr--prune-session-targets (entries)
  "Drop recent session targets that are absent from ENTRIES."
  (let ((targets (delq nil (mapcar #'herdr--entry-target entries))))
    (setq herdr--recent-session-targets
          (cl-remove-if-not (lambda (target) (member target targets))
                            herdr--recent-session-targets))))

(defun herdr-visit (entry)
  "Show ENTRY and return its buffer.
An entry that nothing shows yet is attached first, on the server it
came from."
  (let ((buffer
         (if-let* ((buffer (herdr--entry-buffer entry)))
             (progn (pop-to-buffer buffer) buffer)
           (herdr-with-session (alist-get 'session entry)
             (herdr-attach-entry entry)))))
    (when (and buffer (alist-get 'agent entry))
      (herdr--record-session-target (herdr--entry-target entry)))
    buffer))

;;;; Commands

(autoload 'herdr-agent-attach-entry "herdr-agent")
(defvar herdr-attach-functions '(herdr-agent-attach-entry)
  "Functions that may claim an entry before it is attached as a terminal.
Each is called with the pane or agent alist and returns the buffer it
opened, or nil to let the next one try.  The plain terminal attach runs
only when all of them decline.")

(defun herdr-attach-entry (entry)
  "Attach pane or agent ENTRY and return the buffer showing it.
Gives `herdr-attach-functions' the first chance to claim ENTRY."
  (let ((server-key (alist-get 'server_key entry)))
    (if server-key
        (let ((herdr-socket-path server-key)
              (herdr-session (or (alist-get 'session entry) herdr-session)))
          (or (run-hook-with-args-until-success 'herdr-attach-functions entry)
              (herdr-attach-terminal (alist-get 'terminal_id entry)
                                     :label (herdr--entry-label entry)
                                     :directory (herdr-entry-directory entry)
                                     :takeover herdr-attach-takeover
                                     :display t)))
      (herdr-with-session (alist-get 'session entry)
        (or (run-hook-with-args-until-success 'herdr-attach-functions entry)
            (herdr-attach-terminal (alist-get 'terminal_id entry)
                                   :label (herdr--entry-label entry)
                                   :directory (herdr-entry-directory entry)
                                   :takeover herdr-attach-takeover
                                   :display t))))))

;;;###autoload
(defun herdr-attach-agent (agent)
  "Attach the terminal of herdr AGENT to an Emacs buffer.
Offers the agents of the session this directory routes to."
  (interactive (list (herdr-with-session (herdr-session-for)
                       (herdr-read-entry "Attach herdr agent: " (herdr-agent-sessions)))))
  (herdr-attach-entry agent))

;;;###autoload
(defun herdr-attach-pane (pane)
  "Attach the terminal of herdr PANE to an Emacs buffer.
Offers the panes of the session this directory routes to."
  (interactive (list (herdr-with-session (herdr-session-for)
                       (let ((session herdr-session))
                         (herdr-read-entry
                          "Attach herdr pane: "
                          (mapcar (lambda (pane)
                                    (append `((kind . "herdr") (session . ,session)) pane))
                                  (herdr-panes)))))))
  (herdr-attach-entry pane))

;;;; Attaching a whole session

(defcustom herdr-workspace-open-function nil
  "Function opening an editor workspace for a herdr workspace group.
Called with the workspace alist and the directory its panes work in,
before `herdr-attach-session' attaches that group's terminals.  Its
return value is bound to `herdr-attach-session-workspace' while those
terminals are attached.  Nil attaches everything wherever you are."
  :type '(choice (const :tag "Attach where you are" nil) function)
  :group 'herdr)

(defcustom herdr-attach-session-workspace-policy 'mirror
  "How full herdr sessions are grouped into editor workspaces.
`mirror' preserves each herdr workspace as a separate group.  `merge'
combines entries whose working directories have the same
`herdr-workspace-label'."
  :type '(choice (const :tag "Mirror herdr workspaces" mirror)
                 (const :tag "Merge by editor workspace label" merge))
  :group 'herdr)

(defvar herdr-attach-session-workspace nil
  "Editor workspace selected for the session group being attached.")

(defun herdr-session-layout (&optional all)
  "Return the herdr session's workspaces paired with their entries.
Agents only, unless ALL asks for every pane.  Workspaces with nothing
in them are left out."
  (let* ((tabs (mapcar (lambda (tab)
                         (cons (alist-get 'tab_id tab) (alist-get 'label tab)))
                       (herdr-tabs)))
         (panes (mapcar (lambda (pane)
                          (append `((kind . "herdr")
                                    (session . ,herdr-session)
                                    (server_key . ,(herdr-server-key)))
                                  (unless (alist-get 'label pane)
                                    `((label . ,(cdr (assoc (alist-get 'tab_id pane) tabs)))))
                                  pane))
                        (if all (herdr-panes) (herdr-agents)))))
    (delq nil
          (mapcar (lambda (workspace)
                    (when-let* ((members (cl-remove-if-not
                                          (lambda (pane)
                                            (equal (alist-get 'workspace_id pane)
                                                   (alist-get 'workspace_id workspace)))
                                          panes)))
                      (cons workspace members)))
                  (herdr-workspaces)))))

(defun herdr--session-attachment-layout (layout)
  "Return LAYOUT grouped for full-session attachment."
  (if (not (eq herdr-attach-session-workspace-policy 'merge))
      layout
    (let ((by-label (make-hash-table :test #'equal))
          groups)
      (dolist (group layout)
        (dolist (entry (cdr group))
          (let* ((directory (herdr-entry-directory entry))
                 (label (and directory (herdr-workspace-label directory)))
                 (existing (gethash label by-label)))
            (if existing
                (setcdr existing (nconc (cdr existing) (list entry)))
              (let ((merged (cons (car group) (list entry))))
                (puthash label merged by-label)
                (push merged groups))))))
      (nreverse groups))))

;;;###autoload
(defun herdr-attach-session (&optional session all takeover)
  "Attach the agents of a herdr SESSION in editor workspace groups.
`herdr-attach-session-workspace-policy' controls whether the groups
mirror herdr workspaces or merge by editor workspace label.
`herdr-workspace-open-function' opens each group, and every agent in it
becomes a buffer there.  ALL attaches plain panes too.  Input ownership
stays with herdr's own client unless TAKEOVER says otherwise, so the
attached buffers start as a view of a session someone else is driving.
Terminals Emacs already shows are left alone.  Returns the buffers it
attached."
  (interactive (list (herdr-read-session "Attach herdr session: ")
                     current-prefix-arg
                     nil))
  (herdr-with-session session
    (unless (herdr-available-p)
      (user-error "No herdr server on %s" (herdr-socket-file)))
    (let ((herdr-attach-takeover takeover)
          (buffers nil))
      (dolist (group (herdr--session-attachment-layout
                      (herdr-session-layout all)))
        (let* ((workspace (car group))
               (entries (cdr group))
               (directory (herdr-entry-directory (car entries)))
               (herdr-attach-session-workspace
                (when herdr-workspace-open-function
                  (funcall herdr-workspace-open-function workspace directory))))
          (dolist (entry entries)
            (unless (if-let* ((server-key (alist-get 'server_key entry)))
                        (herdr-terminal-buffer (alist-get 'terminal_id entry) server-key)
                      (herdr-terminal-buffer (alist-get 'terminal_id entry)))
              (push (herdr-attach-entry entry) buffers)))))
      (setq buffers (delq nil (nreverse buffers)))
      (message "Attached %d terminal%s from %s"
               (length buffers) (if (= (length buffers) 1) "" "s")
               (or (herdr-session-name session) "the shared session"))
      buffers)))

;;;###autoload
(defun herdr-jump (session)
  "Jump to a running SESSION, whether or not Emacs already show it."
  (interactive (list (herdr-read-entry "Jump to session: " (herdr-sessions))))
  (herdr-visit session))

(defun herdr--session-designator (name)
  "Return the session designator NAME stands for."
  (pcase name
    ("shared" 'shared)
    ("emacs" 'emacs)
    (_ name)))

(defun herdr-available-sessions ()
  "Return the sessions with a socket on disk, the shared one first."
  (let* ((shared (let ((herdr-socket-path nil) (herdr-session 'shared))
                   (herdr-socket-file)))
         (sessions (expand-file-name "sessions" (file-name-directory shared))))
    (cons 'shared
          (when (file-directory-p sessions)
            (cl-remove-if-not
             (lambda (name)
               (file-exists-p (expand-file-name (format "%s/herdr.sock" name) sessions)))
             (directory-files sessions nil "\\`[^.]"))))))

(defun herdr-all-sessions ()
  "Return every session Emacs may talk to, configured or merely running.
`herdr-known-sessions' contributes the configured ones and
`herdr-available-sessions' those a socket on disk reveals.  Designators
naming the same session appear once."
  (let ((seen (make-hash-table :test #'equal))
        (sessions nil))
    (dolist (session (append (herdr-known-sessions) (herdr-available-sessions))
                     (nreverse sessions))
      (let ((name (or (herdr-session-name session) "")))
        (unless (gethash name seen)
          (puthash name t seen)
          (push session sessions))))))

(defun herdr-read-session (prompt &optional default)
  "Read a herdr session designator with PROMPT, offering DEFAULT."
  (let* ((known (mapcar (lambda (session)
                          (pcase session
                            ((or 'nil 'shared) "shared")
                            ('emacs "emacs")
                            (name name)))
                        (herdr-all-sessions)))
         (default (pcase default
                    ((or 'nil 'shared) "shared")
                    ('emacs "emacs")
                    (name name))))
    (herdr--session-designator
     (completing-read (format-prompt prompt default)
                      (delete-dups (append known (list "shared" "emacs")))
                      nil nil nil nil default))))

;;;###autoload
(defun herdr-assign-project-session (session &optional root no-save)
  "Route the project at ROOT to herdr SESSION.
ROOT defaults to the current project.  The assignment is written to
`herdr-state-file' unless NO-SAVE is non-nil, which a prefix argument
asks for.  Projects nothing was assigned to take their session from
`herdr-session-alist' and `herdr-session'."
  (interactive
   (let ((root (or (funcall herdr-project-root-function) default-directory)))
     (list (herdr-read-session (format "Session for %s" (abbreviate-file-name root))
                               (herdr-session-for root))
           root
           current-prefix-arg)))
  (let ((root (or root (funcall herdr-project-root-function) default-directory)))
    (herdr-assign-project root session no-save)
    (message "%s runs in the %s herdr session%s"
             (abbreviate-file-name root)
             (or (herdr-session-name session) "shared")
             (if no-save " for now" ""))
    session))

(provide 'herdr)
;;; herdr.el ends here
