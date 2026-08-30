;;; herdr-claude-code-ide-mcp-server.el --- Loopback HTTP MCP service -*- lexical-binding: t; -*-

;;; Commentary:

;; Loopback HTTP transport for session-scoped MCP tools.

;;; Code:

(require 'cl-lib)
(require 'json)

(defvar herdr-claude-code-ide-mcp-server--listener nil
  "Loopback HTTP listener process.")
(defvar herdr-claude-code-ide-mcp-server--sessions nil
  "MCP sessions indexed by route.")

(defun herdr-claude-code-ide-mcp-server--entry (key object)
  "Return KEY's entry in OBJECT."
  (or (assoc key object)
      (assoc (if (symbolp key) (symbol-name key) (intern key)) object)))

(defun herdr-claude-code-ide-mcp-server--value (key object)
  "Return KEY's value in OBJECT."
  (cdr (herdr-claude-code-ide-mcp-server--entry key object)))

(defun herdr-claude-code-ide-mcp-server--route (context)
  "Return CONTEXT's MCP route."
  (plist-get context :mcp-route))

(defun herdr-claude-code-ide-mcp-server--eligible-p (context)
  "Return non-nil when CONTEXT can use MCP."
  (equal (format "%s" (plist-get context :kind)) "claude"))

(defun herdr-claude-code-ide-mcp-server--session (route)
  "Return the session registered for ROUTE."
  (assoc route herdr-claude-code-ide-mcp-server--sessions))

(defun herdr-claude-code-ide-mcp-server--state ()
  "Return the loopback MCP server state."
  (when (process-live-p herdr-claude-code-ide-mcp-server--listener)
    (list :host "127.0.0.1"
            :port (process-contact herdr-claude-code-ide-mcp-server--listener :service)
            :session-count (length herdr-claude-code-ide-mcp-server--sessions))))

(defun herdr-claude-code-ide-mcp-server-state ()
  "Return the loopback MCP server state."
  (herdr-claude-code-ide-mcp-server--state))

(defun herdr-claude-code-ide-mcp-server--http-response (response)
  "Encode RESPONSE as an HTTP response string."
  (let* ((status (herdr-claude-code-ide-mcp-server--value 'status response))
         (body (or (herdr-claude-code-ide-mcp-server--value 'body response) ""))
         (headers (herdr-claude-code-ide-mcp-server--value 'headers response))
         (reason (if (= status 200) "OK" (if (= status 202) "Accepted" "Bad Request"))))
    (concat (format "HTTP/1.1 %d %s\r\n" status reason)
            (mapconcat (lambda (header) (format "%s: %s\r\n" (car header) (cdr header)))
                       headers "")
            (format "Content-Length: %d\r\n\r\n%s" (string-bytes body) body))))

(defun herdr-claude-code-ide-mcp-server--decode-request (input)
  "Decode one complete HTTP request from INPUT."
  (when-let ((boundary (string-match "\r\n\r\n" input)))
    (let* ((header-lines (split-string (substring input 0 boundary) "\r\n"))
           (request-line (split-string (car header-lines) " "))
           (headers (delq nil
                         (mapcar (lambda (line)
                                   (when (string-match "\\`\\([^:]+\\): *\\(.*\\)\\'" line)
                                     (cons (downcase (match-string 1 line))
                                           (match-string 2 line))))
                                 (cdr header-lines))))
           (body-start (+ boundary 4))
           (content-length (cdr (assoc "content-length" headers))))
      (when (and (stringp content-length)
                 (string-match-p "\\`[0-9]+\\'" content-length))
        (let ((length-header (string-to-number content-length)))
          (when (>= (string-bytes (substring input body-start)) length-header)
            `((method . ,(car request-line))
              (path . ,(cadr request-line))
              (headers . ,headers)
              (body . ,(decode-coding-string
                        (substring input body-start (+ body-start length-header)) 'utf-8-unix)))))))))

(defun herdr-claude-code-ide-mcp-server--receive (process chunk)
  "Append CHUNK to PROCESS and serve a complete request."
  (let ((input (concat (or (process-get process 'herdr-input) "") chunk)))
    (process-put process 'herdr-input input)
    (when-let ((request (herdr-claude-code-ide-mcp-server--decode-request input)))
      (process-send-string process
                           (encode-coding-string
                            (herdr-claude-code-ide-mcp-server--http-response
                             (herdr-claude-code-ide-mcp-server-handle-request request))
                            'utf-8-unix))
      (delete-process process))))

(defun herdr-claude-code-ide-mcp-server--accept (_listener client _message)
  "Configure CLIENT to receive an HTTP request."
  (set-process-coding-system client 'binary 'binary)
  (set-process-filter client #'herdr-claude-code-ide-mcp-server--receive))

(defun herdr-claude-code-ide-mcp-server--start ()
  "Start the loopback MCP HTTP server."
  (setq herdr-claude-code-ide-mcp-server--listener
        (make-network-process :name "herdr-mcp" :server t :host "127.0.0.1"
                              :service t :noquery t
                              :log #'herdr-claude-code-ide-mcp-server--accept)))

(defun herdr-claude-code-ide-mcp-server-register-session (context)
  "Register a loopback MCP session for CONTEXT."
  (when (herdr-claude-code-ide-mcp-server--eligible-p context)
    (unless (equal (plist-get context :bind-host) "127.0.0.1")
      (error "HTTP MCP service only accepts loopback contexts"))
    (let ((route (herdr-claude-code-ide-mcp-server--route context)))
      (setq herdr-claude-code-ide-mcp-server--sessions
            (cl-remove-if (lambda (entry) (equal (car entry) route))
                          herdr-claude-code-ide-mcp-server--sessions))
      (push (cons route (list :context context :tools nil))
            herdr-claude-code-ide-mcp-server--sessions)
      (unless (process-live-p herdr-claude-code-ide-mcp-server--listener)
        (herdr-claude-code-ide-mcp-server--start)))))

(defun herdr-claude-code-ide-mcp-server-unregister-session (context)
  "Unregister CONTEXT's loopback MCP session."
  (when (herdr-claude-code-ide-mcp-server--eligible-p context)
    (setq herdr-claude-code-ide-mcp-server--sessions
          (cl-remove-if (lambda (entry)
                          (equal (car entry) (herdr-claude-code-ide-mcp-server--route context)))
                        herdr-claude-code-ide-mcp-server--sessions))
    (when (and (null herdr-claude-code-ide-mcp-server--sessions)
               (process-live-p herdr-claude-code-ide-mcp-server--listener))
      (delete-process herdr-claude-code-ide-mcp-server--listener)
      (setq herdr-claude-code-ide-mcp-server--listener nil))))

(defun herdr-claude-code-ide-mcp-server--tool-name (name)
  "Return NAME with the Herdr MCP prefix."
  (if (string-prefix-p "herdr-" name) name (concat "herdr-" name)))

(defun herdr-claude-code-ide-mcp-server-register-tool (context name schema callback)
  "Register NAME with SCHEMA and CALLBACK for CONTEXT."
  (when-let ((session (herdr-claude-code-ide-mcp-server--session
                       (herdr-claude-code-ide-mcp-server--route context))))
    (push (list :name (herdr-claude-code-ide-mcp-server--tool-name name)
                :schema schema :callback callback)
          (plist-get (cdr session) :tools))))

(defun herdr-claude-code-ide-mcp-server--body (object)
  "Encode OBJECT as a JSON response body."
  (json-encode object))

(defun herdr-claude-code-ide-mcp-server--response (status body &optional route)
  "Return an HTTP response with STATUS, BODY, and optional ROUTE."
  `((status . ,status)
    (headers . ,(append '((Content-Type . "application/json"))
                        (and route `((Mcp-Session-Id . ,route)))))
    (body . ,(and body (herdr-claude-code-ide-mcp-server--body body)))))

(defun herdr-claude-code-ide-mcp-server--error (status id code message)
  "Return a JSON-RPC error response from STATUS, ID, CODE, and MESSAGE."
  (herdr-claude-code-ide-mcp-server--response
   status `((jsonrpc . "2.0") (id . ,id) (error . ((code . ,code) (message . ,message))))))

(defun herdr-claude-code-ide-mcp-server--valid-arguments-p (schema arguments)
  "Return non-nil when ARGUMENTS satisfy SCHEMA's required fields."
  (and (listp arguments)
       (cl-every (lambda (name) (herdr-claude-code-ide-mcp-server--entry name arguments))
                 (herdr-claude-code-ide-mcp-server--value 'required schema))))

(defun herdr-claude-code-ide-mcp-server--valid-initialize-params-p (params)
  "Return non-nil when PARAMS form valid initialize parameters."
  (and (listp params)
       (equal (herdr-claude-code-ide-mcp-server--value 'protocolVersion params) "2025-11-25")
       (let ((capabilities (herdr-claude-code-ide-mcp-server--entry 'capabilities params))
             (client-info (herdr-claude-code-ide-mcp-server--value 'clientInfo params)))
         (and capabilities
              (listp (cdr capabilities))
              (listp client-info)
              (stringp (herdr-claude-code-ide-mcp-server--value 'name client-info))
              (stringp (herdr-claude-code-ide-mcp-server--value 'version client-info))))))

(defun herdr-claude-code-ide-mcp-server--tool-result (session name arguments id)
  "Return SESSION tool NAME's result for ARGUMENTS and ID."
  (let ((tool (cl-find name (plist-get (cdr session) :tools)
                       :key (lambda (entry) (plist-get entry :name)) :test #'equal)))
    (cond
     ((null tool) (herdr-claude-code-ide-mcp-server--error 200 id -32602 "Unknown tool"))
     ((not (herdr-claude-code-ide-mcp-server--valid-arguments-p
            (plist-get tool :schema) arguments))
      (herdr-claude-code-ide-mcp-server--error 200 id -32602 "Invalid params"))
     (t
      (condition-case _err
          (let* ((context (plist-get (cdr session) :context))
                 (buffer (plist-get context :active-buffer))
                 (root (plist-get context :project-root))
                 (result (with-current-buffer buffer
                           (let ((default-directory root))
                             (funcall (plist-get tool :callback) context arguments)))))
            (herdr-claude-code-ide-mcp-server--response
             200 `((jsonrpc . "2.0") (id . ,id) (result . ,result))))
        (error (herdr-claude-code-ide-mcp-server--error 200 id -32603 "Internal error")))))))

(defun herdr-claude-code-ide-mcp-server-handle-request (request)
  "Return the response for MCP HTTP REQUEST."
  (let* ((path (herdr-claude-code-ide-mcp-server--value 'path request))
         (route (and (string-match "\\`/mcp/\\(.+\\)\\'" path) (match-string 1 path)))
         (session (and route (herdr-claude-code-ide-mcp-server--session route)))
         (body (herdr-claude-code-ide-mcp-server--value 'body request))
         message)
    (if (or (not session) (not (equal (herdr-claude-code-ide-mcp-server--value 'method request) "POST")))
        (herdr-claude-code-ide-mcp-server--error 400 nil -32600 "Invalid Request")
      (condition-case _err
          (setq message (json-parse-string body :object-type 'alist :array-type 'list
                                            :null-object nil :false-object :json-false))
        (error
         (setq message :parse-error)))
      (cond
       ((eq message :parse-error)
        (herdr-claude-code-ide-mcp-server--error 400 nil -32700 "Parse error"))
       ((or (not (listp message))
            (not (equal (herdr-claude-code-ide-mcp-server--value 'jsonrpc message) "2.0"))
            (not (herdr-claude-code-ide-mcp-server--entry 'method message)))
        (herdr-claude-code-ide-mcp-server--error 400 nil -32600 "Invalid Request"))
       (t
        (let ((id (herdr-claude-code-ide-mcp-server--value 'id message))
              (method (herdr-claude-code-ide-mcp-server--value 'method message))
              (params (herdr-claude-code-ide-mcp-server--value 'params message)))
          (cond
           ((equal method "initialize")
            (if (not (herdr-claude-code-ide-mcp-server--valid-initialize-params-p params))
                (herdr-claude-code-ide-mcp-server--error 200 id -32602 "Invalid params")
              (herdr-claude-code-ide-mcp-server--response
               200
               `((jsonrpc . "2.0") (id . ,id)
                 (result . ((protocolVersion . "2025-11-25")
                            (capabilities . ((tools . ((listChanged . t)))
                                             (resources . ((subscribe . :json-false) (listChanged . :json-false)))
                                             (prompts . ((listChanged . t)))))
                            (serverInfo . ((name . "herdr-claude-code-ide") (version . "fixture"))))))
               route)))
           ((equal method "notifications/initialized")
            `((status . 202) (headers . ((Content-Type . "application/json")))))
           ((equal method "tools/list")
            (herdr-claude-code-ide-mcp-server--response
             200 `((jsonrpc . "2.0") (id . ,id)
                    (result . ((tools . ,(mapcar (lambda (tool)
                                                    `((name . ,(plist-get tool :name))
                                                      (description . "Herdr Emacs tool")
                                                      (inputSchema . ,(plist-get tool :schema))))
                                                  (plist-get (cdr session) :tools))))))))
           ((equal method "tools/call")
            (let ((name (herdr-claude-code-ide-mcp-server--value 'name params)))
              (if (not (stringp name))
                  (herdr-claude-code-ide-mcp-server--error 200 id -32602 "Invalid params")
                (herdr-claude-code-ide-mcp-server--tool-result
                 session name (herdr-claude-code-ide-mcp-server--value 'arguments params) id))))
           (t (herdr-claude-code-ide-mcp-server--error 200 id -32601 "Method not found")))))))))

(provide 'herdr-claude-code-ide-mcp-server)
;;; herdr-claude-code-ide-mcp-server.el ends here
