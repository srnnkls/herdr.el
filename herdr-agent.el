;;; herdr-agent.el --- Manage herdr agent attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Generic lifecycle ownership for herdr agent attachments.

;;; Code:

(require 'cl-lib)
(require 'herdr)

(cl-defstruct (herdr-agent-session
               (:constructor herdr-agent--make-session))
  key server terminal kind name requested-name agent-session project route workspace tab pane
  buffer attachment-process state ownership cleanup adapter adapter-state)

(defvar herdr-agent-harnesses
  '(("claude" :label "Claude Code"
     :arguments ((start) (continue "--continue")
                 (resume "--resume" :reference)))
    ("codex" :label "Codex"
     :arguments ((start) (continue "resume" "--last")
                 (resume "resume" :reference)))
    ("pi" :label "Pi"
     :arguments ((start) (continue "--continue")
                 (resume "--session" :reference))))
  "Harness descriptors keyed by Herdr agent kind.")

(defun herdr-agent-register-harness (kind &rest properties)
  "Register KIND with descriptor PROPERTIES.
PROPERTIES must contain an `:arguments' action alist."
  (unless (and (stringp kind) (plist-member properties :arguments))
    (signal 'wrong-type-argument (list 'herdr-agent-harness kind properties)))
  (setq herdr-agent-harnesses
        (cons (cons kind properties)
              (cl-remove kind herdr-agent-harnesses :key #'car :test #'equal)))
  kind)

(defvar herdr-agent--sessions (make-hash-table :test #'equal)
  "Primary agent sessions keyed by server and terminal.")
(defvar herdr-agent--adapters nil
  "Registered adapters keyed by Herdr agent kind.")
(defvar herdr-agent--adapter-sessions
  (make-hash-table :test #'eq :weakness 'key)
  "Sessions that have captured an adapter.")

(defvar herdr-agent--buffers (make-hash-table :test #'eq)
  "Agent keys keyed by terminal buffers.")
(defvar herdr-agent--projects (make-hash-table :test #'equal)
  "Agent keys keyed by project roots.")
(defvar herdr-agent--panes (make-hash-table :test #'equal)
  "Terminal IDs keyed by server and pane.")
(defvar herdr-agent--subscriptions (make-hash-table :test #'equal)
  "Lifecycle subscription processes keyed by server.")

(defvar herdr-agent-event-functions nil
  "Functions called with server key, event type, and event data.")

(defmacro herdr-agent--with-server (server-key &rest body)
  "Evaluate BODY against SERVER-KEY."
  (declare (indent 1) (debug (form body)))
  `(let ((herdr-socket-path ,server-key)) ,@body))

(defun herdr-agent--canonical-server-key (server-key)
  "Return SERVER-KEY in canonical socket form."
  (herdr-agent--with-server server-key
    (herdr-server-key)))

(defun herdr-agent-find (server-key terminal-id)
  "Return the live session for SERVER-KEY and TERMINAL-ID."
  (gethash (cons (herdr-agent--canonical-server-key server-key) terminal-id)
           herdr-agent--sessions))

(defun herdr-agent--harness (kind &optional noerror)
  "Return KIND's harness descriptor, or nil when NOERROR permits it."
  (or (cdr (assoc kind herdr-agent-harnesses))
      (unless noerror
        (signal 'herdr-error (list (format "unsupported agent kind %s" kind))))))

(defun herdr-agent-set-adapter-state (session state)
  "Set opaque adapter STATE on Herdr SESSION and return STATE."
  (unless (herdr-agent-session-p session)
    (signal 'wrong-type-argument (list 'herdr-agent-session-p session)))
  (setf (herdr-agent-session-adapter-state session) state))

(defun herdr-agent-adapter (kind)
  "Return the adapter registered for agent KIND, or nil."
  (cdr (assoc kind herdr-agent--adapters)))

(defun herdr-agent-register-adapter (kind adapter)
  "Register ADAPTER for KIND and return KIND.
Registering the same ADAPTER again is idempotent."
  (unless (herdr-agent--harness kind t)
    (signal 'herdr-error (list (format "unsupported agent kind %s" kind))))
  (unless (functionp adapter)
    (signal 'wrong-type-argument (list 'functionp adapter)))
  (if-let* ((entry (assoc kind herdr-agent--adapters)))
      (unless (eq (cdr entry) adapter)
        (signal 'herdr-error
                (list (format "adapter already registered for agent kind %s" kind))))
    (push (cons kind adapter) herdr-agent--adapters))
  kind)

(defun herdr-agent--adapter-in-use-p (adapter)
  "Return non-nil when a non-stopped session has captured ADAPTER."
  (let (in-use)
    (maphash (lambda (session _value)
               (when (and (not (eq (herdr-agent-session-state session) 'stopped))
                          (eq (herdr-agent-session-adapter session) adapter))
                 (setq in-use t)))
             herdr-agent--adapter-sessions)
    (maphash (lambda (_key session)
               (when (and (not (eq (herdr-agent-session-state session) 'stopped))
                          (eq (herdr-agent-session-adapter session) adapter))
                 (setq in-use t)))
             herdr-agent--sessions)
    in-use))

(defun herdr-agent-unregister-adapter (kind adapter)
  "Unregister ADAPTER for KIND.
Return nil when KIND has no registered adapter."
  (when-let* ((entry (assoc kind herdr-agent--adapters)))
    (unless (eq (cdr entry) adapter)
      (signal 'herdr-error
              (list (format "different adapter registered for agent kind %s" kind))))
    (when (herdr-agent--adapter-in-use-p adapter)
      (signal 'herdr-error
              (list (format "adapter is in use for agent kind %s" kind))))
    (setq herdr-agent--adapters (delq entry herdr-agent--adapters))
    t))

(defun herdr-agent--kind (agent)
  "Return AGENT's supported kind."
  (let ((kind (alist-get 'agent agent)))
    (herdr-agent--harness kind)
    kind))

(defun herdr-agent--project (root)
  "Return ROOT in canonical form."
  (and root (directory-file-name (file-truename root))))

(defun herdr-agent--name-valid-p (name)
  "Return non-nil when NAME is valid for Herdr."
  (let ((case-fold-search nil))
    (and (stringp name)
         (string-match-p "\\`[a-z][a-z0-9_-]\\{0,31\\}\\'" name))))

(defun herdr-agent--blank-name-p (name)
  "Return non-nil when NAME needs an automatic name."
  (or (null name)
      (and (stringp name) (string-match-p "\\`[[:space:]]*\\'" name))))

(defun herdr-agent--occupied-names (server-key)
  "Return agent names occupied on SERVER-KEY."
  (append
   (delq nil (mapcar (lambda (agent) (alist-get 'name agent))
                     (alist-get 'agents (herdr-api-agent-list))))
   (let (names)
     (maphash (lambda (key session)
                (when (equal (car key) server-key)
                  (push (herdr-agent-session-name session) names)
                  (push (herdr-agent-session-requested-name session) names)))
              herdr-agent--sessions)
     names)))

(defun herdr-agent--available-name (name server-key)
  "Return an unused valid NAME for SERVER-KEY."
  (unless (or (herdr-agent--blank-name-p name)
              (herdr-agent--name-valid-p name))
    (user-error "Invalid Herdr agent name: %s" name))
  (let* ((name (if (herdr-agent--blank-name-p name) "agent" name))
         (occupied (herdr-agent--occupied-names server-key)))
    (if (not (member name occupied))
        name
      (let ((suffix 2)
            candidate)
        (while (progn
                 (setq candidate
                       (format "%s-%d"
                               (substring name 0 (min (length name)
                                                      (- 32 (length (number-to-string suffix)) 1)))
                               suffix))
                 (setq suffix (1+ suffix))
                 (member candidate occupied)))
        candidate))))

(defun herdr-agent--register (session)
  "Register SESSION and its derived indexes."
  (let* ((server-key (herdr-agent--canonical-server-key (herdr-agent-session-server session)))
         (terminal (herdr-agent-session-terminal session))
         (key (cons server-key terminal))
         (project (herdr-agent--project (herdr-agent-session-project session)))
         (buffer (herdr-agent-session-buffer session))
         (pane (herdr-agent-session-pane session)))
    (setf (herdr-agent-session-server session) server-key
          (herdr-agent-session-key session) key
          (herdr-agent-session-project session) project)
    (puthash key session herdr-agent--sessions)
    (when project
      (puthash project (cons key (delete key (gethash project herdr-agent--projects)))
               herdr-agent--projects))
    (when buffer (puthash buffer key herdr-agent--buffers))
    (when pane
      (puthash (cons server-key pane) terminal herdr-agent--panes))
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

(defun herdr-agent--run-adapter (session phase &optional context)
  "Run SESSION's adapter PHASE with optional CONTEXT."
  (let ((adapter
         (or (herdr-agent-session-adapter session)
             (cdr (assoc (herdr-agent-session-kind session)
                         herdr-agent--adapters)))))
    (when adapter
      (setf (herdr-agent-session-adapter session) adapter)
      (puthash session t herdr-agent--adapter-sessions)
      (funcall adapter session phase context))))

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
           (process-put process 'herdr-agent--died t)
           (unless (eq (herdr-agent-session-state session) 'starting)
             (herdr-agent-detach session))))))))

(defun herdr-agent--route (session)
  "Return the herdr session SESSION's terminal is reached through.
The server SESSION was found on is what holds its terminal, so that is
what names the route when the agent itself reported no session; only
a server no session answers for falls back to the scope in hand."
  (or (herdr-agent-session-route session)
      (herdr-session-for-socket (herdr-agent-session-server session))
      herdr-session))

(defun herdr-agent--attach (session &optional display)
  "Attach SESSION's terminal and record its Emacs resources.
DISPLAY shows the buffer once attached."
  (let ((buffer
         (herdr-attach-terminal
          (herdr-agent-session-terminal session)
          :session (herdr-agent--route session)
          :label (herdr-agent-session-name session)
          :directory (herdr-agent-session-project session)
          :takeover herdr-attach-takeover :display display)))
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
        (unless (and (buffer-live-p buffer) (processp process) (process-live-p process))
          (signal 'herdr-error (list "terminal attachment did not return a buffer and process")))
        (herdr-claim-buffer buffer (herdr-agent-session-terminal session)
                            (herdr-agent--route session))
        (setf (herdr-agent-session-buffer session) buffer
              (herdr-agent-session-attachment-process session) process)
        (herdr-agent--watch-attachment session)
        (unless (and (buffer-live-p buffer) (process-live-p process)
                     (not (process-get process 'herdr-agent--died)))
          (signal 'herdr-error (list "terminal attachment did not return a buffer and process")))
        (herdr-agent--register session)
        (herdr-agent--watch-buffer session)
        (unless (and (buffer-live-p buffer) (process-live-p process)
                     (eq (herdr-agent-session-state session) 'starting))
          (signal 'herdr-error (list "terminal attachment did not return a buffer and process")))
        (herdr-agent--run-adapter session :attached)
        (unless (and (buffer-live-p buffer) (process-live-p process)
                     (eq (herdr-agent-session-state session) 'starting))
          (signal 'herdr-error (list "terminal attachment did not return a buffer and process")))
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
  (let ((terminal (alist-get 'terminal_id agent))
        (server-key (herdr-agent--canonical-server-key server-key)))
    (unless terminal
      (signal 'herdr-error (list "agent has no terminal_id")))
    (setf (herdr-agent-session-key session) (cons server-key terminal)
          (herdr-agent-session-server session) server-key
          (herdr-agent-session-terminal session) terminal
          (herdr-agent-session-kind session) (herdr-agent--kind agent)
          (herdr-agent-session-name session) (or (alist-get 'name agent) terminal)
          (herdr-agent-session-agent-session session) (alist-get 'agent_session agent)
          (herdr-agent-session-project session) (herdr-agent--project (herdr-entry-directory agent))
          (herdr-agent-session-route session) (or (alist-get 'session agent)
                                                  (herdr-agent-session-route session))
          (herdr-agent-session-workspace session) (alist-get 'workspace_id agent)
          (herdr-agent-session-tab session) (alist-get 'tab_id agent)
          (herdr-agent-session-pane session) (alist-get 'pane_id agent))
    session))

(defun herdr-agent--subscribe-if-live (server-key)
  "Subscribe SERVER-KEY when it is available."
  (condition-case err
      (herdr-agent-subscribe server-key)
    (herdr-error
     (unless (or (string-prefix-p "no herdr socket" (cadr err))
                 (string-prefix-p "cannot reach herdr" (cadr err)))
       (signal (car err) (cdr err))))))

(defun herdr-agent--subscribe-before-start (server-key)
  "Subscribe SERVER-KEY before creating startup resources."
  (herdr-agent-subscribe server-key))

(cl-defun herdr-agent-adopt (agent &key session server-key (attach t) (display t))
  "Adopt AGENT on SESSION, optionally deferring ATTACH.
SESSION defaults to AGENT's session.  SERVER-KEY supports legacy callers
without a session; session routing takes precedence.
DISPLAY shows the attached buffer; nil keeps adoption driven by
events from replacing whatever terminal is on screen."
  (let* ((route (or session (alist-get 'session agent)))
         (agent (if route (cons (cons 'session route) agent) agent))
         (server-key (herdr-agent--canonical-server-key
                      (if route (herdr-session-socket route)
                        (or server-key (alist-get 'server_key agent) (herdr-server-key)))))
         (terminal (alist-get 'terminal_id agent)))
    (unless terminal
      (signal 'herdr-error (list "agent has no terminal_id")))
    (let ((existing (herdr-agent-find server-key terminal)))
      (herdr-agent--subscribe-if-live server-key)
      (when (and existing (not (herdr-agent--live-session-p existing)))
        (herdr-agent-detach existing)
        (when (not (eq (herdr-agent-session-state existing) 'stopped))
          (signal 'herdr-error (list "agent cleanup is still pending")))
        (setq existing nil))
      (if existing
          (progn
            (herdr-agent--run-adapter existing :adopted agent)
            existing)
        (let ((session
               (herdr-agent--make-session
                :state 'starting)))
          (herdr-agent--apply-agent session agent server-key)
          (unless attach
            (herdr-agent--register session))
          (condition-case err
              (progn
                (herdr-agent--run-adapter session :adopted agent)
                (when attach (herdr-agent--attach session display))
                (when attach
                  (setf (herdr-agent-session-state session) 'attached
                        (herdr-agent-session-ownership session) nil))
                session)
            (error
             (herdr-agent--rollback session)
             (signal (car err) (cdr err)))))))))

(defun herdr-agent--request-target (_server-key terminal-id &optional _agent)
  "Return a Herdr agent target for TERMINAL-ID."
  terminal-id)

(defun herdr-agent--refresh-session (session agent server-key)
  "Refresh SESSION from AGENT on SERVER-KEY."
  (let* ((key (herdr-agent-session-key session))
         (project (herdr-agent-session-project session))
         (pane (herdr-agent-session-pane session))
         (keys (delete key (gethash project herdr-agent--projects))))
    (remhash key herdr-agent--sessions)
    (if keys
        (puthash project keys herdr-agent--projects)
      (remhash project herdr-agent--projects))
    (when pane
      (remhash (cons (herdr-agent-session-server session) pane)
               herdr-agent--panes))
    (herdr-agent--apply-agent session agent server-key)
    (herdr-agent--register session)))

(defun herdr-agent--fresh-agent (server-key terminal-id)
  "Return TERMINAL-ID's fresh agent record on SERVER-KEY."
  (herdr-agent--with-server server-key
    (cl-find terminal-id (alist-get 'agents (herdr-api-agent-list))
             :key (lambda (agent) (alist-get 'terminal_id agent)) :test #'equal)))

(defun herdr-agent--call-with-request-target (server-key terminal-id function)
  "Call FUNCTION with a compatible Herdr target for SERVER-KEY and TERMINAL-ID."
  (condition-case err
      (funcall function (herdr-agent--request-target server-key terminal-id))
    (herdr-api-error
     (if (equal (nth 1 err) "agent_not_found")
         (if-let* ((agent (herdr-agent--fresh-agent server-key terminal-id)))
             (let ((session (herdr-agent-find server-key terminal-id))
                   (last-error err)
                   result)
               (when session
                 (herdr-agent--refresh-session session agent server-key))
               (catch 'done
                 (dolist (target (delq nil (list (alist-get 'pane_id agent)
                                                 (alist-get 'name agent))))
                   (condition-case retry-error
                       (throw 'done (setq result (funcall function target)))
                     (herdr-api-error
                      (setq last-error retry-error))))
                 (signal (car last-error) (cdr last-error)))
               result)
           (signal (car err) (cdr err)))
       (signal (car err) (cdr err))))))

(defun herdr-agent--interactive-ready-p (agent)
  "Return non-nil when AGENT can accept interactive input."
  (or (alist-get 'interactive_ready agent)
      (and (alist-get 'agent agent)
           (equal (alist-get 'agent_status agent) "idle"))))

(defun herdr-agent--ready-agent (agent server-key timeout-ms)
  "Return AGENT after it becomes interactive-ready on SERVER-KEY within TIMEOUT-MS."
  (let ((terminal (alist-get 'terminal_id agent))
        (deadline (+ (float-time) (/ timeout-ms 1000.0))))
    (unless terminal
      (signal 'herdr-error (list "agent.start did not return a terminal_id")))
    (while (not (herdr-agent--interactive-ready-p agent))
      (when (>= (float-time) deadline)
        (signal 'herdr-error (list "agent did not become interactive-ready")))
      (setq agent
            (condition-case err
                (or (alist-get 'agent
                               (herdr-api-agent-get
                                (herdr-agent--request-target
                                 server-key terminal agent)))
                    (signal 'herdr-error
                            (list "agent.get did not return an agent")))
              (herdr-api-error
               (if (equal (cadr err) "agent_not_found")
                   agent
                 (signal (car err) (cdr err))))))
      (unless (herdr-agent--interactive-ready-p agent)
        (sleep-for 0.1)))
    agent))

(defun herdr-agent--start-agent (kind name pane-id args timeout-ms)
  "Start KIND named NAME in PANE-ID with ARGS within TIMEOUT-MS."
  (let ((deadline (+ (float-time) (/ (or timeout-ms 30000) 1000.0))))
    (catch 'started
      (while t
        (condition-case err
            (throw 'started
                   (if timeout-ms
                       (herdr-api-agent-start kind name pane-id
                                              :args args :timeout-ms timeout-ms)
                     (herdr-api-agent-start kind name pane-id :args args)))
          (herdr-api-error
           (unless (and (equal (cadr err) "agent_pane_busy")
                        (< (float-time) deadline))
             (signal (car err) (cdr err)))
           (sleep-for 0.1)))))))

(cl-defun herdr-agent-start-in-pane
    (kind name pane &key server-key args (attach t) session timeout-ms)
  "Start KIND named NAME in PANE on SERVER-KEY.
ARGS, ATTACH, SESSION, and TIMEOUT-MS control startup."
  (let* ((server-key (herdr-agent--canonical-server-key
                      (or server-key (herdr-server-key))))
         (start-timeout-ms (or timeout-ms 30000))
         (pane-id (alist-get 'pane_id pane))
         (session (or session
                      (herdr-agent--make-session
                       :server server-key :kind kind :name name :pane pane-id
                       :workspace (alist-get 'workspace_id pane)
                       :tab (alist-get 'tab_id pane) :state 'starting))))
    (herdr-agent--subscribe-before-start server-key)
    (condition-case err
        (let* ((result (herdr-agent--with-server server-key
                         (herdr-agent--start-agent kind name pane-id args timeout-ms)))
               (agent (alist-get 'agent result)))
          (unless agent (signal 'herdr-error (list "agent.start did not return an agent")))
          (herdr-agent--apply-agent
           session
           (herdr-agent--with-server server-key
             (herdr-agent--ready-agent agent server-key start-timeout-ms))
           server-key)
          (unless attach
            (herdr-agent--register session))
          (when attach (herdr-agent--attach session t))
          (unless attach
            (herdr-agent--run-adapter session :attached))
          (setf (herdr-agent-session-state session) 'attached
                (herdr-agent-session-ownership session) nil)
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
        (had-tab (plist-get (herdr-agent-session-ownership session) :tab))
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
            (if (herdr-agent--workspace-empty-p workspace)
                (progn
                  (herdr-api-workspace-close workspace)
                  (setf (plist-get ownership :workspace) nil))
              (unless had-tab
                (setf (plist-get ownership :workspace) nil)))
          (error (push err errors)))))
    (setf (herdr-agent-session-ownership session)
          (and (or (plist-get ownership :tab) (plist-get ownership :workspace)) ownership))
    errors))

(defun herdr-agent--rollback (session)
  "Clean SESSION's transaction-owned startup resources."
  (if (plist-get (herdr-agent-session-ownership session) :preterminal)
      (setf (herdr-agent-session-state session) 'detaching
            (herdr-agent-session-cleanup session)
            (or (herdr-agent-session-cleanup session) '(preterminal)))
    (unless (eq (herdr-agent-session-state session) 'detaching)
      (herdr-agent-detach session)))
  (when (and (eq (herdr-agent-session-state session) 'detaching)
             (or (herdr-agent-session-cleanup session)
                 (herdr-agent-session-ownership session)))
    (herdr-agent--register session))
  session)

(cl-defun herdr-agent-start-session
    (kind name &key server-key project-root workspace args (attach t) timeout-ms)
  "Start KIND named NAME on SERVER-KEY for PROJECT-ROOT in WORKSPACE with ARGS.
ATTACH controls terminal attachment; TIMEOUT-MS limits startup."
  (let* ((project-root (or project-root
                           (funcall herdr-project-root-function)
                           default-directory))
         (project-session (and (not server-key) (herdr-session-for project-root)))
         (server-key (if server-key
                         (herdr-agent--canonical-server-key server-key)
                       (herdr-with-session project-session
                         (herdr-agent--canonical-server-key (herdr-server-key))))))
    (herdr-with-session project-session
      (unless (or (herdr-agent--blank-name-p name)
                  (herdr-agent--name-valid-p name))
        (user-error "Invalid Herdr agent name: %s" name))
      (herdr-agent--with-server server-key
        (herdr-start-server-if-needed)
        (when-let* ((existing (herdr-agent-find server-key nil)))
          (herdr-agent-detach existing)
          (unless (eq (herdr-agent-session-state existing) 'stopped)
            (signal 'herdr-error (list "agent cleanup is still pending"))))
        (herdr-agent--subscribe-before-start server-key)
        (let* ((name (herdr-agent--available-name name server-key))
               (session (herdr-agent--make-session
                         :server server-key :kind kind :name name :requested-name name
                         :project (herdr-agent--project project-root) :state 'starting)))
          (condition-case err
              (let* ((env (herdr-agent--run-adapter session :prepare))
                     (args (or (herdr-agent--run-adapter session :arguments args)
                               args))
                     (workspace (or workspace (herdr-workspace-label project-root)))
                     (existing (herdr-workspace-id workspace))
                     (created
                      (let ((herdr--open-tab-cleanup-failed-function
                             (lambda (created)
                               (let ((tab (alist-get 'tab created))
                                     (pane (alist-get 'root_pane created)))
                                 (setf (herdr-agent-session-workspace session)
                                       (or (alist-get 'workspace_id (alist-get 'workspace created))
                                           (alist-get 'workspace_id pane))
                                       (herdr-agent-session-tab session) (alist-get 'tab_id tab)
                                       (herdr-agent-session-pane session) (alist-get 'pane_id pane)
                                       (herdr-agent-session-ownership session)
                                       (list :tab (alist-get 'tab_id tab)
                                             :workspace (herdr-agent-session-workspace session)
                                             :preterminal t))
                                 (unless (herdr-agent-session-cleanup session)
                                   (condition-case err
                                       (progn
                                         (herdr-agent--run-adapter session :detach)
                                         (setf (herdr-agent-session-cleanup session)
                                               '(:adapter-detached)))
                                     (error
                                      (setf (herdr-agent-session-state session) 'detaching
                                            (herdr-agent-session-cleanup session) (list err)))))
                                 (unless (memq :preterminal (herdr-agent-session-cleanup session))
                                   (setf (herdr-agent-session-cleanup session)
                                         (cons :preterminal
                                               (herdr-agent-session-cleanup session)))))))
                            (workspace-close (symbol-function 'herdr-api-workspace-close)))
                        (cl-letf (((symbol-function 'herdr-api-workspace-close)
                                   (lambda (&rest arguments)
                                     (unless (herdr-agent-session-cleanup session)
                                       (condition-case err
                                           (progn
                                             (herdr-agent--run-adapter session :detach)
                                             (setf (herdr-agent-session-cleanup session)
                                                   '(:adapter-detached)))
                                         (error
                                          (setf (herdr-agent-session-state session) 'detaching
                                                (herdr-agent-session-cleanup session) (list err)))))
                                     (apply workspace-close arguments))))
                          (herdr-open-tab :cwd project-root :label name :workspace workspace :env env))))
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
             (signal (car err) (cdr err)))))))))

(defun herdr-agent-attach-entry (entry)
  "Attach supported agent ENTRY through the generic lifecycle root."
  (when (and (herdr-agent--harness (alist-get 'agent entry) t)
             (alist-get 'terminal_id entry))
    (herdr-agent-session-buffer
     (herdr-agent-adopt entry :session (or (alist-get 'session entry) herdr-session)))))

(defun herdr-agent--pane (data)
  "Return pane data carried by DATA."
  (or (alist-get 'pane data) data))

(defun herdr-agent--index-pane (server-key pane)
  "Update SERVER-KEY's pane mapping from PANE."
  (let ((server-key (herdr-agent--canonical-server-key server-key)))
    (when-let* ((pane-id (alist-get 'pane_id pane))
                (terminal (alist-get 'terminal_id pane)))
      (puthash (cons server-key pane-id) terminal herdr-agent--panes)
      (when-let* ((session (herdr-agent-find server-key terminal)))
        (setf (herdr-agent-session-pane session) pane-id
              (herdr-agent-session-workspace session) (alist-get 'workspace_id pane)
              (herdr-agent-session-tab session) (alist-get 'tab_id pane)))
      terminal)))

(defun herdr-agent--release-pane (server-key pane-id)
  "Detach the session currently mapped to PANE-ID on SERVER-KEY."
  (let* ((server-key (herdr-agent--canonical-server-key server-key))
         (key (cons server-key pane-id))
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
  (setq server-key (herdr-agent--canonical-server-key server-key))
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
     (herdr-agent--release-pane server-key (alist-get 'pane_id data))))
  (run-hook-with-args 'herdr-agent-event-functions server-key type data))

(defun herdr-agent-subscribe (server-key)
  "Subscribe SERVER-KEY to generic agent lifecycle events."
  (let* ((server-key (herdr-agent--canonical-server-key server-key))
         (cached (gethash server-key herdr-agent--subscriptions)))
    (if (and (= (length cached) 5)
             (cl-every (lambda (process)
                         (and (processp process) (process-live-p process)))
                       cached))
        cached
      (dolist (process cached)
        (when (and (processp process) (process-live-p process))
          (delete-process process)))
      (remhash server-key herdr-agent--subscriptions)
      (let (candidates)
        (condition-case err
            (progn
              (dolist (type '("pane.agent_detected" "pane.exited" "pane.closed"
                              "pane.updated" "pane.moved"))
                (let ((process
                       (herdr-agent--with-server server-key
                         (herdr-subscribe
                          (list type)
                          (lambda (data)
                            (herdr-agent--handle-event server-key type data))))))
                  (unless (and (processp process) (process-live-p process))
                    (signal 'herdr-error (list "subscription did not return a live process")))
                  (push process candidates)))
              (setq candidates (nreverse candidates))
              (unless (cl-every (lambda (process)
                                  (and (processp process) (process-live-p process)))
                                candidates)
                (signal 'herdr-error (list "subscription batch contains a dead process")))
              (puthash server-key candidates herdr-agent--subscriptions)
              candidates)
          (error
           (dolist (process candidates)
             (when (and (processp process) (process-live-p process))
               (delete-process process)))
           (if (eq (car err) 'herdr-error)
               (signal (car err) (cdr err))
             (signal 'herdr-error (list (error-message-string err))))))))))

(defun herdr-agent-detach (session)
  "Detach SESSION's Emacs resources without terminating its herdr pane."
  (unless (eq (herdr-agent-session-state session) 'stopped)
    (setf (herdr-agent-session-state session) 'detaching)
    (when-let* ((buffer (herdr-agent-session-buffer session))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer (herdr--terminal-closing)))
    (herdr-agent--with-server (herdr-agent-session-server session)
      (let (errors adapter-detached)
        (setq errors (herdr-agent--cleanup-ownership session))
        (condition-case _err
            (unless (memq :adapter-detached (herdr-agent-session-cleanup session))
              (herdr-agent--run-adapter session :detach)
              (setq adapter-detached t))
          (error (push 'adapter errors)))
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
        (setf (herdr-agent-session-cleanup session)
              (append (and (or adapter-detached
                               (memq :adapter-detached
                                     (herdr-agent-session-cleanup session)))
                           '(:adapter-detached))
                      errors))
        (unless (or errors (herdr-agent-session-ownership session))
          (setf (herdr-agent-session-cleanup session) nil)
          (herdr-agent--unregister session)))))
  session)

(defun herdr-agent--native-args (kind action &optional reference)
  "Return arguments for native KIND ACTION and optional REFERENCE."
  (let* ((arguments (plist-get (herdr-agent--harness kind) :arguments))
         (entry (assq action arguments)))
    (unless entry
      (signal 'herdr-error
              (list (format "unsupported %s action for agent kind %s" action kind))))
    (mapcar (lambda (argument)
              (if (eq argument :reference) reference argument))
            (cdr entry))))

(cl-defun herdr-agent-start
    (kind name &key server-key project-root workspace (attach t) timeout-ms)
  "Start native KIND named NAME on SERVER-KEY for PROJECT-ROOT in WORKSPACE.
ATTACH controls terminal attachment; TIMEOUT-MS limits startup."
  (herdr-agent-start-session
   kind name :server-key server-key :project-root project-root :workspace workspace
   :args (herdr-agent--native-args kind 'start) :attach attach :timeout-ms timeout-ms))

(cl-defun herdr-agent-continue
    (kind name &key server-key project-root workspace (attach t) timeout-ms)
  "Continue the most recent native KIND session named NAME on SERVER-KEY.
PROJECT-ROOT and WORKSPACE select its location; ATTACH controls terminal
attachment; TIMEOUT-MS limits startup."
  (herdr-agent-start-session
   kind name :server-key server-key :project-root project-root :workspace workspace
   :args (herdr-agent--native-args kind 'continue) :attach attach :timeout-ms timeout-ms))

(cl-defun herdr-agent-resume
    (kind name reference &key server-key project-root workspace (attach t) timeout-ms)
  "Resume native KIND session REFERENCE named NAME on SERVER-KEY.
PROJECT-ROOT and WORKSPACE select its location; ATTACH controls terminal
attachment; TIMEOUT-MS limits startup."
  (unless (and (stringp reference) (> (length reference) 0))
    (user-error "A session reference is required"))
  (herdr-agent-start-session
   kind name :server-key server-key :project-root project-root :workspace workspace
   :args (herdr-agent--native-args kind 'resume reference)
   :attach attach :timeout-ms timeout-ms))

(defun herdr-agent--in-project-p (agent project)
  "Return non-nil when AGENT belongs to PROJECT."
  (or (null project)
      (when-let* ((cwd (herdr-entry-directory agent)))
        (string-prefix-p (file-name-as-directory (herdr-agent--project project))
                         (file-name-as-directory (herdr-agent--project cwd))))))

(defun herdr-agent-resolve-target (target agents project mru)
  "Return TARGET from AGENTS, or PROJECT's project-local MRU target."
  (if target
      (or (cl-find target agents :key (lambda (agent) (alist-get 'terminal_id agent))
                   :test #'equal)
          (user-error "Unknown agent: %s" target))
    (or (cl-loop for terminal in mru
                 for agent = (cl-find terminal agents
                                      :key (lambda (item) (alist-get 'terminal_id item))
                                      :test #'equal)
                 when (and agent (herdr-agent--in-project-p agent project))
                 return agent)
        (user-error "No recent agent for this project"))))

(defun herdr-agent--current-target ()
  "Return the agent target attached to the current buffer."
  (gethash (current-buffer) herdr-agent--buffers))

(defun herdr-agent--visible-target ()
  "Return the first visible target for the current project."
  (cl-loop for key in (gethash (herdr-agent--project default-directory)
                               herdr-agent--projects)
           for session = (gethash key herdr-agent--sessions)
           for buffer = (and session (herdr-agent-session-buffer session))
           when (and (herdr-agent--live-session-p session)
                     (buffer-live-p buffer)
                     (equal key (gethash buffer herdr-agent--buffers))
                     (get-buffer-window buffer t))
           return key))

(defun herdr-agent--project-target ()
  "Return the most recent live target for the current project."
  (cl-find-if (lambda (key)
                (when-let* ((session (gethash key herdr-agent--sessions)))
                  (herdr-agent--live-session-p session)))
              (gethash (herdr-agent--project default-directory) herdr-agent--projects)))

(defun herdr-agent--public-target (target)
  "Return TARGET's server and terminal identity."
  (or (cond
       ((consp target)
        (cons (herdr-agent--canonical-server-key (car target)) (cdr target)))
       (target (cons (herdr-server-key) target))
       ((herdr-agent--current-target))
       ((herdr-agent--visible-target))
       ((herdr-agent--project-target)))
      (user-error "No recent agent for this project")))

(defun herdr-agent-resolve-session (&optional target)
  "Return the live session identified by TARGET."
  (pcase-let ((`(,server-key . ,terminal)
               (herdr-agent--public-target target)))
    (or (herdr-agent-find server-key terminal)
        (user-error "Unknown agent: %s" terminal))))

(defun herdr-agent-list (&optional server-key)
  "Return the agents reported by herdr on SERVER-KEY."
  (herdr-agent--with-server (or server-key (herdr-server-key))
    (append (alist-get 'agents (herdr-api-agent-list)) nil)))

(defun herdr-agent-switch (target)
  "Focus TARGET in herdr and show its terminal buffer."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (prog1
        (herdr-agent--with-server server-key
          (herdr-agent--call-with-request-target
           server-key terminal
           (lambda (request-target)
             (herdr-api-agent-focus request-target)
             (if-let* ((buffer (herdr-terminal-buffer terminal server-key)))
                 (herdr-display-buffer buffer)
               (when-let* ((agent (alist-get 'agent (herdr-api-agent-get request-target))))
                 (herdr-attach-entry (cons (cons 'server_key server-key) agent)))))))
      (herdr--record-session-target (cons server-key terminal)))))

(defun herdr-agent-rename (target name)
  "Rename TARGET to NAME."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (herdr-api-agent-rename request-target :name name))))))

(defun herdr-agent-status (target)
  "Return the status of TARGET."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (let ((status (alist-get 'agent (herdr-api-agent-get request-target))))
           (append status
                   (when-let* ((session (herdr-agent-find server-key terminal)))
                     (herdr-agent--run-adapter session :status)))))))))

(defun herdr-agent-stop (target)
  "Stop TARGET by closing its pane."
  (unless target
    (user-error "An agent target is required"))
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (when-let* ((agent (alist-get 'agent (herdr-api-agent-get request-target)))
                     (pane-id (alist-get 'pane_id agent)))
           (herdr-api-pane-close pane-id)))))))

(defun herdr-agent-stop-all ()
  "Stop all agents reported by herdr."
  (let ((server-key (herdr-server-key)))
    (herdr-agent--with-server server-key
      (dolist (agent (herdr-agent-list))
        (when-let* ((pane-id (alist-get 'pane_id agent)))
          (herdr-api-pane-close pane-id))))))

(defun herdr-agent-send-text (target text)
  "Send TEXT directly to TARGET's pane."
  (let ((session (herdr-agent-resolve-session target)))
    (herdr-agent--with-server (herdr-agent-session-server session)
      (herdr-api-pane-send-text (herdr-agent-session-pane session) text))))

(defun herdr-agent-prompt (target text)
  "Send TEXT to TARGET through herdr's agent API."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (prog1
        (herdr-agent--with-server server-key
          (herdr-agent--call-with-request-target
           server-key terminal
           (lambda (request-target)
             (herdr-api-agent-prompt request-target text))))
      (herdr--record-session-target (cons server-key terminal)))))

(defvar herdr-send-context-functions nil
  "Functions returning context text for a selected agent entry.
Each function receives the entry and may return a string, or nil to let
another provider handle it.  `herdr-default-send-context' is the fallback.")

(defun herdr-default-send-context (_entry)
  "Return the active region or current line as agent context."
  (let* ((bounds (if (use-region-p)
                     (cons (region-beginning) (region-end))
                   (cons (line-beginning-position) (line-end-position))))
         (beginning (car bounds))
         (end (cdr bounds))
         (last-position (if (> end beginning) (1- end) beginning))
         start-line end-line)
    (save-restriction
      (widen)
      (setq start-line (line-number-at-pos beginning)
            end-line (line-number-at-pos last-position)))
    (format "Emacs context\n%s: %s:%s\nmode: %s\n\n```\n%s\n```"
            (if buffer-file-name "file" "buffer")
            (if buffer-file-name
                (expand-file-name buffer-file-name)
              (buffer-name))
            (if (= start-line end-line)
                start-line
              (format "%d-%d" start-line end-line))
            major-mode
            (string-trim-right (buffer-substring-no-properties beginning end)))))

(defun herdr-agent--send-context (entry)
  "Return context for agent ENTRY from the configured providers."
  (or (run-hook-with-args-until-success 'herdr-send-context-functions entry)
      (herdr-default-send-context entry)))

(defun herdr-agent--send-candidates ()
  "Return every running agent session eligible to receive context."
  (cl-remove-if-not
   (lambda (entry)
     (and (alist-get 'agent entry)
          (alist-get 'terminal_id entry)
          (herdr--entry-target entry)))
   (herdr-sessions)))

(defun herdr-agent--entry-project (entry)
  "Return the project root for agent ENTRY, or nil."
  (when-let* ((directory (herdr-entry-directory entry)))
    (condition-case nil
        (funcall herdr-project-root-function directory)
      (file-error nil))))

(defun herdr-agent--send-scope-entries (entries scope)
  "Filter agent ENTRIES for send SCOPE."
  (pcase scope
    ('all entries)
    ('project
     (let* ((directory (or (and buffer-file-name
                                (file-name-directory buffer-file-name))
                           default-directory))
            (project (or (funcall herdr-project-root-function directory)
                         (user-error "Current buffer is not in a project"))))
       (cl-remove-if-not
        (lambda (entry)
          (when-let* ((entry-project (herdr-agent--entry-project entry)))
            (herdr--same-directory-p project entry-project)))
        entries)))
    ('workspace
     (let ((workspace (or (herdr-current-workspace-label)
                          (user-error "No current editor workspace"))))
       (cl-remove-if-not
        (lambda (entry)
          (when-let* ((directory (herdr-entry-directory entry)))
            (equal workspace (herdr-workspace-label directory))))
        entries)))
    (_ (error "Unknown send scope: %S" scope))))

(defun herdr-agent--last-send-entry (entries scope)
  "Return the most recently used member of ENTRIES for SCOPE."
  (or (cl-loop for target in herdr--recent-session-targets
               thereis (cl-find target entries :key #'herdr--entry-target
                                :test #'equal))
      (user-error "No recent herdr agent in the current %s"
                  (pcase scope
                    ('all "session set")
                    ('project "project")
                    ('workspace "workspace")))))

(defun herdr-agent--send-session (scope last)
  "Send context to an agent in SCOPE, selecting by LAST when non-nil."
  (let* ((all (herdr-agent--send-candidates))
         (_ (herdr--prune-session-targets all))
         (entries (herdr-agent--send-scope-entries all scope))
         (entry (if last
                    (herdr-agent--last-send-entry entries scope)
                  (herdr-read-entry "Send to agent session: " entries)))
         (target (herdr--entry-target entry)))
    (herdr-agent-prompt target (herdr-agent--send-context entry))))

;;;###autoload
(defun herdr-send-session ()
  "Send context at point to an agent selected from every session."
  (interactive)
  (herdr-agent--send-session 'all nil))

;;;###autoload
(defun herdr-send-last-session ()
  "Send context at point to the last-used agent across all sessions."
  (interactive)
  (herdr-agent--send-session 'all t))

;;;###autoload
(defun herdr-send-project-session ()
  "Send context at point to a selected agent in the current project."
  (interactive)
  (herdr-agent--send-session 'project nil))

;;;###autoload
(defun herdr-send-last-project-session ()
  "Send context at point to the last-used agent in the current project."
  (interactive)
  (herdr-agent--send-session 'project t))

;;;###autoload
(defun herdr-send-workspace-session ()
  "Send context at point to a selected agent in the current workspace."
  (interactive)
  (herdr-agent--send-session 'workspace nil))

;;;###autoload
(defun herdr-send-last-workspace-session ()
  "Send context at point to the last-used agent in the current workspace."
  (interactive)
  (herdr-agent--send-session 'workspace t))

;;;; Messages

(defvar herdr-message-history nil
  "Messages sent to agents, most recent first.
Completion candidates and minibuffer history for `herdr-message-session'.")

(defvar-local herdr-message--target nil
  "Agent target the current message buffer sends to.")

(defvar-local herdr-message--context nil
  "Context text captured when the current message buffer was opened.")

(defvar-local herdr-message--window-configuration nil
  "Window configuration to restore when the message buffer closes.")

(defvar herdr-message-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c '") #'herdr-message-edit-from-minibuffer)
    map)
  "Keys added to the minibuffer while reading an agent message.")

(defvar herdr-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'herdr-message-send)
    (define-key map (kbd "C-c C-k") #'herdr-message-cancel)
    map)
  "Keymap for `herdr-message-mode'.")

(define-derived-mode herdr-message-mode text-mode "Herdr-Message"
  "Major mode for composing a message to a herdr agent.
\\<herdr-message-mode-map>\\[herdr-message-send] sends the message with the
context captured when the buffer opened; \\[herdr-message-cancel] discards it.")

(defun herdr-message--context (entry)
  "Return message context for agent ENTRY from the current buffer.
Providers on `herdr-send-context-functions' answer first; without one,
only file-visiting buffers contribute their region or current line."
  (or (run-hook-with-args-until-success 'herdr-send-context-functions entry)
      (and buffer-file-name (herdr-default-send-context entry))))

(defun herdr-message--compose (text context)
  "Return TEXT followed by a barrier and CONTEXT when CONTEXT is non-nil."
  (if context
      (concat text "\n\n---\n" (string-trim-right context))
    text))

(defvar herdr-message-compose-functions nil
  "Functions composing the prompt sent for a message.
Each receives the agent target, the trimmed message text, and the context
string or nil, and returns the prompt to send or nil to defer.  When none
returns a prompt, `herdr-message--compose' appends the context under a
barrier.")

(defun herdr-message--send (target text context)
  "Send TEXT with CONTEXT to agent TARGET and record TEXT in history."
  (let ((text (string-trim text)))
    (when (string-empty-p text)
      (user-error "Message is empty"))
    (add-to-history 'herdr-message-history text)
    (herdr-agent-prompt target
                        (or (run-hook-with-args-until-success
                             'herdr-message-compose-functions target text context)
                            (herdr-message--compose text context)))))

(defun herdr-message--target-label (target)
  "Return a short label for agent TARGET."
  (or (when-let* ((entry (cl-find target (herdr-sessions)
                                  :key #'herdr--entry-target :test #'equal)))
        (herdr--entry-label entry))
      (format "%s" (cdr target))))

(defun herdr-message--context-summary (context)
  "Return the file or buffer location line of CONTEXT text, or nil."
  (when context
    (seq-some (lambda (line)
                (and (string-match "\\`\\(?:file\\|buffer\\): \\(.+\\)" line)
                     (match-string 1 line)))
              (split-string context "\n"))))

(defun herdr-message--edit (target draft context)
  "Open a message buffer for TARGET holding DRAFT, sending with CONTEXT."
  (let ((configuration (current-window-configuration))
        (buffer (get-buffer-create "*herdr message*"))
        (summary (herdr-message--context-summary context)))
    (with-current-buffer buffer
      (herdr-message-mode)
      (setq herdr-message--target target
            herdr-message--context context
            herdr-message--window-configuration configuration
            header-line-format
            (format " Message to %s%s  —  C-c C-c send, C-c C-k cancel"
                    (herdr-message--target-label target)
                    (if summary (format "  [%s]" summary) "")))
      (erase-buffer)
      (when draft (insert draft)))
    (pop-to-buffer buffer)
    buffer))

(defun herdr-message--close ()
  "Kill the current message buffer and restore its window configuration."
  (let ((configuration herdr-message--window-configuration))
    (kill-buffer (current-buffer))
    (when configuration
      (set-window-configuration configuration))))

(defun herdr-message-send ()
  "Send the current message buffer to its agent."
  (interactive)
  (unless (derived-mode-p 'herdr-message-mode)
    (user-error "Not in a herdr message buffer"))
  (herdr-message--send herdr-message--target
                       (buffer-substring-no-properties (point-min) (point-max))
                       herdr-message--context)
  (herdr-message--close))

(defun herdr-message-cancel ()
  "Discard the current message buffer."
  (interactive)
  (unless (derived-mode-p 'herdr-message-mode)
    (user-error "Not in a herdr message buffer"))
  (herdr-message--close))

(defvar herdr-message--pending nil
  "Target and context of the message being read in the minibuffer.")

(defun herdr-message-edit-from-minibuffer ()
  "Leave the minibuffer and continue the message in a full buffer."
  (interactive)
  (let ((draft (minibuffer-contents))
        (pending herdr-message--pending))
    (throw 'exit
           (lambda ()
             (herdr-message--edit (car pending) draft (cdr pending))))))

(defun herdr-message--read (target context)
  "Read a message for TARGET and send it with CONTEXT.
\\<herdr-message-minibuffer-map>\\[herdr-message-edit-from-minibuffer] in the
minibuffer moves the draft to a `herdr-message-mode' buffer instead."
  (let ((herdr-message--pending (cons target context)))
    (minibuffer-with-setup-hook
        (lambda ()
          (use-local-map (make-composed-keymap herdr-message-minibuffer-map
                                               (current-local-map))))
      (let ((text (completing-read "Message: " herdr-message-history
                                   nil nil nil 'herdr-message-history)))
        (herdr-message--send target text context)))))

(defun herdr-message--session (scope last)
  "Message an agent in SCOPE, selecting by LAST when non-nil."
  (let* ((all (herdr-agent--send-candidates))
         (_ (herdr--prune-session-targets all))
         (entries (herdr-agent--send-scope-entries all scope))
         (entry (if last
                    (herdr-agent--last-send-entry entries scope)
                  (herdr-read-entry "Message agent: " entries)))
         (target (herdr--entry-target entry)))
    (herdr-message--read target (herdr-message--context entry))))

;;;###autoload
(defun herdr-message-session ()
  "Message an agent selected from every session, with context at point."
  (interactive)
  (herdr-message--session 'all nil))

;;;###autoload
(defun herdr-message-last-session ()
  "Message the last-used agent across all sessions, with context at point."
  (interactive)
  (herdr-message--session 'all t))

;;;###autoload
(defun herdr-message-project-session ()
  "Message a selected agent in the current project, with context at point."
  (interactive)
  (herdr-message--session 'project nil))

;;;###autoload
(defun herdr-message-last-project-session ()
  "Message the last-used agent in the current project, with context at point."
  (interactive)
  (herdr-message--session 'project t))

;;;###autoload
(defun herdr-message-workspace-session ()
  "Message a selected agent in the current workspace, with context at point."
  (interactive)
  (herdr-message--session 'workspace nil))

;;;###autoload
(defun herdr-message-last-workspace-session ()
  "Message the last-used agent in the current workspace, with context at point."
  (interactive)
  (herdr-message--session 'workspace t))

;;;; Primary agents

(defvar-local herdr-current-agent nil
  "Composite target of the agent associated with the current buffer.")

(defvar herdr--project-agents nil
  "Alist of project roots to the composite agent target bound to each.")

(defvar herdr--workspace-agents nil
  "Alist of workspace labels to the composite agent target bound to each.")

(defun herdr--current-project-root ()
  "Return the current buffer's project root, or nil."
  (let ((directory (or (and buffer-file-name
                            (file-name-directory buffer-file-name))
                       default-directory)))
    (condition-case nil
        (funcall herdr-project-root-function directory)
      (file-error nil))))

(defun herdr-primary-agent-target ()
  "Return the primary agent target for the current buffer, or nil.
The buffer binding wins over the project binding, which wins over the
workspace binding.  Bindings whose agent is gone are dropped."
  (let ((live (delq nil (mapcar #'herdr--entry-target
                                (herdr-agent--send-candidates))))
        (project (herdr--current-project-root))
        (workspace (herdr-current-workspace-label)))
    (unless (member herdr-current-agent live)
      (setq herdr-current-agent nil))
    (setq herdr--project-agents
          (cl-remove-if-not (lambda (binding) (member (cdr binding) live))
                            herdr--project-agents)
          herdr--workspace-agents
          (cl-remove-if-not (lambda (binding) (member (cdr binding) live))
                            herdr--workspace-agents))
    (or herdr-current-agent
        (and project (cdr (assoc project herdr--project-agents)))
        (and workspace (cdr (assoc workspace herdr--workspace-agents))))))

(defun herdr--read-agent-target (prompt)
  "Read a running agent with PROMPT and return its composite target."
  (let ((all (herdr-agent--send-candidates)))
    (herdr--prune-session-targets all)
    (herdr--entry-target (herdr-read-entry prompt all))))

;;;###autoload
(defun herdr-associate-agent (target)
  "Bind agent TARGET as the current buffer's primary agent."
  (interactive (list (herdr--read-agent-target "Primary agent for this buffer: ")))
  (setq herdr-current-agent target)
  (message "Buffer %s now messages %s"
           (buffer-name) (herdr-message--target-label target))
  target)

;;;###autoload
(defun herdr-associate-project-agent (target)
  "Bind agent TARGET as the current project's primary agent."
  (interactive (list (herdr--read-agent-target "Primary agent for this project: ")))
  (let ((project (or (herdr--current-project-root)
                     (user-error "Current buffer is not in a project"))))
    (setf (alist-get project herdr--project-agents nil nil #'equal) target)
    (message "Project %s now messages %s"
             (abbreviate-file-name project)
             (herdr-message--target-label target))
    target))

;;;###autoload
(defun herdr-associate-workspace-agent (target)
  "Bind agent TARGET as the current workspace's primary agent."
  (interactive (list (herdr--read-agent-target "Primary agent for this workspace: ")))
  (let ((workspace (or (herdr-current-workspace-label)
                       (user-error "No current editor workspace"))))
    (setf (alist-get workspace herdr--workspace-agents nil nil #'equal) target)
    (message "Workspace %s now messages %s"
             workspace (herdr-message--target-label target))
    target))

;;;###autoload
(defun herdr-dissociate-agent (&optional all)
  "Clear the current buffer's primary agent.
With prefix argument ALL, also clear the current project's and
workspace's bindings."
  (interactive "P")
  (setq herdr-current-agent nil)
  (when all
    (when-let* ((project (herdr--current-project-root)))
      (setf (alist-get project herdr--project-agents nil t #'equal) nil))
    (when-let* ((workspace (herdr-current-workspace-label)))
      (setf (alist-get workspace herdr--workspace-agents nil t #'equal) nil)))
  (message "Primary agent cleared"))

(defun herdr--primary-or-bind-target ()
  "Return the primary agent target, binding the project on first use."
  (or (herdr-primary-agent-target)
      (let ((target (herdr--read-agent-target "Primary agent: "))
            (project (herdr--current-project-root)))
        (if project
            (progn
              (setf (alist-get project herdr--project-agents nil nil #'equal)
                    target)
              (message "Project %s now messages %s"
                       (abbreviate-file-name project)
                       (herdr-message--target-label target)))
          (setq herdr-current-agent target))
        target)))

(defun herdr--entry-for-target (target)
  "Return the running session entry for TARGET, or nil."
  (cl-find target (herdr-agent--send-candidates)
           :key #'herdr--entry-target :test #'equal))

;;;###autoload
(defun herdr-message-primary-session ()
  "Message the primary agent for the current buffer, with context at point.
Without a binding, read an agent and bind it to the current project."
  (interactive)
  (let ((target (herdr--primary-or-bind-target)))
    (herdr-message--read target
                         (herdr-message--context
                          (herdr--entry-for-target target)))))

;;;###autoload
(defun herdr-send-primary-session ()
  "Send context at point to the primary agent for the current buffer."
  (interactive)
  (let ((target (herdr--primary-or-bind-target)))
    (herdr-agent-prompt target
                        (herdr-agent--send-context
                         (herdr--entry-for-target target)))))

(defun herdr-agent-escape (target)
  "Send escape to TARGET through herdr's agent API."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (herdr-api-agent-send-keys '("esc") request-target))))))

(defun herdr-agent-newline (target)
  "Send return to TARGET through herdr's agent API."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (herdr-api-agent-send-keys '("enter") request-target))))))

(defun herdr-agent-send-keys (target keys)
  "Send KEYS, a list of key names, to TARGET through herdr's agent API.
Unlike `herdr-agent-prompt' this drives the pane directly, so it reaches
an agent that is blocked waiting on interactive input."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (herdr-api-agent-send-keys (vconcat keys) request-target))))))

(provide 'herdr-agent)
;;; herdr-agent.el ends here
