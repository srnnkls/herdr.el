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
  "The `type' of the messages carrying terminal output.")

(defvar-local herdr-session-stream--pending nil
  "Bytes read from herdr that do not yet make up a whole line.")

(defun herdr-session-stream--feed (writer output)
  "Hand OUTPUT to WRITER, the function drawing into this buffer's terminal."
  (when (and writer (not (string-empty-p output)))
    (funcall writer output)))

(defun herdr-session-stream--frames (chunk)
  "Return the ANSI carried by the whole lines in CHUNK, and what is left.
Answers (OUTPUT . REMAINDER).  herdr writes one JSON object per line and
a read can land anywhere, so the tail of CHUNK is kept for the next one.

The newlines are walked rather than split on: splitting allocates every
line of the chunk and copies the list again to hold the last one back,
which measured 2.7 times the cost of scanning for them."
  (let ((start 0)
        (output nil)
        (at nil))
    (while (setq at (string-search "\n" chunk start))
      (when (> at start)
        (let* ((line (substring chunk start at))
               (json-start (string-search "{" line)))
          (when-let* ((frame (and json-start
                                  (ignore-errors
                                    (json-parse-string
                                     (substring line json-start)
                                     :object-type 'alist))))
                      ((equal (alist-get 'type frame)
                              herdr-session-stream-frame))
                      (bytes (alist-get 'bytes frame)))
            (push (base64-decode-string bytes) output))))
      (setq start (1+ at)))
    (cons (apply #'concat (nreverse output)) (substring chunk start))))

(defun herdr-session-stream--filter (writer)
  "Return a process filter drawing herdr's frames through WRITER."
  (lambda (process chunk)
    (when-let* ((buffer (process-buffer process))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (pcase-let ((`(,output . ,remainder)
                     (herdr-session-stream--frames
                      (concat herdr-session-stream--pending chunk))))
          (setq herdr-session-stream--pending remainder)
          (herdr-session-stream--feed writer output))))))

(defun herdr-session-stream-command (terminal-id takeover cols rows)
  "Return the herdr command streaming TERMINAL-ID at COLS by ROWS.
`control' is writable and only one client may hold it, so it is refused
outright while somebody else does; `observe' is read-only and never
contends.  TAKEOVER is what asks for the writable one."
  (append (list "terminal" "session" (if takeover "control" "observe") terminal-id
                "--cols" (number-to-string cols)
                "--rows" (number-to-string rows))
          (when takeover '("--takeover"))))

(defun herdr-session-stream-wrap (process)
  "Decode herdr\='s terminal frames on their way into PROCESS\='s filter.
The terminal emulator keeps the filter it installed and is handed raw
ANSI, so nothing about it has to know the stream was framed."
  (when (process-live-p process)
    (let ((inner (process-filter process)))
      (set-process-filter
       process
       (lambda (process chunk)
         (when-let* ((buffer (process-buffer process))
                     ((buffer-live-p buffer)))
           (let ((output nil))
             (with-current-buffer buffer
               (pcase-let ((`(,drawn . ,remainder)
                            (herdr-session-stream--frames
                             (concat herdr-session-stream--pending chunk))))
                 (setq herdr-session-stream--pending remainder
                       output drawn)))
             (unless (string-empty-p output)
               (funcall inner process output)))))))
    process))

(defun herdr-session-stream-history (terminal-id lines)
  "Return at most LINES of the scrollback herdr retains for TERMINAL-ID.
A LINES of nil asks for as much as herdr will hand over, which is the
1000 its read clamps to whatever it is asked for; a number caps it below
that.  The clamp is the ceiling either way, and there is no offset to
ask for what falls above it.

Nil where the pane has none, which is what a full-screen program leaves:
it redraws in place rather than scrolling, so nothing is ever retained
above the screen and `max_offset_from_bottom\=' stays at zero.

The answer is styled text and nothing else - measured over 179kB of it,
the only escape sequences present were colour - so it can be replayed
into a terminal as the history it is."
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

(defvar herdr-session-stream--writing-command nil
  "Non-nil while writing framed control input to a Herdr process.")

(defun herdr-session-stream--send-command (process command)
  "Send COMMAND as one JSON line to PROCESS without re-encoding it."
  (let ((herdr-session-stream--writing-command t))
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
  "Report to PROCESS that this client now draws COLS by ROWS."
  (herdr-session-stream--send-command
   process `((type . "terminal.resize") (cols . ,cols) (rows . ,rows))))

(defun herdr-session-stream-release (process)
  "Release PROCESS\='s terminal controller ownership."
  (herdr-session-stream--send-command process '((type . "terminal.release"))))

(defun herdr-session-stream--process-send-string (original process data)
  "Use ORIGINAL to route terminal DATA through PROCESS\='s control protocol."
  (if (and (process-get process 'herdr-session-stream)
           (not herdr-session-stream--writing-command))
      (when (eq (process-get process 'herdr-session-stream-mode) 'control)
        (herdr-session-stream-input process data))
    (funcall original process data)))

(advice-add 'process-send-string :around
            #'herdr-session-stream--process-send-string)

(provide 'herdr-session-stream)
;;; herdr-session-stream.el ends here
