;;; herdr-transient.el --- Herdr workflow transient -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; One transient for Herdr sessions, agents, attachments, and Claude editor work.

;;; Code:

(require 'subr-x)
(require 'transient)
(require 'herdr-agent)

(autoload 'herdr-claude-adopt "herdr-claude" nil t)
(autoload 'herdr-claude-connect "herdr-claude" nil t)
(autoload 'herdr-claude-at-mention "herdr-claude" nil t)
(autoload 'herdr-claude-auto-adopt-mode "herdr-claude" nil t)
(autoload 'herdr-claude-debug-open-log "herdr-claude-debug" nil t)
(autoload 'herdr-claude-debug-enable "herdr-claude-debug" nil t)
(autoload 'herdr-claude-debug-disable "herdr-claude-debug" nil t)

(defun herdr-transient--kind ()
  "Read a registered agent harness kind."
  (completing-read "Agent kind: " (mapcar #'car herdr-agent-harnesses) nil t))

(defun herdr-transient--name ()
  "Read an agent name."
  (read-string "Agent name: "))

(defun herdr-transient--start (kind name)
  "Start KIND named NAME."
  (interactive (list (herdr-transient--kind) (herdr-transient--name)))
  (herdr-agent-start kind name))

(defun herdr-transient--continue (kind name)
  "Continue KIND named NAME."
  (interactive (list (herdr-transient--kind) (herdr-transient--name)))
  (herdr-agent-continue kind name))

(defun herdr-transient--resume (kind name reference)
  "Resume KIND named NAME from REFERENCE."
  (interactive (list (herdr-transient--kind)
                     (herdr-transient--name)
                     (read-string "Session reference: ")))
  (herdr-agent-resume kind name reference))

(defun herdr-transient--target ()
  "Read a composite agent target."
  (let ((entry (herdr-read-entry "Agent target: " (herdr-sessions))))
    (cons (alist-get 'server_key entry) (alist-get 'terminal_id entry))))

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

(defun herdr-transient--customize ()
  "Customize Herdr."
  (interactive)
  (customize-group 'herdr))

(defun herdr-transient--format-status (status)
  "Format agent STATUS for display."
  (let* ((kind (alist-get 'agent status))
         (harness (herdr-agent--harness kind t))
         (integration (alist-get 'integration_status status)))
    (string-join
     (delq nil
           (list (or (plist-get harness :label) kind)
                 (format "Herdr: %s" (or (alist-get 'herdr_status status) "connected"))
                 (format "Agent: %s" (or (alist-get 'agent_status status) "unknown"))
                 (and integration
                      (format "%s: %s"
                              (or (alist-get 'integration_label status) "Integration")
                              integration))
                 (alist-get 'integration_endpoint status)))
     " | ")))

(defun herdr-transient--status (target)
  "Show TARGET's status."
  (interactive (list (herdr-transient--target)))
  (message "%s" (herdr-transient--format-status (herdr-agent-status target))))

(defun herdr-transient--claude-auto-adopt ()
  "Toggle automatic Claude adoption."
  (interactive)
  (herdr-claude-auto-adopt-mode 'toggle))

;;;###autoload
(transient-define-prefix herdr-transient-claude ()
  "Manage Claude editor integration."
  [["Lifecycle"
    ("a" "adopt" herdr-claude-adopt)
    ("c" "connect" herdr-claude-connect)
    ("m" "auto-adopt" herdr-transient--claude-auto-adopt)]
   ["Context"
    ("s" "status" herdr-transient--status)
    ("@" "at-mention" herdr-claude-at-mention)]
   ["Debug"
    ("p" "protocol log" herdr-claude-debug-open-log)
    ("d" "enable logging" herdr-claude-debug-enable)
    ("D" "disable logging" herdr-claude-debug-disable)]])

;;;###autoload
(transient-define-prefix herdr-transient ()
  "Manage Herdr workflows."
  [["Session"
    ("s" "start" herdr-transient--start)
    ("c" "continue" herdr-transient--continue)
    ("r" "resume" herdr-transient--resume)]
   ["Agent"
    ("j" "switch" herdr-transient--switch)
    ("p" "prompt" herdr-transient--prompt)
    ("n" "rename" herdr-transient--rename)
    ("e" "escape" herdr-transient--escape)
    ("RET" "return" herdr-transient--newline)
    ("k" "stop" herdr-transient--stop)
    ("K" "stop all" herdr-transient--stop-all)]
   ["Attach"
    ("a" "agent" herdr-attach-agent)
    ("P" "pane" herdr-attach-pane)
    ("A" "session" herdr-attach-session)
    ("J" "jump" herdr-jump)
    ("R" "route project" herdr-assign-project-session)]
   ["Status"
    ("i" "status" herdr-transient--status)
    ("C" "customize" herdr-transient--customize)
    ("I" "Claude" herdr-transient-claude)]])

(provide 'herdr-transient)
;;; herdr-transient.el ends here
