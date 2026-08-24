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
    (let ((herdr-session "work"))
      (should (equal (herdr-socket-file) "/xdg/herdr/herdr-work.sock")))
    (let ((herdr-socket-path "/tmp/other.sock"))
      (should (equal (herdr-socket-file) "/tmp/other.sock")))))

(ert-deftest herdr-attach-command-shape ()
  (let ((herdr-executable "herdr"))
    (should (equal (herdr-attach-command "term_1")
                   '("herdr" "terminal" "attach" "term_1")))
    (should (equal (herdr-attach-command "term_1" t)
                   '("herdr" "terminal" "attach" "term_1" "--takeover")))))

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

(ert-deftest herdr-claude-code-ide-label-from-buffer-name ()
  (should (equal (herdr-claude-code-ide-default-label "*claude-code[dotfiles]*" "/x/dotfiles")
                 "claude-dotfiles"))
  (should (equal (herdr-claude-code-ide-default-label "*claude-code[dotfiles:review]*" "/x/dotfiles")
                 "claude-dotfiles:review"))
  (should (equal (herdr-claude-code-ide-default-label "*scratch*" "/x/dotfiles")
                 "claude-dotfiles")))

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
