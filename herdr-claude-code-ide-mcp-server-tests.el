;;; herdr-claude-code-ide-mcp-server-tests.el --- HTTP MCP server tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'xref)
(require 'project)
(require 'imenu)
(require 'herdr-claude-code-ide-mcp-server nil t)
(require 'herdr-claude-code-ide-emacs-tools nil t)

(defconst herdr-claude-code-ide-mcp-server-tests--root
  (file-name-directory (or load-file-name buffer-file-name)))

(defun herdr-claude-code-ide-mcp-server-tests--call (function &rest arguments)
  (unless (fboundp function)
    (ert-fail (format "T006 HTTP MCP entry point is unavailable: %s" function)))
  (apply function arguments))

(defun herdr-claude-code-ide-mcp-server-tests--fixture (&optional name)
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (or name "testdata/claude-code-ide/client-originated.json")
                       herdr-claude-code-ide-mcp-server-tests--root))
    (json-parse-buffer :object-type 'alist :array-type 'list
                       :null-object nil :false-object :json-false)))

(defun herdr-claude-code-ide-mcp-server-tests--exchange (fixture identifier)
  (seq-find (lambda (exchange)
              (equal (alist-get 'id exchange) identifier))
            (alist-get 'exchanges fixture)))

(defun herdr-claude-code-ide-mcp-server-tests--entry (key object)
  (or (assoc key object)
      (assoc (if (symbolp key) (symbol-name key) (intern key)) object)))

(defun herdr-claude-code-ide-mcp-server-tests--value (key object)
  (cdr (herdr-claude-code-ide-mcp-server-tests--entry key object)))

(defun herdr-claude-code-ide-mcp-server-tests--header (name headers)
  (herdr-claude-code-ide-mcp-server-tests--value name headers))

(defun herdr-claude-code-ide-mcp-server-tests--request (fixture identifier route &optional payload)
  (let* ((exchange (herdr-claude-code-ide-mcp-server-tests--exchange fixture identifier))
         (request (copy-tree (herdr-claude-code-ide-mcp-server-tests--value 'request exchange)))
         (headers (herdr-claude-code-ide-mcp-server-tests--value 'headers request)))
    (setf (alist-get 'path request)
          (replace-regexp-in-string "<session-id>" route
                                    (herdr-claude-code-ide-mcp-server-tests--value
                                     'path request)))
    (when (herdr-claude-code-ide-mcp-server-tests--header "Mcp-Session-Id" headers)
      (setf (alist-get 'Mcp-Session-Id headers) route))
    (append request
            `((body . ,(json-serialize
                         (or payload
                             (herdr-claude-code-ide-mcp-server-tests--value
                              'payload exchange))))))))

(defun herdr-claude-code-ide-mcp-server-tests--loopback-request (host port request)
  (let* ((body (herdr-claude-code-ide-mcp-server-tests--value 'body request))
         (headers (herdr-claude-code-ide-mcp-server-tests--value 'headers request))
         (buffer (generate-new-buffer " *herdr-t006-http*"))
         process)
    (unwind-protect
        (progn
          (setq process (open-network-stream "herdr-t006-http" buffer host port
                                             :type 'plain :coding 'utf-8-unix))
          (set-process-sentinel process #'ignore)
          (process-send-string
           process
           (concat (herdr-claude-code-ide-mcp-server-tests--value 'method request)
                   " " (herdr-claude-code-ide-mcp-server-tests--value 'path request)
                   " HTTP/1.1\r\nHost: " host "\r\n"
                   (mapconcat (lambda (header)
                                (format "%s: %s" (car header) (cdr header)))
                              headers "\r\n")
                   "\r\ncontent-length: " (number-to-string (string-bytes body))
                   "\r\n\r\n" body))
          (with-timeout (2 (ert-fail "Loopback HTTP listener did not respond"))
            (while (with-current-buffer buffer
                     (goto-char (point-min))
                     (not (search-forward "\r\n\r\n" nil t)))
              (accept-process-output process 0.05)))
          (with-current-buffer buffer (buffer-string)))
      (when (and process (process-live-p process)) (delete-process process))
      (kill-buffer buffer))))

(defun herdr-claude-code-ide-mcp-server-tests--body (response)
  (let ((body (herdr-claude-code-ide-mcp-server-tests--value 'body response)))
    (if (stringp body)
        (json-parse-string body :object-type 'alist :array-type 'list
                           :null-object nil :false-object :json-false)
      body)))

(defun herdr-claude-code-ide-mcp-server-tests--content-data (response)
  (json-parse-string
   (herdr-claude-code-ide-mcp-server-tests--value
    'text
    (car (herdr-claude-code-ide-mcp-server-tests--value
          'content
          (herdr-claude-code-ide-mcp-server-tests--value
           'result
           (herdr-claude-code-ide-mcp-server-tests--body response)))))
   :object-type 'alist :array-type 'list :null-object nil :false-object :json-false))

(defun herdr-claude-code-ide-mcp-server-tests--context (route key root &optional kind)
  (list :session-key key
        :kind (or kind "claude")
        :mcp-route route
        :project-root root
        :active-buffer (current-buffer)
        :bind-host "127.0.0.1"))

(defun herdr-claude-code-ide-mcp-server-tests--unregister (&rest contexts)
  (when (fboundp 'herdr-claude-code-ide-mcp-server-unregister-session)
    (dolist (context contexts)
      (ignore-errors
        (herdr-claude-code-ide-mcp-server-unregister-session context)))))

(defun herdr-claude-code-ide-mcp-server-tests--initialize (fixture context)
  (herdr-claude-code-ide-mcp-server-tests--call
   'herdr-claude-code-ide-mcp-server-handle-request
   (herdr-claude-code-ide-mcp-server-tests--request
    fixture "http/initialize" (plist-get context :mcp-route))))

(defun herdr-claude-code-ide-mcp-server-tests--tool-request (fixture context name arguments &optional id)
  (herdr-claude-code-ide-mcp-server-tests--request
   fixture "http/tools/call" (plist-get context :mcp-route)
   `((jsonrpc . "2.0")
     (id . ,(or id 22))
     (method . "tools/call")
     (params . ((name . ,name) (arguments . ,arguments))))))

(ert-deftest herdr-claude-code-ide-mcp-server-shares-a-loopback-service-and-routes-composite-sessions ()
  (let* ((fixture (herdr-claude-code-ide-mcp-server-tests--fixture))
         (pi (herdr-claude-code-ide-mcp-server-tests--context
              "t006-pi" '("/tmp/herdr-pi.sock" . "terminal-pi") "/tmp/t006-pi" "pi"))
         (first (herdr-claude-code-ide-mcp-server-tests--context
                 "t006-first" '("/tmp/herdr-a.sock" . "terminal-a") "/tmp/t006-a"))
         (second (herdr-claude-code-ide-mcp-server-tests--context
                  "t006-second" '("/tmp/herdr-b.sock" . "terminal-b") "/tmp/t006-b")))
    (unwind-protect
        (progn
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-session pi)
          (should-not (herdr-claude-code-ide-mcp-server-tests--call
                       'herdr-claude-code-ide-mcp-server-state))
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-session first)
          (let* ((state (herdr-claude-code-ide-mcp-server-tests--call
                         'herdr-claude-code-ide-mcp-server-state))
                 (host (plist-get state :host))
                 (port (plist-get state :port)))
            (should (equal host "127.0.0.1"))
            (should (and (integerp port) (> port 0)))
            (let* ((response
                    (herdr-claude-code-ide-mcp-server-tests--loopback-request
                     host port
                     (herdr-claude-code-ide-mcp-server-tests--request
                      fixture "http/initialize" (plist-get first :mcp-route))))
                   (body (json-parse-string (cadr (split-string response "\r\n\r\n"))
                                            :object-type 'alist :array-type 'list
                                            :null-object nil :false-object :json-false))
                   (expected (herdr-claude-code-ide-mcp-server-tests--value
                              'result
                              (herdr-claude-code-ide-mcp-server-tests--exchange
                               (herdr-claude-code-ide-mcp-server-tests--fixture
                                "testdata/claude-code-ide/herdr-decided.json")
                               "initialize-result"))))
              (should (string-match-p "HTTP/1\\.[01] 200" response))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'result body)
                             expected)))
            (herdr-claude-code-ide-mcp-server-tests--call
             'herdr-claude-code-ide-mcp-server-register-session second)
            (dolist (context (list first second))
              (herdr-claude-code-ide-mcp-server-tests--call
               'herdr-claude-code-ide-mcp-server-register-tool
               context "route" '((type . "object") (properties . ()) (required . ()))
               (lambda (tool-context _arguments)
                 (let ((key (plist-get tool-context :session-key)))
                   `((content . (((type . "text")
                                  (text . ,(json-serialize
                                             `((server . ,(car key))
                                               (terminal . ,(cdr key))))))))))))
              (herdr-claude-code-ide-mcp-server-tests--initialize fixture context))
            (dolist (context (list first second))
              (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                                'herdr-claude-code-ide-mcp-server-handle-request
                                (herdr-claude-code-ide-mcp-server-tests--tool-request
                                 fixture context "herdr-route" '())))
                     (data (herdr-claude-code-ide-mcp-server-tests--content-data response)))
                (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'server data)
                               (car (plist-get context :session-key))))
                (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'terminal data)
                               (cdr (plist-get context :session-key))))))
            (herdr-claude-code-ide-mcp-server-tests--call
             'herdr-claude-code-ide-mcp-server-unregister-session first)
            (should (= (plist-get (herdr-claude-code-ide-mcp-server-tests--call
                                   'herdr-claude-code-ide-mcp-server-state)
                                  :session-count)
                       1))
            (herdr-claude-code-ide-mcp-server-tests--call
             'herdr-claude-code-ide-mcp-server-unregister-session second)
            (should-not (herdr-claude-code-ide-mcp-server-tests--call
                         'herdr-claude-code-ide-mcp-server-state))
            (let ((buffer (generate-new-buffer " *herdr-t006-closed*")) process)
              (unwind-protect
                  (should-error
                   (setq process (open-network-stream "herdr-t006-closed" buffer host port
                                                      :type 'plain :coding 'utf-8-unix)))
                (when (and process (process-live-p process)) (delete-process process))
                (kill-buffer buffer)))))
      (herdr-claude-code-ide-mcp-server-tests--unregister pi first second))))

(ert-deftest herdr-claude-code-ide-mcp-server-replays-http-fixtures-and-protocol-errors ()
  (let* ((fixture (herdr-claude-code-ide-mcp-server-tests--fixture))
         (context (herdr-claude-code-ide-mcp-server-tests--context
                   "t001-session" '("/tmp/herdr.sock" . "terminal") "/tmp/t006")))
    (unwind-protect
        (progn
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-session context)
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-emacs-tools-register context)
          (let* ((response (herdr-claude-code-ide-mcp-server-tests--initialize fixture context))
                 (expected (herdr-claude-code-ide-mcp-server-tests--value
                            'result
                            (herdr-claude-code-ide-mcp-server-tests--exchange
                             (herdr-claude-code-ide-mcp-server-tests--fixture
                              "testdata/claude-code-ide/herdr-decided.json")
                             "initialize-result"))))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response) 200))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--header
                            "Content-Type"
                            (herdr-claude-code-ide-mcp-server-tests--value 'headers response))
                           "application/json"))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--header
                            "Mcp-Session-Id"
                            (herdr-claude-code-ide-mcp-server-tests--value 'headers response))
                           "t001-session"))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--value
                            'result
                            (herdr-claude-code-ide-mcp-server-tests--body response))
                           expected)))
          (let ((response (herdr-claude-code-ide-mcp-server-tests--call
                           'herdr-claude-code-ide-mcp-server-handle-request
                           (herdr-claude-code-ide-mcp-server-tests--request
                            fixture "http/tools/list" "t001-session"))))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response) 200))
            (should (member "herdr-project-information"
                            (mapcar (lambda (tool)
                                      (herdr-claude-code-ide-mcp-server-tests--value 'name tool))
                                    (herdr-claude-code-ide-mcp-server-tests--value
                                     'tools
                                     (herdr-claude-code-ide-mcp-server-tests--value
                                      'result
                                      (herdr-claude-code-ide-mcp-server-tests--body response)))))))
          (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                            'herdr-claude-code-ide-mcp-server-handle-request
                            (herdr-claude-code-ide-mcp-server-tests--tool-request
                             fixture context "herdr-project-information" '())))
                 (body (herdr-claude-code-ide-mcp-server-tests--body response)))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response) 200))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'id body) 22))
            (should (herdr-claude-code-ide-mcp-server-tests--entry 'result body))
            (should-not (herdr-claude-code-ide-mcp-server-tests--entry 'error body)))
          (let ((response (herdr-claude-code-ide-mcp-server-tests--call
                           'herdr-claude-code-ide-mcp-server-handle-request
                           `((method . "POST") (path . "/mcp/t001-session")
                             (headers . ((Accept . "application/json, text/event-stream")
                                         (Content-Type . "application/json")
                                         (MCP-Protocol-Version . "2025-11-25")
                                         (Mcp-Session-Id . "t001-session")))
                             (body . "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response) 202)))
          (dolist (case '(("{" 400 -32700 "Parse error")
                          ("{}" 400 -32600 "Invalid Request")
                          ("{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"unknown\"}" 200 -32601 "Method not found")
                          ("{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}" 200 -32602 "Unknown tool")))
            (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                              'herdr-claude-code-ide-mcp-server-handle-request
                              `((method . "POST") (path . "/mcp/t001-session")
                                (headers . ((Content-Type . "application/json")))
                                (body . ,(nth 0 case)))))
                   (error (herdr-claude-code-ide-mcp-server-tests--value
                           'error (herdr-claude-code-ide-mcp-server-tests--body response))))
              (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response)
                         (nth 1 case)))
              (should (= (herdr-claude-code-ide-mcp-server-tests--value 'code error)
                         (nth 2 case)))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'message error)
                             (nth 3 case)))))
          (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                            'herdr-claude-code-ide-mcp-server-handle-request
                            `((method . "POST") (path . "/mcp/t001-session")
                              (headers . ((Content-Type . "application/json")))
                              (body . "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"initialize\",\"params\":null}"))))
                 (body (herdr-claude-code-ide-mcp-server-tests--body response))
                 (error (herdr-claude-code-ide-mcp-server-tests--value 'error body)))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response) 200))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'id body) 23))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'code error) -32602))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'message error)
                           "Invalid params"))))
      (herdr-claude-code-ide-mcp-server-tests--unregister context))))

(ert-deftest herdr-claude-code-ide-mcp-server-preserves-present-false-and-nil-arguments ()
  (let* ((fixture (herdr-claude-code-ide-mcp-server-tests--fixture))
         (context (herdr-claude-code-ide-mcp-server-tests--context
                   "t001-session" '("/tmp/herdr.sock" . "terminal") "/tmp/t006"))
         received)
    (unwind-protect
        (progn
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-session context)
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-tool
           context "argument-presence"
           '((type . "object")
             (properties . ((enabled . ((type . ("boolean" "null"))))))
             (required . ("enabled")))
           (lambda (_context arguments)
             (setq received arguments)
             '((content . (((type . "text") (text . "ok")))))))
          (herdr-claude-code-ide-mcp-server-tests--initialize fixture context)
          (dolist (case '((((enabled . :false)) :json-false)
                          (((enabled . nil)) nil)))
            (pcase-let ((`(,arguments ,expected) case))
              (herdr-claude-code-ide-mcp-server-tests--call
               'herdr-claude-code-ide-mcp-server-handle-request
               (herdr-claude-code-ide-mcp-server-tests--tool-request
                fixture context "herdr-argument-presence" arguments))
              (let ((entry (herdr-claude-code-ide-mcp-server-tests--entry
                            'enabled received)))
                (should entry)
                (should (equal (cdr entry) expected)))))
          (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                            'herdr-claude-code-ide-mcp-server-handle-request
                            (herdr-claude-code-ide-mcp-server-tests--tool-request
                             fixture context "herdr-argument-presence" '() 7)))
                 (error (herdr-claude-code-ide-mcp-server-tests--value
                         'error (herdr-claude-code-ide-mcp-server-tests--body response))))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'status response) 200))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'id
                                                             (herdr-claude-code-ide-mcp-server-tests--body response))
                       7))
            (should (= (herdr-claude-code-ide-mcp-server-tests--value 'code error) -32602))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'message error)
                           "Invalid params"))))
      (herdr-claude-code-ide-mcp-server-tests--unregister context))))

(ert-deftest herdr-claude-code-ide-mcp-server-rejects-nonloopback-and-omits-cors-headers ()
  (let ((nonloopback (herdr-claude-code-ide-mcp-server-tests--context
                      "t006-public" '("/tmp/herdr-public.sock" . "terminal") "/tmp/t006")))
    (setf (plist-get nonloopback :bind-host) "0.0.0.0")
    (should (fboundp 'herdr-claude-code-ide-mcp-server-register-session))
    (should-error
     (herdr-claude-code-ide-mcp-server-register-session nonloopback)))
  (let* ((fixture (herdr-claude-code-ide-mcp-server-tests--fixture))
         (context (herdr-claude-code-ide-mcp-server-tests--context
                   "t001-session" '("/tmp/herdr.sock" . "terminal") "/tmp/t006")))
    (unwind-protect
        (progn
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-session context)
          (let ((response (herdr-claude-code-ide-mcp-server-tests--initialize fixture context)))
            (dolist (header '("Access-Control-Allow-Origin" "Access-Control-Allow-Headers"
                              "Access-Control-Allow-Methods" "Access-Control-Allow-Credentials"))
              (should-not (herdr-claude-code-ide-mcp-server-tests--header
                           header
                           (herdr-claude-code-ide-mcp-server-tests--value 'headers response))))))
      (herdr-claude-code-ide-mcp-server-tests--unregister context))))

(ert-deftest herdr-claude-code-ide-mcp-server-keeps-dynamic-tools-session-local ()
  (let* ((fixture (herdr-claude-code-ide-mcp-server-tests--fixture))
         (first (herdr-claude-code-ide-mcp-server-tests--context
                 "t006-first" '("/tmp/herdr-a.sock" . "terminal-a") "/tmp/t006-a"))
         (second (herdr-claude-code-ide-mcp-server-tests--context
                  "t006-second" '("/tmp/herdr-b.sock" . "terminal-b") "/tmp/t006-b")))
    (unwind-protect
        (progn
          (dolist (context (list first second))
            (herdr-claude-code-ide-mcp-server-tests--call
             'herdr-claude-code-ide-mcp-server-register-session context)
            (herdr-claude-code-ide-mcp-server-tests--initialize fixture context))
          (herdr-claude-code-ide-mcp-server-tests--call
           'herdr-claude-code-ide-mcp-server-register-tool
           first "session-label"
           '((type . "object") (properties . ()) (required . ()))
           (lambda (context _arguments)
             `((content . (((type . "text")
                            (text . ,(plist-get context :mcp-route))))))))
          (dolist (entry `((,first . t006-first) (,second . nil)))
            (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                              'herdr-claude-code-ide-mcp-server-handle-request
                              (herdr-claude-code-ide-mcp-server-tests--request
                               fixture "http/tools/list"
                               (plist-get (car entry) :mcp-route))))
                   (names (mapcar (lambda (tool)
                                    (herdr-claude-code-ide-mcp-server-tests--value 'name tool))
                                  (herdr-claude-code-ide-mcp-server-tests--value
                                   'tools
                                   (herdr-claude-code-ide-mcp-server-tests--value
                                    'result
                                    (herdr-claude-code-ide-mcp-server-tests--body response))))))
              (if (cdr entry)
                  (should (member "herdr-session-label" names))
                (should-not (member "herdr-session-label" names)))))
          (let* ((response (herdr-claude-code-ide-mcp-server-tests--call
                            'herdr-claude-code-ide-mcp-server-handle-request
                            (herdr-claude-code-ide-mcp-server-tests--tool-request
                             fixture first "herdr-session-label" '())))
                 (body (herdr-claude-code-ide-mcp-server-tests--body response))
                 (result (herdr-claude-code-ide-mcp-server-tests--value 'result body))
                 (content (herdr-claude-code-ide-mcp-server-tests--value 'content result)))
            (should (equal (herdr-claude-code-ide-mcp-server-tests--value
                            'text (car content))
                           "t006-first"))))
      (herdr-claude-code-ide-mcp-server-tests--unregister first second))))

(ert-deftest herdr-claude-code-ide-emacs-tools-normalize-provider-results-in-the-owning-context ()
  (let* ((fixture (herdr-claude-code-ide-mcp-server-tests--fixture))
         (root-a (make-temp-file "herdr-t006-a" t))
         (root-b (make-temp-file "herdr-t006-b" t))
         (buffer-a (generate-new-buffer " *herdr-t006-a*"))
         (buffer-b (generate-new-buffer " *herdr-t006-b*"))
         (first (herdr-claude-code-ide-mcp-server-tests--context
                 "t006-first" '("/tmp/herdr-a.sock" . "terminal-a") root-a))
         (second (herdr-claude-code-ide-mcp-server-tests--context
                  "t006-second" '("/tmp/herdr-b.sock" . "terminal-b") root-b)))
    (unwind-protect
        (with-current-buffer buffer-a
          (insert "12345678")
          (setq first (plist-put first :active-buffer buffer-a))
          (setq second (plist-put second :active-buffer buffer-b))
          (cl-letf (((symbol-function 'xref-find-backend) (lambda () 't006))
                    ((symbol-function 'xref-backend-references)
                     (lambda (_backend identifier)
                       (list (xref-make identifier
                                        (xref-make-file-location
                                         (expand-file-name "lib.el" root-a) 2 3)))))
                    ((symbol-function 'xref-backend-apropos)
                     (lambda (_backend pattern)
                       (list (xref-make pattern
                                        (xref-make-file-location
                                         (expand-file-name "api.el" root-a) 4 5)))))
                    ((symbol-function 'project-current) (lambda (&rest _) default-directory))
                    ((symbol-function 'project-root) (lambda (project) project))
                    ((symbol-function 'imenu--make-index-alist)
                     (lambda (&rest _)
                       (list '("*Rescan*" . -99)
                             (list "Widgets" (cons "Widget" (copy-marker 9))))))
                    ((symbol-function 'treesit-buffer-root-node) (lambda (&rest _) 'root))
                    ((symbol-function 'treesit-node-type) (lambda (&rest _) "source_file"))
                    ((symbol-function 'treesit-node-start) (lambda (&rest _) 1))
                    ((symbol-function 'treesit-node-end) (lambda (&rest _) 12))
                    ((symbol-function 'treesit-node-children) (lambda (&rest _) nil)))
            (dolist (context (list first second))
              (herdr-claude-code-ide-mcp-server-tests--call
               'herdr-claude-code-ide-mcp-server-register-session context)
              (herdr-claude-code-ide-mcp-server-tests--call
               'herdr-claude-code-ide-emacs-tools-register context)
              (herdr-claude-code-ide-mcp-server-tests--initialize fixture context))
            (let* ((references
                    (herdr-claude-code-ide-mcp-server-tests--content-data
                     (herdr-claude-code-ide-mcp-server-tests--call
                      'herdr-claude-code-ide-mcp-server-handle-request
                      (herdr-claude-code-ide-mcp-server-tests--tool-request
                       fixture first "herdr-xref-references" '((identifier . "needle"))))))
                   (apropos
                    (herdr-claude-code-ide-mcp-server-tests--content-data
                     (herdr-claude-code-ide-mcp-server-tests--call
                      'herdr-claude-code-ide-mcp-server-handle-request
                      (herdr-claude-code-ide-mcp-server-tests--tool-request
                       fixture first "herdr-xref-apropos" '((pattern . "needle"))))))
                   (project-a
                    (herdr-claude-code-ide-mcp-server-tests--content-data
                     (herdr-claude-code-ide-mcp-server-tests--call
                      'herdr-claude-code-ide-mcp-server-handle-request
                      (herdr-claude-code-ide-mcp-server-tests--tool-request
                       fixture first "herdr-project-information" '()))))
                   (project-b
                    (herdr-claude-code-ide-mcp-server-tests--content-data
                     (herdr-claude-code-ide-mcp-server-tests--call
                      'herdr-claude-code-ide-mcp-server-handle-request
                      (herdr-claude-code-ide-mcp-server-tests--tool-request
                       fixture second "herdr-project-information" '()))))
                   (imenu-response
                    (herdr-claude-code-ide-mcp-server-tests--call
                     'herdr-claude-code-ide-mcp-server-handle-request
                     (herdr-claude-code-ide-mcp-server-tests--tool-request
                      fixture first "herdr-imenu-symbols" '())))
                   (imenu-body (herdr-claude-code-ide-mcp-server-tests--body imenu-response))
                   (tree
                    (herdr-claude-code-ide-mcp-server-tests--content-data
                     (herdr-claude-code-ide-mcp-server-tests--call
                      'herdr-claude-code-ide-mcp-server-handle-request
                      (herdr-claude-code-ide-mcp-server-tests--tool-request
                       fixture first "herdr-tree-sitter-information" '())))))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value
                              'path
                              (car (herdr-claude-code-ide-mcp-server-tests--value
                                    'references references)))
                             (expand-file-name "lib.el" root-a)))
              (should (= (herdr-claude-code-ide-mcp-server-tests--value
                          'line
                          (car (herdr-claude-code-ide-mcp-server-tests--value
                                'references references)))
                         2))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value
                              'path
                              (car (herdr-claude-code-ide-mcp-server-tests--value
                                    'references apropos)))
                             (expand-file-name "api.el" root-a)))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'root project-a)
                             root-a))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'root project-b)
                             root-b))
              (should-not (herdr-claude-code-ide-mcp-server-tests--entry 'error imenu-body))
              (let* ((imenu (herdr-claude-code-ide-mcp-server-tests--content-data imenu-response))
                     (symbols (herdr-claude-code-ide-mcp-server-tests--value 'symbols imenu))
                     (symbol (car symbols)))
                (should (= (length symbols) 1))
                (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'name symbol)
                               "Widget"))
                (should (= (herdr-claude-code-ide-mcp-server-tests--value 'position symbol) 9)))
              (should (equal (herdr-claude-code-ide-mcp-server-tests--value 'type tree)
                             "source_file"))
              (should (= (herdr-claude-code-ide-mcp-server-tests--value 'start tree) 1))
              (should (= (herdr-claude-code-ide-mcp-server-tests--value 'end tree) 12)))))
      (herdr-claude-code-ide-mcp-server-tests--unregister first second)
      (when (buffer-live-p buffer-a) (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b) (kill-buffer buffer-b))
      (delete-directory root-a t)
      (delete-directory root-b t))))

(provide 'herdr-claude-code-ide-mcp-server-tests)
;;; herdr-claude-code-ide-mcp-server-tests.el ends here
