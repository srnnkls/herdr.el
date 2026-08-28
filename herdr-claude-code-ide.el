;;; herdr-claude-code-ide.el --- Claude IDE adapter for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Claude IDE policy over generic herdr agent sessions.

;;; Code:

(require 'herdr)
(require 'herdr-agent)
(require 'herdr-claude-code-ide-mcp)
(require 'cl-lib)

(defgroup herdr-claude-code-ide nil
  "Connect Claude Code sessions to Emacs through herdr."
  :group 'herdr
  :prefix "herdr-claude-code-ide-")

(defcustom herdr-claude-code-ide-auto-adopt-predicate
  #'herdr-claude-code-ide-known-project-p
  "Predicate deciding whether automatic adoption accepts an agent."
  :type 'function)

(defcustom herdr-claude-code-ide-adopt-on-attach t
  "Whether attaching a Claude agent adopts it for the Claude IDE."
  :type 'boolean)

(defcustom herdr-claude-code-ide-connect-on-adopt 'idle
  "When an adopted Claude is asked to connect to this Emacs."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "While the agent is idle" idle)
                 (const :tag "Always" t)))

(defvar herdr-claude-code-ide--auto-adopt-process nil)

(defun herdr-claude-code-ide--connect-p (agent)
  "Return non-nil when AGENT should connect to this Emacs."
  (and herdr-attach-takeover
       (pcase herdr-claude-code-ide-connect-on-adopt
         ('nil nil)
         ('idle (equal (alist-get 'agent_status agent) "idle"))
         (_ t))))

;;;###autoload
(defun herdr-claude-code-ide-adopt (agent)
  "Adopt AGENT through the generic lifecycle root."
  (interactive (list (herdr-read-entry "Adopt herdr Claude: " (herdr-agents)
                                       :require-agent "claude")))
  (let* ((server-key (or (alist-get 'server_key agent) (herdr-server-key)))
         (session
          (let ((herdr-agent-kind-adapters
                 (cl-remove-if (lambda (adapter) (equal (car adapter) "claude"))
                               herdr-agent-kind-adapters)))
            (herdr-agent-adopt agent :server-key server-key))))
    (herdr-claude-code-ide-mcp-adopt session)
    (when (herdr-claude-code-ide--connect-p agent)
      (herdr-agent--with-server server-key
        (herdr-api-pane-send-text (alist-get 'pane_id agent) "/ide\n")))
    (herdr-agent-session-buffer session)))

(defun herdr-claude-code-ide--attach-entry (entry)
  "Adopt ENTRY when it is an attachable Claude agent."
  (when (and (equal (alist-get 'agent entry) "claude")
             (alist-get 'cwd entry)
             (alist-get 'terminal_id entry))
    (if herdr-claude-code-ide-adopt-on-attach
        (herdr-claude-code-ide-adopt entry)
      (let ((herdr-agent-kind-adapters
             (cl-remove-if (lambda (adapter) (equal (car adapter) "claude"))
                           herdr-agent-kind-adapters)))
        (herdr-agent-session-buffer
         (herdr-agent-adopt entry :server-key (or (alist-get 'server_key entry)
                                                   (herdr-server-key))))))))

(defun herdr-claude-code-ide-connect-ide (pane-id)
  "Ask the Claude running in PANE-ID to connect to this Emacs."
  (interactive (list (alist-get 'pane_id
                                (herdr-read-entry "Connect herdr Claude: "
                                                  (herdr-agents)
                                                  :require-agent "claude"))))
  (herdr-api-pane-send-text pane-id "/ide\n"))

(defun herdr-claude-code-ide-known-project-p (agent)
  "Return non-nil when AGENT's directory is a known project."
  (when-let* ((cwd (alist-get 'cwd agent)))
    (and (file-directory-p cwd) (project-current nil cwd) t)))

(defun herdr-claude-code-ide--agent-for-pane (server-key pane-id)
  "Return SERVER-KEY's agent in PANE-ID."
  (herdr-agent--with-server server-key
    (cl-find pane-id (herdr-agents) :key (lambda (agent) (alist-get 'pane_id agent))
             :test #'equal)))

(defun herdr-claude-code-ide--maybe-adopt (data &optional server-key)
  "Adopt the detected Claude in event DATA when appropriate."
  (when (and (equal (alist-get 'agent data) "claude")
             (not (alist-get 'released data)))
    (when-let* ((server-key (or server-key (herdr-server-key)))
                (agent (herdr-claude-code-ide--agent-for-pane
                        server-key (alist-get 'pane_id data)))
                ((funcall herdr-claude-code-ide-auto-adopt-predicate agent)))
      (herdr-agent--with-server server-key
        (herdr-claude-code-ide-adopt agent)))))

;;;###autoload
(define-minor-mode herdr-claude-code-ide-auto-adopt-mode
  "Adopt detected Claude agents for the Claude IDE."
  :global t
  :group 'herdr-claude-code-ide
  (when (process-live-p herdr-claude-code-ide--auto-adopt-process)
    (delete-process herdr-claude-code-ide--auto-adopt-process))
  (setq herdr-claude-code-ide--auto-adopt-process
        (when herdr-claude-code-ide-auto-adopt-mode
          (let ((server-key (herdr-server-key)))
            (herdr-subscribe
             '("pane.agent_detected")
             (lambda (data)
               (herdr-claude-code-ide--maybe-adopt data server-key)))))))

(add-hook 'herdr-attach-functions #'herdr-claude-code-ide--attach-entry)

(provide 'herdr-claude-code-ide)
;;; herdr-claude-code-ide.el ends here
