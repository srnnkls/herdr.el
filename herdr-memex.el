;;; herdr-memex.el --- Search agent history from the dashboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Memex indexes the transcript of every agent session; herdr reports the
;; session each of its agents is running.  This binds the two together, so
;; a search from the dashboard is narrowed to whatever the section at point
;; stands for: one agent, every agent a herd holds, or every agent listed.
;;
;; memex.el is optional.  Where it is absent no key is bound, and the
;; commands here refuse by name rather than failing on a void function.

;;; Code:

(require 'subr-x)
(require 'transient)
(require 'magit-section)
(require 'herdr-status)

(declare-function memex-search-in-sessions "memex" (scope &optional mode initial))
(declare-function memex-herdr-session-scope "memex-herdr" (reference &optional directory))
(declare-function memex-herdr-open-session "memex-herdr" (session-id source-path &optional doc-id))
(declare-function memex-herdr-resume "memex-herdr" (record))
(declare-function herdr-herd-member-entries "herdr-herd" (name))

(defun herdr-memex-available-p ()
  "Return non-nil when memex.el can be loaded."
  (and (locate-library "memex") (locate-library "memex-herdr") t))

(defun herdr-memex-install-keys ()
  "Bind the memex keys in `herdr-status-mode-map' where memex.el exists."
  (when (herdr-memex-available-p)
    (keymap-set herdr-status-mode-map "m" #'herdr-memex-search)
    (keymap-set herdr-status-mode-map "M" #'herdr-memex-dispatch)))

(defun herdr-memex--ready ()
  "Load memex, refusing by name when it is not installed."
  (unless (and (require 'memex nil t) (require 'memex-herdr nil t))
    (user-error "Memex is not installed: no memex.el on the load path"))
  (unless (fboundp 'memex-search-in-sessions)
    (user-error "Memex is too old: it has no `memex-search-in-sessions'")))

;;;; Resolving what point stands for

(defun herdr-memex--agents-at-point ()
  "Return the agent entries the dashboard section at point stands for.
An agent row is itself; a herd is its live members; anywhere else in the
dashboard is every agent currently listed.  Outside the dashboard there
is nothing to narrow by and the answer is nil."
  (when-let* (((derived-mode-p 'herdr-status-mode))
              (section (magit-current-section)))
    (pcase (oref section type)
      ('herdr-status-agent (list (oref section value)))
      ('herdr-status-herd (herdr-herd-member-entries (oref section value)))
      (_ (herdr-status--visible-agents)))))

(defun herdr-memex--scope (entries)
  "Return the memex session scope covering ENTRIES.
An entry herdr reports no session for, or memex has not indexed, drops out."
  (delq nil
        (mapcar (lambda (entry)
                  (when-let* ((reference (alist-get 'agent_session entry)))
                    (memex-herdr-session-scope reference (alist-get 'cwd entry))))
                entries)))

(defun herdr-memex--scope-at-point ()
  "Return the scope for the section at point, refusing an empty narrowing.
Nil means a global search and is returned only where point asked for one.
Agents whose sessions memex has all missed are an error, not a widening."
  (let ((entries (herdr-memex--agents-at-point)))
    (if (null entries)
        nil
      (or (herdr-memex--scope entries)
          (user-error "Memex has indexed no session of %s"
                      (if (cdr entries) "these agents" "this agent"))))))

;;;; Commands

;;;###autoload
(defun herdr-memex-search (&optional mode)
  "Search memex over the sessions the section at point stands for.
MODE is `lexical', `semantic' or `hybrid', read with a prefix argument."
  (interactive)
  (herdr-memex--ready)
  (memex-search-in-sessions (herdr-memex--scope-at-point) mode))

;;;###autoload
(defun herdr-memex-search-globally (&optional mode)
  "Search memex across every indexed session, ignoring point.
MODE is `lexical', `semantic' or `hybrid'."
  (interactive)
  (herdr-memex--ready)
  (memex-search-in-sessions nil mode))

(defun herdr-memex--session-at-point ()
  "Return the memex scope entry of the single agent at point."
  (herdr-memex--ready)
  (let ((entries (herdr-memex--agents-at-point)))
    (unless (and entries (null (cdr entries)))
      (user-error "Point is on no single agent"))
    (or (car (herdr-memex--scope entries))
        (user-error "Memex has indexed no session of this agent"))))

;;;###autoload
(defun herdr-memex-transcript ()
  "Show memex's transcript of the session the agent at point is running."
  (interactive)
  (let ((scope (herdr-memex--session-at-point)))
    (memex-herdr-open-session (plist-get scope :session-id)
                              (plist-get scope :source-path))))

;;;###autoload
(defun herdr-memex-resume ()
  "Resume the session the agent at point is running in a herdr tab."
  (interactive)
  (let ((scope (herdr-memex--session-at-point)))
    (memex-herdr-resume
     `((session_id . ,(plist-get scope :session-id))
       (source_path . ,(plist-get scope :source-path))
       (source . ,(plist-get scope :source))))))

(defun herdr-memex--scope-description ()
  "Return what a search from point would be narrowed to."
  (let ((entries (herdr-memex--agents-at-point)))
    (cond
     ((null entries) "search everything")
     ((null (cdr entries))
      (format "search %s" (herdr--entry-label (car entries))))
     (t (format "search %d listed agents" (length entries))))))

;;;###autoload
(transient-define-prefix herdr-memex-dispatch ()
  "Search and read the history of the agents herdr runs."
  [["Search"
    ("m" herdr-memex-search :description herdr-memex--scope-description)
    ("g" "search everything" herdr-memex-search-globally)]
   ["Mode"
    ("l" "lexical"
     (lambda () (interactive) (herdr-memex-search 'lexical)))
    ("s" "semantic"
     (lambda () (interactive) (herdr-memex-search 'semantic)))
    ("y" "hybrid"
     (lambda () (interactive) (herdr-memex-search 'hybrid)))]
   ["This agent"
    ("t" "transcript" herdr-memex-transcript)
    ("r" "resume" herdr-memex-resume)]])

(provide 'herdr-memex)
;;; herdr-memex.el ends here
