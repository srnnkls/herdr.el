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

(defvar herdr-claude-code-ide--attach-terminal nil
  "Terminal id an in-flight session attaches to instead of starting Claude.")

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
  (let* ((tab (herdr-api-tab-create
               :cwd (expand-file-name working-dir)
               :label (funcall herdr-claude-code-ide-label-function
                               buffer-name working-dir)
               :workspace-id herdr-claude-code-ide-workspace
               :focus (if herdr-claude-code-ide-focus-herdr t :false)
               :env `((CLAUDE_CODE_SSE_PORT . ,(number-to-string port))
                      (TERM_PROGRAM . "emacs")
                      (FORCE_CODE_TERMINAL . "true"))))
         (pane (alist-get 'root_pane tab)))
    (herdr-api-pane-send-text (alist-get 'pane_id pane) (concat command "\n"))
    (alist-get 'terminal_id pane)))

(defun herdr-claude-code-ide--create-terminal-session (original &rest args)
  "Attach ARGS' claude-code-ide session to a herdr terminal.
ORIGINAL is `claude-code-ide--create-terminal-session', which ends up running
the attach command instead of the Claude CLI."
  (cl-destructuring-bind (buffer-name working-dir port continue resume session-id) args
    (let ((terminal-id
           (or herdr-claude-code-ide--attach-terminal
               (herdr-claude-code-ide--spawn
                buffer-name working-dir port
                (claude-code-ide--build-claude-command continue resume session-id)))))
      (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                 (lambda (&rest _)
                   (mapconcat #'identity
                              (herdr-attach-command terminal-id herdr-attach-takeover)
                              " "))))
        (apply original args)))))

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
                    #'herdr-claude-code-ide--create-terminal-session))
    (advice-remove 'claude-code-ide--create-terminal-session
                   #'herdr-claude-code-ide--create-terminal-session)))

;;;###autoload
(defun herdr-claude-code-ide-adopt (agent)
  "Open a claude-code-ide session attached to the herdr AGENT."
  (interactive (list (herdr-read-entry "Adopt herdr claude: " (herdr-agents)
                                       :require-agent "claude")))
  (unless herdr-claude-code-ide-mode (herdr-claude-code-ide-mode 1))
  (let* ((default-directory (file-name-as-directory (alist-get 'cwd agent)))
         (herdr-claude-code-ide--attach-terminal (alist-get 'terminal_id agent)))
    (claude-code-ide)))

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
