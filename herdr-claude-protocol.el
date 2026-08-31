;;; herdr-claude-protocol.el --- Claude protocol transport for Herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; MCP transport and lifecycle state for Claude editor sessions.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'herdr-agent)
(require 'herdr-claude-editor)

(declare-function websocket-server "websocket" (port &rest plist))
(declare-function websocket-server-close "websocket" (server))
(declare-function websocket-close "websocket" (websocket))
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-frame-text "websocket" (frame))

(cl-defstruct herdr-claude-protocol-client
  raw open-p initialized-p generation state owner)

(cl-defstruct herdr-claude-protocol-request
  state client generation id owner resolved-p)

(cl-defstruct herdr-claude-protocol-state
  session instance-id instance-name state endpoint endpoint-live-p
  server lockfile discovery environment clients current-client client-generation
  reconnect-deadline reconnect-deadline-seconds reconnect-token tool-list tool-call
  raw-clients)

(defvar herdr-claude-protocol--states (make-hash-table :test #'eq))
(defvar herdr-claude-protocol--global-hooks-installed nil)
(defvar herdr-claude-protocol--defer-close nil)
(defvar herdr-claude-protocol--close-after-send nil)
(defvar herdr-claude-protocol--incoming-observers nil)
(defvar herdr-claude-protocol--outgoing-observers nil)

(defun herdr-claude-protocol--value (key object)
  "Return KEY's value from OBJECT."
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-protocol--registry-states (&optional states)
  "Return states from STATES or the global registry."
  (cond ((hash-table-p states)
         (let (values) (maphash (lambda (_ state) (push state values)) states) values))
        ((null states)
         (herdr-claude-protocol--registry-states herdr-claude-protocol--states))
        ((herdr-claude-protocol-state-p (car states)) states)
        (t (mapcar #'cdr states))))

(defun herdr-claude-protocol--port (server)
  "Return SERVER's listening port."
  (let ((service (plist-get (process-contact server t) :service)))
    (if (stringp service) (string-to-number service) service)))

(defun herdr-claude-protocol--project-root (root)
  "Return ROOT in canonical project form."
  (herdr-agent--project root))

(defun herdr-claude-protocol--same-project-root-p (left right)
  "Return non-nil when LEFT and RIGHT name the same project."
  (and left right
       (equal (herdr-agent--project left) (herdr-agent--project right))))

(defun herdr-claude-protocol--state-root (state)
  "Return STATE's project root."
  (when-let* ((session (herdr-claude-protocol-state-session state))
              (project (herdr-agent-session-project session)))
    (herdr-claude-protocol--project-root project)))

(defun herdr-claude-protocol--current-client-p (state)
  "Return non-nil when STATE has an initialized client."
  (when-let* ((session (herdr-claude-protocol-state-session state))
              ((equal (herdr-agent-session-kind session) "claude"))
              (client (herdr-claude-protocol-state-current-client state)))
    (and (herdr-claude-protocol-client-open-p client)
         (herdr-claude-protocol-client-initialized-p client))))

(defun herdr-claude-protocol--observe (observers state client text)
  "Notify OBSERVERS of TEXT for STATE and CLIENT."
  (dolist (observer (symbol-value observers))
    (condition-case nil
        (funcall observer state client text)
      (error nil))))

(defun herdr-claude-protocol--send (state client payload)
  "Send PAYLOAD through CLIENT for STATE."
  (when (herdr-claude-protocol-client-open-p client)
    (let ((text (json-serialize payload :false-object :json-false :null-object nil)))
      (herdr-claude-protocol--observe
       'herdr-claude-protocol--outgoing-observers state client text)
      (websocket-send-text (herdr-claude-protocol-client-raw client) text)
      t)))

(defun herdr-claude-protocol--notify (client method payload)
  "Send METHOD with PAYLOAD to CLIENT."
  (herdr-claude-protocol--send
   (herdr-claude-protocol-client-state client) client
   `((jsonrpc . "2.0") (method . ,method) (params . ,payload))))

(defun herdr-claude-protocol-broadcast-project-context (states root method payload)
  "Send METHOD and PAYLOAD to initialized states in ROOT.
STATES selects a registry; nil uses the global registry."
  (let ((root (herdr-claude-protocol--project-root root)))
    (dolist (state (herdr-claude-protocol--registry-states states))
      (when (and (herdr-claude-protocol--same-project-root-p
                  root (herdr-claude-protocol--state-root state))
                 (herdr-claude-protocol--current-client-p state))
        (herdr-claude-protocol--notify
         (herdr-claude-protocol-state-current-client state) method payload)))))

(defun herdr-claude-protocol--selection-payload (snapshot)
  "Convert normalized editor SNAPSHOT to Claude selection payload."
  `((filePath . ,(plist-get snapshot :file))
    (text . ,(plist-get snapshot :text))
    (selection . ((start . ((line . ,(plist-get snapshot :start-line))
                            (character . ,(plist-get snapshot :start-column))))
                  (end . ((line . ,(plist-get snapshot :end-line))
                          (character . ,(plist-get snapshot :end-column))))))))

(defun herdr-claude-protocol--cancel-selection (state)
  "Cancel STATE's pending editor selection notification."
  (when-let* ((client (herdr-claude-protocol-state-current-client state))
              (owner (herdr-claude-protocol-client-owner client)))
    (herdr-claude-editor-cancel-selection owner)))

(defun herdr-claude-protocol--schedule-selection (state buffer)
  "Schedule a selection notification for STATE from BUFFER."
  (when-let* ((client (herdr-claude-protocol-state-current-client state))
              (owner (herdr-claude-protocol-client-owner client))
              (root (herdr-claude-protocol--state-root state)))
    (let ((generation (herdr-claude-protocol-state-client-generation state)))
      (herdr-claude-editor-schedule-selection
       owner buffer root
       (lambda ()
         (and (eq client (herdr-claude-protocol-state-current-client state))
              (= generation (herdr-claude-protocol-state-client-generation state))
              (herdr-claude-protocol--current-client-p state)))
       (lambda (snapshot)
         (herdr-claude-protocol--notify
          client "selection_changed"
          (herdr-claude-protocol--selection-payload snapshot)))))))

(defun herdr-claude-protocol-selection-context-changed (&optional states root buffer)
  "Schedule selection notifications from BUFFER for matching states in ROOT.
STATES selects a registry; BUFFER defaults to current."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((file (buffer-file-name buffer)))
      (dolist (state (herdr-claude-protocol--registry-states states))
        (when (herdr-claude-protocol--current-client-p state)
          (let ((state-root (herdr-claude-protocol--state-root state)))
            (when (and state-root
                       (or (null root)
                           (herdr-claude-protocol--same-project-root-p
                            (herdr-claude-protocol--project-root root) state-root))
                       (herdr-claude-editor--project-file-p file state-root))
              (herdr-claude-protocol--schedule-selection state buffer))))))))

(defun herdr-claude-protocol--state-for-target (target &optional states)
  "Return Claude state for session or composite TARGET from STATES."
  (let ((session
         (cond
          ((herdr-agent-session-p target) target)
          ((consp target) (herdr-agent-find (car target) (cdr target))))))
    (if states
        (cl-find session (herdr-claude-protocol--registry-states states)
                 :key #'herdr-claude-protocol-state-session :test #'eq)
      (and session (gethash session herdr-claude-protocol--states)))))

(defun herdr-claude-protocol-send-at-mentioned (target &optional states)
  "Send the current selection as an at-mention to TARGET in STATES."
  (when-let* ((state (herdr-claude-protocol--state-for-target target states))
              (file (buffer-file-name))
              ((herdr-claude-editor--project-file-p
                file (herdr-claude-protocol--state-root state)))
              ((herdr-claude-protocol--current-client-p state)))
    (let ((mention (herdr-claude-editor-mention)))
      (herdr-claude-protocol--notify
       (herdr-claude-protocol-state-current-client state) "at_mentioned"
       `((filePath . ,(plist-get mention :file))
         (lineStart . ,(plist-get mention :start-line))
         (lineEnd . ,(plist-get mention :end-line)))))))

(defun herdr-claude-protocol--start-server (state)
  "Start STATE's local MCP WebSocket server."
  (unless (require 'websocket nil t)
    (error "Claude protocol transport requires websocket.el"))
  (let ((server
         (websocket-server
          0 :host "127.0.0.1" :protocol '("mcp")
          :on-open (lambda (raw)
                     (puthash raw
                              (herdr-claude-protocol-client-connect state raw)
                              (herdr-claude-protocol-state-raw-clients state)))
          :on-message (lambda (raw frame)
                        (when-let* ((client (gethash raw
                                                     (herdr-claude-protocol-state-raw-clients state))))
                          (let ((herdr-claude-protocol--defer-close t)
                                (herdr-claude-protocol--close-after-send nil))
                            (when-let* ((response (herdr-claude-protocol-receive
                                                   state client (websocket-frame-text frame))))
                              (unwind-protect
                                  (herdr-claude-protocol--send state client response)
                                (when herdr-claude-protocol--close-after-send
                                  (herdr-claude-protocol-client-close state client)))))))
          :on-close (lambda (raw)
                      (when-let* ((client (gethash raw
                                                   (herdr-claude-protocol-state-raw-clients state))))
                        (herdr-claude-protocol-client-close state client))))))
    (setf (herdr-claude-protocol-state-server state) server)
    (herdr-claude-protocol--port server)))

(defun herdr-claude-protocol--default-tools ()
  "Return the default MCP tool definitions."
  (let ((empty-properties (make-hash-table :test #'equal)))
    (list
     '((name . "openFile") (description . "Open a file in the editor.")
       (inputSchema . ((type . "object")
                       (properties . ((filePath . ((type . "string")))
                                      (startLine . ((type . "integer")))
                                      (endLine . ((type . "integer")))
                                      (startText . ((type . "string")))
                                      (endText . ((type . "string")))))
                       (required . ["filePath"]))))
     '((name . "getDiagnostics") (description . "Get diagnostics for visited files.")
       (inputSchema . ((type . "object") (properties . ((uri . ((type . "string")))))
                       (required . []))))
     '((name . "close_tab") (description . "Release the requesting session view.")
       (inputSchema . ((type . "object")
                       (properties . ((path . ((type . "string")))
                                      (tab_name . ((type . "string")))))
                       (required . []))))
     '((name . "openDiff") (description . "Open an editable diff.")
       (inputSchema . ((type . "object")
                       (properties . ((old_file_path . ((type . "string")))
                                      (new_file_path . ((type . "string")))
                                      (new_file_contents . ((type . "string")))
                                      (tab_name . ((type . "string")))))
                       (required . ["new_file_contents" "new_file_path" "old_file_path" "tab_name"]))))
     `((name . "closeAllDiffTabs") (description . "Close all session-owned diff tabs.")
       (inputSchema . ((type . "object") (properties . ,empty-properties) (required . []))))
     '((name . "executeCode") (description . "Evaluate explicitly enabled Emacs Lisp.")
       (inputSchema . ((type . "object") (properties . ((code . ((type . "string")))))
                       (required . ["code"])))))))

(defun herdr-claude-protocol--available-tools ()
  "Return the currently enabled Claude tool definitions."
  (seq-remove
   (lambda (tool)
     (and (not herdr-claude-enable-elisp-tool)
          (equal (herdr-claude-protocol--value 'name tool) "executeCode")))
   (herdr-claude-protocol--default-tools)))

(defun herdr-claude-protocol--normalize-tool-call (name arguments)
  "Convert wire tool NAME and ARGUMENTS to one normalized editor request."
  (when (listp arguments)
    (pcase name
      ("openFile"
       (cons 'open-file
             (list :path (herdr-claude-protocol--value 'filePath arguments)
                   :start-line (herdr-claude-protocol--value 'startLine arguments)
                   :end-line (herdr-claude-protocol--value 'endLine arguments)
                   :start-text (herdr-claude-protocol--value 'startText arguments)
                   :end-text (herdr-claude-protocol--value 'endText arguments))))
      ("getDiagnostics"
       (cons 'diagnostics
             (list :uri (herdr-claude-protocol--value 'uri arguments))))
      ("close_tab"
       (cons 'close-tab
             (list :path (herdr-claude-protocol--value 'path arguments)
                   :tab-name (herdr-claude-protocol--value 'tab_name arguments))))
      ("openDiff"
       (cons 'open-diff
             (list :old-path (herdr-claude-protocol--value 'old_file_path arguments)
                   :new-path (herdr-claude-protocol--value 'new_file_path arguments)
                   :contents (herdr-claude-protocol--value 'new_file_contents arguments)
                   :tab-name (herdr-claude-protocol--value 'tab_name arguments))))
      ("closeAllDiffTabs" (cons 'close-diffs nil))
      ("executeCode"
       (cons 'execute
             (list :code (herdr-claude-protocol--value 'code arguments)))))))

(defun herdr-claude-protocol--editor-result (result)
  "Convert normalized editor RESULT to a Claude tool result."
  (when (herdr-claude-editor-result-p result)
    (pcase (herdr-claude-editor-result-kind result)
      ('text
       `((content . [((type . "text")
                      (text . ,(herdr-claude-editor-result-value result)))])))
      ('diagnostics
       `((content . ,(vconcat
                      (mapcar
                       (lambda (diagnostic)
                         `((filePath . ,(plist-get diagnostic :file))
                           (message . ,(plist-get diagnostic :message))
                           (line . ,(plist-get diagnostic :line))
                           (column . ,(plist-get diagnostic :column))
                           (severity . ,(plist-get diagnostic :severity))))
                       (append (herdr-claude-editor-result-value result) nil)))))))))

(defun herdr-claude-protocol--request-current-p (request)
  "Return non-nil when REQUEST may still send a response."
  (let ((state (herdr-claude-protocol-request-state request))
        (client (herdr-claude-protocol-request-client request)))
    (and (not (herdr-claude-protocol-request-resolved-p request))
         (eq client (herdr-claude-protocol-state-current-client state))
         (herdr-claude-protocol-client-open-p client)
         (herdr-claude-protocol-client-initialized-p client)
         (= (herdr-claude-protocol-request-generation request)
            (herdr-claude-protocol-state-client-generation state)))))

(defun herdr-claude-protocol-resolve (request result)
  "Resolve opaque REQUEST with normalized editor RESULT."
  (when (herdr-claude-protocol--request-current-p request)
    (setf (herdr-claude-protocol-request-resolved-p request) t)
    (herdr-claude-protocol--send
     (herdr-claude-protocol-request-state request)
     (herdr-claude-protocol-request-client request)
     (herdr-claude-protocol--response
      (herdr-claude-protocol-request-id request)
      (herdr-claude-protocol--editor-result result)))))

(defun herdr-claude-protocol-reject (request code message)
  "Reject opaque REQUEST with CODE and MESSAGE."
  (when (herdr-claude-protocol--request-current-p request)
    (setf (herdr-claude-protocol-request-resolved-p request) t)
    (herdr-claude-protocol--send
     (herdr-claude-protocol-request-state request)
     (herdr-claude-protocol-request-client request)
     (herdr-claude-protocol--error
      (herdr-claude-protocol-request-id request) code message))))

(defun herdr-claude-protocol--dispatch-editor (state name arguments request)
  "Dispatch Claude tool NAME and ARGUMENTS for STATE using opaque REQUEST."
  (if-let* ((normalized (herdr-claude-protocol--normalize-tool-call name arguments)))
      (herdr-claude-editor-dispatch
       (herdr-claude-protocol-request-owner request)
       (herdr-claude-protocol--state-root state)
       (car normalized) (cdr normalized)
       (list :resolve (lambda (result)
                        (herdr-claude-protocol-resolve request result))
             :cancel (lambda (&optional _result)
                       (herdr-claude-protocol-reject
                        request -32800 "Request cancelled"))))
    (cons herdr-claude-editor--invalid-params "Invalid params")))

(defun herdr-claude-protocol--initialize-result ()
  "Return the MCP initialize response."
  `((protocolVersion . "2025-11-25")
    (capabilities . ((tools . ((listChanged . t)))
                     (resources . ((subscribe . :json-false) (listChanged . :json-false)))
                     (prompts . ((listChanged . t)))))
    (serverInfo . ((name . "herdr") (version . ,herdr-version)))))

(defun herdr-claude-protocol--response (id result)
  "Return a JSON-RPC success response for ID and RESULT."
  `((jsonrpc . "2.0") (id . ,id) (result . ,result)))

(defun herdr-claude-protocol--error (id code message)
  "Return a JSON-RPC error response for ID, CODE, and MESSAGE."
  `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message)))))

(defun herdr-claude-protocol--close-raw (client)
  "Close CLIENT's raw WebSocket connection."
  (when-let* ((raw (herdr-claude-protocol-client-raw client)))
    (when (fboundp 'websocket-close)
      (let* ((state (herdr-claude-protocol-client-state client))
             (raw-clients (herdr-claude-protocol-state-raw-clients state))
             (mapped (eq (gethash raw raw-clients) client)))
        (when mapped (remhash raw raw-clients))
        (condition-case err
            (websocket-close raw)
          (error
           (when mapped (puthash raw client raw-clients))
           (signal (car err) (cdr err))))))))

(defun herdr-claude-protocol--cancel-work (state)
  "Cancel editor work owned by STATE's current client."
  (condition-case nil
      (if-let* ((client (herdr-claude-protocol-state-current-client state))
                (owner (herdr-claude-protocol-client-owner client)))
          (herdr-claude-editor-cancel owner)
        t)
    (error nil)))

(defun herdr-claude-protocol--publish-discovery (lockfile discovery)
  "Atomically publish DISCOVERY at LOCKFILE with mode 0600."
  (let ((temporary (make-temp-file (concat lockfile "."))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (insert (json-serialize discovery)))
          (set-file-modes temporary #o600)
          (rename-file temporary lockfile t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun herdr-claude-protocol--cancel-deadline (state)
  "Cancel STATE's reconnect deadline."
  (when-let* ((timer (herdr-claude-protocol-state-reconnect-deadline state)))
    (cancel-timer timer))
  (setf (herdr-claude-protocol-state-reconnect-deadline state) nil
        (herdr-claude-protocol-state-reconnect-token state) nil))

(defun herdr-claude-protocol--arm-deadline (state generation)
  "Arm STATE's reconnect deadline for GENERATION."
  (let ((token (make-symbol "reconnect")))
    (setf (herdr-claude-protocol-state-reconnect-token state) token
          (herdr-claude-protocol-state-reconnect-deadline-seconds state) 30
          (herdr-claude-protocol-state-reconnect-deadline state)
          (run-at-time 30 nil
                       (lambda ()
                         (when (and (eq token (herdr-claude-protocol-state-reconnect-token state))
                                    (eq generation (herdr-claude-protocol-state-client-generation state))
                                    (null (herdr-claude-protocol-state-current-client state))
                                    (eq (herdr-claude-protocol-state-state state) 'waiting-for-client))
                           (setf (herdr-claude-protocol-state-reconnect-deadline state) nil)
                           (herdr-claude-protocol-cleanup state)))))))

(cl-defun herdr-claude-protocol-prepare
    (agent &key server-key project-root instance-id discovery-directory
           tool-list tool-call session)
  "Prepare Claude protocol state for AGENT on SERVER-KEY.
PROJECT-ROOT, INSTANCE-ID, DISCOVERY-DIRECTORY, TOOL-LIST, TOOL-CALL, and
SESSION configure it."
  (when (equal (herdr-claude-protocol--value 'agent agent) "claude")
    (or (and session (gethash session herdr-claude-protocol--states))
        (let* ((instance-id (or instance-id
                                (herdr-claude-protocol--value 'terminal_id agent)))
               (state (make-herdr-claude-protocol-state
                       :session session :instance-id instance-id
                       :instance-name (format "%s/%s/%s" server-key
                                              (herdr-claude-protocol--value 'name agent)
                                              instance-id)
                       :state 'starting :client-generation 0
                       :tool-list (or tool-list #'herdr-claude-protocol--available-tools)
                       :tool-call (or tool-call #'herdr-claude-protocol--dispatch-editor)
                       :raw-clients (make-hash-table :test #'eq)))
               (port (herdr-claude-protocol--start-server state))
               (root (expand-file-name project-root))
               (directory (file-name-as-directory
                           (expand-file-name discovery-directory)))
               (lockfile (expand-file-name (format "%s.lock" port) directory))
               (discovery `((pid . ,(emacs-pid))
                            (workspaceFolders . ,(vector root))
                            (ideName . ,(format "herdr %s"
                                                (herdr-claude-protocol-state-instance-name state)))
                            (transport . "ws"))))
          (condition-case err
              (progn
                (make-directory directory t)
                (herdr-claude-protocol--publish-discovery lockfile discovery)
                (setf (herdr-claude-protocol-state-endpoint state)
                      (format "ws://127.0.0.1:%s" port)
                      (herdr-claude-protocol-state-endpoint-live-p state) t
                      (herdr-claude-protocol-state-lockfile state) lockfile
                      (herdr-claude-protocol-state-discovery state)
                      (json-parse-string
                       (json-serialize discovery) :object-type 'alist :array-type 'list
                       :null-object nil :false-object :json-false)
                      (herdr-claude-protocol-state-environment state)
                      (append
                       `((CLAUDE_CODE_SSE_PORT . ,(number-to-string port))
                         (FORCE_CODE_TERMINAL . "true") (TERM_PROGRAM . "emacs"))
                       (when-let* ((configured (getenv "CLAUDE_CONFIG_DIR"))
                                   ((not (string= configured ""))))
                         `((CLAUDE_CONFIG_DIR . ,configured)))))
                (puthash (or session state) state herdr-claude-protocol--states)
                (unless herdr-claude-protocol--global-hooks-installed
                  (add-hook 'post-command-hook
                            #'herdr-claude-protocol-selection-context-changed)
                  (setq herdr-claude-protocol--global-hooks-installed t))
                state)
            (error
             (herdr-claude-protocol-cleanup state)
             (signal (car err) (cdr err))))))))

(defun herdr-claude-protocol-client-connect (state &optional raw)
  "Create a client for STATE and optional RAW connection."
  (let ((client (make-herdr-claude-protocol-client
                 :raw raw :open-p t :state state)))
    (push client (herdr-claude-protocol-state-clients state))
    client))

(defun herdr-claude-protocol--known-tool-p (state name)
  "Return NAME's tool from STATE, if present."
  (seq-find (lambda (tool) (equal (herdr-claude-protocol--value 'name tool) name))
            (funcall (herdr-claude-protocol-state-tool-list state))))

(defun herdr-claude-protocol--initialize-params-p (params)
  "Return non-nil when PARAMS is a valid initialize payload."
  (and (listp params)
       (equal (herdr-claude-protocol--value 'protocolVersion params) "2025-11-25")
       (let ((capabilities (or (assoc 'capabilities params)
                               (assoc "capabilities" params))))
         (and capabilities (listp (cdr capabilities))))
       (let ((client-info (herdr-claude-protocol--value 'clientInfo params)))
         (and (listp client-info)
              (stringp (herdr-claude-protocol--value 'name client-info))
              (stringp (herdr-claude-protocol--value 'version client-info))))))

(defun herdr-claude-protocol--initialize-params (text)
  "Return initialize parameters parsed from TEXT."
  (herdr-claude-protocol--value
   'params
   (json-parse-string text :object-type 'alist :array-type 'array
                      :null-object :json-null :false-object :json-false)))

(defun herdr-claude-protocol--reject-initialize (state client id close code message)
  "Reject CLIENT initialization on STATE with CODE and MESSAGE."
  (when close
    (if herdr-claude-protocol--defer-close
        (setq herdr-claude-protocol--close-after-send t)
      (herdr-claude-protocol-client-close state client)))
  (herdr-claude-protocol--error id code message))

(defun herdr-claude-protocol--initialize (state client id params)
  "Initialize CLIENT on STATE with ID and PARAMS."
  (if (memq (herdr-claude-protocol-state-state state) '(detaching stopped))
      (progn
        (herdr-claude-protocol-client-close state client)
        nil)
    (let ((old (herdr-claude-protocol-state-current-client state)))
      (cond
       ((not (herdr-claude-protocol--initialize-params-p params))
        (herdr-claude-protocol--reject-initialize
         state client id (not (eq client old)) -32602 "Invalid params"))
       ((eq client old)
        (herdr-claude-protocol--error id -32602 "Invalid params"))
       (t
        (if (and old (not (herdr-claude-protocol--cancel-work state)))
            (herdr-claude-protocol--reject-initialize
             state client id t -32603 "Internal error")
          (when old (herdr-claude-protocol--cancel-selection state))
          (herdr-claude-protocol--cancel-deadline state)
          (setf (herdr-claude-protocol-state-current-client state) client
                (herdr-claude-protocol-state-client-generation state)
                (1+ (or (herdr-claude-protocol-state-client-generation state) 0))
                (herdr-claude-protocol-client-initialized-p client) t
                (herdr-claude-protocol-client-generation client)
                (herdr-claude-protocol-state-client-generation state)
                (herdr-claude-protocol-client-owner client)
                (make-symbol "herdr-claude-editor-owner"))
          (when old (herdr-claude-protocol-client-close state old))
          (unless (eq (herdr-claude-protocol-state-state state) 'starting)
            (setf (herdr-claude-protocol-state-state state) 'connected))
          (herdr-claude-protocol--response
           id (herdr-claude-protocol--initialize-result))))))))

(defun herdr-claude-protocol-receive (state client text)
  "Process TEXT received from CLIENT for STATE."
  (setf (herdr-claude-protocol-client-state client) state)
  (herdr-claude-protocol--observe
   'herdr-claude-protocol--incoming-observers state client text)
  (when (herdr-claude-protocol-client-open-p client)
    (condition-case nil
        (let* ((message (json-parse-string text :object-type 'alist :array-type 'list
                                           :null-object nil :false-object :json-false))
               (id (herdr-claude-protocol--value 'id message))
               (method (herdr-claude-protocol--value 'method message))
               (params (herdr-claude-protocol--value 'params message)))
          (cond
           ((or (not (listp message)) (not (equal (herdr-claude-protocol--value 'jsonrpc message) "2.0"))
                (not (stringp method)))
            (herdr-claude-protocol--error nil -32600 "Invalid Request"))
           ((equal method "initialize")
            (herdr-claude-protocol--initialize
             state client id (herdr-claude-protocol--initialize-params text)))
           ((or (not (eq client (herdr-claude-protocol-state-current-client state)))
                (not (herdr-claude-protocol-client-initialized-p client))) nil)
           ((equal method "ide_connected") nil)
           ((equal method "tools/list")
            (herdr-claude-protocol--response id
                                                  `((tools . ,(vconcat (funcall (herdr-claude-protocol-state-tool-list state)))))))
           ((equal method "prompts/list")
            (herdr-claude-protocol--response id '((prompts . []))))
           ((equal method "resources/list")
            (herdr-claude-protocol--response id '((resources . []))))
           ((equal method "tools/call")
            (let* ((name (herdr-claude-protocol--value 'name params))
                   (arguments (herdr-claude-protocol--value 'arguments params)))
              (if (and (stringp name) (herdr-claude-protocol--known-tool-p state name)
                       (functionp (herdr-claude-protocol-state-tool-call state)))
                  (condition-case nil
                      (let* ((request
                              (make-herdr-claude-protocol-request
                               :state state :client client
                               :generation (herdr-claude-protocol-state-client-generation state)
                               :id id :owner (herdr-claude-protocol-client-owner client)))
                             (result
                              (funcall (herdr-claude-protocol-state-tool-call state)
                                       state name arguments request)))
                        (cond
                         ((eq result herdr-claude-editor-deferred) nil)
                         ((eq (car-safe result) herdr-claude-editor--invalid-params)
                          (setf (herdr-claude-protocol-request-resolved-p request) t)
                          (herdr-claude-protocol--error id -32602 (cdr result)))
                         (t
                          (setf (herdr-claude-protocol-request-resolved-p request) t)
                          (herdr-claude-protocol--response
                           id (or (herdr-claude-protocol--editor-result result) result)))))
                    (error (herdr-claude-protocol--error id -32603 "Internal error")))
                (herdr-claude-protocol--error id -32602 "Unknown tool"))))
           (t (herdr-claude-protocol--error id -32601 "Method not found"))))
      (error (herdr-claude-protocol--error nil -32700 "Parse error")))))

(defun herdr-claude-protocol-client-close (state client)
  "Close CLIENT for STATE."
  (let ((current (eq client (herdr-claude-protocol-state-current-client state)))
        (raw (herdr-claude-protocol-client-raw client)))
    (when (and current
               (not (eq (herdr-claude-protocol--cancel-work state) t)))
      (error "Deferred work cancellation is incomplete"))
    (herdr-claude-protocol--close-raw client)
    (setf (herdr-claude-protocol-client-open-p client) nil
          (herdr-claude-protocol-state-clients state)
          (delq client (herdr-claude-protocol-state-clients state)))
    (when (and raw
               (eq (gethash raw (herdr-claude-protocol-state-raw-clients state)) client))
      (remhash raw (herdr-claude-protocol-state-raw-clients state)))
    (when current
      (setf (herdr-claude-protocol-state-current-client state) nil)
      (when (memq (herdr-claude-protocol-state-state state) '(connected waiting-for-client))
        (setf (herdr-claude-protocol-state-state state) 'waiting-for-client)
        (herdr-claude-protocol--arm-deadline
         state (herdr-claude-protocol-state-client-generation state)))))
  nil)

(defun herdr-claude-protocol-terminal-attached (state)
  "Mark STATE's terminal attachment complete."
  (when (eq (herdr-claude-protocol-state-state state) 'starting)
    (setf (herdr-claude-protocol-state-state state)
          (if (herdr-claude-protocol-state-current-client state) 'connected 'waiting-for-client))))

(defun herdr-claude-protocol-cleanup (state)
  "Clean up STATE resources."
  (unless (eq (herdr-claude-protocol-state-state state) 'stopped)
    (setf (herdr-claude-protocol-state-state state) 'detaching)
    (unless (eq (herdr-claude-protocol--cancel-work state) t)
      (error "Deferred work cancellation is incomplete"))
    (herdr-claude-protocol--cancel-deadline state)
    (herdr-claude-protocol--cancel-selection state)
    (let (errors)
      (dolist (client (copy-sequence (herdr-claude-protocol-state-clients state)))
        (condition-case err
            (let ((raw (herdr-claude-protocol-client-raw client)))
              (herdr-claude-protocol--close-raw client)
              (setf (herdr-claude-protocol-client-open-p client) nil
                    (herdr-claude-protocol-state-clients state)
                    (delq client (herdr-claude-protocol-state-clients state)))
              (when (and raw
                         (eq (gethash raw
                                      (herdr-claude-protocol-state-raw-clients state))
                             client))
                (remhash raw (herdr-claude-protocol-state-raw-clients state)))
              (when (eq client (herdr-claude-protocol-state-current-client state))
                (setf (herdr-claude-protocol-state-current-client state) nil)))
          (error (push err errors))))
      (when-let* ((server (herdr-claude-protocol-state-server state)))
        (condition-case err
            (if (fboundp 'websocket-server-close)
                (websocket-server-close server)
              (when (process-live-p server) (delete-process server)))
          (error (push err errors))))
      (if errors
          (signal (caar errors) (cdar errors))
        (when-let* ((lockfile (herdr-claude-protocol-state-lockfile state)))
          (when (file-exists-p lockfile) (delete-file lockfile)))
        (setf (herdr-claude-protocol-state-clients state) nil
              (herdr-claude-protocol-state-current-client state) nil
              (herdr-claude-protocol-state-server state) nil
              (herdr-claude-protocol-state-endpoint-live-p state) nil
              (herdr-claude-protocol-state-discovery state) nil)
        (clrhash (herdr-claude-protocol-state-raw-clients state))
        (remhash (or (herdr-claude-protocol-state-session state) state)
                 herdr-claude-protocol--states)
        (setf (herdr-claude-protocol-state-state state) 'stopped))))
  (let ((active (> (hash-table-count herdr-claude-protocol--states) 0)))
    (unless active
      (remove-hook 'post-command-hook
                   #'herdr-claude-protocol-selection-context-changed))
    (setq herdr-claude-protocol--global-hooks-installed active))
  state)

(defun herdr-claude-protocol-agent-released (state)
  "Clean up STATE after its agent is released."
  (herdr-claude-protocol-cleanup state))

(defun herdr-claude-protocol-global-hooks-installed-p ()
  "Return non-nil when MCP global hooks are installed."
  herdr-claude-protocol--global-hooks-installed)

(defun herdr-claude-protocol--discovery-directory ()
  "Return Claude's IDE discovery directory."
  (let ((configured (getenv "CLAUDE_CONFIG_DIR")))
    (expand-file-name
     "ide"
     (if (and configured (not (string= configured "")))
         configured
       (expand-file-name ".claude" (or (getenv "HOME") "~"))))))

(cl-defun herdr-claude-protocol-adopt
    (session &key project-root discovery-directory)
  "Adopt Claude SESSION into its protocol state.
PROJECT-ROOT and DISCOVERY-DIRECTORY configure a newly prepared state."
  (when (equal (herdr-agent-session-kind session) "claude")
    (let ((state
           (or (gethash session herdr-claude-protocol--states)
               (herdr-claude-protocol-prepare
                `((agent . "claude")
                  (terminal_id . ,(herdr-agent-session-terminal session))
                  (name . ,(herdr-agent-session-name session)))
                :server-key (herdr-agent-session-server session)
                :project-root (or project-root (herdr-agent-session-project session))
                :instance-id (herdr-agent-session-terminal session)
                :discovery-directory
                (or discovery-directory
                    (herdr-claude-protocol--discovery-directory))
                :session session))))
      (herdr-claude-protocol-terminal-attached state)
      state)))

(defun herdr-claude-protocol--prepare-session (session)
  "Prepare Claude protocol state for SESSION."
  (let ((state
         (herdr-claude-protocol-prepare
          `((agent . "claude") (name . ,(herdr-agent-session-name session)))
          :server-key (herdr-agent-session-server session)
          :project-root (herdr-agent-session-project session)
          :instance-id (herdr-agent-session-name session)
          :discovery-directory (herdr-claude-protocol--discovery-directory)
          :session session)))
    (herdr-claude-protocol-state-environment state)))

(defun herdr-claude-protocol--attached-session (session)
  "Complete Claude protocol attachment for SESSION."
  (when-let* ((state (gethash session herdr-claude-protocol--states)))
    (setf (herdr-claude-protocol-state-instance-id state)
          (herdr-agent-session-terminal session))
    (herdr-claude-protocol-terminal-attached state)))

(defun herdr-claude-protocol--status-session (session)
  "Return Claude protocol status for SESSION."
  (when-let* ((state (gethash session herdr-claude-protocol--states)))
    `((integration_label . "Claude editor")
      (integration_status . ,(symbol-name (herdr-claude-protocol-state-state state)))
      (integration_endpoint . ,(herdr-claude-protocol-state-endpoint state)))))

(defun herdr-claude-protocol--detach-session (session)
  "Detach SESSION's Claude protocol state."
  (when-let* ((state (gethash session herdr-claude-protocol--states)))
    (herdr-claude-protocol-cleanup state)))

(defun herdr-claude-protocol-connect (server-key pane-id)
  "Ask Claude in PANE-ID on SERVER-KEY to connect to this endpoint."
  (unless pane-id
    (user-error "Claude agent has no pane"))
  (let ((herdr-socket-path server-key))
    (herdr-api-pane-send-text pane-id "/ide\n")))

(provide 'herdr-claude-protocol)
;;; herdr-claude-protocol.el ends here
