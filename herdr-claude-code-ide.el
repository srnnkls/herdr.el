;;; herdr-claude-code-ide.el --- Claude UI bridge for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Claude-specific UI behavior over generic herdr agent sessions.

;;; Code:

(require 'herdr)
(require 'herdr-agent)
(require 'cl-lib)

(declare-function claude-code-ide "claude-code-ide" ())
(declare-function claude-code-ide--build-claude-command "claude-code-ide"
                  (&optional continue resume session-id))
(declare-function claude-code-ide--session-display-name "claude-code-ide" (session))
(declare-function claude-code-ide-mcp--active-sessions "claude-code-ide-mcp" ())
(declare-function claude-code-ide-mcp-session-buffer "claude-code-ide-mcp" (session))
(declare-function claude-code-ide-mcp-session-project-dir "claude-code-ide-mcp" (session))
(defvar claude-code-ide-focus-on-open)

(defgroup herdr-claude-code-ide nil
  "Run Claude Code sessions inside herdr panes."
  :group 'herdr
  :prefix "herdr-claude-code-ide-")

(defcustom herdr-claude-code-ide-workspace nil
  "Herdr workspace label that new Claude tabs are created in."
  :type '(choice (const :tag "Workspace of the session's directory" nil) string))

(defcustom herdr-claude-code-ide-focus-herdr nil
  "Whether herdr focuses a tab it creates for a Claude session."
  :type 'boolean)

(defcustom herdr-claude-code-ide-label-function
  #'herdr-claude-code-ide-default-label
  "Function returning the herdr tab label for a Claude session."
  :type 'function)

(defcustom herdr-claude-code-ide-auto-adopt-predicate
  #'herdr-claude-code-ide-known-project-p
  "Predicate deciding whether automatic adoption accepts an agent."
  :type 'function)

(defcustom herdr-claude-code-ide-adopt-on-attach t
  "Whether attaching a Claude agent uses the Claude UI bridge."
  :type 'boolean)

(defcustom herdr-claude-code-ide-instance-name-function
  #'herdr-claude-code-ide-default-instance-name
  "Function suggesting an instance name for an adopted agent."
  :type 'function)

(defcustom herdr-claude-code-ide-connect-on-adopt 'idle
  "When an adopted Claude is asked to connect to this Emacs."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "While the agent is idle" idle)
                 (const :tag "Always" t)))

(defvar herdr-claude-code-ide--auto-adopt-process nil)
(defvar herdr-claude-code-ide--starting-session nil)

(defun herdr-claude-code-ide-default-label (_buffer-name directory)
  "Return a herdr tab label for a session running in DIRECTORY."
  (file-name-nondirectory (directory-file-name (expand-file-name directory))))

(defun herdr-claude-code-ide--host-ready-p ()
  "Start herdr when needed, or signal when it remains unavailable."
  (condition-case err
      (herdr-start-server-if-needed)
    (herdr-error
     (user-error "Claude Code sessions run inside herdr, which is unreachable: %s"
                 (error-message-string err)))))

(defun herdr-claude-code-ide--terminal-for (buffer-name working-dir _port _continue _resume _session-id)
  "Return the terminal that BUFFER-NAME should attach to in WORKING-DIR."
  (progn
    (herdr-claude-code-ide--host-ready-p)
    (let ((session
           (herdr-agent-start-session
            "claude"
            (funcall herdr-claude-code-ide-label-function buffer-name working-dir)
            :project-root (expand-file-name working-dir)
            :workspace (or herdr-claude-code-ide-workspace
                           (herdr-workspace-label working-dir))
            :attach nil)))
      (setq herdr-claude-code-ide--starting-session session)
      (herdr-agent-session-terminal session))))

(defun herdr-claude-code-ide--create-terminal-session (original &rest args)
  "Attach ORIGINAL's ARGS Claude UI session to a herdr terminal."
  (cl-destructuring-bind (buffer-name working-dir port continue resume session-id) args
    (herdr-with-session (herdr-session-for working-dir)
      (let (herdr-claude-code-ide--starting-session)
        (condition-case err
            (let ((terminal-id (herdr-claude-code-ide--terminal-for
                                buffer-name working-dir port continue resume session-id)))
              (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                         (lambda (&rest _)
                           (mapconcat #'identity
                                      (herdr-attach-command terminal-id herdr-attach-takeover)
                                      " "))))
                (let ((process-environment (herdr-process-environment))
                      (result (apply original args)))
                  (herdr-agent-claim-attachment herdr-claude-code-ide--starting-session
                                                (car result) (cdr result))
                  result)))
          (error
           (when herdr-claude-code-ide--starting-session
             (herdr-agent--rollback herdr-claude-code-ide--starting-session))
           (signal (car err) (cdr err))))))))

(defun herdr-claude-code-ide-sessions ()
  "Return Claude UI sessions as `herdr-jump' entries."
  (when (fboundp 'claude-code-ide-mcp--active-sessions)
    (mapcar (lambda (session)
              (let ((buffer (claude-code-ide-mcp-session-buffer session)))
                `((kind . "claude-code-ide")
                  (label . ,(claude-code-ide--session-display-name session))
                  (cwd . ,(claude-code-ide-mcp-session-project-dir session))
                  (buffer . ,buffer)
                  (server_key . ,(and (buffer-live-p buffer)
                                      (buffer-local-value 'herdr-terminal-server-key buffer)))
                  (terminal_id . ,(and (buffer-live-p buffer)
                                       (buffer-local-value 'herdr-terminal-id buffer))))))
            (claude-code-ide-mcp--active-sessions))))

(add-to-list 'herdr-session-functions #'herdr-claude-code-ide-sessions t)

;;;###autoload
(define-minor-mode herdr-claude-code-ide-mode
  "Run Claude UI terminal sessions through herdr."
  :global t
  :group 'herdr-claude-code-ide
  (if herdr-claude-code-ide-mode
      (progn
        (require 'claude-code-ide)
        (unless (fboundp 'claude-code-ide--create-terminal-session)
          (setq herdr-claude-code-ide-mode nil)
          (user-error "This claude-code-ide has no terminal bridge"))
        (advice-add 'claude-code-ide--create-terminal-session :around
                    #'herdr-claude-code-ide--create-terminal-session)
        (add-hook 'herdr-attach-functions #'herdr-claude-code-ide--attach-entry))
    (advice-remove 'claude-code-ide--create-terminal-session
                   #'herdr-claude-code-ide--create-terminal-session)
    (remove-hook 'herdr-attach-functions #'herdr-claude-code-ide--attach-entry)))

(defun herdr-claude-code-ide-default-instance-name (agent)
  "Return a suggested Claude UI instance name for AGENT."
  (when-let* ((raw (or (alist-get 'name agent)
                       (alist-get 'terminal_title_stripped agent)
                       (alist-get 'pane_id agent))))
    (let ((name (string-trim
                 (replace-regexp-in-string
                  "[[:space:]]+" " "
                  (replace-regexp-in-string "[][*[:cntrl:]]" "" raw)))))
      (unless (or (string-empty-p name) (string-match-p "\\`[0-9]+\\'" name))
        (truncate-string-to-width name 40)))))

(defun herdr-claude-code-ide--instance-prompt-answer (name)
  "Return a `read-string' stand-in that answers NAME once."
  (let ((answered nil))
    (lambda (&rest _)
      (if answered "" (progn (setq answered t) (or name ""))))))

(defun herdr-claude-code-ide--connect-p (agent)
  "Return non-nil when AGENT should be asked to connect to this Emacs."
  (and herdr-attach-takeover
       (pcase herdr-claude-code-ide-connect-on-adopt
         ('nil nil)
         ('idle (equal (alist-get 'agent_status agent) "idle"))
         (_ t))))

;;;###autoload
(defun herdr-claude-code-ide-adopt (agent)
  "Adopt AGENT through the generic lifecycle root."
  (interactive (list (herdr-read-entry "Adopt herdr claude: " (herdr-agents)
                                       :require-agent "claude")))
  (let* ((server-key (or (alist-get 'server_key agent) (herdr-server-key)))
         (session (herdr-agent-adopt agent :server-key server-key)))
    (when (herdr-claude-code-ide--connect-p agent)
      (herdr-agent--with-server server-key
        (herdr-api-pane-send-text (alist-get 'pane_id agent) "/ide\n")))
    (herdr-agent-session-buffer session)))

(defun herdr-claude-code-ide--attach-entry (entry)
  "Open ENTRY through the Claude bridge when it is a Claude agent."
  (when (and herdr-claude-code-ide-adopt-on-attach
             (fboundp 'claude-code-ide)
             (equal (alist-get 'agent entry) "claude")
             (alist-get 'cwd entry)
             (alist-get 'terminal_id entry))
    (herdr-claude-code-ide-adopt entry)))

;;;###autoload
(defun herdr-claude-code-ide-connect-ide (pane-id)
  "Ask the Claude running in PANE-ID to connect to this Emacs."
  (interactive (list (alist-get 'pane_id
                                (herdr-read-entry "Connect herdr claude: "
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
      (let ((claude-code-ide-focus-on-open nil))
        (herdr-agent--with-server server-key
          (herdr-claude-code-ide-adopt agent))))))

;;;###autoload
(define-minor-mode herdr-claude-code-ide-auto-adopt-mode
  "Adopt detected Claude agents into the Claude UI bridge."
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

(provide 'herdr-claude-code-ide)
;;; herdr-claude-code-ide.el ends here
