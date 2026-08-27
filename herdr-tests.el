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

(ert-deftest herdr-subscribe-delivers-event-data-not-the-event-kind ()
  (unwind-protect
      (let* ((data '((pane_id . "w1:t1:p1") (terminal_id . "term-1")))
             (received nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (_request)
                 `((event . "pane.updated") (data . ,data))))))
        (herdr-subscribe '("pane.updated") (lambda (event) (setq received event)))
        (accept-process-output nil 0.05)
        (should (equal received data)))
    (herdr-tests--teardown)))

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

(ert-deftest herdr-open-tab-opens-a-workspace-in-an-empty-session ()
  (unwind-protect
      (let* ((calls nil)
             (workspaces nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (request)
                 (push (cons (alist-get 'method request) (alist-get 'params request))
                       calls)
                 `((id . ,(alist-get 'id request))
                   (result . ((type . "ok")
                              (tab . ((tab_id . "w1:t1")))
                              (workspaces . ,(or workspaces [])))))))))
        (herdr-open-tab :cwd "/tmp" :label "first")
        (should (equal (mapcar #'car (reverse calls))
                       '("workspace.list" "workspace.create" "tab.rename")))
        (should (equal (cdr (assq 'label (cdr (nth 1 (reverse calls))))) "first"))
        (setq calls nil)
        (setq workspaces (vector '((workspace_id . "w1") (label . "app"))))
        (herdr-open-tab :cwd "/tmp" :label "second")
        (should (equal (caar calls) "tab.create"))
        (herdr-open-tab :cwd "/tmp" :label "third" :workspace "app")
        (should (equal (cdr (assq 'workspace_id (cdar calls))) "w1")))
    (herdr-tests--teardown)))

(ert-deftest herdr-open-tab-creates-a-missing-workspace-and-names-its-tab ()
  (unwind-protect
      (let* ((calls nil)
             (herdr-socket-path
              (herdr-tests--start-server
               (lambda (request)
                 (push (cons (alist-get 'method request) (alist-get 'params request))
                       calls)
                 `((id . ,(alist-get 'id request))
                   (result . ((type . "ok")
                              (tab . ((tab_id . "w2:t1")))
                              (workspaces . ,(vector '((workspace_id . "w1")
                                                       (label . "other")))))))))))
        (herdr-open-tab :cwd "/tmp" :label "feat-x" :workspace "app")
        (let ((methods (mapcar #'car (reverse calls))))
          (should (equal methods '("workspace.list" "workspace.create" "tab.rename"))))
        (should (equal (cdr (assq 'label (cdr (nth 1 (reverse calls))))) "app"))
        (should (equal (cdr (assq 'label (cdar calls))) "feat-x"))
        (should (equal (cdr (assq 'tab_id (cdar calls))) "w2:t1")))
    (herdr-tests--teardown)))

(ert-deftest herdr-buffer-names-make-room-for-repeated-labels ()
  (let ((first (get-buffer-create "*herdr: 1*"))
        (second nil))
    (unwind-protect
        (progn
          (start-process "herdr-test-sleep" first "sleep" "30")
          (herdr-claim-buffer first "term_a")
          (should (equal (herdr--free-buffer-name "1" "term_b") "*herdr: 1<2>*"))
          (should-error (herdr--free-buffer-name "1" "term_a") :type 'user-error)
          (setq second (get-buffer-create "*herdr: 1<2>*"))
          (start-process "herdr-test-sleep-2" second "sleep" "30")
          (herdr-claim-buffer second "term_b")
          (should (equal (herdr--free-buffer-name "1" "term_c") "*herdr: 1<3>*")))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (when-let* ((process (get-buffer-process buffer))) (delete-process process))
          (kill-buffer buffer))))))

(ert-deftest herdr-session-layout-groups-entries-by-workspace ()
  (cl-letf (((symbol-function 'herdr-workspaces)
             (lambda () '(((workspace_id . "w1") (label . "app"))
                          ((workspace_id . "w2") (label . "empty")))))
            ((symbol-function 'herdr-tabs)
             (lambda () '(((tab_id . "w1:t1") (label . "feat-a")))))
            ((symbol-function 'herdr-agents)
             (lambda () '(((workspace_id . "w1") (tab_id . "w1:t1") (terminal_id . "t1"))
                          ((workspace_id . "w1") (terminal_id . "t2")))))
            ((symbol-function 'herdr-panes)
             (lambda () '(((workspace_id . "w1") (terminal_id . "t1"))
                          ((workspace_id . "w2") (terminal_id . "t3"))))))
    (let ((layout (herdr-session-layout)))
      (should (= (length layout) 1))
      (should (equal (alist-get 'label (caar layout)) "app"))
      (should (= (length (cdar layout)) 2))
      (should (equal (alist-get 'kind (car (cdar layout))) "herdr"))
      (should (equal (herdr--entry-label (car (cdar layout))) "feat-a")))
    (should (= (length (herdr-session-layout t)) 2))))

(ert-deftest herdr-attach-session-opens-workspaces-and-skips-attached ()
  (let* ((opened nil)
         (attached nil)
         (herdr-workspace-open-function
          (lambda (workspace directory)
            (push (cons (alist-get 'label workspace) directory) opened)))
         (herdr-attach-takeover t))
    (cl-letf (((symbol-function 'herdr-available-p) (lambda () t))
              ((symbol-function 'herdr-session-layout)
               (lambda (&optional _all)
                 '((((workspace_id . "w1") (label . "app"))
                    ((terminal_id . "t1") (cwd . "/src/app"))
                    ((terminal_id . "t2") (cwd . "/src/app"))))))
              ((symbol-function 'herdr-terminal-buffer)
               (lambda (terminal-id) (equal terminal-id "t2")))
              ((symbol-function 'herdr-attach-entry)
               (lambda (entry)
                 (push (cons (alist-get 'terminal_id entry) herdr-attach-takeover)
                       attached)
                 'buffer)))
      (should (equal (herdr-attach-session "work") '(buffer)))
      (should (equal opened '(("app" . "/src/app"))))
      (should (equal attached '(("t1" . nil)))))))

(ert-deftest herdr-workspace-label-defaults-to-the-directory-name ()
  (let ((herdr-workspace-label-function #'herdr-default-workspace-label))
    (should (equal (herdr-workspace-label "/src/app/") "app"))
    (should (equal (herdr-workspace-label "/src/app/.worktrees/feat-x") "feat-x"))))

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

(ert-deftest herdr-claude-code-ide-label-is-the-checkout-name ()
  (should (equal (herdr-claude-code-ide-default-label "*claude-code[dotfiles]*" "/x/dotfiles")
                 "dotfiles"))
  (should (equal (herdr-claude-code-ide-default-label
                  "*claude-code[shiftlet]*" "/x/shiftlet/.worktrees/feat-mvp/")
                 "feat-mvp")))

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

(ert-deftest herdr-project-root-asks-projectile-only-when-loaded ()
  (cl-letf (((symbol-function 'projectile-project-root) (lambda (&rest _) "/p/projectile/"))
            ((symbol-function 'project-current) (lambda (&rest _) nil)))
    (should-not (featurep 'projectile))
    (should-not (herdr-project-root "/tmp"))
    (unwind-protect
        (progn
          (provide 'projectile)
          (should (equal (herdr-project-root "/tmp") "/p/projectile/")))
      (setq features (delq 'projectile features)))))

(ert-deftest herdr-session-for-prefers-assignments-over-rules ()
  (let ((herdr-session 'shared)
        (herdr-session-alist '(("/src" . "derived")))
        (herdr-project-sessions '(("/src/work/" . "work")))
        (herdr-project-root-function
         (lambda (&optional directory)
           (when (string-prefix-p "/src/work" (or directory "")) "/src/work/"))))
    (should (equal (herdr-session-for "/src/work/sub") "work"))
    (should (equal (herdr-session-for "/src/other") "derived"))
    (should (eq (herdr-session-for "/elsewhere") 'shared))))

(ert-deftest herdr-project-session-falls-back-to-the-deepest-assignment ()
  (let ((herdr-project-sessions '(("/src/" . "outer") ("/src/app/" . "inner")))
        (herdr-project-root-function (lambda (&rest _) nil)))
    (should (equal (herdr-project-session "/src/app/lib") "inner"))
    (should (equal (herdr-project-session "/src/other") "outer"))
    (should-not (herdr-project-session "/elsewhere")))
  (let ((herdr-project-sessions '(("/src/" . "outer") ("/src/app/" . "inner")))
        (herdr-project-root-function (lambda (&rest _) "/src/")))
    (should (equal (herdr-project-session "/src/app/lib") "outer"))))

(ert-deftest herdr-assign-project-replaces-and-drops ()
  (let ((herdr-project-sessions nil)
        (herdr--stored-assignments (cons herdr-state-file nil)))
    (herdr-assign-project "/tmp/proj" "work" t)
    (should (equal (cdar (herdr-stored-assignments)) "work"))
    (herdr-assign-project "/tmp/proj/" "private" t)
    (should (= (length (herdr-stored-assignments)) 1))
    (should (equal (cdar (herdr-stored-assignments)) "private"))
    (herdr-assign-project "/tmp/proj" nil t)
    (should-not (herdr-stored-assignments))))

(ert-deftest herdr-assignments-survive-a-round-trip-through-the-state-file ()
  (let* ((directory (make-temp-file "herdr-state" t))
         (herdr-state-file (expand-file-name "herdr/project-sessions.eld" directory))
         (herdr-project-sessions nil)
         (herdr--stored-assignments nil))
    (unwind-protect
        (progn
          (herdr-assign-project "/tmp/work" "work")
          (should (file-readable-p herdr-state-file))
          (let ((herdr--stored-assignments nil))
            (should (equal (herdr-stored-assignments) '(("/tmp/work/" . "work"))))
            (should (equal (herdr-project-session "/tmp/work/sub") "work"))))
      (delete-directory directory t))))

(ert-deftest herdr-configured-assignments-win-over-stored-ones ()
  (let ((herdr-project-sessions '(("/tmp/proj/" . "configured")))
        (herdr--stored-assignments (cons herdr-state-file '(("/tmp/proj/" . "stored"))))
        (herdr-project-root-function (lambda (&rest _) "/tmp/proj/")))
    (should (equal (herdr-project-session "/tmp/proj/sub") "configured"))
    (should (equal (herdr-known-sessions) '(shared "configured" "stored")))))

(ert-deftest herdr-stored-assignments-tolerate-a-broken-state-file ()
  (let* ((directory (make-temp-file "herdr-state" t))
         (herdr-state-file (expand-file-name "broken.eld" directory))
         (herdr--stored-assignments nil))
    (unwind-protect
        (progn
          (with-temp-file herdr-state-file (insert "(((("))
          (should-not (herdr-stored-assignments)))
      (delete-directory directory t))))

(ert-deftest herdr-known-sessions-covers-assignments-and-rules ()
  (let ((herdr-session 'shared)
        (herdr-project-sessions '(("/a" . "work")))
        (herdr-session-alist '(("/b" . "private") ("/c" . "work"))))
    (should (equal (herdr-known-sessions) '(shared "work" "private")))))

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
  (let* ((legacy 'herdr-claude-code-ide--attach-terminal)
         (was-bound (boundp legacy))
         (saved-value (and was-bound (symbol-value legacy))))
    (unwind-protect
        (dolist (state '(nil unbound))
          (let ((called nil))
            (pcase state
              ('nil (set legacy nil))
              ('unbound (makunbound legacy)))
            (cl-letf (((symbol-function 'herdr-start-server-if-needed)
                       (lambda () (signal 'herdr-error (list "no server")))))
              (let ((error
                     (should-error
                      (herdr-claude-code-ide--create-terminal-session
                       (lambda (&rest _) (setq called t) 'unwrapped)
                       "*claude-code[x]*" "/tmp" 4711 nil nil "s1"))))
                (should (eq (car error) 'user-error))
                (should-not called)))))
      (if was-bound
          (set legacy saved-value)
        (makunbound legacy)))))

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
        (working '((agent_status . "working")))
        (herdr-attach-takeover t))
    (let ((herdr-claude-code-ide-connect-on-adopt 'idle))
      (should (herdr-claude-code-ide--connect-p idle))
      (should-not (herdr-claude-code-ide--connect-p working)))
    (let ((herdr-claude-code-ide-connect-on-adopt t))
      (should (herdr-claude-code-ide--connect-p working)))
    (let ((herdr-claude-code-ide-connect-on-adopt nil))
      (should-not (herdr-claude-code-ide--connect-p idle)))
    (let ((herdr-claude-code-ide-connect-on-adopt t)
          (herdr-attach-takeover nil))
      (should-not (herdr-claude-code-ide--connect-p idle)))))

(ert-deftest herdr-live-server-answers-ping ()
  (let ((herdr-socket-path nil))
    (unless (herdr-available-p)
      (ert-skip "no herdr server running"))
    (should (alist-get 'protocol (herdr-request "ping")))
    (should (listp (herdr-agents)))))

(provide 'herdr-tests)
;;; herdr-tests.el ends here
