;;; herdr-claude-code-ide-mcp-tests.el --- Claude Code IDE contract tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'seq)
(require 'subr-x)

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

(defun herdr-claude-code-ide-mcp-tests--verification-p (value)
  (let ((prefix (cond ((string-prefix-p "ERT:" value) "ERT:")
                      ((string-prefix-p "manual:" value) "manual:"))))
    (when prefix
      (let ((target (string-trim (substring value (length prefix)))))
        (and (not (string-blank-p target))
             (string-match-p "[[:alnum:]]" target))))))

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
  (let ((path (expand-file-name "docs/claude-code-ide-parity.md"
                                herdr-claude-code-ide-mcp-tests--root)))
    (should (file-exists-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (should (equal (herdr-claude-code-ide-mcp-tests--ledger-row "Workflow")
                     '("Workflow" "Scope task" "Verification" "State")))
      (dolist (workflow-task
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
                 ("platform-verification" . "T010")))
        (let ((row (herdr-claude-code-ide-mcp-tests--ledger-row (car workflow-task))))
          (should row)
          (should (= (length row) 4))
          (should (equal (nth 1 row) (cdr workflow-task)))
          (should (stringp (nth 2 row)))
          (should (herdr-claude-code-ide-mcp-tests--verification-p (nth 2 row)))
          (should (member (nth 3 row) '("captured" "planned" "pending" "blocked"))))))))

(provide 'herdr-claude-code-ide-mcp-tests)
;;; herdr-claude-code-ide-mcp-tests.el ends here
