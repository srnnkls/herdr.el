;;; herdr-claude-code-ide.el --- Run claude-code-ide sessions in herdr panes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (herdr "0.1.0"))
;; Keywords: terminals, tools, processes
;; URL: https://github.com/srnnkls/herdr.el

;;; Commentary:

;; Bridges claude-code-ide.el and herdr in both directions.
;;
;; With `herdr-claude-code-ide-mode' on, every claude-code-ide session runs
;; its CLI in a herdr pane and the Emacs buffer is an attached view: the
;; conversation survives Emacs restarts and shows up in the herdr UI, while
;; MCP stays connected because the pane inherits CLAUDE_CODE_SSE_PORT.
;;
;; The other direction is `herdr-claude-code-ide-adopt', which wraps a
;; claude already running in herdr in a claude-code-ide session, and
;; `herdr-claude-code-ide-auto-adopt-mode', which does that for every claude
;; herdr detects.

;;; Code:

(require 'herdr)
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
  "Run claude-code-ide sessions inside herdr panes."
  :group 'herdr
  :prefix "herdr-claude-code-ide-")

(defcustom herdr-claude-code-ide-workspace nil
  "Workspace id that new Claude tabs are created in.
Nil creates them in the workspace herdr currently has focused."
  :type '(choice (const :tag "Focused workspace" nil) string))

(defcustom herdr-claude-code-ide-focus-herdr nil
  "Whether herdr focuses a tab it creates for a Claude session."
  :type 'boolean)

(defcustom herdr-claude-code-ide-label-function
  #'herdr-claude-code-ide-default-label
  "Function returning the herdr tab label for a Claude session.
It is called with the Emacs buffer name and the working directory."
  :type 'function)

(defcustom herdr-claude-code-ide-auto-adopt-predicate
  #'herdr-claude-code-ide-known-project-p
  "Predicate deciding whether `herdr-claude-code-ide-auto-adopt-mode' adopts.
Called with the agent alist herdr reports."
  :type 'function)

(defcustom herdr-claude-code-ide-require-herdr t
  "Whether Claude Code sessions must run inside herdr.
Non-nil refuses to start a session when no herdr server can be reached,
rather than letting claude-code-ide spawn the CLI in an Emacs-owned
process.  See `herdr-auto-start-server', which starts one first."
  :type 'boolean)

(defcustom herdr-claude-code-ide-adopt-on-attach t
  "Whether attaching a claude agent opens a claude-code-ide session.
With this on, `herdr-attach-agent' and `herdr-attach-pane' hand claude
agents to `herdr-claude-code-ide-adopt' instead of opening a plain
terminal buffer."
  :type 'boolean)

(defcustom herdr-claude-code-ide-instance-name-function
  #'herdr-claude-code-ide-default-instance-name
  "Function naming the claude-code-ide instance an adopted agent becomes.
It is called with the agent alist and returns a name, or nil to let
claude-code-ide number the instance."
  :type 'function)

(defcustom herdr-claude-code-ide-connect-on-adopt 'idle
  "When an adopted claude is asked to connect to this Emacs.
A CLI that herdr started has no MCP port in its environment, so it
needs `/ide' to find the session's server.  Claude answers with its
picker, which you finish by hand.  `idle' only sends it while herdr
reports the agent idle, t always sends it, nil never does."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "While the agent is idle" idle)
                 (const :tag "Always" t)))

(defvar herdr-claude-code-ide--attach-terminal nil
  "Terminal id an in-flight session attaches to instead of starting Claude.")

(defvar herdr-claude-code-ide--session-buffer nil
  "Buffer name the in-flight claude-code-ide session was given.")

(defvar herdr-claude-code-ide--buffers (make-hash-table :test 'equal)
  "Terminal id to the claude-code-ide buffer adopting it.")

(defvar herdr-claude-code-ide--auto-adopt-process nil)

(defun herdr-claude-code-ide-default-label (buffer-name directory)
  "Return a herdr tab label for BUFFER-NAME in DIRECTORY."
  (if (string-match "\\*claude-code\\[\\(.*\\)\\]\\*" buffer-name)
      (format "claude-%s" (match-string 1 buffer-name))
    (format "claude-%s" (file-name-nondirectory (directory-file-name directory)))))

(defun herdr-claude-code-ide--spawn (buffer-name working-dir port command)
  "Start COMMAND in a new herdr tab and return its terminal id.
The tab runs in WORKING-DIR, is labelled after BUFFER-NAME, and its
shell carries the claude-code-ide MCP environment for PORT."
  (let* ((tab (herdr-new-tab
               :cwd (expand-file-name working-dir)
               :label (funcall herdr-claude-code-ide-label-function
                               buffer-name working-dir)
               :workspace herdr-claude-code-ide-workspace
               :focus (if herdr-claude-code-ide-focus-herdr t :false)
               :env `((CLAUDE_CODE_SSE_PORT . ,(number-to-string port))
                      (TERM_PROGRAM . "emacs")
                      (FORCE_CODE_TERMINAL . "true"))))
         (pane (alist-get 'root_pane tab)))
    (herdr-api-pane-send-text (alist-get 'pane_id pane) (concat command "\n"))
    (alist-get 'terminal_id pane)))

(defun herdr-claude-code-ide--host-ready-p ()
  "Return non-nil when herdr can host a session, starting a server if needed.
Refuses with a `user-error' instead of returning nil while
`herdr-claude-code-ide-require-herdr' is on."
  (condition-case err
      (herdr-start-server-if-needed)
    (herdr-error
     (when herdr-claude-code-ide-require-herdr
       (user-error "Claude Code sessions run inside herdr, which is unreachable: %s"
                   (error-message-string err)))
     nil)))

(defun herdr-claude-code-ide--terminal-for (buffer-name working-dir port continue resume session-id)
  "Return the herdr terminal the session in BUFFER-NAME should attach to.
Adoption reuses its terminal; everything else gets a fresh herdr tab in
WORKING-DIR whose CLI carries PORT and the CONTINUE, RESUME and
SESSION-ID flags.  Nil means claude-code-ide keeps the session itself."
  (or herdr-claude-code-ide--attach-terminal
      (when (herdr-claude-code-ide--host-ready-p)
        (herdr-claude-code-ide--spawn
         buffer-name working-dir port
         (claude-code-ide--build-claude-command continue resume session-id)))))

(defun herdr-claude-code-ide--create-terminal-session (original &rest args)
  "Attach ARGS' claude-code-ide session to a herdr terminal.
ORIGINAL is `claude-code-ide--create-terminal-session', which ends up running
the attach command instead of the Claude CLI."
  (cl-destructuring-bind (buffer-name working-dir port continue resume session-id) args
    (setq herdr-claude-code-ide--session-buffer buffer-name)
    (if-let* ((terminal-id (herdr-claude-code-ide--terminal-for
                            buffer-name working-dir port continue resume session-id)))
        (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                   (lambda (&rest _)
                     (mapconcat #'identity
                                (herdr-attach-command terminal-id herdr-attach-takeover)
                                " "))))
          (let* ((process-environment (herdr-process-environment))
                 (result (apply original args)))
            (herdr-claim-buffer (car-safe result) terminal-id)
            result))
      (apply original args))))

(defun herdr-claude-code-ide-sessions ()
  "Return the claude-code-ide sessions as `herdr-jump' entries."
  (when (fboundp 'claude-code-ide-mcp--active-sessions)
    (mapcar (lambda (session)
              (let ((buffer (claude-code-ide-mcp-session-buffer session)))
                `((kind . "claude-code-ide")
                  (label . ,(claude-code-ide--session-display-name session))
                  (cwd . ,(claude-code-ide-mcp-session-project-dir session))
                  (buffer . ,buffer)
                  (terminal_id . ,(and (buffer-live-p buffer)
                                       (buffer-local-value 'herdr-terminal-id buffer))))))
            (claude-code-ide-mcp--active-sessions))))

(add-to-list 'herdr-session-functions #'herdr-claude-code-ide-sessions t)

;;;###autoload
(define-minor-mode herdr-claude-code-ide-mode
  "Run claude-code-ide sessions in herdr panes instead of Emacs-owned processes."
  :global t
  :group 'herdr-claude-code-ide
  (if herdr-claude-code-ide-mode
      (progn
        (require 'claude-code-ide)
        (unless (fboundp 'claude-code-ide--create-terminal-session)
          (setq herdr-claude-code-ide-mode nil)
          (user-error "This claude-code-ide has no `claude-code-ide--create-terminal-session' to bridge"))
        (advice-add 'claude-code-ide--create-terminal-session :around
                    #'herdr-claude-code-ide--create-terminal-session)
        (add-hook 'herdr-attach-functions #'herdr-claude-code-ide--attach-entry))
    (advice-remove 'claude-code-ide--create-terminal-session
                   #'herdr-claude-code-ide--create-terminal-session)
    (remove-hook 'herdr-attach-functions #'herdr-claude-code-ide--attach-entry)))

(defun herdr-claude-code-ide-default-instance-name (agent)
  "Return the claude-code-ide instance name for herdr AGENT.
Nil lets claude-code-ide number the instance itself."
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
  "Return a `read-string' stand-in that answers NAME once, then empty.
claude-code-ide asks for an instance name while starting a session, and
the adopt paths run where no one can answer; an empty answer makes it
auto-number, including when NAME turns out to be taken."
  (let ((answered nil))
    (lambda (&rest _)
      (if answered "" (progn (setq answered t) (or name ""))))))

(defun herdr-claude-code-ide--adopted-buffer (terminal-id)
  "Return the live claude-code-ide buffer already adopting TERMINAL-ID."
  (let ((buffer (gethash terminal-id herdr-claude-code-ide--buffers)))
    (if (and (buffer-live-p buffer) (get-buffer-process buffer))
        buffer
      (remhash terminal-id herdr-claude-code-ide--buffers)
      nil)))

(defun herdr-claude-code-ide--connect-p (agent)
  "Return non-nil when AGENT should be asked to connect to this Emacs."
  (pcase herdr-claude-code-ide-connect-on-adopt
    ('nil nil)
    ('idle (equal (alist-get 'agent_status agent) "idle"))
    (_ t)))

;;;###autoload
(defun herdr-claude-code-ide-adopt (agent)
  "Open a claude-code-ide session attached to the herdr AGENT.
Returns the session buffer.  A session already adopting that terminal
is reused rather than started a second time."
  (interactive (list (herdr-read-entry "Adopt herdr claude: " (herdr-agents)
                                       :require-agent "claude")))
  (unless herdr-claude-code-ide-mode (herdr-claude-code-ide-mode 1))
  (let ((terminal-id (alist-get 'terminal_id agent)))
    (if-let* ((buffer (herdr-claude-code-ide--adopted-buffer terminal-id)))
        (progn (pop-to-buffer buffer) buffer)
      (let* ((default-directory (file-name-as-directory (alist-get 'cwd agent)))
             (herdr-claude-code-ide--attach-terminal terminal-id)
             (herdr-claude-code-ide--session-buffer nil)
             (suggested (funcall herdr-claude-code-ide-instance-name-function agent)))
        (cl-letf (((symbol-function 'read-string)
                   (herdr-claude-code-ide--instance-prompt-answer suggested)))
          (claude-code-ide))
        (let ((buffer (and herdr-claude-code-ide--session-buffer
                           (get-buffer herdr-claude-code-ide--session-buffer))))
          (when buffer
            (puthash terminal-id buffer herdr-claude-code-ide--buffers)
            (when (herdr-claude-code-ide--connect-p agent)
              (herdr-api-pane-send-text (alist-get 'pane_id agent) "/ide\n")))
          buffer)))))

(defun herdr-claude-code-ide--attach-entry (entry)
  "Open ENTRY as a claude-code-ide session when it is a claude agent."
  (when (and herdr-claude-code-ide-adopt-on-attach
             (fboundp 'claude-code-ide)
             (equal (alist-get 'agent entry) "claude")
             (alist-get 'cwd entry)
             (alist-get 'terminal_id entry))
    (herdr-claude-code-ide-adopt entry)))

;;;###autoload
(defun herdr-claude-code-ide-connect-ide (pane-id)
  "Ask the Claude running in PANE-ID to connect to this Emacs.
Claude answers with its IDE picker; choose the Emacs entry there."
  (interactive (list (alist-get 'pane_id
                                (herdr-read-entry "Connect herdr claude: "
                                                  (herdr-agents)
                                                  :require-agent "claude"))))
  (herdr-api-pane-send-text pane-id "/ide\n"))

(defun herdr-claude-code-ide-known-project-p (agent)
  "Return non-nil when AGENT's directory is a project Emacs knows."
  (when-let* ((cwd (alist-get 'cwd agent)))
    (and (file-directory-p cwd)
         (project-current nil cwd)
         t)))

(defun herdr-claude-code-ide--maybe-adopt (event)
  "Adopt the claude EVENT reports, when the adopt predicate agrees."
  (let ((agent (or (alist-get 'agent event) (alist-get 'pane event))))
    (when (and agent
               (equal (alist-get 'agent agent) "claude")
               (funcall herdr-claude-code-ide-auto-adopt-predicate agent))
      (let ((claude-code-ide-focus-on-open nil))
        (herdr-claude-code-ide-adopt agent)))))

;;;###autoload
(define-minor-mode herdr-claude-code-ide-auto-adopt-mode
  "Adopt every claude herdr detects into a claude-code-ide session."
  :global t
  :group 'herdr-claude-code-ide
  (when (process-live-p herdr-claude-code-ide--auto-adopt-process)
    (delete-process herdr-claude-code-ide--auto-adopt-process))
  (setq herdr-claude-code-ide--auto-adopt-process
        (when herdr-claude-code-ide-auto-adopt-mode
          (herdr-subscribe '("pane.agent_detected")
                           #'herdr-claude-code-ide--maybe-adopt))))

(provide 'herdr-claude-code-ide)
;;; herdr-claude-code-ide.el ends here
