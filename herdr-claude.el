;;; herdr-claude.el --- Claude IDE adapter for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Claude IDE policy over generic herdr agent sessions.

;;; Code:

(require 'herdr)
(require 'herdr-agent)
(require 'herdr-claude-protocol)
(require 'cl-lib)

(defgroup herdr-claude nil
  "Connect Claude Code sessions to Emacs through herdr."
  :group 'herdr
  :prefix "herdr-claude-")

(defcustom herdr-claude-auto-adopt-predicate
  #'herdr-claude-known-project-p
  "Predicate deciding whether automatic adoption accepts an agent."
  :type 'function)

(defcustom herdr-claude-connect-on-adopt 'idle
  "When an adopted Claude is asked to connect to this Emacs."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "While the agent is idle" idle)
                 (const :tag "Always" t)))

(defvar herdr-claude--auto-adopt-process nil)

(defun herdr-claude--connect-p (agent)
  "Return non-nil when AGENT should connect to this Emacs."
  (and herdr-attach-takeover
       (pcase herdr-claude-connect-on-adopt
         ('nil nil)
         ('idle (equal (alist-get 'agent_status agent) "idle"))
         (_ t))))

;;;###autoload
(defun herdr-claude-adopt (agent)
  "Adopt AGENT through the generic lifecycle root."
  (interactive (list (herdr-read-entry "Adopt herdr Claude: " (herdr-agents)
                                       :require-agent "claude")))
  (herdr-agent-session-buffer
   (herdr-agent-adopt agent :server-key (or (alist-get 'server_key agent)
                                             (herdr-server-key)))))

;;;###autoload
(defun herdr-claude-connect (agent)
  "Ask AGENT to connect to this Emacs."
  (interactive (list (herdr-read-entry "Connect herdr Claude: "
                                       (herdr-agents) :require-agent "claude")))
  (herdr-claude-protocol-connect
   (or (alist-get 'server_key agent) (herdr-server-key))
   (alist-get 'pane_id agent)))

;;;###autoload
(defun herdr-claude-at-mention (agent)
  "Send the current file selection as an at-mention to AGENT."
  (interactive (list (herdr-read-entry "Mention to herdr Claude: "
                                       (herdr-agents) :require-agent "claude")))
  (let ((target (cons (or (alist-get 'server_key agent) (herdr-server-key))
                      (alist-get 'terminal_id agent))))
    (unless (herdr-claude-protocol-send-at-mentioned target)
      (user-error "Claude has no initialized editor connection for this file"))))

(defun herdr-claude--adapter (session phase &optional context)
  "Apply Claude adapter PHASE to SESSION using optional CONTEXT."
  (pcase phase
    (:prepare (herdr-claude-protocol--prepare-session session))
    (:adopted
     (prog1 (herdr-claude-protocol-adopt session)
       (when (and context (herdr-claude--connect-p context))
         (herdr-claude-protocol-connect
          (herdr-agent-session-server session)
          (herdr-agent-session-pane session)))))
    (:attached (herdr-claude-protocol--attached-session session))
    (:status (herdr-claude-protocol--status-session session))
    (:detach (herdr-claude-protocol--detach-session session))))

(defun herdr-claude-known-project-p (agent)
  "Return non-nil when AGENT's directory is a known project."
  (when-let* ((cwd (alist-get 'cwd agent)))
    (and (file-directory-p cwd) (project-current nil cwd) t)))

(defun herdr-claude--agent-for-pane (server-key pane-id)
  "Return SERVER-KEY's agent in PANE-ID."
  (herdr-agent--with-server server-key
    (cl-find pane-id (herdr-agents) :key (lambda (agent) (alist-get 'pane_id agent))
             :test #'equal)))

(defun herdr-claude--maybe-adopt (data &optional server-key)
  "Adopt the detected Claude in event DATA when SERVER-KEY permits it."
  (when (and (equal (alist-get 'agent data) "claude")
             (not (alist-get 'released data)))
    (when-let* ((server-key (or server-key (herdr-server-key)))
                (agent (herdr-claude--agent-for-pane
                        server-key (alist-get 'pane_id data)))
                ((funcall herdr-claude-auto-adopt-predicate agent)))
      (herdr-agent--with-server server-key
        (herdr-claude-adopt agent)))))

;;;###autoload
(define-minor-mode herdr-claude-auto-adopt-mode
  "Adopt detected Claude agents for the Claude IDE."
  :global t
  :group 'herdr-claude
  (when (process-live-p herdr-claude--auto-adopt-process)
    (delete-process herdr-claude--auto-adopt-process))
  (setq herdr-claude--auto-adopt-process
        (when herdr-claude-auto-adopt-mode
          (let ((server-key (herdr-server-key)))
            (herdr-subscribe
             '("pane.agent_detected")
             (lambda (data)
               (herdr-claude--maybe-adopt data server-key)))))))

(provide 'herdr-claude)
;;; herdr-claude.el ends here
