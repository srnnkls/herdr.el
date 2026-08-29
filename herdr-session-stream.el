;;; herdr-session-stream.el --- Attach a pane at this client's own size -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (herdr "0.1.0"))
;; Keywords: terminals, tools, processes
;; URL: https://github.com/srnnkls/herdr.el

;;; Commentary:

;;; Code:

(require 'seq)
(require 'subr-x)

(declare-function herdr-panes "herdr" ())
(declare-function herdr-api-pane-read "herdr-api"
                  (pane-id source &rest keys))

(defgroup herdr-session-stream nil
  "Attaching a herdr pane at this client's own size."
  :group 'herdr)

(defconst herdr-session-stream-frame "terminal.frame"
  "The `type' of messages carrying terminal output.")

(defun herdr-session-stream--parse (chunk)
  "Return (FRAMES . REMAINDER) parsed from CHUNK.
Each frame retains its metadata and carries decoded ANSI in `bytes'."
  (let ((start 0)
        (frames nil)
        at)
    (while (setq at (string-search "\n" chunk start))
      (when (> at start)
        (let* ((line (substring chunk start at))
               (json-start (string-search "{" line))
               (frame (and json-start
                           (ignore-errors
                             (json-parse-string
                              (substring line json-start)
                              :object-type 'alist
                              :null-object nil
                              :false-object nil)))))
          (when (and frame
                     (equal (alist-get 'type frame)
                            herdr-session-stream-frame)
                     (stringp (alist-get 'bytes frame)))
            (setf (alist-get 'bytes frame)
                  (base64-decode-string (alist-get 'bytes frame)))
            (push frame frames))))
      (setq start (1+ at)))
    (cons (nreverse frames) (substring chunk start))))

(defun herdr-session-stream--frames (chunk)
  "Return the ANSI in complete frames from CHUNK and its remainder."
  (pcase-let ((`(,frames . ,remainder)
               (herdr-session-stream--parse chunk)))
    (cons (mapconcat (lambda (frame) (alist-get 'bytes frame)) frames "")
          remainder)))

(defun herdr-session-stream-filter (receiver)
  "Return a process filter passing decoded terminal frames to RECEIVER.
RECEIVER is called with PROCESS, ANSI, FULL, WIDTH and HEIGHT."
  (lambda (process chunk)
    (pcase-let ((`(,frames . ,remainder)
                 (herdr-session-stream--parse
                  (concat (process-get process 'herdr-session-stream-remainder)
                          chunk))))
      (process-put process 'herdr-session-stream-remainder remainder)
      (dolist (frame frames)
        (funcall receiver process
                 (alist-get 'bytes frame)
                 (alist-get 'full frame)
                 (alist-get 'width frame)
                 (alist-get 'height frame))))))

(defun herdr-session-stream-command (terminal-id takeover cols rows)
  "Return the Herdr command streaming TERMINAL-ID at COLS by ROWS.
TAKEOVER selects a writable controller instead of an observer."
  (append (list "terminal" "session" (if takeover "control" "observe")
                terminal-id
                "--cols" (number-to-string cols)
                "--rows" (number-to-string rows))
          (when takeover '("--takeover"))))

(defun herdr-session-stream-history (terminal-id lines)
  "Return at most LINES of retained scrollback for TERMINAL-ID.
Nil asks for as much as Herdr can return."
  (when (or (null lines) (> lines 0))
    (when-let* ((pane (seq-find (lambda (pane)
                                  (equal (alist-get 'terminal_id pane)
                                         terminal-id))
                                (herdr-panes)))
                (pane-id (alist-get 'pane_id pane))
                (retained (alist-get 'max_offset_from_bottom
                                     (alist-get 'scroll pane)))
                ((and (numberp retained) (> retained 0))))
      (let ((text (alist-get 'text
                             (alist-get 'read
                                        (herdr-api-pane-read
                                         pane-id "recent"
                                         :format "ansi"
                                         :lines (if lines
                                                    (min lines retained)
                                                  retained))))))
        (and text (not (string-empty-p text))
             (if (string-suffix-p "\n" text) text (concat text "\n")))))))

(defun herdr-session-stream--send-command (process command)
  "Send COMMAND as one JSON line to PROCESS."
  (when (process-live-p process)
    (process-send-string process (concat (json-serialize command) "\n"))))

(defun herdr-session-stream-input (process data)
  "Send DATA to PROCESS as a `terminal.input' command."
  (herdr-session-stream--send-command
   process
   `((type . "terminal.input")
     (bytes . ,(base64-encode-string
                (if (multibyte-string-p data)
                    (encode-coding-string data 'utf-8 t)
                  data)
                t)))))

(defun herdr-session-stream-resize (process cols rows)
  "Report COLS by ROWS to the controller PROCESS."
  (herdr-session-stream--send-command
   process `((type . "terminal.resize") (cols . ,cols) (rows . ,rows))))

(defun herdr-session-stream-release (process)
  "Release PROCESS's terminal controller ownership."
  (herdr-session-stream--send-command process '((type . "terminal.release"))))

(defun herdr-session-stream--process-send-string (original process data)
  "Use ORIGINAL unless PROCESS belongs to a Herdr terminal buffer.
Terminal DATA goes to that buffer's current controller."
  (if-let* ((buffer (and (processp process)
                         (process-get process 'herdr-session-stream-buffer)))
            ((buffer-live-p buffer)))
      (let* ((active (buffer-local-value 'herdr--attach-sidecar buffer))
             (candidate (buffer-local-value 'herdr--attach-candidate buffer))
             (controller
              (cond
               ((and (eq (buffer-local-value 'herdr--attach-control-state buffer)
                         'control)
                     (process-live-p active))
                active)
               ((and (process-live-p candidate)
                     (eq (process-get candidate 'herdr-session-stream-mode)
                         'control))
                candidate))))
        (when controller
          (herdr-session-stream-input controller data)))
    (funcall original process data)))

(advice-add 'process-send-string :around
            #'herdr-session-stream--process-send-string)

(provide 'herdr-session-stream)
;;; herdr-session-stream.el ends here
