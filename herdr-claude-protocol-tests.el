;;; herdr-claude-protocol-tests.el --- Claude Code IDE protocol tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'herdr-claude-protocol)

(defun herdr-claude-protocol-tests--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-protocol-tests--session (root name &optional terminal)
  (herdr-agent--make-session
   :key (make-symbol name)
   :server (concat "/tmp/" name ".sock")
   :terminal (or terminal name)
   :kind "claude"
   :name name
   :project (file-name-as-directory root)))

(defun herdr-claude-protocol-tests--agent (name terminal)
  `((agent . "claude") (name . ,name) (terminal_id . ,terminal)))

(defun herdr-claude-protocol-tests--valid-params ()
  '((protocolVersion . "2025-11-25")
    (capabilities)
    (clientInfo . ((name . "ERT") (version . "1")))))

(defun herdr-claude-protocol-tests--request (id method &optional params)
  (json-serialize
   `((jsonrpc . "2.0") (id . ,id) (method . ,method)
     ,@(when params `((params . ,params))))))

(defun herdr-claude-protocol-tests--error-code (response)
  (herdr-claude-protocol-tests--value
   'code (herdr-claude-protocol-tests--value 'error response)))

(defun herdr-claude-protocol-tests--prepare (root session &rest options)
  (apply #'herdr-claude-protocol-prepare
         (herdr-claude-protocol-tests--agent
          (herdr-agent-session-name session)
          (herdr-agent-session-terminal session))
         :server-key (herdr-agent-session-server session)
         :project-root root
         :instance-id (herdr-agent-session-terminal session)
         :discovery-directory (expand-file-name "discovery" root)
         :session session
         options))

(defmacro herdr-claude-protocol-tests--with-runtime (&rest body)
  `(let ((process-environment
          (cons "CLAUDE_CONFIG_DIR" process-environment))
         (herdr-claude-protocol--states (make-hash-table :test #'eq))
         (herdr-claude-protocol--global-hooks-installed nil)
         (post-command-hook nil)
         (herdr-claude-protocol--incoming-observers nil)
         (herdr-claude-protocol--outgoing-observers nil)
         (herdr-claude-protocol--defer-close nil)
         (herdr-claude-protocol--close-after-send nil)
         (herdr-claude-enable-elisp-tool nil)
         (herdr-claude-protocol-tests--servers nil)
         (herdr-claude-protocol-tests--server-arguments nil)
         (herdr-claude-protocol-tests--closed-servers nil)
         (herdr-claude-protocol-tests--closed-raw nil)
         (herdr-claude-protocol-tests--sent nil)
         (herdr-claude-protocol-tests--next-port 4200)
         (original-require (symbol-function 'require)))
     (cl-letf (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'websocket)
                      'websocket
                    (funcall original-require feature filename noerror))))
               ((symbol-function 'websocket-server)
                (lambda (&rest arguments)
                  (push arguments herdr-claude-protocol-tests--server-arguments)
                  (let ((server (make-symbol "websocket-server")))
                    (push server herdr-claude-protocol-tests--servers)
                    server)))
               ((symbol-function 'websocket-server-close)
                (lambda (server)
                  (push server herdr-claude-protocol-tests--closed-servers)))
               ((symbol-function 'websocket-close)
                (lambda (raw)
                  (push raw herdr-claude-protocol-tests--closed-raw)))
               ((symbol-function 'websocket-send-text)
                (lambda (raw text)
                  (push (cons raw text) herdr-claude-protocol-tests--sent)))
               ((symbol-function 'herdr-claude-protocol--port)
                (lambda (_server)
                  (cl-incf herdr-claude-protocol-tests--next-port))))
       ,@body)))

(ert-deftest herdr-claude-protocol-prepare-publishes-discovery-and-environment ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((root (make-temp-file "herdr-claude-prepare" t))
          (session (herdr-claude-protocol-tests--session root "review" "term-1"))
          written-modes
          state)
     (unwind-protect
         (progn
           (let ((default-file-modes #o644)
                 (original-write-region (symbol-function 'write-region)))
             (cl-letf (((symbol-function 'write-region)
                        (lambda (&rest arguments)
                          (prog1 (apply original-write-region arguments)
                            (push (file-modes (nth 2 arguments)) written-modes)))))
               (setq state (herdr-claude-protocol-tests--prepare root session))))
           (should (equal written-modes (list #o600)))
           (let* ((lockfile (herdr-claude-protocol-state-lockfile state))
                  (discovery
                   (with-temp-buffer
                     (insert-file-contents lockfile)
                     (json-parse-buffer :object-type 'alist :array-type 'list))))
             (should (equal discovery (herdr-claude-protocol-state-discovery state)))
             (should (= (file-modes lockfile) #o600))
             (should (equal (herdr-claude-protocol-tests--value
                             'workspaceFolders discovery)
                            (list (expand-file-name root))))
             (should (string-match-p
                      "review.*term-1"
                      (herdr-claude-protocol-tests--value 'ideName discovery)))
             (should (equal (herdr-claude-protocol-tests--value 'transport discovery)
                            "ws")))
           (let ((arguments (car herdr-claude-protocol-tests--server-arguments)))
             (should (zerop (car arguments)))
             (should (equal (plist-get (cdr arguments) :host) "127.0.0.1"))
             (should (equal (plist-get (cdr arguments) :protocol) '("mcp"))))
           (should (equal (herdr-claude-protocol-state-endpoint state)
                          "ws://127.0.0.1:4201"))
           (should
            (equal (herdr-claude-protocol-state-environment state)
                   '((CLAUDE_CODE_SSE_PORT . "4201")
                     (FORCE_CODE_TERMINAL . "true")
                     (TERM_PROGRAM . "emacs"))))
           (should (eq (gethash session herdr-claude-protocol--states) state))
           (should (memq #'herdr-claude-protocol-selection-context-changed
                         post-command-hook))
           (let* ((config (expand-file-name "claude-config" root))
                  (process-environment
                   (cons (format "CLAUDE_CONFIG_DIR=%s" config)
                         process-environment))
                  (configured-session
                   (herdr-claude-protocol-tests--session
                    root "configured" "term-configured"))
                  configured-state)
             (unwind-protect
                 (progn
                   (herdr-claude-protocol--prepare-session configured-session)
                   (setq configured-state
                         (gethash configured-session herdr-claude-protocol--states))
                   (should
                    (string-prefix-p
                     (file-name-as-directory (expand-file-name "ide" config))
                     (herdr-claude-protocol-state-lockfile configured-state)))
                   (should
                    (equal
                     (alist-get
                      'CLAUDE_CONFIG_DIR
                      (herdr-claude-protocol-state-environment configured-state))
                     config)))
               (when configured-state
                 (herdr-claude-protocol-cleanup configured-state))))
           (should-not
            (herdr-claude-protocol-prepare
             '((agent . "codex")) :server-key "ignored" :project-root root
             :discovery-directory root)))
       (when state (herdr-claude-protocol-cleanup state))
       (delete-directory root t)))))





(ert-deftest herdr-claude-protocol-mcp-initialize-and-listing-contract ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((state (make-herdr-claude-protocol-state
                  :state 'waiting-for-client :client-generation 0
                  :tool-list #'herdr-claude-protocol--available-tools
                  :raw-clients (make-hash-table :test #'eq)))
          (client (herdr-claude-protocol-client-connect state))
          (initialize
           (herdr-claude-protocol-receive
            state client
            (herdr-claude-protocol-tests--request
             1 "initialize" (herdr-claude-protocol-tests--valid-params))))
          (result (herdr-claude-protocol-tests--value 'result initialize)))
     (should (equal (herdr-claude-protocol-tests--value 'protocolVersion result)
                    "2025-11-25"))
     (should (equal (herdr-claude-protocol-tests--value
                     'name (herdr-claude-protocol-tests--value 'serverInfo result))
                    "herdr"))
     (should
      (equal (herdr-claude-protocol-tests--value 'capabilities result)
             '((tools . ((listChanged . t)))
               (resources . ((subscribe . :json-false) (listChanged . :json-false)))
               (prompts . ((listChanged . t))))))
     (let* ((response (herdr-claude-protocol-receive
                       state client
                       (herdr-claude-protocol-tests--request 2 "tools/list")))
            (tools (herdr-claude-protocol-tests--value
                    'tools (herdr-claude-protocol-tests--value 'result response))))
       (should (vectorp tools))
       (should (equal (mapcar (lambda (tool)
                               (herdr-claude-protocol-tests--value 'name tool))
                             (append tools nil))
                      '("openFile" "getDiagnostics" "close_tab" "openDiff"
                        "closeAllDiffTabs"))))
     (dolist (entry '(("prompts/list" . prompts) ("resources/list" . resources)))
       (let* ((response (herdr-claude-protocol-receive
                         state client
                         (herdr-claude-protocol-tests--request 3 (car entry))))
              (listed (herdr-claude-protocol-tests--value
                       (cdr entry)
                       (herdr-claude-protocol-tests--value 'result response))))
         (should (equal listed [])))))))

(ert-deftest herdr-claude-protocol-mcp-errors-are-json-rpc-specific ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((tool '((name . "openFile")))
          (state (make-herdr-claude-protocol-state
                  :state 'connected :client-generation 1
                  :tool-list (lambda () (list tool))
                  :tool-call (lambda (&rest _) (error "handler failed"))
                  :raw-clients (make-hash-table :test #'eq)))
          (client (herdr-claude-protocol-client-connect state)))
     (setf (herdr-claude-protocol-state-current-client state) client
           (herdr-claude-protocol-client-initialized-p client) t)
     (should (= (herdr-claude-protocol-tests--error-code
                 (herdr-claude-protocol-receive state client "{"))
                -32700))
     (should (= (herdr-claude-protocol-tests--error-code
                 (herdr-claude-protocol-receive
                  state client (json-serialize '((jsonrpc . "1.0") (method . "x")))))
                -32600))
     (should (= (herdr-claude-protocol-tests--error-code
                 (herdr-claude-protocol-receive
                  state client (herdr-claude-protocol-tests--request 2 "missing")))
                -32601))
     (should (= (herdr-claude-protocol-tests--error-code
                 (herdr-claude-protocol-receive
                  state client
                  (herdr-claude-protocol-tests--request
                   3 "tools/call" '((name . "missing") (arguments)))))
                -32602))
     (should (= (herdr-claude-protocol-tests--error-code
                 (herdr-claude-protocol-receive
                  state client
                  (herdr-claude-protocol-tests--request
                   4 "tools/call"
                   '((name . "openFile") (arguments . ((filePath . "a")))))))
                -32603)))))


(ert-deftest herdr-claude-protocol-mcp-tool-call-converts-editor-results ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((seen nil)
          (state (make-herdr-claude-protocol-state
                  :state 'connected :client-generation 1
                  :tool-list (lambda () '(((name . "openFile"))))
                  :tool-call
                  (lambda (_state name arguments request)
                    (setq seen (list name arguments
                                     (herdr-claude-protocol-request-owner request)))
                    (make-herdr-claude-editor-result :kind 'text :value "opened"))
                  :raw-clients (make-hash-table :test #'eq)))
          (client (herdr-claude-protocol-client-connect state)))
     (setf (herdr-claude-protocol-state-current-client state) client
           (herdr-claude-protocol-client-initialized-p client) t
           (herdr-claude-protocol-client-owner client) 'request-owner)
     (let* ((response
             (herdr-claude-protocol-receive
              state client
              (herdr-claude-protocol-tests--request
               7 "tools/call"
               '((name . "openFile") (arguments . ((filePath . "a.el")))))))
            (result (herdr-claude-protocol-tests--value 'result response)))
       (should (equal seen '("openFile" ((filePath . "a.el")) request-owner)))
       (should
        (equal result
               '((content . [((type . "text") (text . "opened"))]))))))))



(ert-deftest herdr-claude-protocol-reconnect-deadline-is-current-client-scoped ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((root (make-temp-file "herdr-claude-reconnect" t))
          (session (herdr-claude-protocol-tests--session root "reconnect"))
          (callbacks nil)
          state)
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (seconds _repeat callback &rest arguments)
                  (should (= seconds 30))
                  (let ((timer (lambda () (apply callback arguments))))
                    (setq callbacks (append callbacks (list timer)))
                    timer)))
               ((symbol-function 'cancel-timer) (lambda (&rest _) nil)))
       (unwind-protect
           (progn
             (setq state (herdr-claude-protocol-tests--prepare root session))
             (herdr-claude-protocol-terminal-attached state)
             (let ((current (herdr-claude-protocol-client-connect state 'current))
                   (bystander (herdr-claude-protocol-client-connect state 'bystander)))
               (herdr-claude-protocol--initialize
                state current 1 (herdr-claude-protocol-tests--valid-params))
               (herdr-claude-protocol-client-close state bystander)
               (should-not callbacks)
               (cl-letf (((symbol-function 'herdr-claude-editor-cancel)
                          (lambda (owner)
                            (should (eq owner
                                        (herdr-claude-protocol-client-owner
                                         current)))
                            nil)))
                 (should-error
                  (herdr-claude-protocol-client-close state current)
                  :type 'error)
                 (should (eq (herdr-claude-protocol-state-current-client state)
                             current))
                 (should (herdr-claude-protocol-client-open-p current))
                 (should (memq current
                               (herdr-claude-protocol-state-clients state)))
                 (should-not callbacks))
               (herdr-claude-protocol-client-close state current)
               (should (= (length callbacks) 1))
               (should (= (herdr-claude-protocol-state-reconnect-deadline-seconds state)
                          30))
               (let ((replacement
                      (herdr-claude-protocol-client-connect state 'replacement)))
                 (herdr-claude-protocol--initialize
                  state replacement 2 (herdr-claude-protocol-tests--valid-params))
                 (funcall (car callbacks))
                 (should (eq (herdr-claude-protocol-state-state state) 'connected))
                 (should (eq (herdr-claude-protocol-state-current-client state)
                             replacement))
                 (herdr-claude-protocol-client-close state replacement)
                 (should (= (length callbacks) 2))
                 (funcall (cadr callbacks))
                 (should (eq (herdr-claude-protocol-state-state state) 'stopped)))))
         (when state (herdr-claude-protocol-cleanup state))
         (delete-directory root t))))))


(ert-deftest herdr-claude-protocol-context-broadcast-and-selection-target-project ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((root-a (make-temp-file "herdr-claude-context-a" t))
          (root-b (make-temp-file "herdr-claude-context-b" t))
          (file-a (expand-file-name "a.el" root-a))
          (session-a (herdr-claude-protocol-tests--session root-a "a"))
          (session-b (herdr-claude-protocol-tests--session root-b "b"))
          (state-a (make-herdr-claude-protocol-state
                    :session session-a :client-generation 1))
          (state-b (make-herdr-claude-protocol-state
                    :session session-b :client-generation 1))
          (client-a (make-herdr-claude-protocol-client
                     :raw 'raw-a :open-p t :initialized-p t :state state-a))
          (client-b (make-herdr-claude-protocol-client
                     :raw 'raw-b :open-p t :initialized-p t :state state-b))
          scheduled)
     (unwind-protect
         (progn
           (with-temp-file file-a (insert "(message \"a\")\n"))
           (setf (herdr-claude-protocol-state-current-client state-a) client-a
                 (herdr-claude-protocol-state-current-client state-b) client-b)
           (puthash session-a state-a herdr-claude-protocol--states)
           (puthash session-b state-b herdr-claude-protocol--states)
           (herdr-claude-protocol-broadcast-project-context
            nil root-a "workspace_updated" '((revision . 3)))
           (should (= (length herdr-claude-protocol-tests--sent) 1))
           (should (eq (caar herdr-claude-protocol-tests--sent) 'raw-a))
           (let ((buffer (find-file-noselect file-a)))
             (unwind-protect
                 (cl-letf (((symbol-function 'herdr-claude-protocol--schedule-selection)
                            (lambda (state selected-buffer)
                              (push (cons state selected-buffer) scheduled))))
                   (herdr-claude-protocol-selection-context-changed
                    nil root-a buffer)
                   (should (= (length scheduled) 1))
                   (should (eq (caar scheduled) state-a))
                   (should (eq (cdar scheduled) buffer)))
               (kill-buffer buffer)))
           (should
            (equal
             (herdr-claude-protocol--selection-payload
              '(:file "/tmp/a.el" :text "x" :start-line 1 :start-column 2
                :end-line 3 :end-column 4))
             '((filePath . "/tmp/a.el") (text . "x")
               (selection . ((start . ((line . 1) (character . 2)))
                             (end . ((line . 3) (character . 4)))))))))
       (delete-directory root-a t)
       (delete-directory root-b t)))))

(ert-deftest herdr-claude-protocol-at-mention-targets-session-or-composite ()
  (herdr-claude-protocol-tests--with-runtime
   (let* ((root (make-temp-file "herdr-claude-mention" t))
          (outside (make-temp-file "herdr-claude-outside" t))
          (file (expand-file-name "mention.el" root))
          (session (herdr-claude-protocol-tests--session root "mention" "terminal"))
          (state (make-herdr-claude-protocol-state
                  :session session :client-generation 1))
          (client (make-herdr-claude-protocol-client
                   :raw 'mention-raw :open-p t :initialized-p t :state state)))
     (unwind-protect
         (progn
           (with-temp-file file (insert "one\ntwo\n"))
           (setf (herdr-claude-protocol-state-current-client state) client)
           (puthash session state herdr-claude-protocol--states)
           (let ((buffer (find-file-noselect file)))
             (unwind-protect
                 (with-current-buffer buffer
                   (cl-letf (((symbol-function 'herdr-claude-editor-mention)
                              (lambda (&optional _)
                                (list :file file :start-line 1 :end-line 2)))
                             ((symbol-function 'herdr-agent-find)
                              (lambda (server terminal)
                                (and (equal server (herdr-agent-session-server session))
                                     (equal terminal "terminal")
                                     session))))
                     (should (herdr-claude-protocol-send-at-mentioned session))
                     (should
                      (herdr-claude-protocol-send-at-mentioned
                       (cons (herdr-agent-session-server session) "terminal")))
                     (should (= (length herdr-claude-protocol-tests--sent) 2))
                     (dolist (wire herdr-claude-protocol-tests--sent)
                       (let* ((message
                               (json-parse-string
                                (cdr wire) :object-type 'alist :array-type 'list))
                              (params
                               (herdr-claude-protocol-tests--value 'params message)))
                         (should (equal
                                  (herdr-claude-protocol-tests--value 'method message)
                                  "at_mentioned"))
                         (should (equal params
                                        `((filePath . ,file)
                                          (lineStart . 1) (lineEnd . 2))))))))
               (kill-buffer buffer)))
           (let ((outside-file (expand-file-name "outside.el" outside)))
             (with-temp-file outside-file (insert "outside\n"))
             (with-temp-buffer
               (setq buffer-file-name outside-file)
               (should-not (herdr-claude-protocol-send-at-mentioned session))))
           (should (= (length herdr-claude-protocol-tests--sent) 2)))
       (delete-directory root t)
       (delete-directory outside t)))))

(provide 'herdr-claude-protocol-tests)
;;; herdr-claude-protocol-tests.el ends here
