;;; herdr-agent.el --- Manage herdr agent attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Generic lifecycle ownership for herdr agent attachments.

;;; Code:

(require 'cl-lib)
(require 'herdr)

(cl-defstruct (herdr-agent-session
               (:constructor herdr-agent--make-session))
  key server terminal kind name agent-session project route workspace tab pane
  buffer attachment-process state ownership cleanup)

(defvar herdr-agent-kind-adapters nil
  "Functions keyed by supported agent kind.")
(defvar herdr-agent--sessions (make-hash-table :test #'equal)
  "Primary agent sessions keyed by server and terminal.")
(defvar herdr-agent--buffers (make-hash-table :test #'eq)
  "Agent keys keyed by terminal buffers.")
(defvar herdr-agent--projects (make-hash-table :test #'equal)
  "Agent keys keyed by project roots.")
(defvar herdr-agent--panes (make-hash-table :test #'equal)
  "Terminal IDs keyed by server and pane.")
(defvar herdr-agent--subscriptions (make-hash-table :test #'equal)
  "Lifecycle subscription processes keyed by server.")

(defmacro herdr-agent--with-server (server-key &rest body)
  "Evaluate BODY against SERVER-KEY."
  (declare (indent 1) (debug (form body)))
  `(let ((herdr-socket-path ,server-key)) ,@body))

(defun herdr-agent-find (server-key terminal-id)
  "Return the live session for SERVER-KEY and TERMINAL-ID."
  (gethash (cons server-key terminal-id) herdr-agent--sessions))

(defun herdr-agent--kind (agent)
  "Return AGENT's supported kind."
  (let ((kind (alist-get 'agent agent)))
    (unless (member kind '("claude" "pi" "codex"))
      (signal 'herdr-error (list (format "unsupported agent kind %s" kind))))
    kind))

(defun herdr-agent--project (root)
  "Return ROOT in canonical form."
  (and root (directory-file-name (expand-file-name root))))

(defun herdr-agent--register (session)
  "Register SESSION and its derived indexes."
  (let ((key (herdr-agent-session-key session))
        (project (herdr-agent-session-project session))
        (buffer (herdr-agent-session-buffer session))
        (pane (herdr-agent-session-pane session)))
    (puthash key session herdr-agent--sessions)
    (when project
      (puthash project (cons key (delete key (gethash project herdr-agent--projects)))
               herdr-agent--projects))
    (when buffer (puthash buffer key herdr-agent--buffers))
    (when pane
      (puthash (cons (herdr-agent-session-server session) pane)
               (herdr-agent-session-terminal session) herdr-agent--panes))
    session))

(defun herdr-agent--unregister (session)
  "Remove SESSION and its derived indexes."
  (let* ((key (herdr-agent-session-key session))
         (project (herdr-agent-session-project session))
         (buffer (herdr-agent-session-buffer session))
         (pane (herdr-agent-session-pane session))
         (keys (delete key (gethash project herdr-agent--projects))))
    (remhash key herdr-agent--sessions)
    (if keys
        (puthash project keys herdr-agent--projects)
      (remhash project herdr-agent--projects))
    (when buffer (remhash buffer herdr-agent--buffers))
    (when pane (remhash (cons (herdr-agent-session-server session) pane)
                        herdr-agent--panes))
    (setf (herdr-agent-session-state session) 'stopped)
    session))

(defun herdr-agent--run-adapter (session phase)
  "Run SESSION's adapter PHASE."
  (when-let* ((adapter (cdr (assoc (herdr-agent-session-kind session)
                                   herdr-agent-kind-adapters))))
    (cond
     ((functionp adapter)
      (when (eq phase :attached) (funcall adapter session)))
     ((functionp (plist-get adapter phase))
      (funcall (plist-get adapter phase) session)))))

(defun herdr-agent--buffer-died ()
  "Clean the session whose attachment buffer is being killed."
  (when-let* ((key (gethash (current-buffer) herdr-agent--buffers))
              (session (gethash key herdr-agent--sessions)))
    (remhash (current-buffer) herdr-agent--buffers)
    (setf (herdr-agent-session-buffer session) nil)
    (herdr-agent-detach session)))

(defun herdr-agent--watch-buffer (session)
  "Watch SESSION's attachment buffer."
  (when-let* ((buffer (herdr-agent-session-buffer session)))
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook #'herdr-agent--buffer-died nil t))))

(defun herdr-agent--watch-attachment (session)
  "Detach SESSION when its terminal attachment exits."
  (when-let* ((process (herdr-agent-session-attachment-process session)))
    (let ((sentinel (process-sentinel process)))
      (process-put process 'herdr-agent--backend-sentinel sentinel)
      (set-process-sentinel
       process
       (lambda (process event)
         (when-let* ((backend-sentinel
                      (process-get process 'herdr-agent--backend-sentinel)))
           (condition-case nil
               (funcall backend-sentinel process event)
             (error nil)))
         (unless (process-live-p process)
           (herdr-agent-detach session)))))))

(defun herdr-agent--attach (session)
  "Attach SESSION's terminal and record its Emacs resources."
  (let ((buffer
         (herdr-agent--with-server (herdr-agent-session-server session)
           (herdr-attach-terminal
            (herdr-agent-session-terminal session)
            :label (herdr-agent-session-name session)
            :directory (herdr-agent-session-project session)
            :takeover herdr-attach-takeover :display t))))
    (herdr-agent-claim-attachment session buffer (get-buffer-process buffer))))

(defun herdr-agent-claim-attachment (session buffer process)
  "Claim BUFFER and PROCESS as SESSION's terminal attachment."
  (unless (eq (herdr-agent-session-state session) 'starting)
    (when (and (processp process) (process-live-p process))
      (delete-process process))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))
    (signal 'herdr-error (list "agent session is no longer starting")))
  (condition-case err
      (progn
        (unless (and (buffer-live-p buffer) process)
          (signal 'herdr-error (list "terminal attachment did not return a buffer and process")))
        (herdr-claim-buffer buffer (herdr-agent-session-terminal session))
        (setf (herdr-agent-session-buffer session) buffer
              (herdr-agent-session-attachment-process session) process)
        (herdr-agent--register session)
        (herdr-agent--watch-buffer session)
        (herdr-agent--watch-attachment session)
        (herdr-agent--run-adapter session :attached)
        (setf (herdr-agent-session-ownership session) nil
              (herdr-agent-session-state session) 'attached)
        session)
    (error
     (herdr-agent--rollback session)
     (signal (car err) (cdr err)))))

(defun herdr-agent--live-session-p (session)
  "Return non-nil when SESSION can be reused."
  (and (memq (herdr-agent-session-state session) '(starting attached))
       (or (eq (herdr-agent-session-state session) 'starting)
           (buffer-live-p (herdr-agent-session-buffer session)))))

(defun herdr-agent--apply-agent (session agent server-key)
  "Set SESSION identity from AGENT on SERVER-KEY."
  (let ((terminal (alist-get 'terminal_id agent)))
    (unless terminal
      (signal 'herdr-error (list "agent has no terminal_id")))
    (setf (herdr-agent-session-key session) (cons server-key terminal)
          (herdr-agent-session-server session) server-key
          (herdr-agent-session-terminal session) terminal
          (herdr-agent-session-kind session) (herdr-agent--kind agent)
          (herdr-agent-session-name session) (or (alist-get 'name agent) terminal)
          (herdr-agent-session-agent-session session) (alist-get 'agent_session agent)
          (herdr-agent-session-project session) (herdr-agent--project (alist-get 'cwd agent))
          (herdr-agent-session-route session) (alist-get 'session agent)
          (herdr-agent-session-workspace session) (alist-get 'workspace_id agent)
          (herdr-agent-session-tab session) (alist-get 'tab_id agent)
          (herdr-agent-session-pane session) (alist-get 'pane_id agent))
    session))

(defun herdr-agent--subscribe-if-live (server-key)
  "Subscribe SERVER-KEY when it is available."
  (herdr-agent--with-server server-key
    (condition-case nil
        (when (and (file-exists-p (herdr-socket-file)) (herdr-available-p))
          (herdr-agent-subscribe server-key))
      (error nil))))

(cl-defun herdr-agent-adopt (agent &key server-key (attach t))
  "Adopt AGENT on SERVER-KEY, optionally deferring terminal attachment."
  (let* ((server-key (or server-key (alist-get 'server_key agent) (herdr-server-key)))
         (terminal (alist-get 'terminal_id agent)))
    (unless terminal
      (signal 'herdr-error (list "agent has no terminal_id")))
    (let ((existing (herdr-agent-find server-key terminal)))
      (when (and existing (not (herdr-agent--live-session-p existing)))
        (herdr-agent-detach existing)
        (when (not (eq (herdr-agent-session-state existing) 'stopped))
          (signal 'herdr-error (list "agent cleanup is still pending")))
        (setq existing nil))
      (or existing
          (let ((session
                 (herdr-agent--make-session
                  :state 'starting)))
            (herdr-agent--apply-agent session agent server-key)
            (herdr-agent--register session)
            (condition-case err
                (progn
                  (herdr-agent--run-adapter session :adopted)
                  (when attach (herdr-agent--attach session))
                  (when attach
                    (setf (herdr-agent-session-state session) 'attached
                          (herdr-agent-session-ownership session) nil))
                  (herdr-agent--subscribe-if-live server-key)
                  session)
              (error
               (herdr-agent-detach session)
               (signal (car err) (cdr err)))))))))

(defun herdr-agent--ready-agent (agent timeout-ms)
  "Return AGENT after its terminal becomes interactive-ready."
  (let ((terminal (alist-get 'terminal_id agent))
        (deadline (+ (float-time) (/ timeout-ms 1000.0))))
    (unless terminal
      (signal 'herdr-error (list "agent.start did not return a terminal_id")))
    (while (not (alist-get 'interactive_ready agent))
      (when (>= (float-time) deadline)
        (signal 'herdr-error (list "agent did not become interactive-ready")))
      (setq agent (alist-get 'agent (herdr-api-agent-get terminal)))
      (unless agent
        (signal 'herdr-error (list "agent.get did not return an agent")))
      (unless (alist-get 'interactive_ready agent)
        (sleep-for 0.1)))
    agent))

(cl-defun herdr-agent-start-in-pane
    (kind name pane &key server-key args (attach t) session timeout-ms)
  "Start KIND named NAME in PANE on SERVER-KEY with ARGS."
  (let* ((server-key (or server-key (herdr-server-key)))
         (start-timeout-ms (or timeout-ms 30000))
         (pane-id (alist-get 'pane_id pane))
         (session (or session
                      (herdr-agent--make-session
                       :server server-key :kind kind :name name :pane pane-id
                       :workspace (alist-get 'workspace_id pane)
                       :tab (alist-get 'tab_id pane) :state 'starting))))
    (condition-case err
        (let* ((result (herdr-agent--with-server server-key
                         (if timeout-ms
                             (herdr-api-agent-start kind name pane-id
                                                    :args args :timeout-ms timeout-ms)
                           (herdr-api-agent-start kind name pane-id :args args))))
               (agent (alist-get 'agent result)))
          (unless agent (signal 'herdr-error (list "agent.start did not return an agent")))
          (herdr-agent--apply-agent
           session
           (herdr-agent--with-server server-key
             (herdr-agent--ready-agent agent start-timeout-ms))
           server-key)
          (herdr-agent--register session)
          (when attach (herdr-agent--attach session))
          (when attach
            (setf (herdr-agent-session-state session) 'attached
                  (herdr-agent-session-ownership session) nil))
          (herdr-agent--subscribe-if-live server-key)
          session)
      (error
       (herdr-agent--rollback session)
       (signal (car err) (cdr err))))))

(defun herdr-agent--workspace-empty-p (workspace-id)
  "Return non-nil when WORKSPACE-ID has no tabs or panes."
  (when-let* ((workspace
               (cl-find workspace-id
                        (alist-get 'workspaces (herdr-api-workspace-list))
                        :key (lambda (item) (alist-get 'workspace_id item))
                        :test #'equal)))
    (and (zerop (or (alist-get 'tab_count workspace) 1))
         (zerop (or (alist-get 'pane_count workspace) 1)))))

(defun herdr-agent--cleanup-ownership (session)
  "Clean SESSION's transaction-owned startup resources."
  (let ((ownership (herdr-agent-session-ownership session))
        errors)
    (when-let* ((tab (plist-get ownership :tab)))
      (condition-case err
          (progn
            (herdr-api-tab-close tab)
            (setf (plist-get ownership :tab) nil))
        (error (push err errors))))
    (when (and (not (plist-get ownership :tab))
               (plist-get ownership :workspace))
      (let ((workspace (plist-get ownership :workspace)))
        (condition-case err
            (progn
              (when (herdr-agent--workspace-empty-p workspace)
                (herdr-api-workspace-close workspace))
              (setf (plist-get ownership :workspace) nil))
          (error (push err errors)))))
    (setf (herdr-agent-session-ownership session)
          (and (or (plist-get ownership :tab) (plist-get ownership :workspace)) ownership))
    errors))

(defun herdr-agent--rollback (session)
  "Clean SESSION's transaction-owned startup resources."
  (herdr-agent-detach session))

(cl-defun herdr-agent-start-session
    (kind name &key server-key project-root workspace args (attach t) timeout-ms)
  "Start KIND named NAME on SERVER-KEY for PROJECT-ROOT in WORKSPACE with ARGS."
  (let* ((server-key (or server-key (herdr-server-key)))
         (current-server-key (herdr-server-key)))
    (when (equal server-key current-server-key)
      (herdr-start-server-if-needed))
    (herdr-agent--with-server server-key
      (unless (equal server-key current-server-key)
        (herdr-start-server-if-needed))
      (let ((session (herdr-agent--make-session
                      :server server-key :kind kind :name name
                      :project (herdr-agent--project project-root) :state 'starting)))
        (condition-case err
            (let* ((env (herdr-agent--run-adapter session :prepare))
                   (workspace (or workspace (herdr-workspace-label project-root)))
                   (existing (herdr-workspace-id workspace))
                   (created (herdr-open-tab :cwd project-root :label name :workspace workspace :env env))
                   (tab (alist-get 'tab created))
                   (pane (alist-get 'root_pane created))
                   (workspace-id (or existing (alist-get 'workspace_id (alist-get 'workspace created))
                                     (alist-get 'workspace_id pane))))
              (setf (herdr-agent-session-workspace session) workspace-id
                    (herdr-agent-session-tab session) (alist-get 'tab_id tab)
                    (herdr-agent-session-pane session) (alist-get 'pane_id pane)
                    (herdr-agent-session-ownership session)
                    (list :tab (alist-get 'tab_id tab)
                          :workspace (and (not existing) workspace-id)))
              (herdr-agent-start-in-pane kind name pane :server-key server-key
                                         :args args :attach attach :session session
                                         :timeout-ms timeout-ms))
          (error
           (herdr-agent--rollback session)
           (signal (car err) (cdr err))))))))

(defun herdr-agent-attach-entry (entry)
  "Attach supported agent ENTRY through the generic lifecycle root."
  (when (and (member (alist-get 'agent entry) '("claude" "pi" "codex"))
             (alist-get 'terminal_id entry))
    (herdr-agent-session-buffer
     (herdr-agent-adopt entry :server-key (or (alist-get 'server_key entry)
                                               (herdr-server-key))))))

(defun herdr-agent--pane (data)
  "Return pane data carried by DATA."
  (or (alist-get 'pane data) data))

(defun herdr-agent--index-pane (server-key pane)
  "Update SERVER-KEY's pane mapping from PANE."
  (when-let* ((pane-id (alist-get 'pane_id pane))
              (terminal (alist-get 'terminal_id pane)))
    (puthash (cons server-key pane-id) terminal herdr-agent--panes)
    (when-let* ((session (herdr-agent-find server-key terminal)))
      (setf (herdr-agent-session-pane session) pane-id
            (herdr-agent-session-workspace session) (alist-get 'workspace_id pane)
            (herdr-agent-session-tab session) (alist-get 'tab_id pane)))
    terminal))

(defun herdr-agent--release-pane (server-key pane-id)
  "Detach the session currently mapped to PANE-ID on SERVER-KEY."
  (let* ((key (cons server-key pane-id))
         (terminal (gethash key herdr-agent--panes))
         (session (and terminal (herdr-agent-find server-key terminal))))
    (if session
        (progn
          (herdr-agent-detach session)
          (when (eq (herdr-agent-session-state session) 'stopped)
            (remhash key herdr-agent--panes)))
      (remhash key herdr-agent--panes))))

(defun herdr-agent--handle-event (server-key type data)
  "Apply TYPE's event DATA to SERVER-KEY's indexes."
  (pcase type
    ((or "pane.updated" "pane.moved")
     (when (equal type "pane.moved")
       (when-let* ((previous (alist-get 'previous_pane_id data)))
         (remhash (cons server-key previous) herdr-agent--panes)))
     (herdr-agent--index-pane server-key (herdr-agent--pane data)))
    ("pane.agent_detected"
     (when (alist-get 'released data)
       (herdr-agent--release-pane server-key (alist-get 'pane_id data))))
    ((or "pane.exited" "pane.closed")
     (herdr-agent--release-pane server-key (alist-get 'pane_id data)))))

(defun herdr-agent-subscribe (server-key)
  "Subscribe SERVER-KEY to generic agent lifecycle events."
  (let* ((server-key (herdr-agent--with-server server-key (herdr-server-key)))
         (cached (gethash server-key herdr-agent--subscriptions)))
    (if (and cached
             (cl-every (lambda (process)
                         (and (processp process) (process-live-p process)))
                       cached))
        cached
      (dolist (process cached)
        (when (and (processp process) (process-live-p process))
          (delete-process process)))
      (puthash
       server-key
       (herdr-agent--with-server server-key
         (mapcar (lambda (type)
                   (herdr-subscribe
                    (list type)
                    (lambda (data) (herdr-agent--handle-event server-key type data))))
                 '("pane.agent_detected" "pane.exited" "pane.closed" "pane.updated" "pane.moved")))
       herdr-agent--subscriptions))))

(defun herdr-agent-detach (session)
  "Detach SESSION's Emacs resources without terminating its herdr pane."
  (unless (eq (herdr-agent-session-state session) 'stopped)
    (setf (herdr-agent-session-state session) 'detaching)
    (herdr-agent--with-server (herdr-agent-session-server session)
      (let (errors)
        (setq errors (herdr-agent--cleanup-ownership session))
        (condition-case err
            (herdr-agent--run-adapter session :detach)
          (error (push err errors)))
        (when-let* ((process (herdr-agent-session-attachment-process session)))
          (condition-case err
              (progn
                (set-process-sentinel process (process-get process 'herdr-agent--backend-sentinel))
                (when (process-live-p process) (delete-process process))
                (setf (herdr-agent-session-attachment-process session) nil))
            (error (push err errors))))
        (when-let* ((buffer (herdr-agent-session-buffer session)))
          (condition-case err
              (progn
                (with-current-buffer buffer
                  (remove-hook 'kill-buffer-hook #'herdr-agent--buffer-died t))
                (when (buffer-live-p buffer) (kill-buffer buffer))
                (setf (herdr-agent-session-buffer session) nil))
            (error (push err errors))))
        (setf (herdr-agent-session-cleanup session) errors)
        (unless errors (herdr-agent--unregister session)))))
  session)

(provide 'herdr-agent)
;;; herdr-agent.el ends here
