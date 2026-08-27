;;; herdr-claude-code-ide-mcp.el --- Claude Code IDE transport for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

(require 'cl-lib)
(require 'json)
(require 'herdr-agent)

(declare-function websocket-server "websocket" (port &rest plist))
(declare-function websocket-server-close "websocket" (server))
(declare-function websocket-close "websocket" (websocket))
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-frame-text "websocket" (frame))

(cl-defstruct herdr-claude-code-ide-mcp-client
  raw open-p initialized-p generation)

(cl-defstruct herdr-claude-code-ide-mcp-adapter
  session-key session instance-id instance-name state endpoint endpoint-live-p
  server lockfile discovery environment clients current-client client-generation
  reconnect-deadline reconnect-deadline-seconds reconnect-token tool-list tool-call
  pending diffs cancelled-work raw-clients)

(defvar herdr-claude-code-ide-mcp--adapters (make-hash-table :test #'equal))
(defvar herdr-claude-code-ide-mcp--starting (make-hash-table :test #'eq))
(defvar herdr-claude-code-ide-mcp--global-hooks-installed nil)
(defvar herdr-claude-code-ide-mcp--defer-close nil)
(defvar herdr-claude-code-ide-mcp--close-after-send nil)

(defun herdr-claude-code-ide-mcp--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-code-ide-mcp--port (server)
  (let ((service (plist-get (process-contact server t) :service)))
    (if (stringp service) (string-to-number service) service)))

(defun herdr-claude-code-ide-mcp--start-server (adapter)
  (unless (require 'websocket nil t)
    (error "Claude Code IDE transport requires websocket.el"))
  (let ((server
         (websocket-server
          0 :host "127.0.0.1" :protocol '("mcp")
          :on-open (lambda (raw)
                     (puthash raw
                              (herdr-claude-code-ide-mcp-client-connect adapter raw)
                              (herdr-claude-code-ide-mcp-adapter-raw-clients adapter)))
          :on-message (lambda (raw frame)
                        (when-let* ((client (gethash raw
                                                     (herdr-claude-code-ide-mcp-adapter-raw-clients adapter))))
                          (let ((herdr-claude-code-ide-mcp--defer-close t)
                                (herdr-claude-code-ide-mcp--close-after-send nil))
                            (when-let* ((response (herdr-claude-code-ide-mcp-receive
                                                   adapter client (websocket-frame-text frame))))
                              (websocket-send-text raw (json-serialize response)))
                            (when herdr-claude-code-ide-mcp--close-after-send
                              (herdr-claude-code-ide-mcp-client-close adapter client)))))
          :on-close (lambda (raw)
                      (when-let* ((client (gethash raw
                                                   (herdr-claude-code-ide-mcp-adapter-raw-clients adapter))))
                        (herdr-claude-code-ide-mcp-client-close adapter client))))))
    (setf (herdr-claude-code-ide-mcp-adapter-server adapter) server)
    (herdr-claude-code-ide-mcp--port server)))

(defun herdr-claude-code-ide-mcp--default-tools ()
  '(((name . "openFile") (description . "Open a file in the editor.")
     (inputSchema . ((type . "object")
                     (properties . ((filePath . ((type . "string")))
                                    (startLine . ((type . "integer")))
                                    (endLine . ((type . "integer")))
                                    (startText . ((type . "string")))
                                    (endText . ((type . "string")))))
                     (required . ("filePath")))))
    ((name . "getDiagnostics") (description . "Get diagnostics for visited files.")
     (inputSchema . ((type . "object") (properties . ((uri . ((type . "string")))))
                     (required . ()))))
    ((name . "close_tab") (description . "Release the requesting session view.")
     (inputSchema . ((type . "object")
                     (properties . ((path . ((type . "string")))
                                    (tab_name . ((type . "string")))))
                     (required . ()))))
    ((name . "openDiff") (description . "Open an editable diff.")
     (inputSchema . ((type . "object")
                     (properties . ((old_file_path . ((type . "string")))
                                    (new_file_path . ((type . "string")))
                                    (new_file_contents . ((type . "string")))
                                    (tab_name . ((type . "string")))))
                     (required . ("new_file_contents" "new_file_path" "old_file_path" "tab_name")))))
    ((name . "closeAllDiffTabs") (description . "Close all session-owned diff tabs.")
     (inputSchema . ((type . "object") (properties . ()) (required . ()))))
    ((name . "executeCode") (description . "Evaluate explicitly enabled Emacs Lisp.")
     (inputSchema . ((type . "object") (properties . ((code . ((type . "string")))))
                     (required . ("code")))))))

(defun herdr-claude-code-ide-mcp--initialize-result ()
  '((protocolVersion . "2025-11-25")
    (capabilities . ((tools . ((listChanged . t)))
                     (resources . ((subscribe . :json-false) (listChanged . :json-false)))
                     (prompts . ((listChanged . t)))))
    (serverInfo . ((name . "herdr-claude-code-ide") (version . "fixture")))))

(defun herdr-claude-code-ide-mcp--response (id result)
  `((jsonrpc . "2.0") (id . ,id) (result . ,result)))

(defun herdr-claude-code-ide-mcp--error (id code message)
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun herdr-claude-code-ide-mcp--close-raw (client)
  (when-let* ((raw (herdr-claude-code-ide-mcp-client-raw client)))
    (when (fboundp 'websocket-close) (ignore-errors (websocket-close raw)))))

(defun herdr-claude-code-ide-mcp--cancel-work (adapter)
  (setf (herdr-claude-code-ide-mcp-adapter-cancelled-work adapter)
        `((requests . ,(herdr-claude-code-ide-mcp-adapter-pending adapter))
          (diffs . ,(herdr-claude-code-ide-mcp-adapter-diffs adapter)))
        (herdr-claude-code-ide-mcp-adapter-pending adapter) nil
        (herdr-claude-code-ide-mcp-adapter-diffs adapter) nil))

(defun herdr-claude-code-ide-mcp--cancel-deadline (adapter)
  (when-let* ((timer (herdr-claude-code-ide-mcp-adapter-reconnect-deadline adapter)))
    (cancel-timer timer))
  (setf (herdr-claude-code-ide-mcp-adapter-reconnect-deadline adapter) nil
        (herdr-claude-code-ide-mcp-adapter-reconnect-token adapter) nil))

(defun herdr-claude-code-ide-mcp--arm-deadline (adapter generation)
  (let ((token (make-symbol "reconnect")))
    (setf (herdr-claude-code-ide-mcp-adapter-reconnect-token adapter) token
          (herdr-claude-code-ide-mcp-adapter-reconnect-deadline-seconds adapter) 30
          (herdr-claude-code-ide-mcp-adapter-reconnect-deadline adapter)
          (run-at-time 30 nil
                       (lambda ()
                         (when (and (eq token (herdr-claude-code-ide-mcp-adapter-reconnect-token adapter))
                                    (eq generation (herdr-claude-code-ide-mcp-adapter-client-generation adapter))
                                    (null (herdr-claude-code-ide-mcp-adapter-current-client adapter))
                                    (eq (herdr-claude-code-ide-mcp-adapter-state adapter) 'waiting-for-client))
                           (setf (herdr-claude-code-ide-mcp-adapter-reconnect-deadline adapter) nil)
                           (herdr-claude-code-ide-mcp-cleanup adapter)))))))

(cl-defun herdr-claude-code-ide-mcp-prepare (agent &key server-key project-root instance-id discovery-directory tool-list tool-call session)
  (when (equal (herdr-claude-code-ide-mcp--value 'agent agent) "claude")
    (let* ((instance-id (or instance-id (herdr-claude-code-ide-mcp--value 'terminal_id agent)))
           (session-key (or session (make-symbol "herdr-claude-code-ide-mcp")))
           (existing (and session (gethash session herdr-claude-code-ide-mcp--starting))))
      (or existing
          (let* ((adapter (make-herdr-claude-code-ide-mcp-adapter
                           :session-key session-key :session session :instance-id instance-id
                           :instance-name (format "%s/%s/%s" server-key
                                                  (herdr-claude-code-ide-mcp--value 'name agent) instance-id)
                           :state 'starting :client-generation 0 :tool-list (or tool-list #'herdr-claude-code-ide-mcp--default-tools)
                           :tool-call tool-call :raw-clients (make-hash-table :test #'eq)))
                 (port (herdr-claude-code-ide-mcp--start-server adapter))
                 (root (expand-file-name project-root))
                 (directory (file-name-as-directory (expand-file-name discovery-directory)))
                 (lockfile (expand-file-name (format "%s.lock" port) directory))
                 (discovery `((pid . ,(emacs-pid)) (workspaceFolders . ,(vector root))
                              (ideName . ,(format "herdr %s" (herdr-claude-code-ide-mcp-adapter-instance-name adapter)))
                              (transport . "ws"))))
            (condition-case err
                (progn
                  (make-directory directory t)
                  (with-temp-file lockfile (insert (json-serialize discovery)))
                  (setf (herdr-claude-code-ide-mcp-adapter-endpoint adapter)
                        (format "ws://127.0.0.1:%s" port)
                        (herdr-claude-code-ide-mcp-adapter-endpoint-live-p adapter) t
                        (herdr-claude-code-ide-mcp-adapter-lockfile adapter) lockfile
                        (herdr-claude-code-ide-mcp-adapter-discovery adapter)
                        (json-parse-string (json-serialize discovery) :object-type 'alist :array-type 'list
                                           :null-object nil :false-object :json-false)
                        (herdr-claude-code-ide-mcp-adapter-environment adapter)
                        `((CLAUDE_CODE_SSE_PORT . ,(number-to-string port))
                          (FORCE_CODE_TERMINAL . "true") (TERM_PROGRAM . "emacs")))
                  (puthash session-key adapter herdr-claude-code-ide-mcp--adapters)
                  (when session (puthash session adapter herdr-claude-code-ide-mcp--starting))
                  (setq herdr-claude-code-ide-mcp--global-hooks-installed t)
                  adapter)
              (error
               (herdr-claude-code-ide-mcp-cleanup adapter)
               (signal (car err) (cdr err)))))))))

(defun herdr-claude-code-ide-mcp-client-connect (adapter &optional raw)
  (let ((client (make-herdr-claude-code-ide-mcp-client :raw raw :open-p t)))
    (push client (herdr-claude-code-ide-mcp-adapter-clients adapter))
    client))

(defun herdr-claude-code-ide-mcp--known-tool-p (adapter name)
  (seq-find (lambda (tool) (equal (herdr-claude-code-ide-mcp--value 'name tool) name))
            (funcall (herdr-claude-code-ide-mcp-adapter-tool-list adapter))))

(defun herdr-claude-code-ide-mcp--initialize (adapter client id params)
  (if (memq (herdr-claude-code-ide-mcp-adapter-state adapter) '(detaching stopped))
      (progn
        (herdr-claude-code-ide-mcp-client-close adapter client)
        nil)
    (if (not (consp params))
        (progn
          (if herdr-claude-code-ide-mcp--defer-close
              (setq herdr-claude-code-ide-mcp--close-after-send t)
            (herdr-claude-code-ide-mcp-client-close adapter client))
          (herdr-claude-code-ide-mcp--error id -32602 "Invalid params"))
      (let ((old (herdr-claude-code-ide-mcp-adapter-current-client adapter)))
      (when old (herdr-claude-code-ide-mcp--cancel-work adapter))
      (herdr-claude-code-ide-mcp--cancel-deadline adapter)
      (setf (herdr-claude-code-ide-mcp-adapter-current-client adapter) client
            (herdr-claude-code-ide-mcp-adapter-client-generation adapter)
            (1+ (herdr-claude-code-ide-mcp-adapter-client-generation adapter))
            (herdr-claude-code-ide-mcp-client-initialized-p client) t
            (herdr-claude-code-ide-mcp-client-generation client)
            (herdr-claude-code-ide-mcp-adapter-client-generation adapter))
      (when old (herdr-claude-code-ide-mcp-client-close adapter old))
      (unless (eq (herdr-claude-code-ide-mcp-adapter-state adapter) 'starting)
        (setf (herdr-claude-code-ide-mcp-adapter-state adapter) 'connected))
      (herdr-claude-code-ide-mcp--response id (herdr-claude-code-ide-mcp--initialize-result))))))

(defun herdr-claude-code-ide-mcp-receive (adapter client text)
  (when (herdr-claude-code-ide-mcp-client-open-p client)
    (condition-case nil
        (let* ((message (json-parse-string text :object-type 'alist :array-type 'list
                                           :null-object nil :false-object :json-false))
               (id (herdr-claude-code-ide-mcp--value 'id message))
               (method (herdr-claude-code-ide-mcp--value 'method message))
               (params (herdr-claude-code-ide-mcp--value 'params message)))
          (cond
           ((or (not (listp message)) (not (equal (herdr-claude-code-ide-mcp--value 'jsonrpc message) "2.0"))
                (not (stringp method)))
            (herdr-claude-code-ide-mcp--error nil -32600 "Invalid Request"))
           ((equal method "initialize")
            (herdr-claude-code-ide-mcp--initialize adapter client id params))
           ((or (not (eq client (herdr-claude-code-ide-mcp-adapter-current-client adapter)))
                (not (herdr-claude-code-ide-mcp-client-initialized-p client))) nil)
           ((equal method "ide_connected") nil)
           ((equal method "tools/list")
            (herdr-claude-code-ide-mcp--response id
                                                  `((tools . ,(funcall (herdr-claude-code-ide-mcp-adapter-tool-list adapter))))))
           ((equal method "prompts/list")
            (herdr-claude-code-ide-mcp--response id '((prompts . ()))))
           ((equal method "resources/list")
            (herdr-claude-code-ide-mcp--response id '((resources . ()))))
           ((equal method "tools/call")
            (let* ((name (herdr-claude-code-ide-mcp--value 'name params))
                   (arguments (herdr-claude-code-ide-mcp--value 'arguments params)))
              (if (and (stringp name) (herdr-claude-code-ide-mcp--known-tool-p adapter name)
                       (functionp (herdr-claude-code-ide-mcp-adapter-tool-call adapter)))
                  (condition-case nil
                      (herdr-claude-code-ide-mcp--response
                       id (funcall (herdr-claude-code-ide-mcp-adapter-tool-call adapter) adapter name arguments))
                    (error (herdr-claude-code-ide-mcp--error id -32603 "Internal error")))
                (herdr-claude-code-ide-mcp--error id -32602 "Unknown tool"))))
           (t (herdr-claude-code-ide-mcp--error id -32601 "Method not found"))))
      (error (herdr-claude-code-ide-mcp--error nil -32700 "Parse error")))))

(defun herdr-claude-code-ide-mcp-client-close (adapter client)
  (when (herdr-claude-code-ide-mcp-client-open-p client)
    (setf (herdr-claude-code-ide-mcp-client-open-p client) nil)
    (herdr-claude-code-ide-mcp--close-raw client)
    (when (eq client (herdr-claude-code-ide-mcp-adapter-current-client adapter))
      (setf (herdr-claude-code-ide-mcp-adapter-current-client adapter) nil)
      (herdr-claude-code-ide-mcp--cancel-work adapter)
      (when (memq (herdr-claude-code-ide-mcp-adapter-state adapter) '(connected waiting-for-client))
        (setf (herdr-claude-code-ide-mcp-adapter-state adapter) 'waiting-for-client)
        (herdr-claude-code-ide-mcp--arm-deadline
         adapter (herdr-claude-code-ide-mcp-adapter-client-generation adapter)))))
  nil)

(defun herdr-claude-code-ide-mcp-terminal-attached (adapter)
  (when (eq (herdr-claude-code-ide-mcp-adapter-state adapter) 'starting)
    (setf (herdr-claude-code-ide-mcp-adapter-state adapter)
          (if (herdr-claude-code-ide-mcp-adapter-current-client adapter) 'connected 'waiting-for-client))))

(defun herdr-claude-code-ide-mcp-track-pending (adapter client request diff)
  (when (and (eq client (herdr-claude-code-ide-mcp-adapter-current-client adapter))
             (herdr-claude-code-ide-mcp-client-initialized-p client))
    (push request (herdr-claude-code-ide-mcp-adapter-pending adapter))
    (push diff (herdr-claude-code-ide-mcp-adapter-diffs adapter))))

(defun herdr-claude-code-ide-mcp-cleanup (adapter)
  (unless (eq (herdr-claude-code-ide-mcp-adapter-state adapter) 'stopped)
    (setf (herdr-claude-code-ide-mcp-adapter-state adapter) 'detaching)
    (herdr-claude-code-ide-mcp--cancel-deadline adapter)
    (dolist (client (herdr-claude-code-ide-mcp-adapter-clients adapter))
      (setf (herdr-claude-code-ide-mcp-client-open-p client) nil)
      (herdr-claude-code-ide-mcp--close-raw client))
    (herdr-claude-code-ide-mcp--cancel-work adapter)
    (when-let* ((server (herdr-claude-code-ide-mcp-adapter-server adapter)))
      (if (fboundp 'websocket-server-close)
          (ignore-errors (websocket-server-close server))
        (when (process-live-p server) (delete-process server))))
    (when-let* ((lockfile (herdr-claude-code-ide-mcp-adapter-lockfile adapter)))
      (when (file-exists-p lockfile) (delete-file lockfile)))
    (remhash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
             herdr-claude-code-ide-mcp--adapters)
    (when-let* ((session (herdr-claude-code-ide-mcp-adapter-session adapter)))
      (remhash session herdr-claude-code-ide-mcp--starting))
    (setf (herdr-claude-code-ide-mcp-adapter-clients adapter) nil
          (herdr-claude-code-ide-mcp-adapter-current-client adapter) nil
          (herdr-claude-code-ide-mcp-adapter-endpoint-live-p adapter) nil
          (herdr-claude-code-ide-mcp-adapter-state adapter) 'stopped))
  (setf (herdr-claude-code-ide-mcp-adapter-clients adapter) nil
        (herdr-claude-code-ide-mcp-adapter-current-client adapter) nil)
  (remhash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
           herdr-claude-code-ide-mcp--adapters)
  (when-let* ((session (herdr-claude-code-ide-mcp-adapter-session adapter)))
    (remhash session herdr-claude-code-ide-mcp--starting))
  (setq herdr-claude-code-ide-mcp--global-hooks-installed
        (or (> (hash-table-count herdr-claude-code-ide-mcp--adapters) 0)
            (> (hash-table-count herdr-claude-code-ide-mcp--starting) 0)))
  adapter)

(defun herdr-claude-code-ide-mcp-agent-released (adapter)
  (herdr-claude-code-ide-mcp-cleanup adapter))

(defun herdr-claude-code-ide-mcp-global-hooks-installed-p ()
  herdr-claude-code-ide-mcp--global-hooks-installed)

(cl-defun herdr-claude-code-ide-mcp-adopt (session &key takeover project-root discovery-directory)
  (when (equal (herdr-agent-session-kind session) "claude")
    (let* ((key (herdr-agent-session-key session))
           (adapter (or (gethash key herdr-claude-code-ide-mcp--adapters)
                        (gethash session herdr-claude-code-ide-mcp--starting)
                        (herdr-claude-code-ide-mcp-prepare
                         `((agent . "claude") (terminal_id . ,(herdr-agent-session-terminal session))
                           (name . ,(herdr-agent-session-name session)))
                         :server-key (herdr-agent-session-server session)
                         :project-root (or project-root (herdr-agent-session-project session))
                         :instance-id (herdr-agent-session-terminal session)
                         :discovery-directory (or discovery-directory
                                                  (expand-file-name ".claude/ide" (getenv "HOME")))
                         :session session))))
      (unless (equal (herdr-claude-code-ide-mcp-adapter-session-key adapter) key)
        (remhash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
                 herdr-claude-code-ide-mcp--adapters)
        (setf (herdr-claude-code-ide-mcp-adapter-session-key adapter) key))
      (puthash key adapter herdr-claude-code-ide-mcp--adapters)
      (puthash session adapter herdr-claude-code-ide-mcp--starting)
      (herdr-claude-code-ide-mcp-terminal-attached adapter)
      (when takeover
        (let ((herdr-socket-path (herdr-agent-session-server session)))
          (herdr-api-pane-send-text (herdr-agent-session-pane session) "/ide\n")))
      adapter)))

(defun herdr-claude-code-ide-mcp--prepare-session (session)
  (let ((adapter
         (herdr-claude-code-ide-mcp-prepare
          `((agent . "claude") (terminal_id . ,(herdr-agent-session-name session))
            (name . ,(herdr-agent-session-name session)))
          :server-key (herdr-agent-session-server session)
          :project-root (herdr-agent-session-project session)
          :instance-id (herdr-agent-session-name session)
          :discovery-directory (expand-file-name ".claude/ide" (getenv "HOME"))
          :session session)))
    (herdr-claude-code-ide-mcp-adapter-environment adapter)))

(defun herdr-claude-code-ide-mcp--attached-session (session)
  (when-let* ((adapter (or (gethash session herdr-claude-code-ide-mcp--starting)
                           (gethash (herdr-agent-session-key session)
                                    herdr-claude-code-ide-mcp--adapters))))
    (remhash session herdr-claude-code-ide-mcp--starting)
    (remhash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
             herdr-claude-code-ide-mcp--adapters)
    (setf (herdr-claude-code-ide-mcp-adapter-session adapter) session
          (herdr-claude-code-ide-mcp-adapter-session-key adapter) (herdr-agent-session-key session)
          (herdr-claude-code-ide-mcp-adapter-instance-id adapter) (herdr-agent-session-terminal session))
    (puthash (herdr-agent-session-key session) adapter herdr-claude-code-ide-mcp--adapters)
    (herdr-claude-code-ide-mcp-terminal-attached adapter)))

(defun herdr-claude-code-ide-mcp--detach-session (session)
  (when-let* ((adapter (or (gethash (herdr-agent-session-key session)
                                    herdr-claude-code-ide-mcp--adapters)
                           (gethash session herdr-claude-code-ide-mcp--starting))))
    (herdr-claude-code-ide-mcp-cleanup adapter)))

(setq herdr-agent-kind-adapters
      (cons (list "claude" :prepare #'herdr-claude-code-ide-mcp--prepare-session
                  :adopted #'herdr-claude-code-ide-mcp-adopt
                  :attached #'herdr-claude-code-ide-mcp--attached-session
                  :detach #'herdr-claude-code-ide-mcp--detach-session)
            (assq-delete-all "claude" herdr-agent-kind-adapters)))

(provide 'herdr-claude-code-ide-mcp)
;;; herdr-claude-code-ide-mcp.el ends here
