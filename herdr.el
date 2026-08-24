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
(require 'herdr-core)
(require 'herdr-api)

(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
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
  "Whether attaching claims input ownership of the terminal.
Only one writable direct-attach client owns input per terminal, so
attaching without takeover leaves the Emacs buffer read-only while
another client holds it."
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
  `(,herdr-executable "terminal" "attach" ,terminal-id
                      ,@(when takeover '("--takeover"))))

(defun herdr--terminal-exec (buffer program args)
  "Run PROGRAM with ARGS inside BUFFER and return the buffer used."
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

(cl-defun herdr-attach-terminal (terminal-id &key label directory takeover display)
  "Attach herdr terminal TERMINAL-ID to an Emacs terminal buffer.
LABEL names the buffer, DIRECTORY sets its `default-directory',
TAKEOVER claims input ownership, and DISPLAY shows the buffer when
non-nil.  Returns the buffer."
  (let* ((name (funcall herdr-buffer-name-function (or label terminal-id)))
         (existing (get-buffer name)))
    (when (and existing (get-buffer-process existing))
      (user-error "Buffer %s is already attached" name))
    (when existing (kill-buffer existing))
    (let ((buffer (get-buffer-create name))
          (command (herdr-attach-command terminal-id takeover)))
      (with-current-buffer buffer
        (when directory (setq default-directory (file-name-as-directory directory))))
      (setq buffer (herdr--terminal-exec buffer (car command) (cdr command)))
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

(defun herdr--entry-annotation (entry)
  "Return the completion annotation for pane or agent ENTRY."
  (string-join
   (delq nil (list (alist-get 'agent entry)
                   (alist-get 'agent_status entry)
                   (when-let* ((cwd (alist-get 'cwd entry)))
                     (abbreviate-file-name cwd))))
   "  "))

(cl-defun herdr-read-entry (prompt entries &key require-agent)
  "Read one of ENTRIES with PROMPT and return its alist.
REQUIRE-AGENT keeps only entries running that agent kind."
  (let* ((entries (if require-agent
                      (cl-remove-if-not
                       (lambda (entry) (equal (alist-get 'agent entry) require-agent))
                       entries)
                    entries))
         (candidates
          (mapcar (lambda (entry)
                    (cons (format "%s  %s" (alist-get 'pane_id entry)
                                  (herdr--entry-label entry))
                          entry))
                  entries))
         (annotation (lambda (candidate)
                       (when-let* ((entry (cdr (assoc candidate candidates))))
                         (concat "   " (herdr--entry-annotation entry))))))
    (unless candidates
      (user-error "No matching herdr %s" (or require-agent "panes")))
    (let ((choice (completing-read
                   prompt
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         `(metadata (annotation-function . ,annotation)
                                    (category . herdr-entry))
                       (complete-with-action action candidates string predicate)))
                   nil t)))
      (cdr (assoc choice candidates)))))

;;;; Commands

;;;###autoload
(defun herdr-attach-agent (agent)
  "Attach the terminal of herdr AGENT to an Emacs buffer."
  (interactive (list (herdr-read-entry "Attach herdr agent: " (herdr-agents))))
  (herdr-attach-terminal (alist-get 'terminal_id agent)
                         :label (herdr--entry-label agent)
                         :directory (alist-get 'cwd agent)
                         :takeover herdr-attach-takeover
                         :display t))

;;;###autoload
(defun herdr-attach-pane (pane)
  "Attach the terminal of herdr PANE to an Emacs buffer."
  (interactive (list (herdr-read-entry "Attach herdr pane: " (herdr-panes))))
  (herdr-attach-terminal (alist-get 'terminal_id pane)
                         :label (herdr--entry-label pane)
                         :directory (alist-get 'cwd pane)
                         :takeover herdr-attach-takeover
                         :display t))

(provide 'herdr)
;;; herdr.el ends here
