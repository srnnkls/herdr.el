;;; herdr-memex-tests.el --- Tests for herdr-memex.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l herdr-memex-tests.el -f ert-run-tests-batch-and-exit
;;
;; Memex itself is stubbed, so these run on a machine that has none.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-memex)
(require 'herdr-herd)

(defun herdr-memex-tests--entry (name session &optional cwd)
  "Return an agent entry called NAME running SESSION in CWD."
  `((kind . "herdr") (session . "alpha") (server_key . "/tmp/alpha.sock")
    (agent . "claude") (agent_status . "idle")
    (agent_session . ((agent . "claude") (kind . "id")
                      (source . "herdr:claude") (value . ,session)))
    (name . ,name) (terminal_title_stripped . ,name)
    (terminal_id . ,(concat "term-" session)) (pane_id . "w1:p1")
    (workspace_id . "w1") (tab_id . "w1:t1")
    (cwd . ,(or cwd "/tmp/proj/"))))

(defvar herdr-memex-tests--entries
  (list (herdr-memex-tests--entry "one" "s1")
        (herdr-memex-tests--entry "two" "s2")
        (herdr-memex-tests--entry "three" "s3"))
  "The agents the fake server reports.")

(defvar herdr-memex-tests--searches nil
  "Scopes the stubbed search was called with, newest first.")

(defmacro herdr-memex-tests--with-dashboard (&rest body)
  "Render a dashboard over stubbed agents and run BODY inside it."
  (declare (indent 0) (debug (body)))
  `(let ((herdr--recent-session-targets nil)
         (herdr-memex-tests--searches nil)
         (buffer (generate-new-buffer " *herdr-memex-test*")))
     (unwind-protect
         (cl-letf (((symbol-function 'herdr-all-sessions) (lambda () '("alpha")))
                   ((symbol-function 'herdr-server-key)
                    (lambda () "/tmp/alpha.sock"))
                   ((symbol-function 'herdr-available-p) (lambda () t))
                   ((symbol-function 'herdr-snapshot)
                    (lambda () '((version . "1.2.3")
                                 (workspaces . (((workspace_id . "w1")
                                                 (label . "proj"))))
                                 (tabs . (((tab_id . "w1:t1") (label . "main"))))
                                 (panes . (((pane_id . "w1:p1")
                                            (workspace_id . "w1")))))))
                   ((symbol-function 'herdr-sessions)
                    (lambda () herdr-memex-tests--entries))
                   ((symbol-function 'herdr--entry-buffer) (lambda (_) nil))
                   ((symbol-function 'herdr-api-agent-read)
                    (lambda (&rest _) '((type . "pane_read"))))
                   ((symbol-function 'herdr-api-pane-read)
                    (lambda (&rest _) '((type . "pane_read"))))
                   ((symbol-function 'herdr-memex--ready) #'ignore)
                   ((symbol-function 'memex-herdr-session-scope)
                    (lambda (reference _directory)
                      (list :source "claude"
                            :session-id (alist-get 'value reference)
                            :source-path (concat "/tmp/"
                                                 (alist-get 'value reference)
                                                 ".jsonl"))))
                   ((symbol-function 'memex-search-in-sessions)
                    (lambda (scope &optional _mode _initial)
                      (push scope herdr-memex-tests--searches)
                      scope)))
           (with-current-buffer buffer
             (herdr-status-mode)
             (herdr-status-refresh)
             ,@body))
       (kill-buffer buffer))))

(defun herdr-memex-tests--goto (text)
  "Move point to the line holding TEXT."
  (goto-char (point-min))
  (unless (search-forward text nil t)
    (error "No line holding %s in the dashboard" text))
  (beginning-of-line))

(defun herdr-memex-tests--scoped-sessions ()
  "Return the session ids the last search was narrowed to."
  (mapcar (lambda (entry) (plist-get entry :session-id))
          (car herdr-memex-tests--searches)))

;;;; Keys

(ert-deftest herdr-memex-binds-no-key-without-memex ()
  (let ((map (copy-keymap herdr-status-mode-map)))
    (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil))
              (herdr-status-mode-map map))
      (herdr-memex-install-keys)
      (should-not (keymap-lookup map "m"))
      (should-not (keymap-lookup map "M")))))

(ert-deftest herdr-memex-binds-its-keys-where-memex-exists ()
  (let ((map (copy-keymap herdr-status-mode-map)))
    (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) "/tmp/memex.el"))
              (herdr-status-mode-map map))
      (herdr-memex-install-keys)
      (should (eq #'herdr-memex-search (keymap-lookup map "m")))
      (should (eq #'herdr-memex-dispatch (keymap-lookup map "M"))))))

;;;; Scope

(ert-deftest herdr-memex-searches-one-session-from-an-agent-row ()
  (herdr-memex-tests--with-dashboard
    (herdr-memex-tests--goto "two")
    (herdr-memex-search)
    (should (equal '("s2") (herdr-memex-tests--scoped-sessions)))))

(ert-deftest herdr-memex-searches-every-listed-agent-from-the-heading ()
  (herdr-memex-tests--with-dashboard
    (herdr-memex-tests--goto "Agents")
    (herdr-memex-search)
    (should (equal '("s1" "s2" "s3") (herdr-memex-tests--scoped-sessions)))))

(ert-deftest herdr-memex-searches-a-herd-from-its-own-section ()
  (let ((herdr-memex-tests--entries
         (mapcar (lambda (entry)
                   (if (member (alist-get 'name entry) '("one" "three"))
                       (cons '(pane_label . "herd:refactor") entry)
                     entry))
                 herdr-memex-tests--entries)))
    (herdr-memex-tests--with-dashboard
      (herdr-memex-tests--goto "refactor")
      (herdr-memex-search)
      (should (equal '("s1" "s3") (herdr-memex-tests--scoped-sessions))))))

(ert-deftest herdr-memex-searches-everything-outside-the-dashboard ()
  (with-temp-buffer
    (let ((herdr-memex-tests--searches nil))
      (cl-letf (((symbol-function 'herdr-memex--ready) #'ignore)
                ((symbol-function 'memex-search-in-sessions)
                 (lambda (scope &optional _mode _initial)
                   (push scope herdr-memex-tests--searches)
                   scope)))
        (herdr-memex-search)
        (should (equal '(nil) herdr-memex-tests--searches))))))

(ert-deftest herdr-memex-refuses-an-agent-memex-has-not-indexed ()
  (herdr-memex-tests--with-dashboard
    (cl-letf (((symbol-function 'memex-herdr-session-scope) (lambda (&rest _) nil)))
      (herdr-memex-tests--goto "two")
      (should-error (herdr-memex-search) :type 'user-error)
      (should-not herdr-memex-tests--searches))))

(provide 'herdr-memex-tests)
;;; herdr-memex-tests.el ends here
