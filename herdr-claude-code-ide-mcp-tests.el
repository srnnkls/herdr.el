;;; herdr-claude-code-ide-mcp-tests.el --- Claude Code IDE contract tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'herdr-claude-code-ide-mcp nil t)

(defconst herdr-claude-code-ide-mcp-tests--root
  (file-name-directory (or load-file-name buffer-file-name)))

(defun herdr-claude-code-ide-mcp-tests--fixture (name)
  (let ((path (expand-file-name (concat "testdata/claude-code-ide/" name)
                                herdr-claude-code-ide-mcp-tests--root)))
    (should (file-exists-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (condition-case error-data
          (json-parse-buffer :object-type 'alist :array-type 'list
                             :null-object nil :false-object :json-false)
        (json-parse-error
         (ert-fail (format "%s is not valid JSON: %s" path error-data)))))))

(defun herdr-claude-code-ide-mcp-tests--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-code-ide-mcp-tests--exchange (identifier fixture)
  (seq-find (lambda (exchange)
              (equal (herdr-claude-code-ide-mcp-tests--value 'id exchange)
                     identifier))
            (herdr-claude-code-ide-mcp-tests--value 'exchanges fixture)))

(defun herdr-claude-code-ide-mcp-tests--structured-p (value)
  (and (listp value) value))

(defun herdr-claude-code-ide-mcp-tests--require-captured-exchanges
    (expectations fixture provenance)
  (dolist (exchange (herdr-claude-code-ide-mcp-tests--value 'exchanges fixture))
    (should (stringp (herdr-claude-code-ide-mcp-tests--value 'id exchange)))
    (should (equal (herdr-claude-code-ide-mcp-tests--value 'provenance exchange)
                   provenance))
    (should (herdr-claude-code-ide-mcp-tests--structured-p
             (herdr-claude-code-ide-mcp-tests--value 'payload exchange)))
    (should (stringp (herdr-claude-code-ide-mcp-tests--value 'transport exchange))))
  (dolist (expectation expectations)
    (let* ((identifier (nth 0 expectation))
           (method (nth 1 expectation))
           (transport (nth 2 expectation))
           (category (nth 3 expectation))
           (tool-name (nth 4 expectation))
           (exchange (herdr-claude-code-ide-mcp-tests--exchange identifier fixture)))
      (should exchange)
      (should (equal (herdr-claude-code-ide-mcp-tests--value 'transport exchange)
                     transport))
      (should (equal (herdr-claude-code-ide-mcp-tests--value 'category exchange)
                     category))
      (when method
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'method exchange)
                       method)))
      (when tool-name
        (let ((payload (herdr-claude-code-ide-mcp-tests--value 'payload exchange)))
          (should (equal (or (herdr-claude-code-ide-mcp-tests--value 'name payload)
                             (herdr-claude-code-ide-mcp-tests--value
                              'name
                              (herdr-claude-code-ide-mcp-tests--value 'params payload)))
                         tool-name)))))))

(defun herdr-claude-code-ide-mcp-tests--coordinates-p (coordinates)
  (let ((start (herdr-claude-code-ide-mcp-tests--value 'start coordinates))
        (end (herdr-claude-code-ide-mcp-tests--value 'end coordinates)))
    (and (equal (herdr-claude-code-ide-mcp-tests--value 'coordinate_base coordinates) 0)
         (listp start)
         (listp end)
         (integerp (herdr-claude-code-ide-mcp-tests--value 'line start))
         (integerp (herdr-claude-code-ide-mcp-tests--value 'character start))
         (integerp (herdr-claude-code-ide-mcp-tests--value 'line end))
         (integerp (herdr-claude-code-ide-mcp-tests--value 'character end))
         (>= (herdr-claude-code-ide-mcp-tests--value 'line start) 0)
         (>= (herdr-claude-code-ide-mcp-tests--value 'character start) 0)
         (>= (herdr-claude-code-ide-mcp-tests--value 'line end) 0)
         (>= (herdr-claude-code-ide-mcp-tests--value 'character end) 0))))

(defun herdr-claude-code-ide-mcp-tests--has-key-p (key object)
  (or (assq key object)
      (assoc-string (symbol-name key) object)))

(defun herdr-claude-code-ide-mcp-tests--nonblank-string-p (value)
  (and (stringp value) (not (string-blank-p value))))

(defun herdr-claude-code-ide-mcp-tests--keys (object)
  (sort (mapcar (lambda (entry)
                  (let ((key (car entry)))
                    (if (symbolp key) (symbol-name key) key)))
                object)
        #'string<))

(defun herdr-claude-code-ide-mcp-tests--ledger-row (workflow)
  (seq-find (lambda (cells) (equal (car cells) workflow))
            (mapcar (lambda (line)
                      (mapcar #'string-trim (split-string line "|" t)))
                    (split-string (buffer-string) "\n" t))))

(ert-deftest herdr-claude-code-ide-contract-fixtures-pin-compatible-version-metadata ()
  (let ((fixtures (mapcar #'herdr-claude-code-ide-mcp-tests--fixture
                          '("compatibility-probed.json"
                            "client-originated.json"
                            "herdr-decided.json"))))
    (dolist (fixture fixtures)
      (let ((metadata (herdr-claude-code-ide-mcp-tests--value 'metadata fixture)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'snapshot_commit metadata)
                       "32a8a904"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'snapshot_version metadata)
                       "0.3.0"))
        (let ((version (herdr-claude-code-ide-mcp-tests--value
                        'claude_code_version metadata))
              (captured-at (herdr-claude-code-ide-mcp-tests--value
                            'captured_at metadata)))
          (should (equal version "2.1.235"))
          (should (stringp captured-at))
          (should (string-match-p "T" captured-at)))))
    (let ((fixture (car fixtures)))
      (should (equal (herdr-claude-code-ide-mcp-tests--value 'provenance fixture)
                     "compatibility-probed"))
      (herdr-claude-code-ide-mcp-tests--require-captured-exchanges
       '(("discovery" nil "discovery" "probed")
         ("websocket-handshake" nil "websocket" "probed"))
       fixture "compatibility-probed")
      (dolist (expectation
               '(("discovery" "Claude Code 2.1.235 compatibility probe")
                 ("websocket-handshake" "Claude Code 2.1.235 compatibility probe")))
        (let ((exchange (herdr-claude-code-ide-mcp-tests--exchange
                         (car expectation) fixture)))
          (should (equal (herdr-claude-code-ide-mcp-tests--value 'basis exchange)
                         (cadr expectation)))))
      (let* ((discovery (herdr-claude-code-ide-mcp-tests--exchange "discovery" fixture))
             (handshake (herdr-claude-code-ide-mcp-tests--exchange
                         "websocket-handshake" fixture))
             (handshake-payload
              (herdr-claude-code-ide-mcp-tests--value 'payload handshake))
             (launch-environment
              (herdr-claude-code-ide-mcp-tests--value
               'launch_environment handshake-payload))
             (capture-environment
              (herdr-claude-code-ide-mcp-tests--value
               'capture_environment handshake-payload)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys launch-environment)
                       '("CLAUDE_CODE_SSE_PORT" "FORCE_CODE_TERMINAL" "TERM_PROGRAM")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'CLAUDE_CODE_SSE_PORT launch-environment)
                       "<port>"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'FORCE_CODE_TERMINAL launch-environment)
                       "true"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'TERM_PROGRAM launch-environment)
                       "emacs"))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys capture-environment)
                       '("CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"
                         "CLAUDE_CODE_IDE_SKIP_VALID_CHECK")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL capture-environment)
                       "1"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'CLAUDE_CODE_IDE_SKIP_VALID_CHECK capture-environment)
                       "1"))))))

(ert-deftest herdr-claude-code-ide-contract-fixtures-cover-every-client-exchange ()
  (let ((fixture (herdr-claude-code-ide-mcp-tests--fixture "client-originated.json")))
    (should (equal (herdr-claude-code-ide-mcp-tests--value 'provenance fixture)
                   "client-originated"))
    (herdr-claude-code-ide-mcp-tests--require-captured-exchanges
     '(("initialize" "initialize" "websocket" "observed")
       ("ide_connected" "ide_connected" "websocket" "observed")
       ("tools/list" "tools/list" "websocket" "observed")
       ("prompts/list" "prompts/list" "websocket" "observed")
       ("resources/list" "resources/list" "websocket" "observed")
       ("tools/call/openFile" "tools/call" "websocket" "probed" "openFile")
       ("tools/call/getDiagnostics" "tools/call" "websocket" "probed" "getDiagnostics")
       ("tools/call/close_tab" "tools/call" "websocket" "probed" "close_tab")
       ("tools/call/openDiff" "tools/call" "websocket" "probed" "openDiff")
       ("tools/call/closeAllDiffTabs" "tools/call" "websocket" "probed" "closeAllDiffTabs")
       ("tools/call/executeCode" "tools/call" "websocket" "probed" "executeCode")
       ("http/initialize" "initialize" "http" "probed")
       ("http/tools/list" "tools/list" "http" "probed")
       ("http/tools/call" "tools/call" "http" "probed"))
     fixture "client-originated")
    (let ((initialize (herdr-claude-code-ide-mcp-tests--exchange "initialize" fixture)))
      (should (herdr-claude-code-ide-mcp-tests--value 'payload initialize))
      (should (herdr-claude-code-ide-mcp-tests--value 'capabilities initialize)))
    (let* ((close-tab (herdr-claude-code-ide-mcp-tests--exchange
                       "tools/call/close_tab" fixture))
           (arguments (herdr-claude-code-ide-mcp-tests--value
                       'arguments
                       (herdr-claude-code-ide-mcp-tests--value
                        'params
                        (herdr-claude-code-ide-mcp-tests--value 'payload close-tab)))))
      (should (equal (herdr-claude-code-ide-mcp-tests--keys arguments) '("tab_name")))
      (should (equal (herdr-claude-code-ide-mcp-tests--value 'tab_name arguments)
                     "t001")))
    (dolist (expectation
             '(("http/initialize" "initialized" ("Accept" "Content-Type") nil nil "t001-session")
               ("http/tools/list" "established"
                ("Accept" "Content-Type" "MCP-Protocol-Version" "Mcp-Session-Id")
                "t001-session" "2025-11-25" nil)
               ("http/tools/call" "established"
                ("Accept" "Content-Type" "MCP-Protocol-Version" "Mcp-Session-Id")
                "t001-session" "2025-11-25" nil)))
      (let* ((exchange (herdr-claude-code-ide-mcp-tests--exchange
                        (nth 0 expectation) fixture))
             (request (herdr-claude-code-ide-mcp-tests--value 'request exchange))
             (request-headers
              (herdr-claude-code-ide-mcp-tests--value 'headers request))
             (response (herdr-claude-code-ide-mcp-tests--value 'response exchange))
             (response-headers
              (herdr-claude-code-ide-mcp-tests--value 'headers response))
             (session (herdr-claude-code-ide-mcp-tests--value 'session exchange)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'method request) "POST"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'path request)
                       "/mcp/<session-id>"))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys request-headers)
                       (nth 2 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'Accept request-headers)
                       "application/json, text/event-stream"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'Content-Type request-headers)
                       "application/json"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'Mcp-Session-Id request-headers)
                       (nth 3 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'MCP-Protocol-Version request-headers)
                       (nth 4 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'status response) 200))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'Content-Type response-headers)
                       "application/json"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'id session)
                       "t001-session"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'phase session)
                       (nth 1 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'Mcp-Session-Id response-headers)
                       (nth 5 expectation)))))))

(ert-deftest herdr-claude-code-ide-contract-fixtures-pin-herdr-decisions ()
  (let ((fixture (herdr-claude-code-ide-mcp-tests--fixture "herdr-decided.json")))
    (should (equal (herdr-claude-code-ide-mcp-tests--value 'provenance fixture)
                   "herdr-decided"))
    (dolist (identifier
             '("initialize-result" "server-capabilities" "selection" "at-mention"
               "json-rpc-errors" "http-mcp-errors" "reconnect-deadline"
               "deferred-response-cancellation" "stale-client-cleanup"
               "tool-schema/openFile" "tool-schema/getDiagnostics" "tool-schema/close_tab"
               "tool-schema/openDiff" "tool-schema/closeAllDiffTabs" "tool-schema/executeCode"))
      (should (herdr-claude-code-ide-mcp-tests--exchange identifier fixture)))
    (dolist (exchange (herdr-claude-code-ide-mcp-tests--value 'exchanges fixture))
      (should (equal (herdr-claude-code-ide-mcp-tests--value 'provenance exchange)
                     "herdr-decided"))
      (should (equal (herdr-claude-code-ide-mcp-tests--value 'category exchange)
                     "decided"))
      (should (herdr-claude-code-ide-mcp-tests--nonblank-string-p
               (herdr-claude-code-ide-mcp-tests--value 'basis exchange))))
    (let* ((initialize (herdr-claude-code-ide-mcp-tests--exchange
                        "initialize-result" fixture))
           (result (herdr-claude-code-ide-mcp-tests--value 'result initialize))
           (initialize-capabilities
            (herdr-claude-code-ide-mcp-tests--value 'capabilities result))
           (server-info (herdr-claude-code-ide-mcp-tests--value 'serverInfo result))
           (server-capabilities
            (herdr-claude-code-ide-mcp-tests--value
             'capabilities
             (herdr-claude-code-ide-mcp-tests--exchange
              "server-capabilities" fixture))))
      (should (equal (herdr-claude-code-ide-mcp-tests--keys result)
                     '("capabilities" "protocolVersion" "serverInfo")))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'protocolVersion result) "2025-11-25"))
      (should (equal (herdr-claude-code-ide-mcp-tests--keys server-info)
                     '("name" "version")))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'name server-info) "herdr-claude-code-ide"))
      (should (equal (herdr-claude-code-ide-mcp-tests--keys initialize-capabilities)
                     '("prompts" "resources" "tools")))
      (let ((tools (herdr-claude-code-ide-mcp-tests--value
                    'tools initialize-capabilities))
            (resources (herdr-claude-code-ide-mcp-tests--value
                        'resources initialize-capabilities))
            (prompts (herdr-claude-code-ide-mcp-tests--value
                      'prompts initialize-capabilities)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys tools)
                       '("listChanged")))
        (should (eq (herdr-claude-code-ide-mcp-tests--value 'listChanged tools) t))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys resources)
                       '("listChanged" "subscribe")))
        (should (eq (herdr-claude-code-ide-mcp-tests--value
                     'listChanged resources) :json-false))
        (should (eq (herdr-claude-code-ide-mcp-tests--value
                     'subscribe resources) :json-false))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys prompts)
                       '("listChanged")))
        (should (eq (herdr-claude-code-ide-mcp-tests--value 'listChanged prompts) t)))
      (should (equal server-capabilities initialize-capabilities)))
    (let ((selection (herdr-claude-code-ide-mcp-tests--exchange "selection" fixture))
          (at-mention (herdr-claude-code-ide-mcp-tests--exchange "at-mention" fixture)))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'coordinate_convention selection)
                     "zero-based-line-and-character"))
      (should (herdr-claude-code-ide-mcp-tests--coordinates-p
               (herdr-claude-code-ide-mcp-tests--value 'coordinates selection)))
      (let* ((coordinates (herdr-claude-code-ide-mcp-tests--value
                           'coordinates selection))
             (payload-selection
              (herdr-claude-code-ide-mcp-tests--value
               'selection
               (herdr-claude-code-ide-mcp-tests--value 'payload selection))))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'start payload-selection)
                       (herdr-claude-code-ide-mcp-tests--value
                        'start coordinates)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value
                        'end payload-selection)
                       (herdr-claude-code-ide-mcp-tests--value
                        'end coordinates))))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'coordinate_convention at-mention)
                     "one-based-lines"))
      (should-not (herdr-claude-code-ide-mcp-tests--has-key-p 'coordinates at-mention))
      (let ((payload (herdr-claude-code-ide-mcp-tests--value 'payload at-mention)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys payload)
                       '("filePath" "lineEnd" "lineStart")))
        (should (= (herdr-claude-code-ide-mcp-tests--value 'lineStart payload) 1))
        (should (= (herdr-claude-code-ide-mcp-tests--value 'lineEnd payload) 1))
        (should (string-match-p "Claude Code 2\\.1\\.235"
                                (herdr-claude-code-ide-mcp-tests--value
                                 'basis at-mention)))))
    (dolist (expectation
             '(("openFile" ("endLine" "endText" "filePath" "startLine" "startText")
                ("filePath"))
               ("getDiagnostics" ("uri") ())
               ("close_tab" ("path" "tab_name") ())
               ("openDiff" ("new_file_contents" "new_file_path" "old_file_path" "tab_name")
                ("new_file_contents" "new_file_path" "old_file_path" "tab_name"))
               ("closeAllDiffTabs" () ())
               ("executeCode" ("code") ("code"))))
      (let* ((exchange (herdr-claude-code-ide-mcp-tests--exchange
                        (concat "tool-schema/" (car expectation)) fixture))
             (schema (herdr-claude-code-ide-mcp-tests--value 'schema exchange))
             (input-schema (herdr-claude-code-ide-mcp-tests--value 'inputSchema schema))
             (properties (herdr-claude-code-ide-mcp-tests--value 'properties input-schema))
             (required (herdr-claude-code-ide-mcp-tests--value 'required input-schema)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys schema)
                       '("description" "inputSchema" "name")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'name schema)
                       (car expectation)))
        (should (herdr-claude-code-ide-mcp-tests--nonblank-string-p
                 (herdr-claude-code-ide-mcp-tests--value 'description schema)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys input-schema)
                       '("properties" "required" "type")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'type input-schema)
                       "object"))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys properties)
                       (nth 1 expectation)))
        (should (equal required (nth 2 expectation)))))
    (dolist (expectation
             '(("parse-error" nil -32700 "Parse error")
               ("invalid-request" nil -32600 "Invalid Request")
               ("invalid-params" 7 -32602 "Invalid params")
               ("unknown-method" 8 -32601 "Method not found")
               ("unknown-tool" 9 -32602 "Unknown tool")
               ("cancelled" 10 -32800 "Request cancelled")
               ("internal-error" 11 -32603 "Internal error")))
      (let* ((entry (seq-find (lambda (error)
                                (equal (herdr-claude-code-ide-mcp-tests--value 'id error)
                                       (car expectation)))
                              (herdr-claude-code-ide-mcp-tests--value
                               'errors
                               (herdr-claude-code-ide-mcp-tests--exchange
                                "json-rpc-errors" fixture))))
             (response (herdr-claude-code-ide-mcp-tests--value 'response entry))
             (error (herdr-claude-code-ide-mcp-tests--value 'error response)))
        (should entry)
        (should (equal (herdr-claude-code-ide-mcp-tests--keys entry)
                       '("id" "response")))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys response)
                       '("error" "id" "jsonrpc")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'jsonrpc response) "2.0"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'id response)
                       (nth 1 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys error)
                       '("code" "message")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'code error)
                       (nth 2 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'message error)
                       (nth 3 expectation)))))
    (dolist (expectation
             '(("parse-error" nil 400 -32700 "Parse error")
               ("invalid-request" nil 400 -32600 "Invalid Request")
               ("invalid-params" 20 200 -32602 "Invalid params")
               ("unknown-method" 21 200 -32601 "Method not found")
               ("unknown-tool" 22 200 -32602 "Unknown tool")
               ("cancelled" 23 200 -32800 "Request cancelled")
               ("internal-error" 24 200 -32603 "Internal error")))
      (let* ((entry (seq-find (lambda (error)
                                (equal (herdr-claude-code-ide-mcp-tests--value 'id error)
                                       (car expectation)))
                              (herdr-claude-code-ide-mcp-tests--value
                               'errors
                               (herdr-claude-code-ide-mcp-tests--exchange
                                "http-mcp-errors" fixture))))
             (headers (herdr-claude-code-ide-mcp-tests--value 'headers entry))
             (response (herdr-claude-code-ide-mcp-tests--value 'response entry))
             (error (herdr-claude-code-ide-mcp-tests--value 'error response)))
        (should entry)
        (should (equal (herdr-claude-code-ide-mcp-tests--keys entry)
                       '("headers" "id" "response" "status")))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys headers)
                       '("Content-Type")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'Content-Type headers)
                       "application/json"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'status entry)
                       (nth 2 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--keys response)
                       '("error" "id" "jsonrpc")))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'jsonrpc response) "2.0"))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'id response)
                       (nth 1 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'code error)
                       (nth 3 expectation)))
        (should (equal (herdr-claude-code-ide-mcp-tests--value 'message error)
                       (nth 4 expectation)))))
    (let ((reconnect (herdr-claude-code-ide-mcp-tests--exchange
                      "reconnect-deadline" fixture))
          (cancellation (herdr-claude-code-ide-mcp-tests--exchange
                         "deferred-response-cancellation" fixture))
          (cleanup (herdr-claude-code-ide-mcp-tests--exchange
                    "stale-client-cleanup" fixture)))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'deadline_seconds reconnect) 30))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'trigger reconnect) "current-client-disconnect"))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'initial_wait_has_deadline reconnect) :json-false))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'invalidated_generation cancellation) 1))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'replacement_generation cancellation) 2))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'cancelled_request_ids cancellation)
                     '("old-generation-request")))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'cancelled_diff_ids cancellation)
                     '("old-generation-diff")))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'scope cleanup) "session-local"))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'idempotent cleanup) t))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'cleaned_resources cleanup)
                     '("deferred-requests" "active-diffs" "superseded-socket"
                       "lockfile" "endpoint" "server" "timers" "hooks"
                       "temporary-buffers" "primary-record" "derived-indexes")))
      (should (equal (herdr-claude-code-ide-mcp-tests--value
                      'retained_resources cleanup)
                     '("shared-herdr-server" "borrowed-workspace" "borrowed-tab"
                       "borrowed-pane"))))))

(ert-deftest herdr-claude-code-ide-parity-ledger-maps-every-workflow ()
  (dolist (suite '(herdr-agent-tests
                   herdr-claude-code-ide-diagnostics-tests
                   herdr-claude-code-ide-mcp-server-tests
                   herdr-claude-code-ide-tools-tests
                   herdr-claude-code-ide-ui-tests))
    (require suite))
  (let ((path (expand-file-name "docs/claude-code-ide-parity.md"
                                herdr-claude-code-ide-mcp-tests--root)))
    (should (file-exists-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (let* ((parsed-rows
              (mapcar (lambda (line)
                        (mapcar #'string-trim (split-string line "|" t)))
                      (split-string (buffer-string) "\n" t)))
             (rows
              (seq-filter
               (lambda (cells)
                 (and (= (length cells) 4)
                      (not (equal (car cells) "Workflow"))
                      (not (equal (car cells) "---"))))
               parsed-rows)))
        (should (equal (seq-find (lambda (row) (equal (car row) "Workflow")) parsed-rows)
                       '("Workflow" "Scope task" "Verification" "State")))
        (let ((workflow-tasks
               '(("contract-capture" . "T001")
                 ("server-startup" . "T002")
                 ("session-identity" . "T002")
                 ("adoption" . "T002")
                 ("detach-without-termination" . "T002")
                 ("claude-disappearance" . "T002")
                 ("startup-rollback" . "T002")
                 ("discovery" . "T003")
                 ("initialize" . "T003")
                 ("reconnect" . "T003")
                 ("supersede" . "T003")
                 ("stale-client" . "T003")
                 ("cleanup" . "T003")
                 ("selection" . "T004")
                 ("context-at-mention" . "T004")
                 ("diagnostics-provider" . "T004")
                 ("getDiagnostics-tool" . "T005")
                 ("openFile" . "T005")
                 ("close_tab" . "T005")
                 ("openDiff" . "T005")
                 ("closeAllDiffTabs" . "T005")
                 ("executeCode" . "T005")
                 ("http-mcp" . "T006")
                 ("xref-references" . "T006")
                 ("xref-apropos" . "T006")
                 ("project-information" . "T006")
                 ("imenu" . "T006")
                 ("tree-sitter" . "T006")
                 ("start" . "T007")
                 ("continue" . "T007")
                 ("resume" . "T007")
                 ("instance-naming" . "T007")
                 ("list" . "T007")
                 ("targeting" . "T007")
                 ("switch" . "T007")
                 ("rename" . "T007")
                 ("session-status" . "T007")
                 ("stop" . "T007")
                 ("stop-all" . "T007")
                 ("prompt" . "T007")
                 ("terminal-at-mention" . "T007")
                 ("escape" . "T007")
                 ("newline" . "T007")
                 ("project-display" . "T007")
                 ("global-display" . "T007")
                 ("recent-window-display" . "T007")
                 ("window-display" . "T007")
                 ("transient" . "T008")
                 ("status" . "T008")
                 ("debug" . "T008")
                 ("configuration" . "T008")
                 ("migration" . "T009")
                 ("platform-verification" . "T010"))))
          (should (equal (mapcar #'car rows) (mapcar #'car workflow-tasks)))
          (should (= (length rows) (length (delete-dups (mapcar #'car rows)))))
          (dolist (workflow-task workflow-tasks)
            (let ((row (seq-find (lambda (cells)
                                   (equal (car cells) (car workflow-task)))
                                 rows)))
              (should row)
          (should (= (length row) 4))
          (should (equal (nth 1 row) (cdr workflow-task)))
          (let* ((verification (nth 2 row))
                 (expected-verification
                  (cond
                   ((equal (car workflow-task) "platform-verification")
                    "matrix: .github/workflows/test.yml")
                   ((member (car workflow-task)
                            '("contract-capture"))
                    "ERT: herdr-claude-code-ide-contract-fixtures-cover-every-client-exchange")
                   ((member (car workflow-task) '("server-startup" "startup-rollback"))
                    "ERT: herdr-claude-code-ide-mcp-retains-startup-initialization-and-rolls-it-back")
                   ((equal (car workflow-task) "session-identity")
                    "ERT: herdr-agent-adoption-separates-same-label-terminal-on-explicit-servers")
                   ((equal (car workflow-task) "adoption")
                    "ERT: herdr-claude-code-ide-mcp-adoption-keeps-project-clients-distinct")
                   ((equal (car workflow-task) "detach-without-termination")
                    "ERT: herdr-agent-detach-and-attachment-death-keep-herdr-open-and-retry-cleanup")
                   ((equal (car workflow-task) "claude-disappearance")
                    "ERT: herdr-agent-event-subscriptions-route-data-per-server-and-repair-moves")
                   ((member (car workflow-task)
                            '("discovery"))
                    "ERT: herdr-claude-code-ide-mcp-prepare-publishes-claude-discovery-before-launch")
                   ((member (car workflow-task)
                            '("initialize"))
                    "ERT: herdr-claude-code-ide-mcp-dispatches-fixture-json-rpc-and-errors")
                   ((member (car workflow-task) '("reconnect"))
                    "ERT: herdr-claude-code-ide-mcp-only-arms-reconnect-after-current-disconnect")
                   ((member (car workflow-task) '("supersede" "stale-client"))
                    "ERT: herdr-claude-code-ide-mcp-supersedes-only-successful-live-candidates")
                   ((member (car workflow-task) '("cleanup"))
                    "ERT: herdr-claude-code-ide-mcp-resolves-deadline-races-and-last-cleanup")
                   ((member (car workflow-task) '("selection"))
                    "ERT: herdr-claude-code-ide-selection-context-walks-debounce-generation-and-cleanup")
                   ((member (car workflow-task) '("context-at-mention"))
                    "ERT: herdr-claude-code-ide-at-mention-uses-ordered-lines-and-the-target-registry-session")
                   ((member (car workflow-task) '("diagnostics-provider"))
                    "ERT: herdr-claude-code-ide-diagnostics-normalizes-native-records-with-safe-severity")
                   ((member (car workflow-task) '("getDiagnostics-tool"))
                    "ERT: herdr-claude-code-ide-tools-get-diagnostics-uses-the-t004-visited-buffer-boundary")
                   ((equal (car workflow-task) "openFile")
                    "ERT: herdr-claude-code-ide-tools-close-tab-releases-only-requesting-global-buffer-view")
                   ((equal (car workflow-task) "executeCode")
                    "ERT: herdr-claude-code-ide-tools-registers-only-fixture-tools-and-requires-elisp-opt-in")
                   ((member (car workflow-task) '("close_tab"))
                    "ERT: herdr-claude-code-ide-tools-close-tab-releases-only-requesting-global-buffer-view")
                   ((member (car workflow-task) '("openDiff"))
                    "ERT: herdr-claude-code-ide-tools-defers-ediff-and-returns-edited-accept-or-distinct-reject")
                   ((member (car workflow-task) '("closeAllDiffTabs"))
                    "ERT: herdr-claude-code-ide-tools-close-all-diffs-is-session-local")
                   ((equal (car workflow-task) "http-mcp")
                    "ERT: herdr-claude-code-ide-mcp-server-replays-http-fixtures-and-protocol-errors")
                   ((member (car workflow-task)
                            '("xref-references" "xref-apropos" "project-information"
                              "imenu" "tree-sitter"))
                    "ERT: herdr-claude-code-ide-emacs-tools-normalize-provider-results-in-the-owning-context")
                   ((member (car workflow-task) '("start" "continue" "resume"))
                    "ERT: herdr-agent-native-start-continue-and-resume-use-harness-arguments")
                   ((equal (car workflow-task) "instance-naming")
                    "ERT: herdr-claude-code-ide-mcp-adoption-keeps-project-clients-distinct")
                   ((member (car workflow-task) '("list" "rename" "session-status" "stop" "stop-all"))
                    "ERT: herdr-agent-native-management-uses-herdr-api-wrappers")
                   ((member (car workflow-task) '("targeting"))
                    "ERT: herdr-agent-native-target-resolution-is-explicit-project-local-and-mru")
                   ((member (car workflow-task) '("switch" "project-display" "global-display"
                                                    "recent-window-display" "window-display"))
                    "ERT: herdr-agent-native-switch-focuses-the-visible-owned-terminal")
                   ((equal (car workflow-task) "terminal-at-mention")
                    "ERT: herdr-claude-code-ide-at-mention-uses-ordered-lines-and-the-target-registry-session")
                   ((member (car workflow-task) '("prompt" "escape" "newline"))
                    "ERT: herdr-agent-native-prompt-escape-and-newline-use-agent-api")
                   ((member (car workflow-task) '("transient" "status" "debug" "configuration"))
                    "ERT: herdr-claude-code-ide-ui-menus-route-agent-workflows-without-a-cli")
                   ((member (car workflow-task) '("migration"))
                    "ERT: herdr-claude-code-ide-explicit-adoption-activates-a-preexisting-generic-session"))))
            (should (stringp verification))
            (should (equal (nth 3 row) "passing"))
            (should expected-verification)
            (should (equal verification expected-verification))
            (if (equal (car workflow-task) "platform-verification")
                (let ((workflow (expand-file-name ".github/workflows/test.yml"
                                                  herdr-claude-code-ide-mcp-tests--root)))
                  (should (file-regular-p workflow)))
              (should (string-match "\\`ERT: \\([[:alnum:]-]+\\)\\'" verification))
              (let ((selector (match-string 1 verification)))
                (should (ert-test-boundp (intern selector)))
                (should-not
                 (equal selector
                        "herdr-claude-code-ide-parity-ledger-maps-every-workflow"))))))))))))

(defun herdr-claude-code-ide-mcp-tests--t003-require-transport ()
  (should (featurep 'herdr-claude-code-ide-mcp)))

(defun herdr-claude-code-ide-mcp-tests--t003-agent (kind terminal-id root)
  `((agent . ,kind)
    (terminal_id . ,terminal-id)
    (name . "review")
    (pane_id . ,(concat terminal-id ":pane"))
    (cwd . ,root)))

(defun herdr-claude-code-ide-mcp-tests--t003-payload (fixture identifier)
  (herdr-claude-code-ide-mcp-tests--value
   'payload
   (herdr-claude-code-ide-mcp-tests--exchange
    identifier (herdr-claude-code-ide-mcp-tests--fixture fixture))))

(defun herdr-claude-code-ide-mcp-tests--t003-initialize-result ()
  (herdr-claude-code-ide-mcp-tests--value
   'result
   (herdr-claude-code-ide-mcp-tests--exchange
    "initialize-result"
    (herdr-claude-code-ide-mcp-tests--fixture "herdr-decided.json"))))

(defun herdr-claude-code-ide-mcp-tests--t003-error (identifier)
  (let* ((fixture (herdr-claude-code-ide-mcp-tests--fixture "herdr-decided.json"))
         (errors (herdr-claude-code-ide-mcp-tests--value
                  'errors
                  (herdr-claude-code-ide-mcp-tests--exchange
                   "json-rpc-errors" fixture))))
    (herdr-claude-code-ide-mcp-tests--value
     'response
     (seq-find (lambda (entry)
                 (equal (herdr-claude-code-ide-mcp-tests--value 'id entry)
                        identifier))
               errors))))

(defun herdr-claude-code-ide-mcp-tests--t003-tool-schemas ()
  (let ((fixture (herdr-claude-code-ide-mcp-tests--fixture "herdr-decided.json")))
    (mapcar (lambda (name)
              (herdr-claude-code-ide-mcp-tests--value
               'schema
               (herdr-claude-code-ide-mcp-tests--exchange
                (concat "tool-schema/" name) fixture)))
            '("openFile" "getDiagnostics" "close_tab" "openDiff"
              "closeAllDiffTabs" "executeCode"))))

(defun herdr-claude-code-ide-mcp-tests--t003-prepare (agent root &rest options)
  (apply #'herdr-claude-code-ide-mcp-prepare
         agent
         (append (list :server-key (expand-file-name "herdr.sock" root)
                       :project-root root
                       :instance-id
                       (herdr-claude-code-ide-mcp-tests--value 'terminal_id agent)
                       :discovery-directory (expand-file-name "discovery" root))
                 options)))

(defmacro herdr-claude-code-ide-mcp-tests--with-websocket (&rest body)
  `(let ((original-require (symbol-function 'require))
         (port 4242))
     (cl-letf (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'websocket)
                      'websocket
                    (funcall original-require feature filename noerror))))
               ((symbol-function 'websocket-server)
                (lambda (&rest _) (gensym "websocket-server")))
               ((symbol-function 'websocket-server-close)
                (lambda (&rest _) nil))
               ((symbol-function 'herdr-claude-code-ide-mcp--port)
                (lambda (&rest _) (cl-incf port))))
       ,@body)))

(defun herdr-claude-code-ide-mcp-tests--t003-initialize (adapter client)
  (herdr-claude-code-ide-mcp-receive
   adapter client
   (json-serialize
    (herdr-claude-code-ide-mcp-tests--t003-payload
     "client-originated.json" "initialize"))))

(ert-deftest herdr-claude-code-ide-mcp-prepare-publishes-claude-discovery-before-launch ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (require 'herdr-agent)
  (let* ((root (make-temp-file "herdr-claude-mcp-prepare" t))
         (server-key (expand-file-name "herdr.sock" root))
         (claude (herdr-claude-code-ide-mcp-tests--t003-agent "claude" "term-claude" root))
         (operations nil)
         (adapter nil)
         (session nil))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-start-server-if-needed)
                   (lambda (&rest _) t))
                  ((symbol-function 'herdr-workspace-id)
                   (lambda (&rest _) nil))
                  ((symbol-function 'herdr-api-agent-list)
                   (lambda () '((agents . ()))))
                  ((symbol-function 'herdr-open-tab)
                   (lambda (&rest _)
                     (push 'pane-create operations)
                     '((workspace . ((workspace_id . "work")))
                       (tab . ((tab_id . "work:tab") (workspace_id . "work")))
                       (root_pane . ((pane_id . "work:pane")
                                     (tab_id . "work:tab")
                                     (workspace_id . "work"))))))
                  ((symbol-function 'herdr-api-agent-start)
                   (lambda (&rest _)
                     (push 'agent-start operations)
                     (should adapter)
                     (let ((lockfile (herdr-claude-code-ide-mcp-adapter-lockfile adapter)))
                       (should (file-exists-p lockfile))
                       (let ((lockfile-discovery
                              (with-temp-buffer
                                (insert-file-contents lockfile)
                                (json-parse-buffer :object-type 'alist :array-type 'list
                                                   :null-object nil :false-object :json-false))))
                         (should (equal lockfile-discovery
                                        (herdr-claude-code-ide-mcp-adapter-discovery adapter)))
                         (should (equal (herdr-claude-code-ide-mcp-tests--keys
                                         lockfile-discovery)
                                        '("ideName" "pid" "transport" "workspaceFolders")))
                         (should (= (herdr-claude-code-ide-mcp-tests--value
                                     'pid lockfile-discovery)
                                    (emacs-pid)))
                         (should (equal (herdr-claude-code-ide-mcp-tests--value
                                         'workspaceFolders lockfile-discovery)
                                        (list root)))
                         (let ((ide-name (herdr-claude-code-ide-mcp-tests--value
                                          'ideName lockfile-discovery)))
                           (should (string-match-p "review" ide-name))
                           (should (string-match-p "term-claude" ide-name)))
                         (should (equal (herdr-claude-code-ide-mcp-tests--value
                                         'transport lockfile-discovery)
                                        "ws"))))
                     `((agent . ,(append claude '((interactive_ready . t)))))))
                  ((symbol-function 'herdr-api-tab-close)
                   (lambda (&rest _) nil))
                  ((symbol-function 'herdr-api-workspace-list)
                   (lambda () '((workspaces . ()))))
                  ((symbol-function 'herdr-api-workspace-close)
                   (lambda (&rest _) nil)))
          (unwind-protect
              (let ((herdr-agent-kind-adapters
                     `(("claude" :prepare
                        ,(lambda (&rest _)
                           (push 'prepare operations)
                           (setq adapter
                                 (herdr-claude-code-ide-mcp-tests--t003-prepare
                                  claude root))
                           (herdr-claude-code-ide-mcp-adapter-environment adapter))))))
                (setq session
                      (herdr-agent-start-session "claude" "review"
                                                 :server-key server-key
                                                 :project-root root
                                                 :attach nil))
                (should (equal (nreverse operations)
                               '(prepare pane-create agent-start)))
                (let ((endpoint (herdr-claude-code-ide-mcp-adapter-endpoint adapter))
                      (environment (herdr-claude-code-ide-mcp-adapter-environment adapter)))
                  (should (string-match
                           "\\`ws://127\\.0\\.0\\.1:\\([0-9]+\\)\\'" endpoint))
                  (let ((port (match-string 1 endpoint)))
                    (should (equal (herdr-claude-code-ide-mcp-tests--keys environment)
                                   '("CLAUDE_CODE_SSE_PORT" "FORCE_CODE_TERMINAL" "TERM_PROGRAM")))
                    (should (equal (herdr-claude-code-ide-mcp-tests--value
                                    'CLAUDE_CODE_SSE_PORT environment) port))
                    (should (equal (herdr-claude-code-ide-mcp-tests--value
                                    'FORCE_CODE_TERMINAL environment) "true"))
                    (should (equal (herdr-claude-code-ide-mcp-tests--value
                                    'TERM_PROGRAM environment) "emacs")))))
                (let (first-provisional second-provisional server-a server-b)
                  (unwind-protect
                      (progn
                        (setq first-provisional
                              (herdr-claude-code-ide-mcp-tests--t003-prepare
                               (herdr-claude-code-ide-mcp-tests--t003-agent
                                "claude" "pending" root)
                               root)
                              second-provisional
                              (herdr-claude-code-ide-mcp-tests--t003-prepare
                               (herdr-claude-code-ide-mcp-tests--t003-agent
                                "claude" "pending" root)
                               root))
                        (should-not (eq first-provisional second-provisional))
                        (should-not
                         (equal (herdr-claude-code-ide-mcp-adapter-endpoint
                                 first-provisional)
                                (herdr-claude-code-ide-mcp-adapter-endpoint
                                 second-provisional)))
                        (let ((server-a-root (expand-file-name "server-a" root))
                              (server-b-root (expand-file-name "server-b" root)))
                          (make-directory server-a-root)
                          (make-directory server-b-root)
                          (setq server-a
                                (herdr-claude-code-ide-mcp-tests--t003-prepare
                                 (herdr-claude-code-ide-mcp-tests--t003-agent
                                  "claude" "same-label" server-a-root)
                                 server-a-root)
                                server-b
                                (herdr-claude-code-ide-mcp-tests--t003-prepare
                                 (herdr-claude-code-ide-mcp-tests--t003-agent
                                  "claude" "same-label" server-b-root)
                                 server-b-root))
                          (should-not
                           (equal (herdr-claude-code-ide-mcp-tests--value
                                   'ideName
                                   (herdr-claude-code-ide-mcp-adapter-discovery server-a))
                                  (herdr-claude-code-ide-mcp-tests--value
                                   'ideName
                                   (herdr-claude-code-ide-mcp-adapter-discovery server-b)))))
                    (dolist (candidate
                             (list first-provisional second-provisional server-a server-b))
                      (when candidate
                        (herdr-claude-code-ide-mcp-cleanup candidate))))))
            (when session
              (herdr-agent-detach session))))
      (when adapter
        (herdr-claude-code-ide-mcp-cleanup adapter))
      (dolist (kind '("pi" "codex"))
        (should-not
         (herdr-claude-code-ide-mcp-tests--t003-prepare
          (herdr-claude-code-ide-mcp-tests--t003-agent kind kind root) root)))
      (delete-directory root t)))))

(ert-deftest herdr-claude-code-ide-mcp-requires-websocket-before-publishing-discovery ()
  (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-no-websocket" t))
         (discovery-directory (expand-file-name "discovery" root))
         (before-processes (process-list))
         (before-adapters (hash-table-count herdr-claude-code-ide-mcp--adapters))
         adapter
         error-data
         leaked)
    (unwind-protect
        (let ((features (delq 'websocket (copy-sequence features)))
              (original-require (symbol-function 'require)))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'websocket)
                           nil
                         (funcall original-require feature filename noerror)))))
            (condition-case error
                (setq adapter
                      (herdr-claude-code-ide-mcp-tests--t003-prepare
                       (herdr-claude-code-ide-mcp-tests--t003-agent
                        "claude" "term-no-websocket" root)
                       root))
              (error (setq error-data error)))
            (setq leaked (seq-filter #'process-live-p
                                     (cl-set-difference (process-list) before-processes)))
            (should error-data)
            (should-not leaked)
            (should (= (hash-table-count herdr-claude-code-ide-mcp--adapters)
                       before-adapters))
            (should-not (and (file-directory-p discovery-directory)
                             (directory-files-recursively discovery-directory ".")))))
      (when adapter
        (herdr-claude-code-ide-mcp-cleanup adapter))
      (mapc #'delete-process leaked)
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-mcp-preparation-closes-a-listener-after-publication-fails ()
  (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-publication" t))
         (before (process-list))
         leaked)
    (unwind-protect
        (cl-letf (((symbol-function 'write-region)
                   (lambda (&rest _) (error "discovery publication failed"))))
          (should-error
           (herdr-claude-code-ide-mcp-tests--t003-prepare
            (herdr-claude-code-ide-mcp-tests--t003-agent
             "claude" "term-publication" root)
            root))
          (setq leaked (seq-filter #'process-live-p
                                   (cl-set-difference (process-list) before)))
          (should-not leaked))
      (mapc #'delete-process leaked)
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-mcp-websocket-invalid-initialize-responds-before-close ()
  (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-websocket" t))
         (original-features features)
         (server 'server)
         (client 'client)
         (open nil)
         (message nil)
         (events nil)
         (adapter nil)
         (json-null (make-symbol "json-null")))
    (cl-labels
        ((assert-json-rpc-error
          (text expected)
          (let* ((actual (json-parse-string text :object-type 'hash-table
                                            :array-type 'array :null-object json-null
                                            :false-object :json-false))
                 (actual-error (gethash "error" actual))
                 (expected-id (herdr-claude-code-ide-mcp-tests--value 'id expected))
                 (expected-error (herdr-claude-code-ide-mcp-tests--value 'error expected)))
            (should (equal (sort (hash-table-keys actual) #'string<)
                           '("error" "id" "jsonrpc")))
            (should (equal (gethash "jsonrpc" actual)
                           (herdr-claude-code-ide-mcp-tests--value 'jsonrpc expected)))
            (if (null expected-id)
                (should (eq (gethash "id" actual) json-null))
              (should (equal (gethash "id" actual) expected-id)))
            (should (hash-table-p actual-error))
            (should (equal (sort (hash-table-keys actual-error) #'string<)
                           '("code" "message")))
            (should (equal (gethash "code" actual-error)
                           (herdr-claude-code-ide-mcp-tests--value 'code expected-error)))
            (should (equal (gethash "message" actual-error)
                           (herdr-claude-code-ide-mcp-tests--value
                            'message expected-error))))))
      (unwind-protect
        (progn
          (setq features (cons 'websocket features))
          (load (expand-file-name "herdr-claude-code-ide-mcp.el"
                                  herdr-claude-code-ide-mcp-tests--root)
                nil nil t)
          (cl-letf (((symbol-function 'herdr-claude-code-ide-mcp--port)
                     (lambda (_server) 4242))
                    ((symbol-function 'websocket-server)
                     (lambda (&rest options)
                       (when (not (keywordp (car options)))
                         (setq options (cdr options)))
                       (setq open (plist-get options :on-open)
                             message (plist-get options :on-message))
                       server))
                    ((symbol-function 'websocket-frame-text)
                     (lambda (frame) frame))
                    ((symbol-function 'websocket-send-text)
                     (lambda (socket text)
                       (push (list 'send socket text) events)))
                    ((symbol-function 'websocket-close)
                     (lambda (socket &rest _)
                       (push (list 'close socket) events)))
                    ((symbol-function 'websocket-server-close)
                     (lambda (socket &rest _)
                       (push (list 'server-close socket) events))))
            (unwind-protect
                (progn
                  (setq adapter
                        (herdr-claude-code-ide-mcp-tests--t003-prepare
                         (herdr-claude-code-ide-mcp-tests--t003-agent
                          "claude" "term-websocket" root) root))
                  (funcall open client)
                  (funcall message client
                           (json-serialize
                            (herdr-claude-code-ide-mcp-tests--t003-payload
                             "client-originated.json" "initialize")))
                  (funcall message client
                           (json-serialize
                            (herdr-claude-code-ide-mcp-tests--t003-payload
                             "client-originated.json" "tools/list")))
                  (funcall message client "{")
                  (let ((protocol-events (nreverse events)))
                    (should (equal (mapcar #'car protocol-events) '(send send send)))
                    (let* ((tools-response
                            (json-parse-string (nth 2 (nth 1 protocol-events))
                                               :object-type 'hash-table :array-type 'array
                                               :null-object json-null))
                           (tools (gethash "tools" (gethash "result" tools-response)))
                           (close-diffs
                            (seq-find (lambda (tool)
                                        (equal (gethash "name" tool) "closeAllDiffTabs"))
                                      tools))
                           (input-schema (gethash "inputSchema" close-diffs))
                           (properties (gethash "properties" input-schema))
                           (required (gethash "required" input-schema)))
                      (should (vectorp tools))
                      (should close-diffs)
                      (should (hash-table-p properties))
                      (should (= (hash-table-count properties) 0))
                      (should (vectorp required))
                      (should (equal required [])))
                    (let* ((parse-error (nth 2 (nth 2 protocol-events)))
                           (parsed-error
                            (json-parse-string parse-error :object-type 'hash-table
                                               :array-type 'array :null-object json-null)))
                      (should (eq (gethash "id" parsed-error) json-null))
                      (assert-json-rpc-error
                       parse-error
                       (herdr-claude-code-ide-mcp-tests--t003-error "parse-error"))))
                  (setq events nil)
                  (let ((invalid-client 'invalid-client))
                    (funcall open invalid-client)
                    (funcall message invalid-client
                             (json-serialize
                              '((jsonrpc . "2.0") (id . 7) (method . "initialize")
                                (params . nil))))
                    (setq events (nreverse events))
                    (should (equal (mapcar #'car events) '(send close)))
                    (should (eq (nth 1 (car events)) invalid-client))
                    (should (eq (nth 1 (cadr events)) invalid-client))
                    (let ((invalid-response
                           (json-parse-string (nth 2 (car events)) :object-type 'hash-table
                                              :array-type 'array :null-object json-null)))
                      (should (= (gethash "code" (gethash "error" invalid-response)) -32602)))
                    (assert-json-rpc-error
                     (nth 2 (car events))
                     (herdr-claude-code-ide-mcp-tests--t003-error "invalid-params"))))
              (when adapter
                (herdr-claude-code-ide-mcp-cleanup adapter)))))
      (setq features original-features)
      (delete-directory root t)))))

(ert-deftest herdr-claude-code-ide-mcp-dispatches-fixture-json-rpc-and-errors ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-dispatch" t))
         (schemas (herdr-claude-code-ide-mcp-tests--t003-tool-schemas))
         (seen nil)
         (adapter nil))
    (unwind-protect
        (progn
          (setq adapter
                (herdr-claude-code-ide-mcp-tests--t003-prepare
                 (herdr-claude-code-ide-mcp-tests--t003-agent
                  "claude" "term-dispatch" root)
                 root
                 :tool-list (lambda () schemas)
                 :tool-call (lambda (_adapter name arguments)
                              (setq seen (list name arguments))
                              '((content . ((type . "text") (text . "handled")))))))
          (herdr-claude-code-ide-mcp-terminal-attached adapter)
          (let ((client (herdr-claude-code-ide-mcp-client-connect adapter)))
            (let ((response
                   (herdr-claude-code-ide-mcp-tests--t003-initialize adapter client)))
              (should (equal (herdr-claude-code-ide-mcp-tests--keys response)
                             '("id" "jsonrpc" "result")))
              (should (= (herdr-claude-code-ide-mcp-tests--value 'id response) 0))
              (should (equal (herdr-claude-code-ide-mcp-tests--value 'jsonrpc response)
                             "2.0"))
              (should (equal (herdr-claude-code-ide-mcp-tests--value 'result response)
                             (herdr-claude-code-ide-mcp-tests--t003-initialize-result))))
            (should-not
             (herdr-claude-code-ide-mcp-receive
              adapter client
              (json-serialize
               (herdr-claude-code-ide-mcp-tests--t003-payload
                "client-originated.json" "ide_connected"))))
            (let ((response
                   (herdr-claude-code-ide-mcp-receive
                    adapter client
                    (json-serialize
                     (herdr-claude-code-ide-mcp-tests--t003-payload
                      "client-originated.json" "tools/list")))))
              (should (equal (herdr-claude-code-ide-mcp-tests--value
                              'tools
                              (herdr-claude-code-ide-mcp-tests--value 'result response))
                             (vconcat schemas))))
            (dolist (expectation '(("prompts/list" prompts)
                                   ("resources/list" resources)))
              (let ((response
                     (herdr-claude-code-ide-mcp-receive
                      adapter client
                      (json-serialize
                       (herdr-claude-code-ide-mcp-tests--t003-payload
                        "client-originated.json" (car expectation))))))
                (should (herdr-claude-code-ide-mcp-tests--has-key-p 'result response))
                (let ((result (herdr-claude-code-ide-mcp-tests--value 'result response)))
                  (should (herdr-claude-code-ide-mcp-tests--has-key-p
                           (cadr expectation) result))
                  (should (equal (herdr-claude-code-ide-mcp-tests--value
                                  (cadr expectation) result)
                                 [])))))
            (let ((response
                   (herdr-claude-code-ide-mcp-receive
                    adapter client
                    (json-serialize
                     (herdr-claude-code-ide-mcp-tests--t003-payload
                      "client-originated.json" "tools/call/openFile")))))
              (should (= (herdr-claude-code-ide-mcp-tests--value 'id response) 10))
              (should (equal seen
                             (list "openFile"
                                   '((filePath . "/tmp/t001-no-file"))))))
            (should (equal (herdr-claude-code-ide-mcp-receive adapter client "{")
                           (herdr-claude-code-ide-mcp-tests--t003-error "parse-error")))
            (should
             (equal
              (herdr-claude-code-ide-mcp-receive
               adapter client
               (json-serialize
                '((jsonrpc . "2.0") (id . 8) (method . "herdr/unknown"))))
              (herdr-claude-code-ide-mcp-tests--t003-error "unknown-method")))))
      (when adapter
        (herdr-claude-code-ide-mcp-cleanup adapter))
      (delete-directory root t)))))

(ert-deftest herdr-claude-code-ide-mcp-retains-startup-initialization-and-rolls-it-back ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-startup" t))
         (first nil)
         (second nil))
    (unwind-protect
        (progn
          (setq first
                (herdr-claude-code-ide-mcp-tests--t003-prepare
                 (herdr-claude-code-ide-mcp-tests--t003-agent
                  "claude" "term-starting" root) root))
          (let ((client (herdr-claude-code-ide-mcp-client-connect first)))
            (herdr-claude-code-ide-mcp-tests--t003-initialize first client)
            (should (eq (herdr-claude-code-ide-mcp-adapter-state first) 'starting))
            (should (eq (herdr-claude-code-ide-mcp-adapter-current-client first) client))
            (herdr-claude-code-ide-mcp-client-close first client)
            (should (eq (herdr-claude-code-ide-mcp-adapter-state first) 'starting))
            (should-not (herdr-claude-code-ide-mcp-adapter-current-client first))
            (should-not (herdr-claude-code-ide-mcp-adapter-reconnect-deadline first))
            (herdr-claude-code-ide-mcp-terminal-attached first)
            (should (eq (herdr-claude-code-ide-mcp-adapter-state first)
                        'waiting-for-client)))
          (setq second
                (herdr-claude-code-ide-mcp-tests--t003-prepare
                 (herdr-claude-code-ide-mcp-tests--t003-agent
                  "claude" "term-rollback" root) root))
          (let ((lockfile (herdr-claude-code-ide-mcp-adapter-lockfile second))
                (client (herdr-claude-code-ide-mcp-client-connect second)))
            (herdr-claude-code-ide-mcp-tests--t003-initialize second client)
            (herdr-claude-code-ide-mcp-agent-released second)
            (should (eq (herdr-claude-code-ide-mcp-adapter-state second) 'stopped))
            (should-not (herdr-claude-code-ide-mcp-adapter-endpoint-live-p second))
            (should-not (file-exists-p lockfile))
            (should-not (herdr-claude-code-ide-mcp-adapter-clients second))))
      (when first
        (herdr-claude-code-ide-mcp-cleanup first))
      (when second
        (herdr-claude-code-ide-mcp-cleanup second))
      (delete-directory root t)))))

(ert-deftest herdr-claude-code-ide-mcp-adoption-keeps-project-clients-distinct ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (require 'herdr-agent)
  (let* ((root (make-temp-file "herdr-claude-mcp-adopt" t))
         (server-key (expand-file-name "herdr.sock" root))
         (commands nil)
         (first-session nil)
         (second-session nil)
         (first nil)
         (second nil))
    (unwind-protect
        (let ((mcp-adopt (symbol-function 'herdr-claude-code-ide-mcp-adopt))
              (adapters nil))
          (cl-letf (((symbol-function 'herdr-api-pane-send-text)
                     (lambda (pane-id text)
                       (push (list pane-id text) commands)))
                    ((symbol-function 'herdr-claude-code-ide-mcp-adopt)
                     (lambda (session &rest options)
                       (let ((adapter (apply mcp-adopt session options)))
                         (push adapter adapters)
                         adapter))))
            (setq first-session
                  (herdr-agent-adopt
                   (herdr-claude-code-ide-mcp-tests--t003-agent
                    "claude" "term-first" root)
                   :server-key server-key :attach nil))
            (setq second-session
                  (herdr-agent-adopt
                   (herdr-claude-code-ide-mcp-tests--t003-agent
                    "claude" "term-second" root)
                   :server-key server-key :attach nil))
            (should (= (length adapters) 2))
            (setq first (nth 1 adapters)
                  second (car adapters))
            (should (eq (herdr-claude-code-ide-mcp-adapter-state first)
                        'waiting-for-client))
            (should (eq (herdr-claude-code-ide-mcp-adapter-state second)
                        'waiting-for-client))
            (should-not commands)
            (let ((reused
                   (herdr-claude-code-ide-mcp-adopt
                    first-session :takeover t :project-root root
                    :discovery-directory (expand-file-name "first" root))))
              (should (eq first reused))
              (should (herdr-claude-code-ide-mcp-adapter-endpoint-live-p reused))
              (should (equal commands
                             '(("term-first:pane" "/ide\n"))))
              (should (eq first
                          (herdr-claude-code-ide-mcp-adopt
                           first-session :takeover nil :project-root root
                           :discovery-directory (expand-file-name "first" root)))))
            (should (equal commands '(("term-first:pane" "/ide\n"))))
            (should-not (equal (herdr-claude-code-ide-mcp-adapter-endpoint first)
                               (herdr-claude-code-ide-mcp-adapter-endpoint second)))
            (should-not (equal (herdr-claude-code-ide-mcp-adapter-instance-name first)
                               (herdr-claude-code-ide-mcp-adapter-instance-name second)))
            (let ((client (herdr-claude-code-ide-mcp-client-connect first)))
              (herdr-claude-code-ide-mcp-tests--t003-initialize first client)
              (should (eq (herdr-claude-code-ide-mcp-adapter-state first) 'connected))
              (should (eq (herdr-claude-code-ide-mcp-adapter-state second)
                          'waiting-for-client)))))
      (when first
        (herdr-claude-code-ide-mcp-cleanup first))
      (when second
        (herdr-claude-code-ide-mcp-cleanup second))
      (when first-session
        (herdr-agent-detach first-session))
      (when second-session
        (herdr-agent-detach second-session))
      (delete-directory root t)))))

(ert-deftest herdr-claude-code-ide-mcp-only-arms-reconnect-after-current-disconnect ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-reconnect" t))
         (adapter nil))
    (unwind-protect
        (progn
          (setq adapter
                (herdr-claude-code-ide-mcp-tests--t003-prepare
                 (herdr-claude-code-ide-mcp-tests--t003-agent
                  "claude" "term-reconnect" root) root))
          (herdr-claude-code-ide-mcp-terminal-attached adapter)
          (should (eq (herdr-claude-code-ide-mcp-adapter-state adapter)
                      'waiting-for-client))
          (should-not (herdr-claude-code-ide-mcp-adapter-reconnect-deadline adapter))
          (let ((client (herdr-claude-code-ide-mcp-client-connect adapter)))
            (herdr-claude-code-ide-mcp-tests--t003-initialize adapter client)
            (herdr-claude-code-ide-mcp-track-pending
             adapter client "old-generation-request" "old-generation-diff")
            (herdr-claude-code-ide-mcp-client-close adapter client)
            (should (eq (herdr-claude-code-ide-mcp-adapter-state adapter)
                        'waiting-for-client))
            (should (= (herdr-claude-code-ide-mcp-adapter-reconnect-deadline-seconds
                        adapter)
                       30))
            (should (equal (herdr-claude-code-ide-mcp-adapter-cancelled-work adapter)
                           '((requests . ("old-generation-request"))
                             (diffs . ("old-generation-diff"))))))
      (when adapter
        (herdr-claude-code-ide-mcp-cleanup adapter))
      (delete-directory root t))))))

(ert-deftest herdr-claude-code-ide-mcp-supersedes-only-successful-live-candidates ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-supersede" t))
         (schemas (herdr-claude-code-ide-mcp-tests--t003-tool-schemas))
         (tool-calls nil)
         (adapter nil))
    (unwind-protect
        (progn
          (setq adapter
                (herdr-claude-code-ide-mcp-tests--t003-prepare
                 (herdr-claude-code-ide-mcp-tests--t003-agent
                  "claude" "term-supersede" root) root
                 :tool-list (lambda () (list (car schemas)))
                 :tool-call (lambda (_adapter name arguments)
                              (push (list name arguments) tool-calls)
                              '((content . ((type . "text") (text . "handled")))))))
          (herdr-claude-code-ide-mcp-terminal-attached adapter)
          (let ((first (herdr-claude-code-ide-mcp-client-connect adapter)))
            (herdr-claude-code-ide-mcp-tests--t003-initialize adapter first)
            (herdr-claude-code-ide-mcp-track-pending
             adapter first "old-generation-request" "old-generation-diff")
            (let ((failed (herdr-claude-code-ide-mcp-client-connect adapter)))
              (should (equal
                       (herdr-claude-code-ide-mcp-receive
                        adapter failed
                        (json-serialize
                         '((jsonrpc . "2.0") (id . 7) (method . "initialize")
                           (params . nil))))
                       (herdr-claude-code-ide-mcp-tests--t003-error "invalid-params")))
              (should (eq (herdr-claude-code-ide-mcp-adapter-current-client adapter)
                          first))
              (should-not (herdr-claude-code-ide-mcp-client-open-p failed)))
            (let ((replacement (herdr-claude-code-ide-mcp-client-connect adapter)))
              (herdr-claude-code-ide-mcp-tests--t003-initialize adapter replacement)
              (should (eq (herdr-claude-code-ide-mcp-adapter-state adapter) 'connected))
              (should (eq (herdr-claude-code-ide-mcp-adapter-current-client adapter)
                          replacement))
              (should (= (herdr-claude-code-ide-mcp-adapter-client-generation adapter) 2))
              (should-not (herdr-claude-code-ide-mcp-client-open-p first))
              (should (equal (herdr-claude-code-ide-mcp-adapter-cancelled-work adapter)
                             '((requests . ("old-generation-request"))
                               (diffs . ("old-generation-diff")))))
              (should-not
               (herdr-claude-code-ide-mcp-receive
                adapter first
                (json-serialize
                 (herdr-claude-code-ide-mcp-tests--t003-payload
                  "client-originated.json" "tools/call/openFile"))))
              (should-not tool-calls)
              (herdr-claude-code-ide-mcp-client-close adapter first)
              (should (eq (herdr-claude-code-ide-mcp-adapter-current-client adapter)
                          replacement))
              (should (= (herdr-claude-code-ide-mcp-adapter-client-generation adapter) 2))))
      (when adapter
        (herdr-claude-code-ide-mcp-cleanup adapter))
      (delete-directory root t))))))

(ert-deftest herdr-claude-code-ide-mcp-resolves-deadline-races-and-last-cleanup ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
  (let* ((root (make-temp-file "herdr-claude-mcp-cleanup" t))
         (first nil)
         (second nil)
         (first-deadline nil)
         (second-deadline nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_seconds _repeat callback &rest arguments)
                 (let ((deadline (lambda () (apply callback arguments))))
                   (if first-deadline
                       (setq second-deadline deadline)
                     (setq first-deadline deadline))
                   deadline)))
              ((symbol-function 'cancel-timer)
               (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (setq first
                  (herdr-claude-code-ide-mcp-tests--t003-prepare
                   (herdr-claude-code-ide-mcp-tests--t003-agent
                    "claude" "term-race-first" root) root))
            (setq second
                  (herdr-claude-code-ide-mcp-tests--t003-prepare
                   (herdr-claude-code-ide-mcp-tests--t003-agent
                    "claude" "term-race-second" root) root))
            (dolist (adapter (list first second))
              (herdr-claude-code-ide-mcp-terminal-attached adapter)
              (let ((client (herdr-claude-code-ide-mcp-client-connect adapter)))
                (herdr-claude-code-ide-mcp-tests--t003-initialize adapter client)
                (herdr-claude-code-ide-mcp-client-close adapter client)))
            (let ((replacement (herdr-claude-code-ide-mcp-client-connect first)))
              (herdr-claude-code-ide-mcp-tests--t003-initialize first replacement)
              (should first-deadline)
              (funcall first-deadline)
              (should (eq (herdr-claude-code-ide-mcp-adapter-state first) 'connected))
              (should (eq (herdr-claude-code-ide-mcp-adapter-current-client first)
                          replacement))
              (should (herdr-claude-code-ide-mcp-client-open-p replacement))
              (should-not (herdr-claude-code-ide-mcp-adapter-reconnect-deadline first)))
            (should second-deadline)
            (let ((second-lockfile (herdr-claude-code-ide-mcp-adapter-lockfile second)))
              (funcall second-deadline)
              (should-not
               (gethash (herdr-claude-code-ide-mcp-adapter-session-key second)
                        herdr-claude-code-ide-mcp--adapters))
              (should (eq (herdr-claude-code-ide-mcp-adapter-state second) 'stopped))
              (should-not (herdr-claude-code-ide-mcp-adapter-endpoint-live-p second))
              (should-not (file-exists-p second-lockfile))
              (should-not (herdr-claude-code-ide-mcp-adapter-reconnect-deadline second))
              (should-not (herdr-claude-code-ide-mcp-adapter-clients second)))
            (let ((late (herdr-claude-code-ide-mcp-client-connect second)))
              (should-not
               (herdr-claude-code-ide-mcp-receive
                second late
                (json-serialize
                 (herdr-claude-code-ide-mcp-tests--t003-payload
                  "client-originated.json" "initialize"))))
              (should-not (herdr-claude-code-ide-mcp-client-open-p late)))
            (let ((first-lockfile (herdr-claude-code-ide-mcp-adapter-lockfile first))
                  (second-lockfile (herdr-claude-code-ide-mcp-adapter-lockfile second)))
              (herdr-claude-code-ide-mcp-cleanup first)
              (should-not (herdr-claude-code-ide-mcp-global-hooks-installed-p))
              (herdr-claude-code-ide-mcp-cleanup second)
              (dolist (adapter (list first second))
                (should (eq (herdr-claude-code-ide-mcp-adapter-state adapter) 'stopped))
                (should-not (herdr-claude-code-ide-mcp-adapter-endpoint-live-p adapter))
                (should-not (herdr-claude-code-ide-mcp-adapter-reconnect-deadline adapter))
                (should-not (herdr-claude-code-ide-mcp-adapter-clients adapter)))
              (should-not (file-exists-p first-lockfile))
              (should-not (file-exists-p second-lockfile))
              (should-not (herdr-claude-code-ide-mcp-global-hooks-installed-p))))
        (when first
          (herdr-claude-code-ide-mcp-cleanup first))
        (when second
          (herdr-claude-code-ide-mcp-cleanup second))
        (delete-directory root t))))))

(ert-deftest herdr-claude-code-ide-mcp-detach-retires-client-authority-and-retries-cancellation ()
  (herdr-claude-code-ide-mcp-tests--with-websocket
    (herdr-claude-code-ide-mcp-tests--t003-require-transport)
    (require 'herdr-agent)
    (let* ((root (make-temp-file "herdr-claude-mcp-detach" t))
           (process-environment (cons (concat "HOME=" root) process-environment))
           (server-key (expand-file-name "herdr.sock" root))
           (terminal-id "term-detach")
           (session nil)
           (adapter nil)
           (websocket-open nil)
           (websocket-message nil)
           (websocket-events nil)
           (failed-raw nil))
      (unwind-protect
          (cl-letf (((symbol-function 'websocket-server)
                     (lambda (&rest options)
                       (when (not (keywordp (car options)))
                         (setq options (cdr options)))
                       (setq websocket-open (plist-get options :on-open)
                             websocket-message (plist-get options :on-message))
                       'websocket-server))
                    ((symbol-function 'websocket-frame-text)
                     (lambda (frame) frame))
                    ((symbol-function 'websocket-send-text)
                     (lambda (socket _text)
                       (if (eq socket failed-raw)
                           (error "deferred response send failed")
                         (push (list 'send socket) websocket-events))))
                    ((symbol-function 'websocket-close)
                     (lambda (socket &rest _)
                       (push (list 'close socket) websocket-events))))
            (progn
            (setq session
                  (herdr-agent-adopt
                   (herdr-claude-code-ide-mcp-tests--t003-agent
                    "claude" terminal-id root)
                   :server-key server-key :attach nil))
            (setq adapter
                  (gethash (herdr-agent-session-key session)
                           herdr-claude-code-ide-mcp--adapters))
            (should adapter)
            (herdr-claude-code-ide-mcp-terminal-attached adapter)
            (setq failed-raw 'failed-invalid-raw)
            (should websocket-open)
            (should websocket-message)
            (funcall websocket-open failed-raw)
            (let ((failed-client
                   (gethash failed-raw
                            (herdr-claude-code-ide-mcp-adapter-raw-clients adapter))))
              (should failed-client)
              (let ((error-data
                     (should-error
                      (funcall websocket-message failed-raw
                               (json-serialize
                                '((jsonrpc . "2.0") (id . 7) (method . "initialize")
                                  (params . nil)))))))
                (should (equal (error-message-string error-data)
                               "deferred response send failed")))
              (should (member (list 'close failed-raw) websocket-events))
              (should-not (memq failed-client
                                (herdr-claude-code-ide-mcp-adapter-clients adapter)))
              (should-not
               (gethash failed-raw
                        (herdr-claude-code-ide-mcp-adapter-raw-clients adapter))))
            (let* ((current-raw 'current-raw)
                   (invalid-raw 'invalid-raw)
                   (closed-raw 'closed-raw)
                   (replacement-raw 'replacement-raw)
                   (current (herdr-claude-code-ide-mcp-client-connect adapter current-raw))
                   (invalid (herdr-claude-code-ide-mcp-client-connect adapter invalid-raw))
                   (closed (herdr-claude-code-ide-mcp-client-connect adapter closed-raw))
                   (replacement (herdr-claude-code-ide-mcp-client-connect
                                 adapter replacement-raw)))
              (dolist (raw-client (list (cons current-raw current)
                                        (cons invalid-raw invalid)
                                        (cons closed-raw closed)
                                        (cons replacement-raw replacement)))
                (puthash (car raw-client) (cdr raw-client)
                         (herdr-claude-code-ide-mcp-adapter-raw-clients adapter)))
              (herdr-claude-code-ide-mcp-tests--t003-initialize adapter current)
              (should
               (herdr-claude-code-ide-mcp-receive
                adapter invalid
                (json-serialize
                 '((jsonrpc . "2.0") (id . 7) (method . "initialize") (params . nil)))))
              (herdr-claude-code-ide-mcp-client-close adapter closed)
              (should-not (memq closed
                                (herdr-claude-code-ide-mcp-adapter-clients adapter)))
              (should-not
               (gethash closed-raw
                        (herdr-claude-code-ide-mcp-adapter-raw-clients adapter)))
              (herdr-claude-code-ide-mcp-tests--t003-initialize adapter replacement)
              (dolist (retired (list (cons current current-raw) (cons invalid invalid-raw)))
                (should-not (memq (car retired)
                                  (herdr-claude-code-ide-mcp-adapter-clients adapter)))
                (should-not
                 (gethash (cdr retired)
                          (herdr-claude-code-ide-mcp-adapter-raw-clients adapter))))
              (herdr-claude-code-ide-mcp-track-pending
               adapter replacement "deferred-request" "deferred-work")
              (should (herdr-claude-code-ide-mcp-adapter-pending adapter))
              (let ((cancellation-fault t)
                    (cancellation-calls nil))
                (setf (herdr-claude-code-ide-mcp-adapter-cancel-work adapter)
                      (lambda (&rest arguments)
                        (push arguments cancellation-calls)
                        (if cancellation-fault
                            (progn
                              (setq cancellation-fault nil)
                              (error "deferred cancellation failed"))
                          t)))
                (herdr-agent-detach session)
                (should-not cancellation-fault)
                (should (= (length cancellation-calls) 1))
                (should (eq (herdr-agent-session-state session) 'detaching))
                (should (eq (herdr-agent-find server-key terminal-id) session))
                (should (herdr-claude-code-ide-mcp-adapter-pending adapter))
                (should-not
                 (herdr-claude-code-ide-mcp-receive
                  adapter replacement
                  (json-serialize
                   '((jsonrpc . "2.0") (id . 9) (method . "tools/call")
                     (params . ((name . "unknown") (arguments . ())))))))
                (herdr-agent-detach session)
                (should (= (length cancellation-calls) 2))
              (should (eq (herdr-agent-session-state session) 'stopped))
              (should-not (herdr-agent-find server-key terminal-id))
              (should-not (herdr-claude-code-ide-mcp-adapter-pending adapter))
              (should-not (memq replacement
                                (herdr-claude-code-ide-mcp-adapter-clients adapter)))
              (should-not
               (gethash replacement-raw
                        (herdr-claude-code-ide-mcp-adapter-raw-clients adapter)))))
        (when session
          (herdr-agent-detach session))
        (when adapter
          (herdr-claude-code-ide-mcp-cleanup adapter))
        (should-not (directory-files-recursively root "\\.lock\\'"))
        (delete-directory root t)))))))

(provide 'herdr-claude-code-ide-mcp-tests)
;;; herdr-claude-code-ide-mcp-tests.el ends here
