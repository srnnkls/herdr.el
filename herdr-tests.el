;;; herdr-tests.el --- Tests for herdr.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l herdr-tests.el -f ert-run-tests-batch-and-exit
;;
;; The socket tests run against a fake server, so no herdr install is needed.
;; Tests that need a real server skip themselves when none answers.

;;; Code:

(require 'ert)
(require 'herdr)
(require 'herdr-api)
(require 'herdr-claude-code-ide)

(defvar herdr-tests--socket-dir nil)

(defun herdr-tests--start-server (handler)
  "Start a fake herdr API server answering with HANDLER.
HANDLER receives the decoded request alist and returns the response
alist.  Returns the socket path."
  (setq herdr-tests--socket-dir (make-temp-file "herdr-test" t))
  (let ((path (expand-file-name "herdr.sock" herdr-tests--socket-dir)))
    (make-network-process
     :name "herdr-test-server" :server t :family 'local :service path
     :coding 'utf-8-unix :noquery t
     :filter (lambda (proc chunk)
               (let ((request (json-parse-string
                               (string-trim-right chunk)
                               :object-type 'alist :array-type 'list
                               :null-object :null :false-object :false)))
                 (process-send-string
                  proc (concat (json-serialize (funcall handler request)) "\n")))))
    path))

(defun herdr-tests--teardown ()
  "Stop fake servers and remove their socket directory."
  (dolist (proc (process-list))
    (when (string-prefix-p "herdr-test-server" (process-name proc))
      (delete-process proc)))
  (when (and herdr-tests--socket-dir (file-directory-p herdr-tests--socket-dir))
    (delete-directory herdr-tests--socket-dir t))
  (setq herdr-tests--socket-dir nil))

(ert-deftest herdr-socket-file-defaults-to-config-dir ()
  (let ((process-environment (cons "XDG_CONFIG_HOME=/xdg" process-environment))
        (herdr-socket-path nil)
        (herdr-session nil))
    (should (equal (herdr-socket-file) "/xdg/herdr/herdr.sock"))
    (let ((herdr-socket-path "/tmp/other.sock"))
      (should (equal (herdr-socket-file) "/tmp/other.sock")))))

(ert-deftest herdr-attach-command-shape ()
  (let ((herdr-executable "herdr")
        (herdr-socket-path nil)
        (herdr-session 'shared))
    (should (equal (herdr-attach-command "term_1")
                   '("herdr" "terminal" "attach" "term_1")))
    (should (equal (herdr-attach-command "term_1" t)
                   '("herdr" "terminal" "attach" "term_1" "--takeover")))
    (let ((herdr-session "agents"))
      (should (equal (herdr-attach-command "term_1")
                     '("herdr" "--session" "agents" "terminal" "attach" "term_1"))))
    (let ((herdr-session "agents")
          (herdr-socket-path "/tmp/probe/herdr.sock"))
      (should (equal (herdr-attach-command "term_1")
                     '("herdr" "terminal" "attach" "term_1"))))))

(ert-deftest herdr-request-returns-result ()
  (unwind-protect
      (let* ((requests nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (request)
                 (push request requests)
                 `((id . ,(alist-get 'id request))
                   (result . ((type . "pong") (protocol . 17))))))))
        (should (equal (alist-get 'protocol (herdr-request "ping")) 17))
        (should (equal (alist-get 'method (car requests)) "ping"))
        (should (herdr-available-p)))
    (herdr-tests--teardown)))

(ert-deftest herdr-request-sends-params ()
  (unwind-protect
      (let* ((seen nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (request)
                 (setq seen (alist-get 'params request))
                 `((id . ,(alist-get 'id request)) (result . ((type . "ok"))))))))
        (herdr-request "pane.send_text" '((pane_id . "w1:p1") (text . "hi\n")))
        (should (equal (alist-get 'pane_id seen) "w1:p1"))
        (should (equal (alist-get 'text seen) "hi\n")))
    (herdr-tests--teardown)))

(ert-deftest herdr-request-signals-api-errors ()
  (unwind-protect
      (let ((herdr-socket-path
             (herdr-tests--start-server
              (lambda (request)
                `((id . ,(alist-get 'id request))
                  (error . ((code . "agent_not_found") (message . "nope"))))))))
        (let ((err (should-error (herdr-request "agent.get" '((target . "x")))
                                 :type 'herdr-api-error)))
          (should (equal (cadr err) "agent_not_found"))))
    (herdr-tests--teardown)))

(ert-deftest herdr-request-without-socket-signals ()
  (let ((herdr-socket-path "/nonexistent/herdr.sock"))
    (should-error (herdr-request "ping") :type 'herdr-error)
    (should-not (herdr-available-p))))

(ert-deftest herdr-api-tab-create-encodes-env-and-focus ()
  (unwind-protect
      (let* ((seen nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (request)
                 (setq seen (alist-get 'params request))
                 `((id . ,(alist-get 'id request))
                   (result . ((type . "tab_created"))))))))
        (herdr-api-tab-create :cwd "/tmp" :label "claude-x" :focus :false
                              :env '((CLAUDE_CODE_SSE_PORT . "4711")))
        (should (equal (alist-get 'label seen) "claude-x"))
        (should (equal (alist-get 'CLAUDE_CODE_SSE_PORT (alist-get 'env seen)) "4711"))
        (should (eq (alist-get 'focus seen) :false)))
    (herdr-tests--teardown)))

(ert-deftest herdr-new-tab-opens-a-workspace-in-an-empty-session ()
  (unwind-protect
      (let* ((methods nil)
             (workspaces nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (request)
                 (push (alist-get 'method request) methods)
                 `((id . ,(alist-get 'id request))
                   (result . ((type . "ok")
                              (workspaces . ,(or workspaces [])))))))))
        (herdr-new-tab :cwd "/tmp" :label "first")
        (should (equal (car methods) "workspace.create"))
        (setq workspaces (vector '((workspace_id . "w1"))))
        (herdr-new-tab :cwd "/tmp" :label "second")
        (should (equal (car methods) "tab.create"))
        (setq workspaces nil)
        (herdr-new-tab :cwd "/tmp" :label "third" :workspace "w1")
        (should (equal (car methods) "tab.create")))
    (herdr-tests--teardown)))

(ert-deftest herdr-display-buffer-uses-a-side-window ()
  (let ((buffer (get-buffer-create "*herdr: probe*"))
        (herdr-use-side-window t)
        (herdr-window-side 'right)
        (herdr-window-width 20)
        (herdr-display-buffer-action nil))
    (unwind-protect
        (let ((window (herdr-display-buffer buffer)))
          (should window)
          (should (eq (window-parameter window 'window-side) 'right))
          (should (equal (window-parameter window 'window-slot)
                         (buffer-local-value 'herdr--window-slot buffer)))
          (should (>= (buffer-local-value 'herdr--window-slot buffer)
                      herdr-window-slot-base))
          (should (window-dedicated-p window)))
      (kill-buffer buffer))))

(ert-deftest herdr-display-buffer-gives-each-terminal-its-own-slot ()
  (let ((first (get-buffer-create "*herdr: one*"))
        (second (get-buffer-create "*herdr: two*"))
        (herdr-window-width 20))
    (unwind-protect
        (progn
          (herdr-display-buffer first)
          (herdr-display-buffer second)
          (should-not (equal (buffer-local-value 'herdr--window-slot first)
                             (buffer-local-value 'herdr--window-slot second))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest herdr-display-buffer-returns-a-window-without-side-windows ()
  (let ((buffer (get-buffer-create "*herdr: plain*"))
        (herdr-use-side-window nil)
        (herdr-display-buffer-action nil))
    (unwind-protect
        (let ((window (herdr-display-buffer buffer)))
          (should (windowp window))
          (should (eq (window-buffer window) buffer))
          (should-not (window-parameter window 'window-side)))
      (kill-buffer buffer))))

(ert-deftest herdr-display-buffer-action-overrides-the-side-window ()
  (let ((buffer (get-buffer-create "*herdr: override*"))
        (herdr-display-buffer-action '(display-buffer-same-window)))
    (unwind-protect
        (should-not (window-parameter (herdr-display-buffer buffer) 'window-side))
      (kill-buffer buffer))))

(ert-deftest herdr-claude-code-ide-label-from-buffer-name ()
  (should (equal (herdr-claude-code-ide-default-label "*claude-code[dotfiles]*" "/x/dotfiles")
                 "claude-dotfiles"))
  (should (equal (herdr-claude-code-ide-default-label "*claude-code[dotfiles:review]*" "/x/dotfiles")
                 "claude-dotfiles:review"))
  (should (equal (herdr-claude-code-ide-default-label "*scratch*" "/x/dotfiles")
                 "claude-dotfiles")))

(ert-deftest herdr-claim-buffer-marks-and-announces-the-buffer ()
  (let ((buffer (get-buffer-create "*herdr: claimed*"))
        (announced nil))
    (unwind-protect
        (let ((herdr-buffer-functions (list (lambda (b) (push b announced)))))
          (should (eq (herdr-claim-buffer buffer "term_claim") buffer))
          (should (equal (buffer-local-value 'herdr-terminal-id buffer) "term_claim"))
          (should (equal announced (list buffer))))
      (kill-buffer buffer))))

(ert-deftest herdr-terminal-buffer-needs-a-live-process ()
  (let ((buffer (get-buffer-create "*herdr: lookup*")))
    (unwind-protect
        (progn
          (herdr-claim-buffer buffer "term_lookup")
          (should-not (herdr-terminal-buffer "term_lookup"))
          (start-process "herdr-test-sleep" buffer "sleep" "30")
          (should (eq (herdr-terminal-buffer "term_lookup") buffer))
          (should-not (herdr-terminal-buffer "term_missing")))
      (when-let* ((process (get-buffer-process buffer))) (delete-process process))
      (kill-buffer buffer))))

(ert-deftest herdr-sessions-dedups-terminals-preferring-live-buffers ()
  (let ((buffer (get-buffer-create "*herdr: session*")))
    (unwind-protect
        (let* ((bare '((kind . "herdr") (terminal_id . "term_dup") (agent . "claude")
                       (terminal_title_stripped . "bare")))
               (rich `((kind . "claude-code-ide") (terminal_id . "term_dup")
                       (label . "rich") (buffer . ,buffer)))
               (other '((kind . "herdr") (terminal_id . "term_other") (agent . "codex")))
               (herdr-session-functions
                (list (lambda () (list bare other)) (lambda () (list rich)))))
          (let ((sessions (herdr-sessions)))
            (should (= (length sessions) 2))
            (should (equal (herdr--entry-label (car sessions)) "rich"))
            (should (equal (alist-get 'terminal_id (cadr sessions)) "term_other"))))
      (kill-buffer buffer))))

(ert-deftest herdr-visit-shows-a-live-buffer-instead-of-attaching ()
  (let ((buffer (get-buffer-create "*herdr: visit*"))
        (popped nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (b &rest _) (setq popped b)))
                  ((symbol-function 'herdr-attach-entry)
                   (lambda (&rest _) (error "Should not attach an attached session"))))
          (should (eq (herdr-visit `((buffer . ,buffer))) buffer))
          (should (eq popped buffer)))
      (kill-buffer buffer))))

(ert-deftest herdr-visit-attaches-a-session-without-a-buffer ()
  (cl-letf (((symbol-function 'herdr-attach-entry) (lambda (_entry) 'attached)))
    (should (eq (herdr-visit '((terminal_id . "term_cold"))) 'attached))))

(ert-deftest herdr-attach-entry-lets-a-hook-claim-the-entry ()
  (let* ((claimed (get-buffer-create "*herdr: claimed*"))
         (seen nil)
         (herdr-attach-functions
          (list (lambda (entry) (setq seen entry) claimed))))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-attach-terminal)
                   (lambda (&rest _) (error "Should not attach a terminal"))))
          (should (eq (herdr-attach-entry '((agent . "claude") (terminal_id . "term_1")))
                      claimed))
          (should (equal (alist-get 'terminal_id seen) "term_1")))
      (kill-buffer claimed))))

(ert-deftest herdr-attach-entry-falls-through-to-the-terminal ()
  (let ((herdr-attach-functions (list (lambda (_entry) nil)))
        (attached nil))
    (cl-letf (((symbol-function 'herdr-attach-terminal)
               (lambda (terminal-id &rest _) (setq attached terminal-id) 'buffer)))
      (should (eq (herdr-attach-entry '((agent . "codex") (terminal_id . "term_2")))
                  'buffer))
      (should (equal attached "term_2")))))

(ert-deftest herdr-claude-code-ide-claims-only-claude-agents ()
  (let ((herdr-claude-code-ide-adopt-on-attach t))
    (cl-letf (((symbol-function 'claude-code-ide) #'ignore)
              ((symbol-function 'herdr-claude-code-ide-adopt) (lambda (_agent) 'adopted)))
      (should (eq (herdr-claude-code-ide--attach-entry
                   '((agent . "claude") (cwd . "/tmp") (terminal_id . "term_3")))
                  'adopted))
      (should-not (herdr-claude-code-ide--attach-entry
                   '((agent . "codex") (cwd . "/tmp") (terminal_id . "term_4"))))
      (let ((herdr-claude-code-ide-adopt-on-attach nil))
        (should-not (herdr-claude-code-ide--attach-entry
                     '((agent . "claude") (cwd . "/tmp") (terminal_id . "term_5"))))))))

(ert-deftest herdr-claude-code-ide-adopt-reuses-a-live-session ()
  (let ((buffer (get-buffer-create "*claude-code[reuse]*"))
        (herdr-claude-code-ide-mode t))
    (unwind-protect
        (progn
          (start-process "herdr-test-sleep" buffer "sleep" "30")
          (puthash "term_reuse" buffer herdr-claude-code-ide--buffers)
          (cl-letf (((symbol-function 'claude-code-ide)
                     (lambda () (error "Should reuse the running session")))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (should (eq (herdr-claude-code-ide-adopt
                         '((agent . "claude") (cwd . "/tmp") (terminal_id . "term_reuse")))
                        buffer))))
      (when-let* ((process (get-buffer-process buffer))) (delete-process process))
      (remhash "term_reuse" herdr-claude-code-ide--buffers)
      (kill-buffer buffer))))

(ert-deftest herdr-socket-file-uses-the-session-data-dir ()
  (let ((process-environment (cons "XDG_CONFIG_HOME=/xdg" process-environment))
        (herdr-socket-path nil)
        (herdr-session "work"))
    (should (equal (herdr-socket-file) "/xdg/herdr/sessions/work/herdr.sock"))))

(ert-deftest herdr-session-name-resolves-the-choices ()
  (let ((herdr-emacs-session-name "emacs"))
    (let ((herdr-session 'shared)) (should-not (herdr-session-name)))
    (let ((herdr-session nil)) (should-not (herdr-session-name)))
    (let ((herdr-session 'emacs)) (should (equal (herdr-session-name) "emacs")))
    (let ((herdr-session "agents")) (should (equal (herdr-session-name) "agents")))
    (let ((herdr-session 42)) (should-error (herdr-session-name) :type 'herdr-error))))

(ert-deftest herdr-socket-file-follows-the-session-choice ()
  (let ((process-environment (cons "XDG_CONFIG_HOME=/xdg" process-environment))
        (herdr-socket-path nil)
        (herdr-emacs-session-name "emacs"))
    (let ((herdr-session 'shared))
      (should (equal (herdr-socket-file) "/xdg/herdr/herdr.sock")))
    (let ((herdr-session 'emacs))
      (should (equal (herdr-socket-file) "/xdg/herdr/sessions/emacs/herdr.sock")))))

(ert-deftest herdr-process-environment-points-at-our-socket ()
  (let ((herdr-socket-path "/tmp/probe/herdr.sock"))
    (should (member "HERDR_SOCKET_PATH=/tmp/probe/herdr.sock"
                    (herdr-process-environment)))))

(ert-deftest herdr-terminal-exec-passes-the-socket-along ()
  (let ((herdr-socket-path "/tmp/probe/herdr.sock")
        (seen nil))
    (cl-letf (((symbol-function 'herdr--terminal-exec-1)
               (lambda (buffer &rest _)
                 (setq seen (getenv "HERDR_SOCKET_PATH"))
                 buffer)))
      (herdr--terminal-exec 'buffer "herdr" '("terminal" "attach" "term_1"))
      (should (equal seen "/tmp/probe/herdr.sock")))))

(ert-deftest herdr-start-server-if-needed-starts-one-when-missing ()
  (let ((started 0))
    (cl-letf (((symbol-function 'herdr-available-p) (lambda () nil))
              ((symbol-function 'herdr-start-server)
               (lambda () (cl-incf started) t)))
      (let ((herdr-auto-start-server t))
        (should (herdr-start-server-if-needed))
        (should (= started 1)))
      (let ((herdr-auto-start-server nil))
        (should-error (herdr-start-server-if-needed) :type 'herdr-error)
        (should (= started 1)))))
  (cl-letf (((symbol-function 'herdr-available-p) (lambda () t))
            ((symbol-function 'herdr-start-server)
             (lambda () (error "Should not start a second server"))))
    (should (herdr-start-server-if-needed))))

(ert-deftest herdr-start-server-needs-the-executable ()
  (let ((herdr-executable "herdr-that-is-not-installed"))
    (cl-letf (((symbol-function 'call-process-shell-command)
               (lambda (&rest _) (error "Should not run a missing executable"))))
      (should-error (herdr-start-server) :type 'herdr-error))))

(ert-deftest herdr-claude-code-ide-refuses-to-run-outside-herdr ()
  (let ((herdr-claude-code-ide--attach-terminal nil))
    (cl-letf (((symbol-function 'herdr-start-server-if-needed)
               (lambda () (signal 'herdr-error (list "no server")))))
      (let ((herdr-claude-code-ide-require-herdr t))
        (should-error (herdr-claude-code-ide--create-terminal-session
                       (lambda (&rest _) 'unwrapped)
                       "*claude-code[x]*" "/tmp" 4711 nil nil "s1")
                      :type 'user-error))
      (let ((herdr-claude-code-ide-require-herdr nil))
        (should (eq (herdr-claude-code-ide--create-terminal-session
                     (lambda (&rest _) 'unwrapped)
                     "*claude-code[x]*" "/tmp" 4711 nil nil "s1")
                    'unwrapped))))))

(ert-deftest herdr-claude-code-ide-sessions-become-jump-entries ()
  (let ((buffer (get-buffer-create "*claude-code[entries]*")))
    (unwind-protect
        (progn
          (herdr-claim-buffer buffer "term_entry")
          (cl-letf (((symbol-function 'claude-code-ide-mcp--active-sessions)
                     (lambda () (list 'session)))
                    ((symbol-function 'claude-code-ide--session-display-name)
                     (lambda (_session) "entries"))
                    ((symbol-function 'claude-code-ide-mcp-session-buffer)
                     (lambda (_session) buffer))
                    ((symbol-function 'claude-code-ide-mcp-session-project-dir)
                     (lambda (_session) "/x/entries")))
            (let ((entry (car (herdr-claude-code-ide-sessions))))
              (should (equal (alist-get 'kind entry) "claude-code-ide"))
              (should (equal (herdr--entry-label entry) "entries"))
              (should (equal (alist-get 'terminal_id entry) "term_entry"))
              (should (eq (alist-get 'buffer entry) buffer)))))
      (kill-buffer buffer))))

(ert-deftest herdr-claude-code-ide-instance-name-from-agent ()
  (should (equal (herdr-claude-code-ide-default-instance-name
                  '((terminal_title_stripped . "Pinned frame detection")))
                 "Pinned frame detection"))
  (should (equal (herdr-claude-code-ide-default-instance-name
                  '((name . "review") (terminal_title_stripped . "ignored")))
                 "review"))
  (should (equal (herdr-claude-code-ide-default-instance-name
                  '((terminal_title_stripped . "  [weird]  *title*  ")))
                 "weird title"))
  (should-not (herdr-claude-code-ide-default-instance-name
               '((terminal_title_stripped . "42"))))
  (should-not (herdr-claude-code-ide-default-instance-name '())))

(ert-deftest herdr-claude-code-ide-answers-the-instance-prompt-once ()
  (let ((answer (herdr-claude-code-ide--instance-prompt-answer "review")))
    (should (equal (funcall answer "Instance name: ") "review"))
    (should (equal (funcall answer "Instance name: ") ""))
    (should (equal (funcall answer "Instance name: ") "")))
  (let ((answer (herdr-claude-code-ide--instance-prompt-answer nil)))
    (should (equal (funcall answer "Instance name: ") ""))))

(ert-deftest herdr-claude-code-ide-connect-p-follows-agent-status ()
  (let ((idle '((agent_status . "idle")))
        (working '((agent_status . "working"))))
    (let ((herdr-claude-code-ide-connect-on-adopt 'idle))
      (should (herdr-claude-code-ide--connect-p idle))
      (should-not (herdr-claude-code-ide--connect-p working)))
    (let ((herdr-claude-code-ide-connect-on-adopt t))
      (should (herdr-claude-code-ide--connect-p working)))
    (let ((herdr-claude-code-ide-connect-on-adopt nil))
      (should-not (herdr-claude-code-ide--connect-p idle)))))

(ert-deftest herdr-claude-code-ide-attaches-instead-of-spawning ()
  (let* ((built nil)
         (herdr-claude-code-ide--attach-terminal "term_adopted")
         (herdr-executable "herdr")
         (original (lambda (&rest _)
                     (setq built (claude-code-ide--build-claude-command nil nil "s1")))))
    (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
               (lambda (&rest _) "claude --resume")))
      (herdr-claude-code-ide--create-terminal-session
       original "*claude-code[x]*" "/tmp" 4711 nil nil "s1"))
    (should (equal built "herdr terminal attach term_adopted --takeover"))))

(ert-deftest herdr-live-server-answers-ping ()
  (let ((herdr-socket-path nil))
    (unless (herdr-available-p)
      (ert-skip "no herdr server running"))
    (should (alist-get 'protocol (herdr-request "ping")))
    (should (listp (herdr-agents)))))

(provide 'herdr-tests)
;;; herdr-tests.el ends here
