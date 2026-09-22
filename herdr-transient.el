;;; herdr-transient.el --- Herdr workflow transient -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; One transient for Herdr sessions, agents, and attachments.

;;; Code:

(require 'subr-x)
(require 'transient)
(require 'herdr-agent)
(require 'herdr-status)

(defun herdr-transient--harness ()
  "Read a registered agent harness."
  (completing-read "Harness: " (mapcar #'car herdr-agent-harnesses) nil t))

(defun herdr-transient--name ()
  "Read an agent name."
  (read-string "Agent name: "))

(defun herdr-transient--start (kind name)
  "Start KIND named NAME."
  (interactive (list (herdr-transient--harness) (herdr-transient--name)))
  (herdr-agent-start kind name))

(defun herdr-transient--continue (kind name)
  "Continue KIND named NAME."
  (interactive (list (herdr-transient--harness) (herdr-transient--name)))
  (herdr-agent-continue kind name))

(defun herdr-transient--resume (kind name reference)
  "Resume KIND named NAME from REFERENCE."
  (interactive (list (herdr-transient--harness)
                     (herdr-transient--name)
                     (read-string "Session reference: ")))
  (herdr-agent-resume kind name reference))

(defun herdr-transient--target ()
  "Return the agent at point in the dashboard, or read one."
  (or (herdr-status-target-at-point)
      (let ((entry (herdr-read-agent "Agent target: ")))
        (cons (alist-get 'server_key entry) (alist-get 'terminal_id entry)))))

(defun herdr-transient--switch (target)
  "Switch to TARGET."
  (interactive (list (herdr-transient--target)))
  (herdr-agent-switch target))

(defun herdr-transient--prompt (target text)
  "Send TEXT to TARGET."
  (interactive (list (herdr-transient--target) (read-string "Prompt: ")))
  (herdr-agent-prompt target text))

(defun herdr-transient--rename (target name)
  "Rename TARGET to NAME."
  (interactive (list (herdr-transient--target) (read-string "Agent name: ")))
  (herdr-agent-rename target name))

(defun herdr-transient--escape (target)
  "Send escape to TARGET."
  (interactive (list (herdr-transient--target)))
  (herdr-agent-escape target))

(defun herdr-transient--newline (target)
  "Send return to TARGET."
  (interactive (list (herdr-transient--target)))
  (herdr-agent-newline target))

(defun herdr-transient--stop (target)
  "Stop TARGET."
  (interactive (list (herdr-transient--target)))
  (herdr-agent-stop target))

(defun herdr-transient--stop-all ()
  "Stop all agents."
  (interactive)
  (herdr-agent-stop-all))

(defun herdr-transient--format-status (status)
  "Format agent STATUS for display."
  (string-join
   (list (or (alist-get 'agent status) "unknown")
         (format "Herdr: %s"
                 (or (alist-get 'herdr_status status) "connected"))
         (format "Agent: %s"
                 (or (alist-get 'agent_status status) "unknown")))
   " | "))

(defun herdr-transient--status (target)
  "Show TARGET's status."
  (interactive (list (herdr-transient--target)))
  (message "%s" (herdr-transient--format-status (herdr-agent-status target))))

(defun herdr-transient--dashboard-p ()
  "Return non-nil in a dashboard buffer."
  (derived-mode-p 'herdr-status-mode))

;;;###autoload
(transient-define-prefix herdr-transient ()
  "Manage Herdr workflows.
An action the dashboard also offers is on the key the dashboard binds it
to, so the two menus can be read as one."
  [["Launch"
    ("N" "new" herdr-transient--start)
    ("c" "continue" herdr-transient--continue)
    ("r" "resume" herdr-transient--resume)]
   ["Agent"
    ("P" "prompt" herdr-transient--prompt)
    ("m" "message" herdr-message-send)
    ("M" "message…" herdr-message-send-project-session)
    ("b" "message primary" herdr-message-send-primary-session)
    ("=" "associate" herdr-associate-agent)
    ("R" "rename" herdr-transient--rename)
    ("j" "switch" herdr-transient--switch)
    ("e" "escape" herdr-transient--escape)
    ("RET" "return" herdr-transient--newline)
    ("x" "stop" herdr-transient--stop)
    ("X" "stop all" herdr-transient--stop-all)]
   ["Attach"
    ("a" "agent" herdr-attach-agent)
    ("p" "pane" herdr-attach-pane)
    ("A" "session" herdr-attach-session)
    ("J" "jump" herdr-jump)
    ("o" "route project" herdr-assign-project-session)]
   ["Find"
    ("i" "dashboard" herdr-status)
    ("I" "one line" herdr-transient--status)
    ("t" herdr-status-toggle-details
     :description herdr-status--details-description
     :if herdr-transient--dashboard-p)]])

(provide 'herdr-transient)
;;; herdr-transient.el ends here
