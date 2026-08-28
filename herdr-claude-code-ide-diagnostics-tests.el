;;; herdr-claude-code-ide-diagnostics-tests.el --- Context and diagnostics tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'flymake)
(require 'herdr-agent)
(require 'herdr-claude-code-ide-mcp nil t)
(require 'herdr-claude-code-ide-diagnostics nil t)

(defconst herdr-claude-code-ide-diagnostics-tests--root
  (file-name-directory (or load-file-name buffer-file-name)))

(defun herdr-claude-code-ide-diagnostics-tests--call (function &rest arguments)
  (unless (fboundp function)
    (ert-fail (format "T004 context entry point is unavailable: %s" function)))
  (apply function arguments))

(defun herdr-claude-code-ide-diagnostics-tests--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-code-ide-diagnostics-tests--session-key (server-key terminal-id)
  (cons server-key terminal-id))

(defun herdr-claude-code-ide-diagnostics-tests--session
    (server-key terminal-id project &optional kind)
  (let ((session (herdr-agent--make-session)))
    (setf (herdr-agent-session-key session)
          (herdr-claude-code-ide-diagnostics-tests--session-key server-key terminal-id)
          (herdr-agent-session-kind session) (or kind "claude")
          (herdr-agent-session-project session) project)
    session))

(defun herdr-claude-code-ide-diagnostics-tests--adapter
    (session raw &optional initialized)
  (let ((client (make-herdr-claude-code-ide-mcp-client
                 :raw raw :open-p t :initialized-p (not (eq initialized :no)))))
    (make-herdr-claude-code-ide-mcp-adapter
     :session-key (herdr-agent-session-key session)
     :session session
     :state 'connected
     :clients (list client)
     :current-client client)))

(defmacro herdr-claude-code-ide-diagnostics-tests--with-adapter-registry
    (adapters &rest body)
  `(let ((herdr-claude-code-ide-mcp--adapters (make-hash-table :test #'equal)))
     ,@(mapcar
        (lambda (adapter)
          `(puthash (herdr-claude-code-ide-mcp-adapter-session-key ,adapter)
                    ,adapter herdr-claude-code-ide-mcp--adapters))
        adapters)
     ,@body))

(defun herdr-claude-code-ide-diagnostics-tests--notifications (deliveries)
  (mapcar (lambda (delivery)
            (cons (car delivery)
                  (json-parse-string (cdr delivery) :object-type 'alist :array-type 'list
                                     :null-object nil :false-object :json-false)))
          (reverse deliveries)))

(defun herdr-claude-code-ide-diagnostics-tests--notification-p
    (notification method payload)
  (and (not (assq 'id (cdr notification)))
       (not (assoc "id" (cdr notification)))
       (equal (herdr-claude-code-ide-diagnostics-tests--value
               'jsonrpc (cdr notification))
              "2.0")
       (equal (herdr-claude-code-ide-diagnostics-tests--value
               'method (cdr notification))
              method)
       (equal (herdr-claude-code-ide-diagnostics-tests--value
               'params (cdr notification))
              payload)))

(defun herdr-claude-code-ide-diagnostics-tests--diagnostic (message diagnostics)
  (cl-find message diagnostics
           :key (lambda (entry)
                  (herdr-claude-code-ide-diagnostics-tests--value 'message entry))
           :test #'equal))

(ert-deftest herdr-claude-code-ide-context-broadcast-uses-session-projects-from-the-adapter-registry ()
  (let* ((server (make-temp-file "herdr-t004-server" t))
         (project (make-temp-file "herdr-t004-project" t))
         (other-project (make-temp-file "herdr-t004-other-project" t))
         (server-key (expand-file-name "herdr.sock" server))
         (first (herdr-claude-code-ide-diagnostics-tests--adapter
                 (herdr-claude-code-ide-diagnostics-tests--session
                  server-key "first" project)
                 'first-client))
         (second (herdr-claude-code-ide-diagnostics-tests--adapter
                  (herdr-claude-code-ide-diagnostics-tests--session
                   server-key "second" project)
                  'second-client))
         (other (herdr-claude-code-ide-diagnostics-tests--adapter
                 (herdr-claude-code-ide-diagnostics-tests--session
                  server-key "other" other-project)
                 'other-client))
         (stale (herdr-claude-code-ide-diagnostics-tests--adapter
                 (herdr-claude-code-ide-diagnostics-tests--session
                  server-key "stale" project)
                 'stale-client))
         (uninitialized (herdr-claude-code-ide-diagnostics-tests--adapter
                         (herdr-claude-code-ide-diagnostics-tests--session
                          server-key "uninitialized" project)
                         'uninitialized-client :no))
         deliveries)
    (unwind-protect
        (progn
          (setf (herdr-claude-code-ide-mcp-adapter-current-client stale) nil)
          (herdr-claude-code-ide-diagnostics-tests--with-adapter-registry
              (first second other stale uninitialized)
            (cl-letf (((symbol-function 'websocket-send-text)
                       (lambda (raw text) (push (cons raw text) deliveries))))
              (herdr-claude-code-ide-diagnostics-tests--call
               'herdr-claude-code-ide-mcp-broadcast-project-context
               nil (concat project "/./") "selection_changed"
               `((filePath . ,(expand-file-name "file.el" project))
                 (text . "")
                 (selection . ((start . ((line . 0) (character . 0)))
                               (end . ((line . 0) (character . 0))))))))
            (should (equal (sort (mapcar #'car
                                         (herdr-claude-code-ide-diagnostics-tests--notifications
                                          deliveries))
                                 (lambda (left right)
                                   (string< (symbol-name left) (symbol-name right))))
                           '(first-client second-client)))))
      (delete-directory server t)
      (delete-directory project t)
      (delete-directory other-project t))))

(ert-deftest herdr-claude-code-ide-selection-context-walks-debounce-generation-and-cleanup ()
  (let* ((server (make-temp-file "herdr-t004-server" t))
         (project (make-temp-file "herdr-t004-project" t))
         (other-project (make-temp-file "herdr-t004-other-project" t))
         (server-key (expand-file-name "herdr.sock" server))
         (file (expand-file-name "selection.el" project))
         (other-file (expand-file-name "other.el" other-project))
         (dead-file (expand-file-name "dead.el" project))
         (drift-file (expand-file-name "drift.el" project))
         (drifted-file (expand-file-name "drifted.el" other-project))
         (session (herdr-claude-code-ide-diagnostics-tests--session
                   server-key "selection" project))
         (adapter (herdr-claude-code-ide-diagnostics-tests--adapter
                   session 'selection-client))
         (post-cleanup (herdr-claude-code-ide-diagnostics-tests--adapter
                        session 'post-cleanup-client))
         (buffer nil)
         (other-buffer nil)
         (dead-buffer nil)
         (drift-buffer nil)
         (non-file-buffer (generate-new-buffer " *herdr-t004-non-file*"))
         timers
         cancelled
         deliveries
         replacement-raw)
    (unwind-protect
        (progn
          (with-temp-file file (insert "first\nsecond\nthird\n"))
          (with-temp-file other-file (insert "outside\n"))
          (with-temp-file dead-file (insert "dead\n"))
          (with-temp-file drift-file (insert "drift\n"))
          (with-temp-file drifted-file (insert "outside drift\n"))
          (setq buffer (find-file-noselect file)
                other-buffer (find-file-noselect other-file)
                dead-buffer (find-file-noselect dead-file)
                drift-buffer (find-file-noselect drift-file))
          (with-current-buffer buffer
            (goto-char (point-min))
            (forward-line 2)
            (set-mark (point))
            (goto-char (point-min))
            (setq mark-active t))
          (cl-labels ((fire-live-timers ()
                        (dolist (timer (nreverse timers))
                          (unless (or (nth 2 timer) (nth 3 timer))
                            (setf (nth 3 timer) t)
                            (apply (car timer) (cadr timer))))))
            (herdr-claude-code-ide-diagnostics-tests--with-adapter-registry
                (adapter)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (_seconds _repeat callback &rest arguments)
                           (let ((timer (list callback arguments nil nil)))
                             (push timer timers)
                             timer)))
                        ((symbol-function 'cancel-timer)
                         (lambda (timer)
                           (setf (nth 2 timer) t)
                           (push timer cancelled)))
                        ((symbol-function 'websocket-send-text)
                         (lambda (raw text) (push (cons raw text) deliveries))))
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-selection-context-changed
                 nil project other-buffer)
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-selection-context-changed
                 nil project non-file-buffer)
                (should-not timers)
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-selection-context-changed
                 nil project buffer)
                (let ((superseded (car timers)))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project buffer)
                  (should (memq superseded cancelled)))
                (with-current-buffer other-buffer
                  (fire-live-timers))
                (let ((notifications
                       (herdr-claude-code-ide-diagnostics-tests--notifications deliveries)))
                  (should (equal (mapcar #'car notifications) '(selection-client)))
                  (should
                   (herdr-claude-code-ide-diagnostics-tests--notification-p
                    (car notifications) "selection_changed"
                    `((filePath . ,file)
                      (text . "first\nsecond\n")
                      (selection . ((start . ((line . 0) (character . 0)))
                                    (end . ((line . 2) (character . 0)))))))))
                (let ((delivery-count (length deliveries)))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project buffer)
                  (fire-live-timers)
                  (should (= (length deliveries) delivery-count)))
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (set-mark (line-end-position))
                  (setq mark-active t))
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-selection-context-changed
                 nil project buffer)
                (let ((old-generation-pending (car timers))
                      (replacement (herdr-claude-code-ide-mcp-client-connect adapter)))
                  (setq replacement-raw
                        (herdr-claude-code-ide-mcp-client-raw replacement))
                  (herdr-claude-code-ide-mcp-receive
                   adapter replacement
                   (json-serialize
                    '((jsonrpc . "2.0") (id . 1) (method . "initialize")
                      (params . ((protocolVersion . "2025-11-25")
                                 (capabilities . ())
                                 (clientInfo . ((name . "T004") (version . "1"))))))))
                  (should (memq old-generation-pending cancelled))
                  (fire-live-timers)
                  (should (= (length deliveries) 1))
                  (with-current-buffer buffer
                    (goto-char (point-min))
                    (forward-line 2)
                    (set-mark (point))
                    (goto-char (point-min))
                    (setq mark-active t))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project buffer)
                  (fire-live-timers)
                  (should (equal (mapcar #'car
                                         (herdr-claude-code-ide-diagnostics-tests--notifications
                                          deliveries))
                                 (list 'selection-client
                                       (herdr-claude-code-ide-mcp-client-raw replacement)))))
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (set-mark (line-end-position))
                  (setq mark-active t))
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-selection-context-changed
                 nil project buffer)
                (let ((pending (car timers))
                      (delivery-count (length deliveries)))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-cleanup adapter)
                  (should (memq pending cancelled))
                  (fire-live-timers)
                  (should (= (length deliveries) delivery-count))
                  (puthash (herdr-claude-code-ide-mcp-adapter-session-key post-cleanup)
                           post-cleanup herdr-claude-code-ide-mcp--adapters)
                  (with-current-buffer buffer
                    (goto-char (point-min))
                    (forward-line 2)
                    (set-mark (point))
                    (goto-char (point-min))
                    (setq mark-active t))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project buffer)
                  (fire-live-timers)
                  (should (equal (mapcar #'car
                                         (herdr-claude-code-ide-diagnostics-tests--notifications
                                          deliveries))
                                 (list 'selection-client
                                       replacement-raw
                                       'post-cleanup-client)))
                  (with-current-buffer buffer
                    (goto-char (point-min))
                    (set-mark (line-end-position))
                    (setq mark-active t))
                  (setf (herdr-claude-code-ide-mcp-adapter-state post-cleanup) 'starting)
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project buffer)
                  (let ((delivery-count (length deliveries)))
                    (herdr-claude-code-ide-mcp-terminal-attached post-cleanup)
                    (condition-case error-data
                        (fire-live-timers)
                      (error
                       (ert-fail
                        (format "selection callback signaled: %S" error-data))))
                    (should (= (length deliveries) (1+ delivery-count)))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-timers)
                               0))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-contexts)
                               1)))
                  (with-current-buffer dead-buffer
                    (goto-char (point-min))
                    (set-mark (point-max))
                    (setq mark-active t))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project dead-buffer)
                  (let ((delivery-count (length deliveries)))
                    (kill-buffer dead-buffer)
                    (condition-case error-data
                        (fire-live-timers)
                      (error
                       (ert-fail
                        (format "selection callback signaled: %S" error-data))))
                    (should (= (length deliveries) delivery-count))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-timers)
                               0))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-contexts)
                               0)))
                  (with-current-buffer drift-buffer
                    (goto-char (point-min))
                    (set-mark (point-max))
                    (setq mark-active t))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project drift-buffer)
                  (let ((delivery-count (length deliveries)))
                    (with-current-buffer drift-buffer
                      (set-visited-file-name drifted-file t))
                    (condition-case error-data
                        (fire-live-timers)
                      (error
                       (ert-fail
                        (format "selection callback signaled: %S" error-data))))
                    (should (= (length deliveries) delivery-count))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-timers)
                               0))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-contexts)
                               0)))
                  (with-current-buffer buffer
                    (goto-char (point-min))
                    (set-mark (line-end-position))
                    (setq mark-active t))
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-selection-context-changed
                   nil project buffer)
                  (let ((pending (car timers)))
                    (setf (herdr-claude-code-ide-mcp-adapter-state post-cleanup)
                          'waiting-for-client)
                    (herdr-claude-code-ide-diagnostics-tests--call
                     'herdr-claude-code-ide-mcp-cleanup post-cleanup)
                    (should (memq pending cancelled))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-timers)
                               0))
                    (should (= (hash-table-count
                                herdr-claude-code-ide-mcp--selection-contexts)
                               0))))))))
      (dolist (candidate (list buffer other-buffer dead-buffer drift-buffer non-file-buffer))
        (when (buffer-live-p candidate) (kill-buffer candidate)))
      (delete-directory server t)
      (delete-directory project t)
      (delete-directory other-project t))))

(ert-deftest herdr-claude-code-ide-at-mention-uses-ordered-lines-and-the-target-registry-session ()
  (let* ((server (make-temp-file "herdr-t004-server" t))
         (project (make-temp-file "herdr-t004-project" t))
         (other-project (make-temp-file "herdr-t004-other-project" t))
         (server-key (expand-file-name "herdr.sock" server))
         (other-server-key (expand-file-name "other-herdr.sock" server))
         (file (expand-file-name "mention.el" project))
         (target-session (herdr-claude-code-ide-diagnostics-tests--session
                          server-key "target" project))
         (target (herdr-claude-code-ide-diagnostics-tests--adapter
                  target-session 'target-client))
         (same-project (herdr-claude-code-ide-diagnostics-tests--adapter
                        (herdr-claude-code-ide-diagnostics-tests--session
                         server-key "same-project" project)
                        'same-project-client))
         (same-terminal-other-server
          (herdr-claude-code-ide-diagnostics-tests--adapter
           (herdr-claude-code-ide-diagnostics-tests--session
            other-server-key "target" project)
           'same-terminal-other-server-client))
         (other-project-adapter (herdr-claude-code-ide-diagnostics-tests--adapter
                                 (herdr-claude-code-ide-diagnostics-tests--session
                                  server-key "other-project" other-project)
                                 'other-project-client))
         (buffer nil)
         (non-file-buffer (generate-new-buffer " *herdr-t004-mention-non-file*"))
         deliveries)
    (unwind-protect
        (progn
          (with-temp-file file (insert "first\nsecond\nthird\n"))
          (setq buffer (find-file-noselect file))
          (herdr-claude-code-ide-diagnostics-tests--with-adapter-registry
              (target same-project same-terminal-other-server other-project-adapter)
            (cl-letf (((symbol-function 'websocket-send-text)
                       (lambda (raw text) (push (cons raw text) deliveries))))
              (with-current-buffer buffer
                (goto-char (point-min))
                (forward-line 1)
                (set-mark (point))
                (forward-line 1)
                (setq mark-active t)
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-send-at-mentioned
                 nil (herdr-agent-session-key target-session))
                (goto-char (point-min))
                (forward-line 2)
                (set-mark (point))
                (forward-line -1)
                (setq mark-active t)
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-send-at-mentioned
                 nil (herdr-agent-session-key target-session)))
              (with-current-buffer non-file-buffer
                (herdr-claude-code-ide-diagnostics-tests--call
                 'herdr-claude-code-ide-mcp-send-at-mentioned
                 nil (herdr-agent-session-key target-session)))))
          (let ((notifications
                 (herdr-claude-code-ide-diagnostics-tests--notifications deliveries)))
            (should (equal (mapcar #'car notifications) '(target-client target-client)))
            (dolist (notification notifications)
              (should
               (herdr-claude-code-ide-diagnostics-tests--notification-p
                notification "at_mentioned"
                `((filePath . ,file) (lineStart . 2) (lineEnd . 3)))))))
      (dolist (candidate (list buffer non-file-buffer))
        (when (buffer-live-p candidate) (kill-buffer candidate)))
      (delete-directory server t)
      (delete-directory project t)
      (delete-directory other-project t))))

(ert-deftest herdr-claude-code-ide-diagnostics-normalizes-native-records-with-safe-severity ()
  (let* ((project (make-temp-file "herdr-t004-project" t))
         (other-project (make-temp-file "herdr-t004-other-project" t))
         (file (expand-file-name "diagnostics.el" project))
         (outside-file (expand-file-name "outside.el" other-project))
         (unvisited-file (expand-file-name "unvisited.el" project))
         (visited nil)
         (outside nil)
         providers-called)
    (unwind-protect
        (progn
          (with-temp-file file (insert "one\ntwo\nthree\n"))
          (with-temp-file outside-file (insert "outside\n"))
          (with-temp-file unvisited-file (insert "unvisited\n"))
          (setq visited (find-file-noselect file)
                outside (find-file-noselect outside-file))
          (let* ((flycheck-record
                  (when (require 'flycheck nil t)
                    (flycheck-error-new-at 2 3 'warning "flycheck warning")))
                 (providers
                  `((flymake . ,(lambda (buffer)
                                  (push buffer providers-called)
                                  (list (flymake-make-diagnostic
                                         buffer 1 4 :error "native flymake error"))))
                    (boundary . ,(lambda (_buffer)
                                   '((:message "string severity" :line 2 :column 0
                                      :severity "warning")
                                     (:message "missing severity" :line 3 :column 0))))
                    ,@(when flycheck-record
                        `((flycheck . ,(lambda (_buffer) (list flycheck-record)))))))
                 (diagnostics
                  (condition-case error-data
                      (cl-letf (((symbol-function 'find-file)
                                 (lambda (&rest _)
                                   (ert-fail "diagnostics opened an unvisited file")))
                                ((symbol-function 'find-file-noselect)
                                 (lambda (&rest _)
                                   (ert-fail "diagnostics opened an unvisited file"))))
                        (herdr-claude-code-ide-diagnostics-tests--call
                         'herdr-claude-code-ide-mcp-collect-diagnostics
                         providers (list visited outside) project))
                    (error
                     (ert-fail
                      (format "diagnostic normalization crashed: %S" error-data))))))
            (should (equal providers-called (list visited)))
            (should-not (get-file-buffer unvisited-file))
            (let ((native (herdr-claude-code-ide-diagnostics-tests--diagnostic
                           "native flymake error" diagnostics))
                  (string-severity (herdr-claude-code-ide-diagnostics-tests--diagnostic
                                    "string severity" diagnostics))
                  (missing-severity (herdr-claude-code-ide-diagnostics-tests--diagnostic
                                     "missing severity" diagnostics)))
              (dolist (diagnostic (list native string-severity missing-severity))
                (should diagnostic)
                (should (equal (herdr-claude-code-ide-diagnostics-tests--value
                                'filePath diagnostic)
                               file))
                (let ((severity (herdr-claude-code-ide-diagnostics-tests--value
                                 'severity diagnostic)))
                  (should (stringp severity))
                  (should-not (equal severity "nil"))))
              (should (equal (herdr-claude-code-ide-diagnostics-tests--value
                              'severity native)
                             "error"))
              (should (equal (herdr-claude-code-ide-diagnostics-tests--value
                              'severity string-severity)
                             "warning"))
              (when flycheck-record
                (should (herdr-claude-code-ide-diagnostics-tests--diagnostic
                         "flycheck warning" diagnostics))))))
      (dolist (buffer (list visited outside))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory project t)
      (delete-directory other-project t))))

(ert-deftest herdr-claude-code-ide-selection-hook-is-owned-by-first-and-last-adapter ()
  (let* ((root (make-temp-file "herdr-t004-hook" t))
         (server-key (expand-file-name "herdr.sock" root))
         (first-agent `((agent . "claude") (terminal_id . "first")
                        (name . "first") (pane_id . "first:pane") (cwd . ,root)))
         (second-agent `((agent . "claude") (terminal_id . "second")
                         (name . "second") (pane_id . "second:pane") (cwd . ,root)))
         (original-require (symbol-function 'require))
         (port 4242)
         (file (expand-file-name "hook.el" root))
         (buffer nil)
         additions
         removals
         first
         second)
    (unwind-protect
        (progn
          (with-temp-file file (insert "selection\n"))
          (setq buffer (find-file-noselect file))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (if (eq feature 'websocket)
                           'websocket
                         (funcall original-require feature filename noerror))))
                    ((symbol-function 'websocket-server)
                     (lambda (&rest _) 'server))
                    ((symbol-function 'websocket-server-close)
                     (lambda (&rest _) nil))
                    ((symbol-function 'herdr-claude-code-ide-mcp--port)
                     (lambda (&rest _) (cl-incf port)))
                    ((symbol-function 'add-hook)
                     (lambda (hook function &optional append local)
                       (when (and (symbolp function)
                                  (string-prefix-p "herdr-" (symbol-name function)))
                         (push (list hook function append local) additions))))
                    ((symbol-function 'remove-hook)
                     (lambda (hook function &optional local)
                       (when (and (symbolp function)
                                  (string-prefix-p "herdr-" (symbol-name function)))
                         (push (list hook function local) removals)))))
            (let ((herdr-claude-code-ide-mcp--adapters (make-hash-table :test #'equal)))
              (setq first
                  (herdr-claude-code-ide-diagnostics-tests--call
                   'herdr-claude-code-ide-mcp-prepare first-agent
                   :server-key server-key :project-root root :instance-id "first"
                   :discovery-directory (expand-file-name "first" root)))
            (should (herdr-claude-code-ide-diagnostics-tests--call
                     'herdr-claude-code-ide-mcp-global-hooks-installed-p))
            (should additions)
            (should (= (length additions)
                       (length (cl-remove-duplicates (copy-sequence additions)
                                                     :test #'equal))))
            (let ((selection-addition
                   (cl-find-if
                    (lambda (addition)
                      (equal (cl-subseq addition 0 2)
                             '(post-command-hook
                               herdr-claude-code-ide-mcp-selection-context-changed)))
                    additions)))
              (should selection-addition)
              (should-not (nth 3 selection-addition))
              (let (boundary-buffer)
                (cl-letf (((symbol-function
                            'herdr-claude-code-ide-mcp-selection-context-changed)
                           (lambda (&rest _)
                             (setq boundary-buffer (current-buffer)))))
                  (with-current-buffer buffer
                    (funcall (nth 1 selection-addition))))
                (should (eq boundary-buffer buffer))))
            (let ((first-additions (copy-sequence additions)))
              (setq second
                    (herdr-claude-code-ide-diagnostics-tests--call
                     'herdr-claude-code-ide-mcp-prepare second-agent
                     :server-key server-key :project-root root :instance-id "second"
                     :discovery-directory (expand-file-name "second" root)))
              (should (equal additions first-additions))
              (herdr-claude-code-ide-diagnostics-tests--call
               'herdr-claude-code-ide-mcp-cleanup first)
              (should-not removals)
              (herdr-claude-code-ide-diagnostics-tests--call
               'herdr-claude-code-ide-mcp-cleanup second)
              (should (= (length removals) (length additions)))
              (dolist (removal removals)
                (should
                 (cl-find-if
                  (lambda (addition)
                    (equal (list (nth 0 addition)
                                 (nth 1 addition)
                                 (nth 3 addition))
                           removal))
                  additions)))))))
      (when first
        (herdr-claude-code-ide-diagnostics-tests--call
         'herdr-claude-code-ide-mcp-cleanup first))
      (when second
        (herdr-claude-code-ide-diagnostics-tests--call
         'herdr-claude-code-ide-mcp-cleanup second))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(provide 'herdr-claude-code-ide-diagnostics-tests)
;;; herdr-claude-code-ide-diagnostics-tests.el ends here
