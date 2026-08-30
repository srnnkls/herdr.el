;;; herdr-claude-code-ide-transient.el --- Claude IDE workflow transient -*- lexical-binding: t; -*-

;;; Commentary:

;; Transient menu for Claude Code IDE status and debugging.

;;; Code:

(require 'transient)
(require 'herdr-agent)
(require 'herdr-agent-transient)
(require 'herdr-claude-code-ide-debug)

(defun herdr-claude-code-ide-transient-status ()
  "Show Claude IDE agent status."
  (interactive)
  (message "%s" (herdr-agent-transient-format-status
                 (herdr-agent-transient--status-state (herdr-agent-status nil)))))

(defun herdr-claude-code-ide-transient-protocol ()
  "Show the Claude IDE protocol log."
  (interactive)
  (pop-to-buffer (herdr-claude-code-ide-debug-log-buffer)))

(defun herdr-claude-code-ide-transient-debug ()
  "Enable Claude IDE protocol logging."
  (interactive)
  (herdr-claude-code-ide-debug-enable))

(defun herdr-claude-code-ide-transient-debug-disable ()
  "Disable Claude IDE protocol logging."
  (interactive)
  (herdr-claude-code-ide-debug-disable))

;;;###autoload
(transient-define-prefix herdr-claude-code-ide-transient ()
  "Manage Claude IDE debugging."
  [["Claude IDE"
    ("s" "status" herdr-claude-code-ide-transient-status)
    ("p" "protocol log" herdr-claude-code-ide-transient-protocol)
    ("d" "enable logging" herdr-claude-code-ide-transient-debug)
    ("D" "disable logging" herdr-claude-code-ide-transient-debug-disable)]])

(provide 'herdr-claude-code-ide-transient)
;;; herdr-claude-code-ide-transient.el ends here
