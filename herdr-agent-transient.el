;;; herdr-agent-transient.el --- Agent workflow transient -*- lexical-binding: t; -*-

;;; Commentary:

;; Transient menu for common herdr agent workflow commands.

;;; Code:

(require 'transient)
(require 'herdr-agent)

(defun herdr-agent-transient--kind ()
  "Read a supported agent kind."
  (completing-read "Agent kind: " '("claude" "pi" "codex") nil t))

(defun herdr-agent-transient--name ()
  "Read an agent name."
  (read-string "Agent name: "))

(defun herdr-agent-transient-start (kind name)
  "Start KIND named NAME."
  (interactive (list (herdr-agent-transient--kind) (herdr-agent-transient--name)))
  (herdr-agent-start kind name))

(defun herdr-agent-transient-continue (kind name)
  "Continue KIND named NAME."
  (interactive (list (herdr-agent-transient--kind) (herdr-agent-transient--name)))
  (herdr-agent-continue kind name))

(defun herdr-agent-transient-resume (kind name reference)
  "Resume KIND named NAME from REFERENCE."
  (interactive (list (herdr-agent-transient--kind)
                     (herdr-agent-transient--name)
                     (read-string "Session reference: ")))
  (herdr-agent-resume kind name reference))

(defun herdr-agent-transient--target ()
  "Read an agent target."
  (let ((entry (herdr-read-entry "Agent target: " (herdr-sessions))))
    (cons (alist-get 'server_key entry) (alist-get 'terminal_id entry))))

(defun herdr-agent-transient-switch (target)
  "Switch to TARGET."
  (interactive (list (herdr-agent-transient--target)))
  (herdr-agent-switch target))

(defun herdr-agent-transient-prompt (target text)
  "Send TEXT to TARGET."
  (interactive (list (herdr-agent-transient--target)
                     (read-string "Prompt: ")))
  (herdr-agent-prompt target text))

(defun herdr-agent-transient-rename (target name)
  "Rename TARGET to NAME."
  (interactive (list (herdr-agent-transient--target)
                     (read-string "Agent name: ")))
  (herdr-agent-rename target name))

(defun herdr-agent-transient-stop (target)
  "Stop TARGET."
  (interactive (list (herdr-agent-transient--target)))
  (herdr-agent-stop target))

(defun herdr-agent-transient-stop-all ()
  "Stop all agents."
  (interactive)
  (herdr-agent-stop-all))

(defun herdr-agent-transient-escape (target)
  "Send escape to TARGET."
  (interactive (list (herdr-agent-transient--target)))
  (herdr-agent-escape target))

(defun herdr-agent-transient-newline (target)
  "Send return to TARGET."
  (interactive (list (herdr-agent-transient--target)))
  (herdr-agent-newline target))

(defun herdr-agent-transient-customize ()
  "Customize Herdr."
  (interactive)
  (customize-group 'herdr))

(defun herdr-agent-transient--status-state (status)
  "Normalize STATUS for display."
  (let* ((kind (alist-get 'agent status))
         (endpoint (alist-get 'ide_endpoint status))
         (state (list :kind kind
                      :harness (pcase kind
                                 ("claude" "Claude Code")
                                 ("pi" "Pi")
                                 ("codex" "Codex"))
                      :herdr (intern (or (alist-get 'herdr_status status) "connected"))
                      :agent (intern (or (alist-get 'agent_status status) "unknown")))))
    (when (and (equal kind "claude") endpoint)
      (setq state (append state (list :ide (intern (or (alist-get 'ide_status status) "connected"))
                                     :ide-endpoint endpoint))))
    state))

(defun herdr-agent-transient-status (target)
  "Show TARGET's status."
  (interactive (list (herdr-agent-transient--target)))
  (message "%s" (herdr-agent-transient-format-status
                 (herdr-agent-transient--status-state (herdr-agent-status target)))))

(defun herdr-agent-transient-format-status (state)
  "Format agent STATE for display."
  (string-join
   (delq nil
         (list (plist-get state :harness)
               (format "Herdr: %s" (plist-get state :herdr))
               (format "Agent: %s" (plist-get state :agent))
               (and (equal (plist-get state :kind) "claude")
                    (plist-member state :ide)
                    (format "IDE: %s" (plist-get state :ide)))
               (and (equal (plist-get state :kind) "claude")
                    (plist-get state :ide-endpoint))))
   " | "))

;;;###autoload
(transient-define-prefix herdr-agent-transient ()
  "Manage Herdr agent workflows."
  [["Session"
    ("s" "start" herdr-agent-transient-start)
    ("c" "continue" herdr-agent-transient-continue)
    ("r" "resume" herdr-agent-transient-resume)]
   ["Navigation"
    ("j" "switch" herdr-agent-transient-switch)
    ("p" "prompt" herdr-agent-transient-prompt)
    ("n" "rename" herdr-agent-transient-rename)
    ("e" "escape" herdr-agent-transient-escape)
    ("RET" "return" herdr-agent-transient-newline)
    ("k" "stop" herdr-agent-transient-stop)
    ("K" "stop all" herdr-agent-transient-stop-all)]
   ["Status"
    ("i" "status" herdr-agent-transient-status)]
   ["Configuration"
    ("C" "customize" herdr-agent-transient-customize)]])

(provide 'herdr-agent-transient)
;;; herdr-agent-transient.el ends here
