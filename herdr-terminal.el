;;; herdr-terminal.el --- Read and drive an attached terminal -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: terminals, tools, processes
;; URL: https://github.com/srnnkls/herdr.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; What can be done to a terminal buffer once it is there: where its
;; prompt is, what is on its screen, and how bytes reach it.  Ghostel,
;; vterm and eat each answer in their own way, and a buffer is asked by
;; the mode it is in rather than by the backend the package spawns with,
;; so a terminal attached by other means answers too.

;;; Code:

(declare-function ghostel-force-redraw "ext:ghostel" ())
(declare-function ghostel-send-string "ext:ghostel" (string))
(declare-function ghostel-paste-string "ext:ghostel" (string))
(defvar ghostel--cursor-char-pos)
(declare-function vterm-reset-cursor-point "ext:vterm" ())
(declare-function vterm-send-string "ext:vterm" (string &optional paste-p))
(declare-function eat-term-send-string "ext:eat" (terminal string))
(declare-function eat-term-send-string-as-yank "ext:eat" (terminal args))
(defvar eat-terminal)

(defvar herdr-terminal-focus-functions nil
  "Functions run in a terminal buffer once point sits at its prompt.
Each is called with no arguments, in the buffer.  An editor that keeps a
modal state hangs the state that types on this: which state that is is
the editor's business rather than herdr's.")

(defun herdr-terminal-goto-prompt (&optional buffer)
  "Put point in BUFFER where its terminal takes input, and return it.
A terminal's cursor is not the end of its buffer - whatever scrolled
past stays behind it - so the prompt is wherever the cursor is.  Each
backend says where that is in its own way, and one that says nothing at
all leaves point where the process left it.
`herdr-terminal-focus-functions' runs afterwards."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((and (derived-mode-p 'ghostel-mode)
           (bound-and-true-p ghostel--cursor-char-pos)
           (<= ghostel--cursor-char-pos (point-max)))
      (goto-char ghostel--cursor-char-pos))
     ((and (derived-mode-p 'vterm-mode) (fboundp 'vterm-reset-cursor-point))
      (vterm-reset-cursor-point))
     ((get-buffer-process (current-buffer))
      (goto-char (process-mark (get-buffer-process (current-buffer))))))
    (run-hooks 'herdr-terminal-focus-functions)
    (point)))

(defun herdr-terminal-screen (&optional buffer)
  "Return the screen of the terminal BUFFER shows, or nil for none.
A terminal keeps its screen as the text of its buffer, so this answers
what is on it now, where the daemon answers with a capture taken some
time ago.  A terminal no window shows is not repainted and answers
nothing rather than what was on it before."
  (with-current-buffer (or buffer (current-buffer))
    (when (get-buffer-window (current-buffer) t)
      (cond
       ((and (derived-mode-p 'ghostel-mode) (fboundp 'ghostel-force-redraw))
        (ghostel-force-redraw)
        (buffer-substring-no-properties (point-min) (point-max)))
       ((derived-mode-p 'vterm-mode 'eat-mode)
        (buffer-substring-no-properties (point-min) (point-max)))))))

(defun herdr-terminal-send (text &optional buffer)
  "Send TEXT to the terminal BUFFER shows as typed input.
Returns non-nil when a backend took it."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((and (derived-mode-p 'ghostel-mode) (fboundp 'ghostel-send-string))
      (ghostel-send-string text) t)
     ((and (derived-mode-p 'vterm-mode) (fboundp 'vterm-send-string))
      (vterm-send-string text) t)
     ((and (derived-mode-p 'eat-mode) (fboundp 'eat-term-send-string)
           (bound-and-true-p eat-terminal))
      (eat-term-send-string eat-terminal text) t))))

(defun herdr-terminal-paste (text &optional buffer)
  "Send TEXT to the terminal BUFFER shows as a bracketed paste.
Returns non-nil when a backend took it."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((and (derived-mode-p 'ghostel-mode) (fboundp 'ghostel-paste-string))
      (ghostel-paste-string text) t)
     ((and (derived-mode-p 'vterm-mode) (fboundp 'vterm-send-string))
      (vterm-send-string text t) t)
     ((and (derived-mode-p 'eat-mode) (fboundp 'eat-term-send-string-as-yank)
           (bound-and-true-p eat-terminal))
      (eat-term-send-string-as-yank eat-terminal text) t))))

(provide 'herdr-terminal)
;;; herdr-terminal.el ends here
