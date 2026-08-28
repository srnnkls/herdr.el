;;; herdr-claude-code-ide-tools-tests.el --- Claude IDE file tool tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'herdr-agent)
(require 'herdr-claude-code-ide-mcp)
(require 'herdr-claude-code-ide-diagnostics)
(require 'herdr-claude-code-ide-tools)

(defconst herdr-claude-code-ide-tools-tests--root
  (file-name-directory (or load-file-name buffer-file-name)))

(defun herdr-claude-code-ide-tools-tests--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-code-ide-tools-tests--fixture ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "testdata/claude-code-ide/herdr-decided.json"
                       herdr-claude-code-ide-tools-tests--root))
    (json-parse-buffer :object-type 'alist :array-type 'list
                       :null-object nil :false-object :json-false)))

(defun herdr-claude-code-ide-tools-tests--schema (name)
  (let ((exchange
         (seq-find
          (lambda (entry)
            (equal (herdr-claude-code-ide-tools-tests--value 'id entry)
                   (concat "tool-schema/" name)))
          (herdr-claude-code-ide-tools-tests--value
           'exchanges (herdr-claude-code-ide-tools-tests--fixture)))))
    (herdr-claude-code-ide-tools-tests--value 'schema exchange)))

(defun herdr-claude-code-ide-tools-tests--session (root terminal-id)
  (let ((session (herdr-agent--make-session))
        (server-key (expand-file-name "herdr.sock" root)))
    (setf (herdr-agent-session-key session) (cons server-key terminal-id)
          (herdr-agent-session-kind session) "claude"
          (herdr-agent-session-project session) root)
    session))

(defun herdr-claude-code-ide-tools-tests--adapter (root terminal-id)
  (let* ((session (herdr-claude-code-ide-tools-tests--session root terminal-id))
         (client (make-herdr-claude-code-ide-mcp-client
                  :raw (intern (concat terminal-id "-client"))
                  :open-p t :initialized-p t :generation 1)))
    (make-herdr-claude-code-ide-mcp-adapter
     :session-key (herdr-agent-session-key session)
     :session session
     :state 'connected
     :clients (list client)
     :current-client client
     :client-generation 1)))

(defun herdr-claude-code-ide-tools-tests--client (adapter)
  (herdr-claude-code-ide-mcp-adapter-current-client adapter))

(defmacro herdr-claude-code-ide-tools-tests--with-adapters (adapters &rest body)
  `(let ((herdr-claude-code-ide-mcp--adapters (make-hash-table :test #'equal)))
     (dolist (adapter ,adapters)
       (puthash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
                adapter herdr-claude-code-ide-mcp--adapters))
     ,@body))

(defun herdr-claude-code-ide-tools-tests--install (adapter)
  (unless (fboundp 'herdr-claude-code-ide-tools-install)
    (ert-fail "T005 IDE tool installer is unavailable"))
  (herdr-claude-code-ide-tools-install adapter)
  (unless (functionp (herdr-claude-code-ide-mcp-adapter-tool-list adapter))
    (ert-fail "T005 IDE tool registry is unavailable"))
  (unless (functionp (herdr-claude-code-ide-mcp-adapter-tool-call adapter))
    (ert-fail "T005 IDE tool dispatcher is unavailable"))
  adapter)

(defun herdr-claude-code-ide-tools-tests--tool-list (adapter)
  (funcall (herdr-claude-code-ide-mcp-adapter-tool-list adapter)))

(defun herdr-claude-code-ide-tools-tests--tool-call (adapter name arguments)
  (funcall (herdr-claude-code-ide-mcp-adapter-tool-call adapter)
           adapter name arguments))

(defun herdr-claude-code-ide-tools-tests--request (adapter client id name arguments)
  (herdr-claude-code-ide-mcp-receive
   adapter client
   (json-serialize
    `((jsonrpc . "2.0") (id . ,id) (method . "tools/call")
      (params . ((name . ,name) (arguments . ,arguments)))))))

(defun herdr-claude-code-ide-tools-tests--error-code (response)
  (herdr-claude-code-ide-tools-tests--value
   'code (herdr-claude-code-ide-tools-tests--value 'error response)))

(defun herdr-claude-code-ide-tools-tests--view-member-p (adapter file)
  (unless (fboundp 'herdr-claude-code-ide-tools-view-member-p)
    (ert-fail "T005 file-view membership query is unavailable"))
  (herdr-claude-code-ide-tools-view-member-p adapter file))

(defun herdr-claude-code-ide-tools-tests--accept (adapter client tab-name)
  (unless (fboundp 'herdr-claude-code-ide-tools-accept-diff)
    (ert-fail "T005 deferred diff acceptance is unavailable"))
  (herdr-claude-code-ide-tools-accept-diff adapter client tab-name))

(defun herdr-claude-code-ide-tools-tests--reject (adapter client tab-name)
  (unless (fboundp 'herdr-claude-code-ide-tools-reject-diff)
    (ert-fail "T005 deferred diff rejection is unavailable"))
  (herdr-claude-code-ide-tools-reject-diff adapter client tab-name))

(defun herdr-claude-code-ide-tools-tests--sent-responses (deliveries id)
  (seq-filter
   (lambda (response)
     (equal (herdr-claude-code-ide-tools-tests--value 'id response) id))
   (mapcar (lambda (delivery)
             (json-parse-string (cdr delivery) :object-type 'alist :array-type 'array
                                :null-object nil :false-object :json-false))
           (reverse deliveries))))

(defun herdr-claude-code-ide-tools-tests--sent-response (deliveries id)
  (car (herdr-claude-code-ide-tools-tests--sent-responses deliveries id)))

(ert-deftest herdr-claude-code-ide-tools-registers-only-fixture-tools-and-requires-elisp-opt-in ()
  (let* ((root (make-temp-file "herdr-t005-tools" t))
         (adapter (herdr-claude-code-ide-tools-tests--adapter root "registry"))
         (original (and (boundp 'herdr-claude-code-ide-tools-enable-elisp)
                        herdr-claude-code-ide-tools-enable-elisp))
         (marker-symbol 'herdr-claude-code-ide-tools-tests--execute-code-marker)
         (marker-present (plist-member (symbol-plist marker-symbol) 'value))
         (marker-value (get marker-symbol 'value)))
    (unwind-protect
        (progn
          (unless (boundp 'herdr-claude-code-ide-tools-enable-elisp)
            (ert-fail "T005 Elisp opt-in is unavailable"))
          (should (get 'herdr-claude-code-ide-tools-enable-elisp 'custom-type))
          (set 'herdr-claude-code-ide-tools-enable-elisp nil)
          (let ((original-default-tools
                 (symbol-function 'herdr-claude-code-ide-mcp--default-tools))
                (sentinel
                 '((name . "sentinel")
                   (description . "sentinel")
                   (inputSchema . ((type . "object")))))
                execute-schema)
            (unwind-protect
                (progn
                  (fset 'herdr-claude-code-ide-mcp--default-tools
                        (lambda (&rest arguments)
                          (let ((tools (apply original-default-tools arguments)))
                            (setq execute-schema
                                  (seq-find
                                   (lambda (schema)
                                     (equal (herdr-claude-code-ide-tools-tests--value
                                             'name schema)
                                            "executeCode"))
                                   tools))
                            (append tools (list sentinel)))))
                  (herdr-claude-code-ide-tools-tests--with-adapters (list adapter)
                    (herdr-claude-code-ide-tools-tests--install adapter)
                    (let ((listed (herdr-claude-code-ide-tools-tests--tool-list adapter)))
                      (should
                       (equal listed
                              (append
                               (mapcar #'herdr-claude-code-ide-tools-tests--schema
                                       '("openFile" "getDiagnostics" "close_tab" "openDiff"
                                         "closeAllDiffTabs"))
                               (list sentinel))))
                      (should execute-schema)
                      (should-not (memq execute-schema listed))
                      (should (memq sentinel listed)))
                    (should
                     (= (herdr-claude-code-ide-tools-tests--error-code
                         (herdr-claude-code-ide-tools-tests--request
                          adapter (herdr-claude-code-ide-tools-tests--client adapter) 21
                          "executeCode" '((code . "(error \"must not run\")"))))
                        -32602))))
              (fset 'herdr-claude-code-ide-mcp--default-tools original-default-tools)))
          (set 'herdr-claude-code-ide-tools-enable-elisp t)
          (let ((enabled (herdr-claude-code-ide-tools-tests--adapter root "enabled")))
            (herdr-claude-code-ide-tools-tests--with-adapters (list enabled)
              (herdr-claude-code-ide-tools-tests--install enabled)
              (should
               (equal (herdr-claude-code-ide-tools-tests--tool-list enabled)
                      (mapcar #'herdr-claude-code-ide-tools-tests--schema
                              '("openFile" "getDiagnostics" "close_tab" "openDiff"
                                "closeAllDiffTabs" "executeCode"))))
              (let ((response
                     (herdr-claude-code-ide-tools-tests--request
                      enabled (herdr-claude-code-ide-tools-tests--client enabled) 22
                      "executeCode"
                      '((code . "(put 'herdr-claude-code-ide-tools-tests--execute-code-marker 'value (let ((value \"lexical\")) (lambda () value)))\n(concat (funcall (get 'herdr-claude-code-ide-tools-tests--execute-code-marker 'value)) \" final value\")\n; complete snippet\n")))))
                (should response)
                (should (herdr-claude-code-ide-tools-tests--value 'result response))
                (should-not (herdr-claude-code-ide-tools-tests--value 'error response))
                (should (string-match-p "lexical final value" (json-serialize response))))
              (should
               (= (herdr-claude-code-ide-tools-tests--error-code
                   (herdr-claude-code-ide-tools-tests--request
                    enabled (herdr-claude-code-ide-tools-tests--client enabled) 24
                    "executeCode" '((code . "(progn (message \"truncated\")"))))
                  -32603)))))
      (if marker-present
          (put marker-symbol 'value marker-value)
        (cl-remprop marker-symbol 'value))
      (when (boundp 'herdr-claude-code-ide-tools-enable-elisp)
        (set 'herdr-claude-code-ide-tools-enable-elisp original))
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-get-diagnostics-uses-the-t004-visited-buffer-boundary ()
  (let* ((root (make-temp-file "herdr-t005-diagnostics" t))
         (visited-file (expand-file-name "visited.el" root))
         (unvisited-file (expand-file-name "unvisited.el" root))
         (visited nil)
         (adapter (herdr-claude-code-ide-tools-tests--adapter root "diagnostics"))
         (client (herdr-claude-code-ide-tools-tests--client adapter))
         boundary)
    (unwind-protect
        (progn
          (with-temp-file visited-file (insert "visited\n"))
          (with-temp-file unvisited-file (insert "unvisited\n"))
          (setq visited (find-file-noselect visited-file))
          (herdr-claude-code-ide-tools-tests--with-adapters (list adapter)
            (herdr-claude-code-ide-tools-tests--install adapter)
            (cl-letf (((symbol-function 'herdr-claude-code-ide-diagnostics-collect-diagnostics)
                       (lambda (providers buffers project)
                         (setq boundary (list providers buffers project))
                         `(((filePath . ,visited-file) (message . "normalized"))))))
              (let ((result
                     (herdr-claude-code-ide-tools-tests--request
                      adapter client 23 "getDiagnostics"
                      `((uri . ,(concat "file://" unvisited-file))))))
                (should result)
                (let ((content
                       (herdr-claude-code-ide-tools-tests--value
                        'content
                        (herdr-claude-code-ide-tools-tests--value 'result result))))
                  (should (vectorp content))
                  (should (consp (aref content 0)))
                  (should (equal (herdr-claude-code-ide-tools-tests--value
                                  'message (aref content 0))
                                 "normalized")))
                (should boundary)
                (should (car boundary))
                (should (equal (nth 1 boundary) (list visited)))
                (should (equal (nth 2 boundary) root))
                (should (string-match-p "normalized" (json-serialize result)))
                (should-not (get-file-buffer unvisited-file))))))
      (when (buffer-live-p visited) (kill-buffer visited))
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-rejects-malformed-calls-without-opening-files ()
  (let* ((root (make-temp-file "herdr-t005-malformed" t))
         (old-file (expand-file-name "malformed-old.el" root))
         (new-file (expand-file-name "malformed-new.el" root))
         (outside-root (make-temp-file "herdr-t005-outside"))
         (adapter (herdr-claude-code-ide-tools-tests--adapter root "malformed"))
         (client (herdr-claude-code-ide-tools-tests--client adapter)))
    (unwind-protect
        (herdr-claude-code-ide-tools-tests--with-adapters (list adapter)
          (herdr-claude-code-ide-tools-tests--install adapter)
          (cl-letf (((symbol-function 'find-file-noselect)
                     (lambda (&rest _)
                       (ert-fail "malformed tool call opened a file"))))
            (dolist (request
                     `((31 "openFile" ((filePath . 7)))
                       (32 "openDiff" ((old_file_path . ,old-file)
                                         (new_file_path . ,new-file)
                                         (new_file_contents . "new")))
                       (33 "openFile" ((filePath . ,outside-root)))))
              (let ((response
                     (herdr-claude-code-ide-tools-tests--request
                      adapter client (nth 0 request) (nth 1 request) (nth 2 request))))
                (should (= (herdr-claude-code-ide-tools-tests--error-code response)
                           -32602))))
          (should-not (get-file-buffer old-file))
          (should-not (get-file-buffer new-file))
          (should-not (get-file-buffer outside-root))))
      (when (file-exists-p outside-root)
        (delete-file outside-root))
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-close-tab-releases-only-requesting-global-buffer-view ()
  (let* ((root (make-temp-file "herdr-t005-views" t))
         (file (expand-file-name "shared.el" root))
         (modified-file (expand-file-name "modified.el" root))
         (external-file (expand-file-name "external.el" root))
         (owned-file (expand-file-name "owned.el" root))
         (first (herdr-claude-code-ide-tools-tests--adapter root "first"))
         (second (herdr-claude-code-ide-tools-tests--adapter root "second"))
         shared modified external owned owned-window)
    (unwind-protect
        (progn
          (with-temp-file file (insert "one\ntwo\nthree\n"))
          (with-temp-file modified-file (insert "modified\n"))
          (with-temp-file external-file (insert "external\n"))
          (with-temp-file owned-file (insert "owned\n"))
          (setq shared (find-file-noselect file)
                modified (find-file-noselect modified-file)
                external (find-file-noselect external-file))
          (save-window-excursion
            (herdr-claude-code-ide-tools-tests--with-adapters (list first second)
              (dolist (adapter (list first second))
                (herdr-claude-code-ide-tools-tests--install adapter))
              (let ((ambient (make-temp-file "herdr-t005-ambient" t)))
                (unwind-protect
                    (let ((default-directory ambient))
                      (herdr-claude-code-ide-tools-tests--tool-call
                       first "openFile"
                       `((filePath . ,(file-name-nondirectory file))
                         (startLine . 2) (endLine . 2))))
                  (delete-directory ambient)))
              (let ((first-owned-window (get-buffer-window shared 0)))
                (should first-owned-window)
                (with-current-buffer shared
                  (should (= (line-number-at-pos (region-beginning)) 2))
                  (should (equal (buffer-substring-no-properties
                                  (region-beginning) (region-end))
                                 "two")))
                (herdr-claude-code-ide-tools-tests--tool-call
                 first "openFile"
                 `((filePath . ,file) (startText . "three") (endText . "three")))
                (with-current-buffer shared
                  (should (equal (buffer-substring-no-properties
                                  (region-beginning) (region-end))
                                 "three")))
                (herdr-claude-code-ide-tools-tests--tool-call
                 second "openFile" `((filePath . ,file)))
                (should (herdr-claude-code-ide-tools-tests--view-member-p first file))
                (should (herdr-claude-code-ide-tools-tests--view-member-p second file))
                (herdr-claude-code-ide-tools-tests--tool-call
                 first "close_tab" `((path . ,file) (tab_name . "shared")))
                (should-not (herdr-claude-code-ide-tools-tests--view-member-p first file))
                (should (herdr-claude-code-ide-tools-tests--view-member-p second file))
                (should (buffer-live-p shared))
                (should-not (memq first-owned-window
                                  (get-buffer-window-list shared nil 0)))
                (herdr-claude-code-ide-tools-tests--tool-call
                 second "close_tab" `((path . ,file) (tab_name . "shared")))
                (should-not (herdr-claude-code-ide-tools-tests--view-member-p second file))
                (should (buffer-live-p shared)))
              (herdr-claude-code-ide-tools-tests--tool-call
               second "openFile" `((filePath . ,modified-file)))
              (with-current-buffer modified
                (goto-char (point-max))
                (insert "changed"))
              (herdr-claude-code-ide-tools-tests--tool-call
               second "close_tab" `((path . ,modified-file) (tab_name . "modified")))
              (should-not
               (herdr-claude-code-ide-tools-tests--view-member-p second modified-file))
              (should (buffer-live-p modified))
              (herdr-claude-code-ide-tools-tests--tool-call
               first "openFile" `((filePath . ,owned-file)))
              (setq owned (get-file-buffer owned-file)
                    owned-window (get-buffer-window (get-file-buffer owned-file) 0))
              (should (buffer-live-p owned))
              (should owned-window)
              (should (herdr-claude-code-ide-tools-tests--view-member-p first owned-file))
              (herdr-claude-code-ide-tools-tests--tool-call
               second "openFile" `((filePath . ,owned-file)))
              (should (herdr-claude-code-ide-tools-tests--view-member-p second owned-file))
              (herdr-claude-code-ide-tools-tests--tool-call
               first "close_tab" `((path . ,owned-file) (tab_name . "owned")))
              (should-not (herdr-claude-code-ide-tools-tests--view-member-p first owned-file))
              (should (herdr-claude-code-ide-tools-tests--view-member-p second owned-file))
              (should (buffer-live-p owned))
              (herdr-claude-code-ide-tools-tests--tool-call
               second "close_tab" `((path . ,owned-file) (tab_name . "owned")))
              (should-not (herdr-claude-code-ide-tools-tests--view-member-p second owned-file))
              (should-not (buffer-live-p owned))
              (herdr-claude-code-ide-tools-tests--tool-call
               first "openFile" `((filePath . ,external-file)))
              (let ((owned-window (get-buffer-window external 0)))
                (should owned-window)
                (let ((external-window (progn
                                         (select-window owned-window)
                                         (split-window-right)))
                      (replacement (generate-new-buffer " *herdr-t005-replacement*")))
                  (unwind-protect
                      (progn
                        (set-window-buffer external-window external)
                        (set-window-buffer owned-window replacement)
                        (herdr-claude-code-ide-tools-tests--tool-call
                         first "close_tab" `((path . ,external-file) (tab_name . "external")))
                        (should-not
                         (herdr-claude-code-ide-tools-tests--view-member-p first external-file))
                        (should (buffer-live-p external))
                        (should (window-live-p external-window))
                        (should (eq (window-buffer external-window) external))
                        (should (window-live-p owned-window))
                        (should (eq (window-buffer owned-window) replacement))
                        (should-not (memq owned-window
                                          (get-buffer-window-list external nil 0)))
                        (herdr-claude-code-ide-mcp-cleanup first)
                        (should-not
                         (herdr-claude-code-ide-tools-tests--view-member-p first owned-file))
                        (should-not (buffer-live-p owned))
                        (should-not
                         (and (window-live-p owned-window)
                              (eq (window-buffer owned-window) owned))))
                    (when (buffer-live-p replacement)
                      (kill-buffer replacement))))))))
      (herdr-claude-code-ide-mcp-cleanup first)
      (herdr-claude-code-ide-mcp-cleanup second)
      (dolist (buffer (list shared modified external owned))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-defers-ediff-and-returns-edited-accept-or-distinct-reject ()
  (let* ((root (make-temp-file "herdr-t005-diff" t))
         (old-file (expand-file-name "old.el" root))
         (new-file (expand-file-name "new.el" root))
         (adapter (herdr-claude-code-ide-tools-tests--adapter root "diff"))
         (client (herdr-claude-code-ide-tools-tests--client adapter))
         (original-kill-buffer (symbol-function 'kill-buffer))
         proposed
         deliveries
         complete-during-startup
         release-fault)
    (unwind-protect
        (progn
          (with-temp-file old-file (insert "old\n"))
          (herdr-claude-code-ide-tools-tests--with-adapters (list adapter)
            (herdr-claude-code-ide-tools-tests--install adapter)
            (cl-letf (((symbol-function 'ediff-buffers)
                       (lambda (_old proposed-buffer &rest _)
                         (setq proposed proposed-buffer)
                         (when complete-during-startup
                           (herdr-claude-code-ide-tools-tests--accept
                            adapter client complete-during-startup))))
                      ((symbol-function 'websocket-send-text)
                       (lambda (raw text) (push (cons raw text) deliveries)))
                      ((symbol-function 'kill-buffer)
                       (lambda (&rest arguments)
                         (let ((target (or (car arguments) (current-buffer))))
                           (if (and release-fault (eq target proposed))
                               (progn
                                 (setq release-fault nil)
                                 (error "T005 post-response release fault"))
                             (apply original-kill-buffer arguments))))))
              (setq complete-during-startup "release-fault"
                    release-fault t)
              (should-not
               (herdr-claude-code-ide-tools-tests--request
                adapter client 40 "openDiff"
                `((old_file_path . ,old-file) (new_file_path . ,new-file)
                  (new_file_contents . "release-fault")
                  (tab_name . "release-fault"))))
              (let ((responses
                     (herdr-claude-code-ide-tools-tests--sent-responses deliveries 40)))
                (should (= (length responses) 1))
                (should (herdr-claude-code-ide-tools-tests--value
                         'result (car responses)))
                (should-not (herdr-claude-code-ide-tools-tests--value
                             'error (car responses))))
              (should-not release-fault)
              (should (buffer-live-p proposed))
              (should (herdr-claude-code-ide-mcp-adapter-diffs adapter))
              (herdr-claude-code-ide-tools-tests--accept adapter client "release-fault")
              (should (= (length
                          (herdr-claude-code-ide-tools-tests--sent-responses deliveries 40))
                         1))
              (should-not (buffer-live-p proposed))
              (should-not (herdr-claude-code-ide-mcp-adapter-pending adapter))
              (should-not (herdr-claude-code-ide-mcp-adapter-diffs adapter))
              (setq proposed nil
                    complete-during-startup nil)
              (should-not
               (herdr-claude-code-ide-tools-tests--request
                adapter client 41 "openDiff"
                `((old_file_path . ,old-file) (new_file_path . ,new-file)
                  (new_file_contents . "proposed") (tab_name . "accept"))))
              (should (buffer-live-p proposed))
              (with-current-buffer proposed
                (erase-buffer)
                (insert "edited proposed"))
              (herdr-claude-code-ide-tools-tests--accept adapter client "accept")
              (let ((accepted (herdr-claude-code-ide-tools-tests--sent-response deliveries 41)))
                (should (= (length
                            (herdr-claude-code-ide-tools-tests--sent-responses deliveries 41))
                           1))
                (should accepted)
                (should (herdr-claude-code-ide-tools-tests--value 'result accepted))
                (should-not (herdr-claude-code-ide-tools-tests--value 'error accepted))
                (should (string-match-p "edited proposed" (json-serialize accepted)))
                (should-not (buffer-live-p proposed))
                (setq proposed nil)
                (should-not
                 (herdr-claude-code-ide-tools-tests--request
                  adapter client 42 "openDiff"
                  `((old_file_path . ,old-file) (new_file_path . ,new-file)
                    (new_file_contents . "rejected proposed") (tab_name . "reject"))))
                (should (buffer-live-p proposed))
                (herdr-claude-code-ide-tools-tests--reject adapter client "reject")
                (let ((rejected (herdr-claude-code-ide-tools-tests--sent-response deliveries 42)))
                  (should (= (length
                              (herdr-claude-code-ide-tools-tests--sent-responses deliveries 42))
                             1))
                  (should rejected)
                  (should (herdr-claude-code-ide-tools-tests--value 'result rejected))
                  (should-not (herdr-claude-code-ide-tools-tests--value 'error rejected))
                  (should-not (equal (herdr-claude-code-ide-tools-tests--value 'result accepted)
                                     (herdr-claude-code-ide-tools-tests--value 'result rejected)))
                  (should-not (string-match-p "rejected proposed" (json-serialize rejected)))
                  (should-not (buffer-live-p proposed))
                  (setq proposed nil)
                  (should-not
                   (herdr-claude-code-ide-tools-tests--request
                    adapter client 43 "openDiff"
                    `((old_file_path . ,old-file) (new_file_path . ,new-file)
                      (new_file_contents . "closed proposed") (tab_name . "closed"))))
                  (should (buffer-live-p proposed))
                  (herdr-claude-code-ide-tools-tests--request
                   adapter client 45 "close_tab" '((tab_name . "closed")))
                  (let ((responses
                         (herdr-claude-code-ide-tools-tests--sent-responses
                          deliveries 43)))
                    (should (= (length responses) 1))
                    (should (= (herdr-claude-code-ide-tools-tests--error-code
                                (car responses))
                               -32800))
                    (should-not
                     (herdr-claude-code-ide-tools-tests--value
                      'result (car responses))))
                  (should-not (buffer-live-p proposed))
                  (should-not (herdr-claude-code-ide-mcp-adapter-pending adapter))
                  (should-not (herdr-claude-code-ide-mcp-adapter-diffs adapter))
                  (herdr-claude-code-ide-tools-tests--accept adapter client "closed")
                  (should (= (length
                              (herdr-claude-code-ide-tools-tests--sent-responses
                               deliveries 43))
                             1))
                  (setq proposed nil
                        complete-during-startup "startup")
                  (should-not
                   (herdr-claude-code-ide-tools-tests--request
                    adapter client 44 "openDiff"
                    `((old_file_path . ,old-file) (new_file_path . ,new-file)
                      (new_file_contents . "startup completion")
                      (tab_name . "startup"))))
                  (let ((responses
                         (herdr-claude-code-ide-tools-tests--sent-responses
                          deliveries 44)))
                    (should (= (length responses) 1))
                    (should (herdr-claude-code-ide-tools-tests--value
                             'result (car responses)))
                    (should-not (herdr-claude-code-ide-tools-tests--value
                                 'error (car responses))))
                  (should-not (buffer-live-p proposed))
                  (should-not (herdr-claude-code-ide-mcp-adapter-pending adapter))
                  (should-not (herdr-claude-code-ide-mcp-adapter-diffs adapter))
                  (herdr-claude-code-ide-tools-tests--accept adapter client "startup")
                  (should (= (length
                              (herdr-claude-code-ide-tools-tests--sent-responses
                               deliveries 44))
                             1)))))))
      (herdr-claude-code-ide-mcp-cleanup adapter)
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-close-all-diffs-is-session-local ()
  (let* ((root (make-temp-file "herdr-t005-close-diffs" t))
         (old-file (expand-file-name "old.el" root))
         (new-file (expand-file-name "new.el" root))
         (first (herdr-claude-code-ide-tools-tests--adapter root "first"))
         (second (herdr-claude-code-ide-tools-tests--adapter root "second"))
         (first-client (herdr-claude-code-ide-tools-tests--client first))
         (second-client (herdr-claude-code-ide-tools-tests--client second))
         proposed
         deliveries)
    (unwind-protect
        (progn
          (with-temp-file old-file (insert "old\n"))
          (herdr-claude-code-ide-tools-tests--with-adapters (list first second)
            (dolist (adapter (list first second))
              (herdr-claude-code-ide-tools-tests--install adapter))
            (let ((untracked-close
                   (herdr-claude-code-ide-tools-tests--request
                    first first-client 50 "close_tab" `((path . ,old-file)))))
              (should untracked-close)
              (should-not (herdr-claude-code-ide-tools-tests--value
                           'error untracked-close)))
            (cl-letf (((symbol-function 'ediff-buffers)
                       (lambda (_old proposed-buffer &rest _)
                         (push proposed-buffer proposed)))
                      ((symbol-function 'websocket-send-text)
                       (lambda (raw text) (push (cons raw text) deliveries))))
              (dolist (request `((,first ,first-client 51 "first")
                                 (,second ,second-client 52 "second")))
                (should-not
                 (herdr-claude-code-ide-tools-tests--request
                  (nth 0 request) (nth 1 request) (nth 2 request) "openDiff"
                  `((old_file_path . ,old-file) (new_file_path . ,new-file)
                    (new_file_contents . ,(nth 3 request))
                    (tab_name . "same-tab")))))
              (should (= (length proposed) 2))
              (let ((second-proposed (car proposed))
                    (first-proposed (cadr proposed)))
                (should (buffer-live-p first-proposed))
                (should (buffer-live-p second-proposed))
                (let ((close-response
                       (herdr-claude-code-ide-tools-tests--request
                        first first-client 53 "close_tab"
                        `((path . ,old-file) (tab_name . "same-tab")))))
                  (should close-response)
                  (should-not (herdr-claude-code-ide-tools-tests--value
                               'error close-response)))
                (should-not (buffer-live-p first-proposed))
                (should-not (herdr-claude-code-ide-mcp-adapter-pending first))
                (should-not (herdr-claude-code-ide-mcp-adapter-diffs first))
                (herdr-claude-code-ide-tools-tests--request
                 first first-client 54 "closeAllDiffTabs" '())
                (should-not (buffer-live-p first-proposed))
                (should (buffer-live-p second-proposed))
                (let ((responses
                       (herdr-claude-code-ide-tools-tests--sent-responses
                        deliveries 51)))
                  (should (= (length responses) 1))
                  (should (= (herdr-claude-code-ide-tools-tests--error-code
                              (car responses))
                             -32800))
                  (should-not
                   (herdr-claude-code-ide-tools-tests--value
                    'result (car responses))))
                (herdr-claude-code-ide-tools-tests--accept second second-client "same-tab")
                (should (= (length
                            (herdr-claude-code-ide-tools-tests--sent-responses
                             deliveries 52))
                           1))
                (should-not (buffer-live-p second-proposed))
                (herdr-claude-code-ide-tools-tests--accept first first-client "same-tab")
                (should (= (length
                            (herdr-claude-code-ide-tools-tests--sent-responses
                             deliveries 51))
                           1))))))
      (herdr-claude-code-ide-mcp-cleanup first)
      (herdr-claude-code-ide-mcp-cleanup second)
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-reconnect-cancels-the-old-generation-diff ()
  (let* ((root (make-temp-file "herdr-t005-reconnect" t))
         (old-file (expand-file-name "old.el" root))
         (new-file (expand-file-name "new.el" root))
         (adapter (herdr-claude-code-ide-tools-tests--adapter root "reconnect"))
         (first (herdr-claude-code-ide-tools-tests--client adapter))
         (original-kill-buffer (symbol-function 'kill-buffer))
         proposed
         deliveries)
    (unwind-protect
        (progn
          (with-temp-file old-file (insert "old\n"))
          (herdr-claude-code-ide-tools-tests--with-adapters (list adapter)
            (herdr-claude-code-ide-tools-tests--install adapter)
            (cl-letf (((symbol-function 'ediff-buffers)
                       (lambda (_old proposed-buffer &rest _)
                         (setq proposed proposed-buffer)))
                      ((symbol-function 'websocket-send-text)
                       (lambda (raw text) (push (cons raw text) deliveries))))
              (should-not
               (herdr-claude-code-ide-tools-tests--request
                adapter first 61 "openDiff"
                `((old_file_path . ,old-file) (new_file_path . ,new-file)
                  (new_file_contents . "old generation") (tab_name . "stale"))))
              (should (buffer-live-p proposed))
              (let ((replacement (herdr-claude-code-ide-mcp-client-connect adapter)))
                (let ((cancellation-fault t))
                  (cl-letf
                      (((symbol-function 'kill-buffer)
                        (lambda (&rest arguments)
                          (let ((target (or (car arguments) (current-buffer))))
                            (if (and cancellation-fault (eq target proposed))
                                (error "T005 cancellation fault")
                              (apply original-kill-buffer arguments))))))
                    (herdr-claude-code-ide-mcp-client-close adapter first)
                    (should cancellation-fault)
                    (should (buffer-live-p proposed))
                    (let ((refused
                           (herdr-claude-code-ide-mcp-receive
                            adapter replacement
                            (json-serialize
                             '((jsonrpc . "2.0") (id . 62) (method . "initialize")
                               (params . ((protocolVersion . "2025-11-25")
                                          (capabilities . ())
                                          (clientInfo . ((name . "T005") (version . "1"))))))))))
                      (should refused)
                      (should (= (herdr-claude-code-ide-tools-tests--error-code refused)
                                 -32603)))
                    (should cancellation-fault)
                    (should-not (herdr-claude-code-ide-mcp-client-initialized-p replacement))
                    (should-not (eq (herdr-claude-code-ide-mcp-adapter-current-client adapter)
                                    replacement))
                    (should (= (herdr-claude-code-ide-mcp-adapter-client-generation adapter)
                               1))
                    (should (buffer-live-p proposed))
                    (should (herdr-claude-code-ide-mcp-adapter-pending adapter))
                    (should (herdr-claude-code-ide-mcp-adapter-diffs adapter))
                    (setq cancellation-fault nil)))
                (should
                 (herdr-claude-code-ide-mcp-receive
                  adapter replacement
                  (json-serialize
                   '((jsonrpc . "2.0") (id . 62) (method . "initialize")
                     (params . ((protocolVersion . "2025-11-25")
                                (capabilities . ())
                                (clientInfo . ((name . "T005") (version . "1")))))))))
                (should-not (buffer-live-p proposed))
                (should (eq (herdr-claude-code-ide-mcp-adapter-current-client adapter)
                            replacement))
                (should (= (herdr-claude-code-ide-mcp-adapter-client-generation adapter)
                           2))
                (should-not (herdr-claude-code-ide-mcp-adapter-pending adapter))
                (should-not (herdr-claude-code-ide-mcp-adapter-diffs adapter))
                (herdr-claude-code-ide-tools-tests--accept adapter first "stale")
                (let ((responses
                       (herdr-claude-code-ide-tools-tests--sent-responses deliveries 61)))
                  (should (= (length responses) 1))
                  (should (= (herdr-claude-code-ide-tools-tests--error-code
                              (car responses))
                             -32800))
                  (should-not
                   (herdr-claude-code-ide-tools-tests--value 'result (car responses))))))))
      (herdr-claude-code-ide-mcp-cleanup adapter)
      (delete-directory root t))))

(ert-deftest herdr-claude-code-ide-tools-cleanup-releases-deferred-diff-buffers-and-hooks ()
  (let* ((root (make-temp-file "herdr-t005-cleanup" t))
         (old-file (expand-file-name "old.el" root))
         (new-file (expand-file-name "new.el" root))
         (ordinary-file (expand-file-name "ordinary.el" root))
         (adapter (herdr-claude-code-ide-tools-tests--adapter root "cleanup"))
         (client (herdr-claude-code-ide-tools-tests--client adapter))
         (original-kill-buffer (symbol-function 'kill-buffer))
         (original-add-hook (symbol-function 'add-hook))
         (original-remove-hook (symbol-function 'remove-hook))
         proposed old ordinary additions removals deliveries)
    (unwind-protect
        (progn
          (with-temp-file old-file (insert "old\n"))
          (with-temp-file ordinary-file (insert "ordinary\n"))
          (setq ordinary (find-file-noselect ordinary-file))
          (herdr-claude-code-ide-tools-tests--with-adapters (list adapter)
            (herdr-claude-code-ide-tools-tests--install adapter)
            (let* ((cleanup-fault nil)
                   (completion nil)
                   (completion-entries
                    (lambda (entries)
                      (seq-filter
                       (lambda (entry)
                         (eq (nth 1 entry) completion))
                       entries)))
                   (same-hook-multiset-p
                    (lambda (left right)
                      (and
                       (= (length left) (length right))
                       (cl-every
                        (lambda (entry)
                          (= (cl-count-if
                              (lambda (candidate)
                                (and (eq (nth 0 entry) (nth 0 candidate))
                                     (eq (nth 1 entry) (nth 1 candidate))
                                     (eq (nth 2 entry) (nth 2 candidate))))
                              left)
                             (cl-count-if
                              (lambda (candidate)
                                (and (eq (nth 0 entry) (nth 0 candidate))
                                     (eq (nth 1 entry) (nth 1 candidate))
                                     (eq (nth 2 entry) (nth 2 candidate))))
                              right)))
                        left)))))
              (cl-letf (((symbol-function 'ediff-buffers)
                         (lambda (old-buffer proposed-buffer &rest _)
                           (setq old old-buffer
                                 proposed proposed-buffer)))
                        ((symbol-function 'add-hook)
                         (lambda (hook function &optional append local)
                           (push (list hook function local) additions)
                           (funcall original-add-hook hook function append local)))
                        ((symbol-function 'remove-hook)
                         (lambda (hook function &optional local)
                           (push (list hook function local) removals)
                           (funcall original-remove-hook hook function local)))
                        ((symbol-function 'websocket-send-text)
                         (lambda (raw text) (push (cons raw text) deliveries)))
                        ((symbol-function 'kill-buffer)
                         (lambda (&rest arguments)
                           (let ((target (or (car arguments) (current-buffer))))
                             (if (and cleanup-fault (eq target proposed))
                                 (progn
                                   (setq cleanup-fault nil)
                                   (error "T005 cleanup fault"))
                               (apply original-kill-buffer arguments))))))
                (should-not
                 (herdr-claude-code-ide-tools-tests--request
                  adapter client 71 "openDiff"
                  `((old_file_path . ,old-file) (new_file_path . ,new-file)
                    (new_file_contents . "callback") (tab_name . "callback"))))
                (should (buffer-live-p proposed))
                (should (buffer-live-p old))
                (setq completion
                      (nth 1
                           (seq-find
                            (lambda (entry)
                              (and (eq (nth 0 entry) 'kill-buffer-hook)
                                   (nth 2 entry)))
                            additions)))
                (should (functionp completion))
                (with-current-buffer proposed
                  (funcall completion))
                (let ((response
                       (herdr-claude-code-ide-tools-tests--sent-response deliveries 71)))
                  (should response)
                  (should (herdr-claude-code-ide-tools-tests--value 'result response))
                  (should-not (herdr-claude-code-ide-tools-tests--value 'error response)))
                (should
                 (funcall same-hook-multiset-p
                          (funcall completion-entries additions)
                          (funcall completion-entries removals)))
                (should-not (buffer-live-p old))
                (when (buffer-live-p proposed)
                  (funcall original-kill-buffer proposed))
                (setq old (find-file-noselect old-file))
                (should (buffer-live-p old))
                (setq proposed nil
                      additions nil
                      removals nil
                      cleanup-fault t)
                (should-not
                 (herdr-claude-code-ide-tools-tests--request
                  adapter client 72 "openDiff"
                  `((old_file_path . ,old-file) (new_file_path . ,new-file)
                    (new_file_contents . "cleanup") (tab_name . "cleanup"))))
                (should (buffer-live-p proposed))
                (should (buffer-live-p old))
                (setq completion
                      (nth 1
                           (seq-find
                            (lambda (entry)
                              (and (eq (nth 0 entry) 'kill-buffer-hook)
                                   (nth 2 entry)))
                            additions)))
                (herdr-claude-code-ide-mcp-cleanup adapter)
                (should-not cleanup-fault)
                (should (buffer-live-p proposed))
                (should (eq (herdr-claude-code-ide-mcp-adapter-state adapter)
                            'detaching))
                (should (eq (gethash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
                                     herdr-claude-code-ide-mcp--adapters)
                            adapter))
                (herdr-claude-code-ide-mcp-cleanup adapter)
                (should-not (buffer-live-p proposed))
                (should (buffer-live-p old))
                (should (eq (herdr-claude-code-ide-mcp-adapter-state adapter)
                            'stopped))
                (should-not
                 (gethash (herdr-claude-code-ide-mcp-adapter-session-key adapter)
                          herdr-claude-code-ide-mcp--adapters))
                (should
                 (funcall same-hook-multiset-p
                          (funcall completion-entries additions)
                          (funcall completion-entries removals)))))))
      (herdr-claude-code-ide-mcp-cleanup adapter)
      (dolist (buffer (list proposed old ordinary))
        (when (buffer-live-p buffer)
          (funcall original-kill-buffer buffer)))
      (delete-directory root t))))

(provide 'herdr-claude-code-ide-tools-tests)
;;; herdr-claude-code-ide-tools-tests.el ends here
