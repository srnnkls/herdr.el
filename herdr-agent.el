;;; herdr-agent.el --- Manage herdr agent attachments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Generic lifecycle ownership for herdr agent attachments.

;;; Code:

(require 'cl-lib)
(require 'herdr)

(defvar cera-session-keymap)
(declare-function cera-read "ext:cera"
                  (table &optional initial bounds source-face))
(declare-function cera-field-open-p "ext:cera" (&optional buffer))
(declare-function herdr-status-harness-glyph "herdr-status" (entry &optional property))
(defvar cera-input-prefix)

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
                 (resume "--session" :reference)))
    ("omp" :label "Oh My Pi"
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

(defun herdr-agent-buffer-target (buffer)
  "Return the composite target of the herdr terminal BUFFER shows, or nil.
A session this Emacs started or adopted answers from the lifecycle
index; a terminal attached on its own answers from the identity
`herdr-claim-buffer' left on the buffer, which every attachment carries."
  (when (buffer-live-p buffer)
    (or (gethash buffer herdr-agent--buffers)
        (when-let* ((terminal (buffer-local-value 'herdr-terminal-id buffer))
                    (server (buffer-local-value 'herdr-terminal-server-key buffer)))
          (cons server terminal)))))

(defun herdr-agent--note-foreground (window)
  "Record WINDOW's agent as the most recently used one.
Runs from `window-state-change-functions' during redisplay, where the
current buffer is unrelated to WINDOW; only the selected window counts.
Getting WINDOW back after a minibuffer is not entering it: an agent
chosen in that minibuffer stays the most recent one."
  (when (and (eq window (selected-window))
             (or (not (eq (window-old-buffer window) (window-buffer window)))
                 (not (minibufferp (window-buffer (old-selected-window))))))
    (herdr--record-session-target
     (herdr-agent-buffer-target (window-buffer window)))))

(defun herdr-agent--watch-foreground (buffer)
  "Make selecting BUFFER's window mark the agent it shows as the foreground one.
Runs for every buffer that starts showing a herdr terminal, so an
attachment this Emacs never took up the lifecycle of counts too."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (add-hook 'window-state-change-functions
                #'herdr-agent--note-foreground nil t))))

(add-hook 'herdr-buffer-functions #'herdr-agent--watch-foreground)

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

(defun herdr-agent-paste (target text)
  "Paste TEXT into TARGET's pane through `pane.send_input'.
TEXT is passed unchanged, without an added submit key.  Bracketed-paste
protection depends on the receiving terminal's mode; without it, newlines
may submit input."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (let ((pane (if-let* ((session (herdr-agent-find server-key terminal)))
                         (herdr-agent-session-pane session)
                       (alist-get 'pane_id
                                  (alist-get 'agent
                                             (herdr-api-agent-get request-target))))))
           (herdr-api-pane-send-input pane :text text)))))))

(defun herdr-agent-read (target)
  "Return TARGET's current screen text with ANSI escapes stripped."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (herdr-agent--with-server server-key
      (herdr-agent--call-with-request-target
       server-key terminal
       (lambda (request-target)
         (alist-get 'text
                    (alist-get 'read
                               (herdr-api-agent-read
                                "visible" request-target :strip-ansi t))))))))

(defcustom herdr-agent-preserve-draft t
  "Whether a draft in an agent's prompt survives a message sent to it.
A message goes out through the daemon, which appends it to whatever the
prompt already holds.  A terminal this Emacs holds and shows can be
driven directly instead: what is in the prompt is read, cleared, and put
back after the message, so a half-written line is not sent along with
it.  Every other session takes the message the way it always did."
  :type 'boolean
  :group 'herdr)

(defconst herdr-agent--prompt-blank "[ \t\u00a0]"
  "A blank cell of a terminal screen, which a prompt pads itself with.")

(defconst herdr-agent--prompt-filled "[^ \t\u00a0]"
  "A cell of a terminal screen carrying something.")

(defcustom herdr-agent-prompt-marker
  (concat "\\`" herdr-agent--prompt-blank "*\\(?:❯\\|›\\|▌\\|>\\)"
          herdr-agent--prompt-blank)
  "What the beginning of an agent's input line looks like on screen.
The draft is the text after the match, together with the lines below it
up to `herdr-agent-prompt-rule'."
  :type 'regexp
  :group 'herdr)

(defcustom herdr-agent-prompt-rule
  (concat "\\`" herdr-agent--prompt-blank "*[─━—_-]\\{8,\\}"
          herdr-agent--prompt-blank "*\\'")
  "What closes the box an agent's input line sits in."
  :type 'regexp
  :group 'herdr)

(defcustom herdr-agent-prompt-clear "\C-u"
  "What is sent to empty an agent's input line."
  :type 'string
  :group 'herdr)

(defcustom herdr-agent-prompt-submit "\r"
  "What is sent to submit an agent's input line."
  :type 'string
  :group 'herdr)

(defun herdr-agent--marker-width (line)
  "Return how far into LINE the text after the prompt marker begins."
  (and (string-match herdr-agent-prompt-marker line) (match-end 0)))

(defun herdr-agent--screen-trim (line)
  "Return LINE without the blank cells the screen padded it out with."
  (replace-regexp-in-string (concat herdr-agent--prompt-blank "+\\'") "" line))

(defun herdr-agent--screen-unindent (line width)
  "Return LINE without the blanks the prompt indents it by, at most WIDTH."
  (substring line (min width (or (string-match herdr-agent--prompt-filled line)
                                 (length line)))))

(defun herdr-agent-screen-draft (screen)
  "Return the draft standing in the input line of SCREEN, or nil.
Lines below the input line belong to the draft up to the rule closing
its box.  A line that wrapped and one the agent was made to break look
alike on a screen, and both are read as a break."
  (when screen
    (let* ((lines (split-string screen "\n"))
           (index (cl-position-if #'herdr-agent--marker-width lines :from-end t)))
      (when index
        (let* ((rest (nthcdr index lines))
               (width (herdr-agent--marker-width (car rest)))
               (body (cons (substring (car rest) width)
                           (seq-take-while
                            (lambda (line)
                              (not (string-match-p herdr-agent-prompt-rule line)))
                            (cdr rest))))
               (draft (herdr-agent--screen-trim
                       (mapconcat
                        (lambda (line)
                          (herdr-agent--screen-trim
                           (herdr-agent--screen-unindent line width)))
                        body "\n"))))
          (unless (string-empty-p draft) draft))))))

(defun herdr-agent-draft (target)
  "Return the draft standing in TARGET's prompt, or nil.
Only a terminal this Emacs holds and shows can be read."
  (when-let* ((buffer (herdr-terminal-buffer (cdr target) (car target))))
    (herdr-agent-screen-draft (herdr-terminal-screen buffer))))

(defun herdr-agent--prompt-locally (target text)
  "Send TEXT to TARGET's own terminal, under the draft its prompt holds.
Answers nil when the terminal is not this Emacs's to drive, or when its
prompt holds nothing to keep, leaving TEXT to go out through the daemon.
The terminal is shown first, since one off screen is not repainted and
reads as it was rather than as it is.  The clear, the message, its
submission and the draft are written in that order by one writer, so
none of them waits on the agent reacting."
  (when-let* ((buffer (herdr-terminal-buffer (cdr target) (car target))))
    (unless (get-buffer-window buffer t) (display-buffer buffer))
    (when-let* ((draft (herdr-agent-screen-draft (herdr-terminal-screen buffer)))
                ((herdr-terminal-send herdr-agent-prompt-clear buffer)))
      (herdr-terminal-paste text buffer)
      (herdr-terminal-send herdr-agent-prompt-submit buffer)
      (herdr-terminal-paste draft buffer)
      t)))

(defun herdr-agent-prompt (target text)
  "Send TEXT to TARGET through herdr's agent API.
A draft standing in the prompt of a terminal this Emacs holds is kept
across the message when `herdr-agent-preserve-draft' allows it."
  (pcase-let ((`(,server-key . ,terminal) (herdr-agent--public-target target)))
    (prog1
        (or (and herdr-agent-preserve-draft
                 (herdr-agent--prompt-locally (cons server-key terminal) text))
            (herdr-agent--with-server server-key
              (herdr-agent--call-with-request-target
               server-key terminal
               (lambda (request-target)
                 (herdr-api-agent-prompt request-target text)))))
      (herdr--record-session-target (cons server-key terminal)))))

(defvar herdr-send-context-functions nil
  "Functions returning context text for a selected agent entry.
Each function receives the entry and may return a string, or nil to let
another provider handle it.  `herdr-default-send-context' is the fallback.")

(defun herdr-agent--context-bounds ()
  "Return the region, or the current line, as the context at point."
  (if (use-region-p)
      (cons (region-beginning) (region-end))
    (cons (line-beginning-position) (line-end-position))))

(defun herdr-default-send-context (_entry)
  "Return the active region or current line as agent context."
  (let* ((bounds (herdr-agent--context-bounds))
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
                  (herdr-read-agent "Send to agent session: " entries)))
         (target (herdr--entry-target entry)))
    (herdr-agent-prompt target (herdr-agent--send-context entry))))

;;;###autoload
(defun herdr-send-session ()
  "Send context at point to an agent selected from every session."
  (interactive)
  (herdr-agent--send-session 'all nil))

;;;###autoload
(defun herdr-send-recent-session ()
  "Send context at point to the last-used agent across all sessions."
  (interactive)
  (herdr-agent--send-session 'all t))

;;;###autoload
(defun herdr-send-project-session ()
  "Send context at point to a selected agent in the current project."
  (interactive)
  (herdr-agent--send-session 'project nil))

;;;###autoload
(defun herdr-send-recent-project-session ()
  "Send context at point to the last-used agent in the current project."
  (interactive)
  (herdr-agent--send-session 'project t))

;;;###autoload
(defun herdr-send-workspace-session ()
  "Send context at point to a selected agent in the current workspace."
  (interactive)
  (herdr-agent--send-session 'workspace nil))

;;;###autoload
(defun herdr-send-recent-workspace-session ()
  "Send context at point to the last-used agent in the current workspace."
  (interactive)
  (herdr-agent--send-session 'workspace t))

;;;; Messages

(defvar herdr-message-history nil
  "Messages sent to agents, most recent first.
Completion candidates and minibuffer history for `herdr-message-send-session'.")

(defvar-local herdr-message--target nil
  "Agent target the current message buffer sends to.")

(defvar-local herdr-message--context nil
  "Context text captured when the current message buffer was opened.")

(defvar-local herdr-message--window-configuration nil
  "Window configuration to restore when the message buffer closes.")

(defvar-keymap herdr-message-field-map
  :doc "Keys an integration adds to the field a message is written in.
The field's own keys stay in place, as does whatever keymap a caller
already put in `cera-session-keymap': this map is composed in front of
it rather than instead of it.  It is where a consumer puts what it can
do about the agent the message goes to, reached through
`herdr-message--pending'.")

(defvar herdr-message-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c '") #'herdr-message-edit-from-minibuffer)
    map)
  "Keys added to the minibuffer while reading an agent message.")

(defvar herdr-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'herdr-message-commit)
    (define-key map (kbd "C-c C-k") #'herdr-message-cancel)
    map)
  "Keymap for `herdr-message-mode'.")

(define-derived-mode herdr-message-mode text-mode "Herdr-Message"
  "Major mode for composing a message to a herdr agent.
\\<herdr-message-mode-map>\\[herdr-message-commit] sends the message with the
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
                            (herdr-message--compose text context)))
    target))

(defcustom herdr-message-show-agent t
  "Whether sending a message shows the agent's terminal.
A terminal already on the selected frame is left where it is, and one
that nothing shows yet is attached.  The window sent from stays selected."
  :type 'boolean
  :group 'herdr)

(defun herdr-message--show-target (target)
  "Show TARGET's terminal after a message, keeping the selected window."
  (when herdr-message-show-agent
    (let ((window (selected-window)))
      (if-let* ((buffer (herdr-terminal-buffer (cdr target) (car target))))
          (unless (get-buffer-window buffer)
            (display-buffer buffer))
        (when-let* ((entry (herdr--entry-for-target target)))
          (herdr-visit entry)))
      (when (window-live-p window)
        (select-window window)))))

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

(defun herdr-message-commit ()
  "Send the current message buffer to its agent."
  (interactive)
  (unless (derived-mode-p 'herdr-message-mode)
    (user-error "Not in a herdr message buffer"))
  (let ((target (herdr-message--send
                 herdr-message--target
                 (buffer-substring-no-properties (point-min) (point-max))
                 herdr-message--context)))
    (herdr-message--close)
    (herdr-message--show-target target)))

(defun herdr-message-cancel ()
  "Discard the current message buffer."
  (interactive)
  (unless (derived-mode-p 'herdr-message-mode)
    (user-error "Not in a herdr message buffer"))
  (herdr-message--close))

(defvar herdr-message--pending nil
  "Target and context of the message being read, while it is being read.
A completion source in the field, or a command in the minibuffer, reads
the agent the message is going to from here.")

(defvar herdr-message--edited nil
  "Non-nil once the draft being read moved to a `herdr-message-mode' buffer.")

(defun herdr-message-edit-from-minibuffer ()
  "Leave the minibuffer and continue the message in a full buffer."
  (interactive)
  (let ((draft (minibuffer-contents))
        (pending herdr-message--pending))
    (throw 'exit
           (lambda ()
             (setq herdr-message--edited t)
             (herdr-message--edit (car pending) draft (cdr pending))))))

(defcustom herdr-message-read-function #'herdr-message-read-minibuffer
  "Function reading a message for an agent and sending it.
It is called with the agent target and the context at point, or nil.
`herdr-message-read-minibuffer' asks in the minibuffer.
`herdr-message-read-field' writes the message in a cera field under the
region or line it is about, and asks in the minibuffer where a process
streams into the buffer."
  :type '(choice (const :tag "Minibuffer" herdr-message-read-minibuffer)
                 (const :tag "Field under the source, with cera"
                        herdr-message-read-field)
                 function)
  :group 'herdr)

(defun herdr-message--target-harness (target)
  "Return the harness TARGET runs, from the attached session or the servers."
  (or (when-let* ((session (herdr-agent-find (car target) (cdr target))))
        (herdr-agent-session-kind session))
      (when-let* ((entry (herdr--entry-for-target target)))
        (alist-get 'agent entry))))

(defun herdr-message--field-prefix (target)
  "Return the mark drawn where the field closes into TARGET's message.
It is the vendor mark `herdr-status' draws beside the agent, so the field
carries the harness it is writing to in that harness's own colour.  The
dashboard is loaded for it, and a harness without a mark, or a missing
dashboard, draws the field bare."
  (when (or (fboundp 'herdr-status-harness-glyph)
            (require 'herdr-status nil t))
    (herdr-status-harness-glyph (herdr-message--target-harness target))))

(defun herdr-message-read-field (target context)
  "Read a message for TARGET in a field under the context at point.
The field sits under the region or line CONTEXT was taken from, which is
left unmarked — the region is its own highlight — and what is written
into the field is sent with CONTEXT.  Cancelling the field quits.
A buffer with a live process, where a terminal streams into what the
field would sit in, asks in the minibuffer instead, as does a missing
cera or the minibuffer itself."
  (if (and (not (minibufferp))
           (not (get-buffer-process (current-buffer)))
           (or (fboundp 'cera-read) (require 'cera nil t)))
      (let ((cera-input-prefix (herdr-message--field-prefix target))
            (cera-session-keymap
             (if cera-session-keymap
                 (make-composed-keymap herdr-message-field-map cera-session-keymap)
               herdr-message-field-map))
            (herdr-message--pending (cons target context)))
        (message "Message to %s" (herdr-message--target-label target))
        (herdr-message--show-target
         (herdr-message--send
          target
          (cera-read herdr-message-history nil
                     (herdr-agent--context-bounds) nil)
          context)))
    (herdr-message-read-minibuffer target context)))

(defun herdr-field-open-p ()
  "Return non-nil while any cera field is being read over this buffer.
A message field is one of them, an annotation another; a buffer redrawn
under either would leave its brackets over rows they were not drawn for
and its markers pointing nowhere."
  (and (fboundp 'cera-field-open-p) (cera-field-open-p)))

(add-hook 'herdr-status-redraw-inhibit-functions #'herdr-field-open-p)

(defun herdr-message-read-minibuffer (target context)
  "Read a message for TARGET in the minibuffer and send it with CONTEXT.
Earlier messages are reached through the history keys.
\\<herdr-message-minibuffer-map>\\[herdr-message-edit-from-minibuffer] in the
minibuffer moves the draft to a `herdr-message-mode' buffer instead."
  (let ((herdr-message--pending (cons target context))
        (herdr-message--edited nil)
        (history-add-new-input nil))
    (minibuffer-with-setup-hook
        (lambda ()
          (use-local-map (make-composed-keymap herdr-message-minibuffer-map
                                               (current-local-map))))
      (let ((text (read-string "Message: " nil 'herdr-message-history)))
        (unless herdr-message--edited
          (herdr-message--show-target
           (herdr-message--send target text context)))))))

(defun herdr-message--read (target context)
  "Read a message for TARGET and send it with CONTEXT.
`herdr-message-read-function' decides where the message is written."
  (funcall herdr-message-read-function target context))

(defun herdr-message--session (scope last)
  "Message an agent in SCOPE, selecting by LAST when non-nil."
  (let* ((all (herdr-agent--send-candidates))
         (_ (herdr--prune-session-targets all))
         (entries (herdr-agent--send-scope-entries all scope))
         (entry (if last
                    (herdr-agent--last-send-entry entries scope)
                  (herdr-read-agent "Message agent: " entries)))
         (target (herdr--entry-target entry)))
    (herdr-message--read target (herdr-message--context entry))))

;;;###autoload
(defun herdr-message-send-session ()
  "Message an agent selected from every session, with context at point."
  (interactive)
  (herdr-message--session 'all nil))

;;;###autoload
(defun herdr-message-send-recent-session ()
  "Message the last-used agent across all sessions, with context at point."
  (interactive)
  (herdr-message--session 'all t))

;;;###autoload
(defun herdr-message-send-project-session ()
  "Message a selected agent in the current project, with context at point."
  (interactive)
  (herdr-message--session 'project nil))

;;;###autoload
(defun herdr-message-send-recent-project-session ()
  "Message the last-used agent in the current project, with context at point."
  (interactive)
  (herdr-message--session 'project t))

;;;###autoload
(defun herdr-message-send-workspace-session ()
  "Message a selected agent in the current workspace, with context at point."
  (interactive)
  (herdr-message--session 'workspace nil))

;;;###autoload
(defun herdr-message-send-recent-workspace-session ()
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
    (herdr--entry-target (herdr-read-agent prompt all))))

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
(defun herdr-message-send-primary-session ()
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

;;;; Foreground agent

(defun herdr-agent--foreground-entry (entries &optional any)
  "Return the foreground agent among ENTRIES, or nil.
The one used most recently from Emacs wins, then the one herdr itself
has focused.  ANY settles for the first of ENTRIES rather than nothing,
which is what a workspace that holds agents at all wants: one of them is
the agent there, and asking which would be asking about a room you are
already standing in."
  (or (cl-loop for target in herdr--recent-session-targets
               thereis (cl-find target entries :key #'herdr--entry-target
                                :test #'equal))
      (seq-find (lambda (entry) (eq (alist-get 'focused entry) t)) entries)
      (and any (car entries))))

(defun herdr-agent--foreground-or-read-entry (choose)
  "Return the foreground agent entry for the current workspace.
An agent in the workspace always answers; failing that the agent last
used anywhere does.  Only a CHOOSE, the prefix argument, or a workspace
with no agent and nothing used yet, asks."
  (let* ((all (herdr-agent--send-candidates))
         (_ (herdr--prune-session-targets all))
         (entries (if (herdr-current-workspace-label)
                      (herdr-agent--send-scope-entries all 'workspace)
                    all)))
    (or (and (not choose)
             (or (herdr-agent--foreground-entry entries t)
                 (herdr-agent--foreground-entry all)))
        (herdr-read-agent "Agent: " all))))

(defun herdr-agent--shown-window ()
  "Return the window on the selected frame whose agent is to be hidden.
The selected window when it shows an agent, then the shown agent used
most recently, then any shown agent."
  (let ((windows (seq-filter
                  (lambda (window)
                    (herdr-agent-buffer-target (window-buffer window)))
                  (window-list))))
    (or (car (memq (selected-window) windows))
        (cl-loop for target in herdr--recent-session-targets
                 thereis (seq-find
                          (lambda (window)
                            (equal (herdr-agent-buffer-target
                                    (window-buffer window))
                                   target))
                          windows))
        (car windows))))

(defun herdr-agent--hide-window (window)
  "Take WINDOW off the screen, keeping its buffer."
  (if (eq (window-deletable-p window) t)
      (delete-window window)
    (switch-to-prev-buffer window 'bury)))

(defcustom herdr-toggle-agent-display-action nil
  "Display action `herdr-toggle-agent' shows an agent's terminal under.
Nil leaves the placement to `display-buffer-alist', so whatever popup
rule the editor already holds for herdr terminals decides where the
agent lands and whether it takes focus."
  :type '(choice (const :tag "Whatever the editor's rules say" nil) sexp)
  :group 'herdr-agent)

(defconst herdr-agent--nowhere '(display-buffer-no-window (allow-no-window . t))
  "Display action putting a buffer nowhere.
An attach shows what it attached on its own; suppressing that leaves the
buffer to go out once, through the rules the editor keeps for it.")

(defun herdr-agent-workspace-buffer-p (buffer)
  "Return non-nil when BUFFER sits in the current editor workspace.
A workspace package keeping a buffer list of its own is the one that
knows: `persp-mode', which doom's workspaces are built on, is asked
wherever it is loaded.  Without one every buffer is in the workspace
there is."
  (if (fboundp 'persp-contain-buffer-p)
      (persp-contain-buffer-p buffer)
    t))

(defcustom herdr-agent-workspace-buffer-predicate #'herdr-agent-workspace-buffer-p
  "Predicate saying whether a terminal buffer is in the current workspace.
It is called with the buffer.  This is what decides which attached
agents `herdr-toggle-agent' counts as being here, so an editor that
groups buffers its own way answers for itself."
  :type 'function
  :group 'herdr-agent)

(defun herdr-agent--workspace-entries (entries)
  "Return the members of ENTRIES this workspace can be said to hold.
The editor's workspace label picks them wherever an agent answers to
it.  A workspace named for no project of its own, or holding several,
falls back to the project at point and then to every agent running, so
what is offered is the nearest thing rather than nothing."
  (or (and (herdr-current-workspace-label)
           (ignore-errors (herdr-agent--send-scope-entries entries 'workspace)))
      (ignore-errors (herdr-agent--send-scope-entries entries 'project))
      entries))

(defun herdr-agent--attached-entries (entries)
  "Return the members of ENTRIES this workspace already holds a buffer for.
Membership is the editor's own, through
`herdr-agent-workspace-buffer-predicate': an agent attached into this
workspace is here whatever directory it works in.  The one reached for
most recently leads, so a workspace with several answers with the one
last worked in."
  (herdr-recent-first
   (seq-filter (lambda (entry)
                 (when-let* ((buffer (herdr--entry-buffer entry)))
                   (funcall herdr-agent-workspace-buffer-predicate buffer)))
               entries)))

(defun herdr-agent--focus-buffer (buffer)
  "Show BUFFER, take the cursor to its prompt, and return its window.
The editor's own rules place the window; taking the cursor there is not
theirs to decide, since the point of showing an agent is to type at it."
  (when-let* ((window (display-buffer buffer herdr-toggle-agent-display-action)))
    (select-window window)
    (herdr-terminal-goto-prompt buffer)
    window))

(defun herdr-agent--show-entry (entry)
  "Show ENTRY's terminal and return the window it went to.
The buffer goes out through `display-buffer', so the editor's own rules
place it, and an entry nothing shows yet is attached without being put
anywhere first rather than taking a window of herdr's choosing."
  (when-let* ((buffer (or (herdr--entry-buffer entry)
                          (let ((herdr-display-buffer-action herdr-agent--nowhere))
                            (herdr-attach-entry entry))))
              ((buffer-live-p buffer)))
    (herdr--record-session-target (herdr--entry-target entry))
    (herdr-agent--focus-buffer buffer)))

(defun herdr-agent--start-in-workspace ()
  "Start an agent where the current workspace works, after asking which.
The workspace is left as it is: the agent opens in it rather than the
editor moving to the agent."
  (let* ((kind (completing-read "No agent here.  Start harness: "
                                (mapcar #'car herdr-agent-harnesses) nil t))
         (session (let ((herdr-display-buffer-action herdr-agent--nowhere))
                    (herdr-agent-start
                     kind nil
                     :project-root (or (funcall herdr-project-root-function)
                                       default-directory)
                     :workspace (herdr-current-workspace-label))))
         (buffer (and session (herdr-agent-session-buffer session))))
    (when (buffer-live-p buffer)
      (herdr-agent--focus-buffer buffer))))

;;;###autoload
(defun herdr-toggle-agent (&optional choose)
  "Show this workspace's agent, or take the one on screen off it.
A herdr terminal already on the frame is hidden: its window goes, its
buffer stays, and nothing else moves.  Otherwise the workspace answers
with the agent it has attached and worked in most recently, shown
wherever the editor's own rules put a herdr terminal.  A workspace
holding no attached agent reads one of the agents running in it, and a
workspace running none offers to start one.  CHOOSE, the prefix
argument, reads an agent whatever is on screen.

The current workspace stays the current one throughout: nothing here
switches to where an agent happens to live, and hiding one keeps its
buffer and everything else about its window."
  (interactive "P")
  (if-let* ((window (and (not choose) (herdr-agent--shown-window))))
      (herdr-agent--hide-window window)
    (let* ((all (herdr-agent--send-candidates))
           (_ (herdr--prune-session-targets all))
           (attached (unless choose (herdr-agent--attached-entries all)))
           (entries (herdr-agent--workspace-entries all)))
      (cond
       (attached (herdr-agent--show-entry (car attached)))
       (entries (herdr-agent--show-entry
                 (herdr-read-agent "Show agent: " entries)))
       (t (herdr-agent--start-in-workspace))))))

;;;###autoload
(defun herdr-switch-agent (&optional all)
  "Read one of this workspace's agents and show it at its prompt.
The workspace's agents are the ones `herdr-toggle-agent' would reach
for; ALL, the prefix argument, offers every agent running instead.  An
agent nothing shows yet is attached, and either way the cursor ends up
where the agent takes input."
  (interactive "P")
  (let* ((entries (herdr-agent--send-candidates))
         (_ (herdr--prune-session-targets entries))
         (pool (if all entries (herdr-agent--workspace-entries entries))))
    (unless pool
      (user-error "No herdr agent is running"))
    (herdr-agent--show-entry
     (herdr-read-agent (if all "Switch to agent: " "Switch to agent here: ")
                       pool))))

;;;###autoload
(defun herdr-message-send (&optional choose)
  "Write a message to the agent at hand, carrying the context at point.
The agent is the foreground one of the workspace, resolved the way
`herdr-toggle-agent' resolves it, which is what makes this the command
to reach for; CHOOSE, the prefix argument, reads one instead.  The
`herdr-message-send-...' commands name a scope to pick from rather than
taking the agent already in front of you."
  (interactive "P")
  (let ((entry (herdr-agent--foreground-or-read-entry choose)))
    (herdr-message--read (herdr--entry-target entry)
                         (herdr-message--context entry))))

;;;###autoload
(defun herdr-send (&optional choose)
  "Send the context at point to the agent at hand, writing nothing.
The agent is resolved as `herdr-message-send' resolves it, and CHOOSE,
the prefix argument, reads one instead.  Where that command opens a
field to write in, this one sends the region or the current line as it
stands."
  (interactive "P")
  (let ((entry (herdr-agent--foreground-or-read-entry choose)))
    (herdr-agent-prompt (herdr--entry-target entry)
                        (herdr-agent--send-context entry))))

(provide 'herdr-agent)
;;; herdr-agent.el ends here
