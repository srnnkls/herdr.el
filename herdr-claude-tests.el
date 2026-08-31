;;; herdr-claude-tests.el --- Native Claude IDE integration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'herdr-claude)

(defun herdr-claude-tests--value (key object)
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-tests--session (root terminal &optional name)
  (herdr-agent--make-session
   :server "/tmp/herdr-tests.sock"
   :terminal terminal
   :kind "claude"
   :name (or name "review")
   :project root))

(defun herdr-claude-tests--state (session owner)
  (let* ((state (make-herdr-claude-protocol-state
                 :session session
                 :state 'connected
                 :client-generation 1
                 :tool-list (lambda () '(((name . "openDiff"))))
                 :tool-call #'herdr-claude-protocol--dispatch-editor
                 :raw-clients (make-hash-table :test #'eq)))
         (client (make-herdr-claude-protocol-client
                  :raw 'socket
                  :open-p t
                  :initialized-p t
                  :generation 1
                  :state state
                  :owner owner)))
    (setf (herdr-claude-protocol-state-current-client state) client
          (herdr-claude-protocol-state-clients state) (list client))
    (cons state client)))

(defun herdr-claude-tests--tool-call (id name arguments)
  (json-serialize
   `((jsonrpc . "2.0")
     (id . ,id)
     (method . "tools/call")
     (params . ((name . ,name) (arguments . ,arguments))))))

(defun herdr-claude-tests--initialize-params ()
  '((protocolVersion . "2025-11-25")
    (capabilities . ())
    (clientInfo . ((name . "claude-code") (version . "1.0")))))

(defun herdr-claude-tests--file-string (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest herdr-claude-has-one-built-in-phase-aware-harness-adapter ()
  (let* ((entries (seq-filter (lambda (entry) (equal (car entry) "claude"))
                              herdr-agent-harnesses))
         (descriptor (cdar entries))
         (session (herdr-claude-tests--session "/tmp" "terminal"))
         calls)
    (should (= (length entries) 1))
    (should (equal (plist-get descriptor :label) "Claude Code"))
    (should (eq (plist-get descriptor :adapter) 'herdr-claude--adapter))
    (should (equal (plist-get descriptor :arguments)
                   '((start) (continue "--continue")
                     (resume "--resume" :reference))))
    (cl-letf (((symbol-function 'herdr-claude--adapter)
               (lambda (actual-session phase &optional context)
                 (push (list actual-session phase context) calls))))
      (herdr-agent--run-adapter session :prepare 'launch))
    (should (equal calls (list (list session :prepare 'launch))))))

(ert-deftest herdr-claude-keeps-one-session-state-from-prepare-through-attach ()
  (let* ((root (make-temp-file "herdr-claude-lifecycle" t))
         (home (expand-file-name "home" root))
         (session (herdr-claude-tests--session root nil))
         (process-environment (cons (concat "HOME=" home) process-environment))
         (herdr-claude-protocol--states (make-hash-table :test #'eq))
         (herdr-claude-protocol--global-hooks-installed nil)
         (post-command-hook nil)
         environment before after)
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-claude-protocol--start-server)
                   (lambda (_state) 41001)))
          (setq environment (herdr-claude--adapter session :prepare)
                before (gethash session herdr-claude-protocol--states))
          (should (eq environment
                      (herdr-claude-protocol-state-environment before)))
          (should (eq (herdr-claude-protocol-state-state before) 'starting))
          (setf (herdr-agent-session-terminal session) "terminal-42")
          (herdr-claude--adapter session :attached)
          (setq after (gethash session herdr-claude-protocol--states))
          (should (eq before after))
          (should (= (hash-table-count herdr-claude-protocol--states) 1))
          (should (equal (herdr-claude-protocol-state-instance-id after)
                         "terminal-42"))
          (should (eq (herdr-claude-protocol-state-state after)
                      'waiting-for-client)))
      (when (gethash session herdr-claude-protocol--states)
        (herdr-claude--adapter session :detach))
      (delete-directory root t))))

(ert-deftest herdr-claude-normalizes-wire-input-before-editor-dispatch ()
  (let* ((root (make-temp-file "herdr-claude-normalize" t))
         (session (herdr-claude-tests--session root "terminal"))
         (pair (herdr-claude-tests--state session 'owner))
         (state (car pair))
         (client (cdr pair))
         captured response)
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-claude-editor-dispatch)
                   (lambda (owner actual-root operation arguments request)
                     (setq captured
                           (list owner actual-root operation arguments request))
                     (make-herdr-claude-editor-result
                      :kind 'text :value "diff opened"))))
          (setq response
                (herdr-claude-protocol-receive
                 state client
                 (herdr-claude-tests--tool-call
                  37 "openDiff"
                  '((old_file_path . "before.el")
                    (new_file_path . "after.el")
                    (new_file_contents . "replacement")
                    (tab_name . "change-37")))))
          (should (eq (nth 0 captured) 'owner))
          (should (equal (nth 1 captured) (file-truename root)))
          (should (eq (nth 2 captured) 'open-diff))
          (should (equal (nth 3 captured)
                         '(:old-path "before.el"
                           :new-path "after.el"
                           :contents "replacement"
                           :tab-name "change-37")))
          (should (functionp (plist-get (nth 4 captured) :resolve)))
          (should (= (herdr-claude-tests--value 'id response) 37))
          (let* ((result (herdr-claude-tests--value 'result response))
                 (content (herdr-claude-tests--value 'content result)))
            (should (equal (herdr-claude-tests--value 'text (aref content 0))
                           "diff opened"))))
      (delete-directory root t))))

(ert-deftest herdr-claude-stale-deferred-completion-sends-nothing ()
  (let* ((root (make-temp-file "herdr-claude-stale" t))
         (session (herdr-claude-tests--session root "terminal"))
         (pair (herdr-claude-tests--state session 'old-owner))
         (state (car pair))
         (old-client (cdr pair))
         (new-client (make-herdr-claude-protocol-client
                      :raw 'new-socket :open-p t :initialized-p t
                      :generation 2 :state state :owner 'new-owner))
         completion deliveries)
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-claude-editor-dispatch)
                   (lambda (_owner _root _operation _arguments request)
                     (setq completion (plist-get request :resolve))
                     herdr-claude-editor-deferred))
                  ((symbol-function 'websocket-send-text)
                   (lambda (&rest delivery) (push delivery deliveries))))
          (should-not
           (herdr-claude-protocol-receive
            state old-client
            (herdr-claude-tests--tool-call
             41 "openDiff"
             '((old_file_path . "before.el")
               (new_file_path . "after.el")
               (new_file_contents . "replacement")
               (tab_name . "change-41")))))
          (should (functionp completion))
          (setf (herdr-claude-protocol-state-current-client state) new-client
                (herdr-claude-protocol-state-client-generation state) 2
                (herdr-claude-protocol-state-clients state)
                (list new-client old-client))
          (funcall completion
                   (make-herdr-claude-editor-result :kind 'text :value "late"))
          (should-not deliveries))
      (delete-directory root t))))

(ert-deftest herdr-claude-client-supersession-cancels-only-the-owning-client ()
  (let* ((root (make-temp-file "herdr-claude-owner" t))
         (session-a (herdr-claude-tests--session root "terminal-a" "agent-a"))
         (session-b (herdr-claude-tests--session root "terminal-b" "agent-b"))
         (owner-a (make-symbol "owner-a"))
         (owner-b (make-symbol "owner-b"))
         (pair-a (herdr-claude-tests--state session-a owner-a))
         (pair-b (herdr-claude-tests--state session-b owner-b))
         (state-a (car pair-a))
         (state-b (car pair-b))
         (old-a (cdr pair-a))
         (old-b (cdr pair-b))
         (candidate (herdr-claude-protocol-client-connect state-a 'candidate-socket))
         (herdr-claude-editor--views (make-hash-table :test #'eq))
         (herdr-claude-editor--diffs (make-hash-table :test #'eq))
         (herdr-claude-editor--selection-timers (make-hash-table :test #'eq))
         (herdr-claude-editor--selection-contexts (make-hash-table :test #'eq))
         (views-a (make-hash-table :test #'equal))
         (views-b (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (puthash owner-a views-a herdr-claude-editor--views)
          (puthash owner-b views-b herdr-claude-editor--views)
          (puthash owner-a 'selection-a herdr-claude-editor--selection-contexts)
          (puthash owner-b 'selection-b herdr-claude-editor--selection-contexts)
          (cl-letf (((symbol-function 'websocket-close) (lambda (&rest _) nil)))
            (let ((response
                   (herdr-claude-protocol--initialize
                    state-a candidate 51
                    (herdr-claude-tests--initialize-params))))
              (should (= (herdr-claude-tests--value 'id response) 51))))
          (should (eq (herdr-claude-protocol-state-current-client state-a)
                      candidate))
          (should-not (herdr-claude-protocol-client-open-p old-a))
          (should-not (gethash owner-a herdr-claude-editor--views))
          (should-not (gethash owner-a
                               herdr-claude-editor--selection-contexts))
          (should (eq (herdr-claude-protocol-state-current-client state-b)
                      old-b))
          (should (herdr-claude-protocol-client-open-p old-b))
          (should (eq (gethash owner-b herdr-claude-editor--views) views-b))
          (should (eq (gethash owner-b
                               herdr-claude-editor--selection-contexts)
                      'selection-b)))
      (delete-directory root t))))

(ert-deftest herdr-claude-discovery-rollback-and-detach-remove-only-owned-artifacts ()
  (let* ((root (make-temp-file "herdr-claude-discovery" t))
         (discovery-directory (expand-file-name "discovery" root))
         (session (herdr-claude-tests--session root "terminal-a" "agent-a"))
         (failed-session
          (herdr-claude-tests--session root "terminal-b" "agent-b"))
         (herdr-claude-protocol--states (make-hash-table :test #'eq))
         (herdr-claude-protocol--global-hooks-installed nil)
         (post-command-hook nil)
         (next-port 45000)
         (servers nil)
         (closed nil)
         state owned-lockfile foreign-lockfile)
    (make-directory discovery-directory t)
    (setq foreign-lockfile (expand-file-name "45002.lock" discovery-directory))
    (with-temp-file foreign-lockfile (insert "foreign discovery"))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-claude-protocol--start-server)
                   (lambda (actual-state)
                     (let ((server (make-symbol "listener")))
                       (push server servers)
                       (setf (herdr-claude-protocol-state-server actual-state)
                             server)
                       (cl-incf next-port))))
                  ((symbol-function 'websocket-server-close)
                   (lambda (server) (push server closed))))
          (setq state
                (herdr-claude-protocol-prepare
                 '((agent . "claude")
                   (terminal_id . "terminal-a")
                   (name . "agent-a"))
                 :server-key "/tmp/herdr-tests.sock"
                 :project-root root
                 :instance-id "terminal-a"
                 :discovery-directory discovery-directory
                 :session session)
                owned-lockfile
                (herdr-claude-protocol-state-lockfile state))
          (should (file-exists-p owned-lockfile))
          (cl-letf (((symbol-function 'write-region)
                     (lambda (&rest _)
                       (error "discovery publication failed"))))
            (should-error
             (herdr-claude-protocol-prepare
              '((agent . "claude")
                (terminal_id . "terminal-b")
                (name . "agent-b"))
              :server-key "/tmp/herdr-tests.sock"
              :project-root root
              :instance-id "terminal-b"
              :discovery-directory discovery-directory
              :session failed-session)))
          (should (= (length closed) 1))
          (should (eq (car closed) (car servers)))
          (should (file-exists-p owned-lockfile))
          (should (equal (herdr-claude-tests--file-string foreign-lockfile)
                         "foreign discovery"))
          (should (= (hash-table-count herdr-claude-protocol--states) 1))
          (herdr-claude-protocol--detach-session session)
          (should-not (file-exists-p owned-lockfile))
          (should (equal (herdr-claude-tests--file-string foreign-lockfile)
                         "foreign discovery"))
          (should (= (length closed) 2))
          (should (= (length servers) 2))
          (dolist (server servers)
            (should (= (cl-count server closed :test #'eq) 1)))
          (should (= (hash-table-count herdr-claude-protocol--states) 0)))
      (when (and state
                 (not (eq (herdr-claude-protocol-state-state state) 'stopped)))
        (ignore-errors (herdr-claude-protocol-cleanup state)))
      (delete-directory root t))))

(provide 'herdr-claude-tests)
;;; herdr-claude-tests.el ends here
