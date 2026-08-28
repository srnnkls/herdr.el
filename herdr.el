;;; herdr.el --- Control herdr terminal workspaces from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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
;; Every API method has a wrapper in herdr-api.el; herdr-claude-code-ide.el
;; bridges herdr and claude-code-ide sessions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'timer)
(require 'herdr-core)
(require 'herdr-api)

(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel--spawn-pty "ghostel"
                  (program program-args extra-env &optional remote-p))
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile switches))
(declare-function vterm "vterm" (&optional buffer-name))
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
  "Whether an attached terminal accepts input while its window has focus.
Ghostel swaps its Herdr child from observation to control when selected,
and back on focus loss; that hands the shared PTY geometry to whichever
Herdr client is active without replacing the Emacs buffer.  Other
terminal backends retain Herdr\='s direct-attach takeover semantics."
  :type 'boolean
  :group 'herdr)

(defcustom herdr-buffer-name-function #'herdr-default-buffer-name
  "Function mapping an attached terminal's label to an Emacs buffer name."
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
Other packages place their own side windows on low slots -
claude-code-ide reserves blocks of 16 per project - and two buffers
sharing a slot evict each other."
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

(defun herdr-workspace-id (label)
  "Return the id of the herdr workspace labelled LABEL, or nil."
  (when label
    (alist-get 'workspace_id
               (cl-find-if (lambda (workspace)
                             (equal (alist-get 'label workspace) label))
                           (herdr-workspaces)))))

(cl-defun herdr-open-tab (&key cwd label workspace env focus)
  "Open a tab labelled LABEL in the herdr workspace labelled WORKSPACE.
Creates that workspace when it does not exist yet, and labels the tab
it comes with rather than leaving an empty one behind.  Without a
WORKSPACE the tab goes to the focused workspace, or to a new one when
the session has none.  The reply carries `root_pane' and `tab'."
  (let ((id (herdr-workspace-id workspace)))
    (if (or id (and (not workspace) (herdr-workspaces)))
        (herdr-api-tab-create :cwd cwd :label label :env env
                              :workspace-id id :focus focus)
      (let ((created (herdr-api-workspace-create
                      :cwd cwd :label (or workspace label) :env env :focus focus)))
        (when-let* ((label label)
                    (tab (alist-get 'tab created)))
          (herdr-api-tab-rename label (alist-get 'tab_id tab)))
        created))))

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

(defcustom herdr-attach-history nil
  "Lines of a pane\='s retained scrollback replayed into a buffer on attach.
An attach starts from the current screen and nothing above it, so without
this a buffer opens holding one screenful however long the session ran.

Nil asks for as much as herdr will hand over, which is 1000 lines: its
read clamps there whatever it is asked for and takes no offset, so a
pane retaining twelve thousand still answers with the newest thousand
and there is no second request that reaches the rest.  A number caps it
below that and zero replays none; above it, nothing changes.

The buffer grows past that on its own - the stream that follows is
appended live, and how much of that survives is the emulator\='s own
scrollback, `ghostel-max-scrollback\=' or `eat-term-scrollback-size\='."
  :type '(choice (const :tag "As much as herdr will hand over" nil) natnum)
  :group 'herdr)

(declare-function herdr-session-stream-wrap "herdr-session-stream" (process))
(declare-function herdr-session-stream-history "herdr-session-stream"
                  (terminal-id lines))
(declare-function herdr-session-stream-command "herdr-session-stream"
                  (terminal-id takeover cols rows))
(declare-function herdr-session-stream-release "herdr-session-stream" (process))
(declare-function herdr-session-stream-resize "herdr-session-stream"
                  (process cols rows))

(defvar ghostel-use-native-pty)
(defvar ghostel--process)
(defvar herdr-session-stream--pending)
(defvar herdr-terminal-session)

(defvar-local herdr--attach-follow-focus nil
  "Whether this relay claims control only while its window has focus.")

(defvar-local herdr--attach-control-state nil
  "Last focus state sent to this buffer's relay.")

(defvar-local herdr--attach-stream nil
  "Whether this buffer speaks Herdr\='s framed terminal session protocol.")

(defvar-local herdr--attach-size nil
  "Last window size reported by this attached terminal.")

(defvar-local herdr--attach-terminal-id nil
  "Terminal whose session stream this buffer shows.")

(defvar herdr--attach-focus-timer nil
  "Timer reconciling attached terminals after focus settles.")

(defun herdr--attach-viewport (&optional target)
  "Return TARGET\='s size, using the selected window when it has none.
TARGET may be a window or a buffer."
  (let ((window (cond ((windowp target) target)
                      ((bufferp target) (get-buffer-window target t))
                      (t nil))))
    (setq window (or window (selected-window)))
    (cons (max 1 (window-max-chars-per-line window))
          (max 1 (with-selected-window window
                   (floor (window-screen-lines)))))))

(defun herdr--stream-command (terminal-id mode &optional buffer)
  "Return the Herdr command streaming TERMINAL-ID in MODE for BUFFER."
  (require 'herdr-session-stream)
  (pcase-let ((`(,cols . ,rows) (herdr--attach-viewport buffer)))
    `(,herdr-executable ,@(herdr-global-args)
                        ,@(herdr-session-stream-command
                           terminal-id (eq mode 'control) cols rows))))

(defun herdr-attach-command (terminal-id &optional takeover)
  "Return the command list attaching to TERMINAL-ID.
Ghostel starts a session observer whose process can be replaced without
rebuilding its terminal core.  TAKEOVER then follows focus by swapping
that child between observation and control.  Other backends use Herdr\='s
direct attach, where TAKEOVER keeps its native permanent meaning."
  (if (eq (herdr--backend) 'ghostel)
      (herdr--stream-command terminal-id 'observe)
    `(,herdr-executable ,@(herdr-global-args)
                        "terminal" "attach" ,terminal-id
                        ,@(when takeover '("--takeover")))))

(defun herdr--prepare-stream-process (process mode)
  "Mark PROCESS as a MODE session stream and unwrap its output."
  (process-put process 'herdr-session-stream t)
  (process-put process 'herdr-session-stream-mode mode)
  (setq herdr-session-stream--pending nil)
  (herdr-session-stream-wrap process)
  process)

(defun herdr--replace-stream-process (buffer mode)
  "Replace BUFFER\='s Herdr child with MODE without rebuilding its terminal."
  (with-current-buffer buffer
    (when-let* ((old (get-buffer-process buffer)))
      (when (process-live-p old)
        (when (eq (process-get old 'herdr-session-stream-mode) 'control)
          (ignore-errors (herdr-session-stream-release old)))
        (set-process-sentinel old #'ignore)
        (delete-process old)))
    (setq ghostel--process nil)
    (let* ((herdr-session herdr-terminal-session)
           (command (herdr--stream-command herdr--attach-terminal-id mode buffer))
           (process-environment (herdr-process-environment))
           (ghostel-use-native-pty nil)
           (process (ghostel--spawn-pty (car command) (cdr command) nil)))
      (herdr--prepare-stream-process process mode)
      (setq herdr--attach-control-state mode
            herdr--attach-size (herdr--attach-viewport buffer))
      process)))

(defun herdr--set-attach-mode (buffer mode)
  "Set BUFFER\='s session stream to MODE while preserving its terminal core."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'herdr--attach-stream buffer)
             (not (eq mode
                      (buffer-local-value 'herdr--attach-control-state buffer))))
    (herdr--replace-stream-process buffer mode)))

(defun herdr--sync-attach-control (buffer)
  "Make BUFFER\='s controller follow its selected window\='s frame focus."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'herdr--attach-follow-focus buffer))
    (let* ((window (get-buffer-window buffer t))
           (control (and window
                         (eq window
                             (frame-selected-window (window-frame window)))
                         (eq t (frame-focus-state (window-frame window)))))
           (state (if control 'control 'observe)))
      (unless (eq state
                  (buffer-local-value 'herdr--attach-control-state buffer))
        (herdr--set-attach-mode buffer state)))))

(defun herdr--sync-current-attach-control ()
  "Claim control before a command reaches the current terminal."
  (herdr--sync-attach-control (current-buffer)))

(defun herdr--sync-attach-controls ()
  "Reconcile every focus-following attached terminal."
  (setq herdr--attach-focus-timer nil)
  (dolist (buffer (buffer-list))
    (herdr--sync-attach-control buffer)))

(defun herdr--schedule-attach-control-sync (&rest _)
  "Reconcile attached terminals after asynchronous focus events settle."
  (unless herdr--attach-focus-timer
    (setq herdr--attach-focus-timer
          (run-at-time 0.01 nil #'herdr--sync-attach-controls))))

(defun herdr--resize-attach-stream (window)
  "Give WINDOW\='s stream its new viewport without rebuilding its buffer."
  (when (window-live-p window)
    (let ((buffer (window-buffer window)))
      (with-current-buffer buffer
        (when herdr--attach-stream
          (let ((wanted (herdr--attach-viewport window)))
            (unless (equal wanted herdr--attach-size)
              (setq herdr--attach-size wanted)
              (pcase-let ((`(,cols . ,rows) wanted))
                (if (eq herdr--attach-control-state 'control)
                    (when-let* ((process (get-buffer-process buffer))
                                ((process-live-p process)))
                      (herdr-session-stream-resize process cols rows))
                  (herdr--replace-stream-process buffer 'observe))))))))))

(add-function :after after-focus-change-function
              #'herdr--schedule-attach-control-sync)
(add-hook 'window-selection-change-functions
          #'herdr--schedule-attach-control-sync)

(defun herdr--terminal-exec (buffer program args)
  "Run PROGRAM with ARGS inside BUFFER and return the buffer used."
  (let ((process-environment (herdr-process-environment)))
    (herdr--terminal-exec-1 buffer program args)))

(defun herdr--terminal-exec-stream (buffer program args)
  "Run PROGRAM with ARGS in BUFFER where Emacs can replace its pty child."
  (let ((ghostel-use-native-pty nil))
    (herdr--terminal-exec buffer program args)))

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

(defun herdr-default-buffer-name (label)
  "Return the Emacs buffer name for an attached terminal named LABEL."
  (format "*herdr: %s*" label))

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
            herdr-terminal-session (or session herdr-session)))
    (run-hook-with-args 'herdr-buffer-functions buffer)
    buffer))

(defun herdr-terminal-buffer (terminal-id)
  "Return the live buffer showing TERMINAL-ID, if there is one."
  (when terminal-id
    (cl-find-if (lambda (buffer)
                  (and (equal (buffer-local-value 'herdr-terminal-id buffer) terminal-id)
                       (get-buffer-process buffer)))
                (buffer-list))))

(defun herdr--free-buffer-name (label terminal-id)
  "Return a buffer name for LABEL that no other terminal answers to.
Tab labels repeat across herdr workspaces, so a taken name gets a
counter.  Signals when TERMINAL-ID is the one already there."
  (let ((name (funcall herdr-buffer-name-function label))
        (counter 1))
    (while (when-let* ((buffer (get-buffer name))
                       ((get-buffer-process buffer)))
             (when (equal (buffer-local-value 'herdr-terminal-id buffer) terminal-id)
               (user-error "Buffer %s is already attached" name))
             (setq name (funcall herdr-buffer-name-function
                                 (format "%s<%d>" label (cl-incf counter))))))
    name))

(cl-defun herdr-attach-terminal (terminal-id &key label directory takeover display)
  "Attach herdr terminal TERMINAL-ID to an Emacs terminal buffer.
LABEL names the buffer, DIRECTORY sets its `default-directory', and
DISPLAY shows it.  Under ghostel, TAKEOVER controls only while its
selected window has frame focus; losing focus returns geometry to
Herdr's foreground client while this buffer keeps observing."
  (let ((name (herdr--free-buffer-name (or label terminal-id) terminal-id)))
    (when-let* ((existing (get-buffer name)))
      (kill-buffer existing))
    (let* ((buffer (get-buffer-create name))
           (stream (eq (herdr--backend) 'ghostel))
           (command (herdr-attach-command terminal-id takeover)))
      (with-current-buffer buffer
        (when directory (setq default-directory (file-name-as-directory directory))))
      (setq buffer (funcall (if stream
                                #'herdr--terminal-exec-stream
                              #'herdr--terminal-exec)
                            buffer (car command) (cdr command)))
      (herdr-claim-buffer buffer terminal-id)
      (when stream
        (with-current-buffer buffer
          (setq herdr--attach-stream t
                herdr--attach-follow-focus takeover
                herdr--attach-control-state 'observe
                herdr--attach-terminal-id terminal-id
                herdr--attach-size (herdr--attach-viewport buffer))
          (add-hook 'window-size-change-functions
                    #'herdr--resize-attach-stream nil t)
          (when takeover
            (add-hook 'pre-command-hook
                      #'herdr--sync-current-attach-control nil t)))
        (when-let* ((process (get-buffer-process buffer)))
          (ignore-errors
            (when-let* ((history (herdr-session-stream-history
                                  terminal-id herdr-attach-history)))
              (funcall (process-filter process) process history)))
          (with-current-buffer buffer
            (herdr--prepare-stream-process process 'observe))))
      (when display (herdr-display-buffer buffer))
      (when takeover (herdr--sync-attach-control buffer))
      buffer)))

;;;; Completion

(defun herdr--entry-label (entry)
  "Return a short label for pane or agent ENTRY."
  (or (alist-get 'name entry)
      (alist-get 'label entry)
      (alist-get 'terminal_title_stripped entry)
      (alist-get 'agent entry)
      (alist-get 'pane_id entry)))

(defvar herdr-entry-annotation-functions nil
  "Functions adding annotation fields to a session entry.
Each is called with the entry and returns a string to append to the
completion annotation, or nil.")

(defun herdr--entry-buffer (entry)
  "Return the live buffer showing ENTRY, if any."
  (let ((buffer (alist-get 'buffer entry)))
    (if (buffer-live-p buffer)
        buffer
      (herdr-terminal-buffer (alist-get 'terminal_id entry)))))

(defun herdr--entry-key (entry)
  "Return the identity ENTRY is deduplicated by."
  (or (alist-get 'terminal_id entry)
      (alist-get 'pane_id entry)
      (herdr--entry-label entry)))

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
                           (when-let* ((cwd (alist-get 'cwd entry)))
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
`buffer' points at the Emacs buffer showing them, when one exists.
herdr-claude-code-ide.el adds the claude-code-ide sessions here.")

(defun herdr-agent-sessions ()
  "Return the agents of the herdr session in scope as session entries."
  (mapcar (lambda (agent)
            (append `((kind . "herdr") (session . ,herdr-session)) agent))
          (herdr-agents)))

(defun herdr--session-entries ()
  "Return the entries of every session in `herdr-known-sessions'.
Sessions whose server does not answer are skipped rather than started."
  (apply #'append
         (mapcar (lambda (session)
                   (herdr-with-session session
                     (when (herdr-available-p)
                       (apply #'append (mapcar #'funcall herdr-session-functions)))))
                 (herdr-known-sessions))))

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

(defun herdr-visit (entry)
  "Show ENTRY and return its buffer.
An entry that nothing shows yet is attached first, on the server it
came from."
  (if-let* ((buffer (herdr--entry-buffer entry)))
      (progn (pop-to-buffer buffer) buffer)
    (herdr-with-session (alist-get 'session entry)
      (herdr-attach-entry entry))))

;;;; Commands

(defvar herdr-attach-functions nil
  "Functions that may claim an entry before it is attached as a terminal.
Each is called with the pane or agent alist and returns the buffer it
opened, or nil to let the next one try.  The plain terminal attach runs
only when all of them decline.  herdr-claude-code-ide.el uses this to
open claude agents as claude-code-ide sessions.")

(defun herdr--entry-session-name (entry)
  "Return the name ENTRY is attached under: the checkout it works in.
Sessions sharing a checkout share the name, and the counter in
`herdr--free-buffer-name' tells their buffers apart."
  (or (when-let* ((cwd (alist-get 'cwd entry)))
        (file-name-nondirectory (directory-file-name (expand-file-name cwd))))
      (herdr--entry-label entry)))

(defun herdr-attach-entry (entry)
  "Attach pane or agent ENTRY and return the buffer showing it.
Gives `herdr-attach-functions' the first chance to claim ENTRY."
  (herdr-with-session (alist-get 'session entry)
    (or (run-hook-with-args-until-success 'herdr-attach-functions entry)
        (herdr-attach-terminal (alist-get 'terminal_id entry)
                               :label (herdr--entry-session-name entry)
                               :directory (alist-get 'cwd entry)
                               :takeover herdr-attach-takeover
                               :display t))))

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
  "Function opening the editor workspace mirroring a herdr workspace.
Called with the workspace alist and the directory its panes work in,
before `herdr-attach-session' attaches that workspace's terminals.  Nil
attaches everything wherever you are."
  :type '(choice (const :tag "Attach where you are" nil) function)
  :group 'herdr)

(defun herdr-session-layout (&optional all)
  "Return the herdr session's workspaces paired with their entries.
Agents only, unless ALL asks for every pane.  Workspaces with nothing
in them are left out."
  (let* ((tabs (mapcar (lambda (tab)
                         (cons (alist-get 'tab_id tab) (alist-get 'label tab)))
                       (herdr-tabs)))
         (panes (mapcar (lambda (pane)
                          (append `((kind . "herdr") (session . ,herdr-session))
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

;;;###autoload
(defun herdr-attach-session (&optional session all takeover)
  "Attach the agents of a herdr SESSION, mirroring how it is laid out.
Each herdr workspace opens an editor workspace of its own through
`herdr-workspace-open-function', and every agent in it becomes a buffer
there.  ALL attaches plain panes too.  Input ownership stays with
herdr's own client unless TAKEOVER says otherwise, so the attached
buffers start as a view of a session someone else is driving.
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
      (dolist (group (herdr-session-layout all))
        (let* ((workspace (car group))
               (entries (cdr group)))
          (when herdr-workspace-open-function
            (funcall herdr-workspace-open-function workspace
                     (alist-get 'cwd (car entries))))
          (dolist (entry entries)
            (unless (herdr-terminal-buffer (alist-get 'terminal_id entry))
              (push (herdr-attach-entry entry) buffers)))))
      (setq buffers (delq nil (nreverse buffers)))
      (message "Attached %d terminal%s from %s"
               (length buffers) (if (= (length buffers) 1) "" "s")
               (or (herdr-session-name session) "the shared session"))
      buffers)))

;;;###autoload
(defun herdr-jump (session)
  "Jump to a running SESSION, whether or not Emacs already shows it."
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

(defun herdr-read-session (prompt &optional default)
  "Read a herdr session designator with PROMPT, offering DEFAULT."
  (let* ((known (mapcar (lambda (session)
                          (pcase session
                            ((or 'nil 'shared) "shared")
                            ('emacs "emacs")
                            (name name)))
                        (append (herdr-known-sessions) (herdr-available-sessions))))
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
