;;; emacsctl-tests.el --- Agent-facing Emacs interface tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'emacsctl)

(defmacro emacsctl-tests--with-registry (&rest body)
  (declare (indent 0) (debug t))
  `(let ((emacsctl--operations (copy-hash-table emacsctl--operations))
         (emacsctl--buffers (make-hash-table :test #'eq)))
     ,@body))

(defun emacsctl-tests--decode-dispatch (response)
  (pcase-let* ((`(,status ,encoded) (split-string response ":"))
               (payload (decode-coding-string (base64-decode-string encoded) 'utf-8)))
    (cons (string-to-number status) payload)))

(ert-deftest emacsctl-registers-replaces-discovers-and-validates-operations ()
  (emacsctl-tests--with-registry
    (let (seen)
      (emacsctl-register-operation
       "sample.lookup"
       (lambda (arguments context)
         (setq seen (list arguments context))
         "old")
       :description "Look up a sample."
       :effect 'read
       :parameters '((:name "name" :type string :required t)))
      (emacsctl-register-operation
       "sample.lookup"
       (lambda (arguments context)
         (setq seen (list arguments context))
         (alist-get 'name arguments))
       :description "Look up a replacement sample."
       :effect 'read
       :parameters '((:name "name" :type string :required t)))
      (let ((descriptor (car (seq-filter
                              (lambda (entry)
                                (equal (alist-get 'name entry) "sample.lookup"))
                              (emacsctl-operations '(:interface cli))))))
        (should (equal (alist-get 'description descriptor)
                       "Look up a replacement sample.")))
      (should (equal (emacsctl-call
                      "sample.lookup" '((name . "current"))
                      '(:interface cli :source cli))
                     "current"))
      (should (equal (alist-get 'name (car seen)) "current"))
      (should-error
       (emacsctl-call "sample.lookup" nil '(:interface cli))
       :type 'emacsctl-invalid-arguments)
      (should-error
       (emacsctl-call "sample.lookup" '((name . 7)) '(:interface cli))
       :type 'emacsctl-invalid-arguments)
      (should-error
       (emacsctl-call "sample.lookup" '((name . "x") (extra . t))
                      '(:interface cli))
       :type 'emacsctl-invalid-arguments)
      (emacsctl-register-operation
       "sample.array" (lambda (arguments _context) (alist-get 'items arguments))
       :parameters '((:name "items" :type array :required t)))
      (should (equal (emacsctl-call "sample.array" '((items . [1 2]))
                                    '(:interface cli))
                     [1 2]))
      (should-error
       (emacsctl-call "sample.array" '((items . ((key . "value"))))
                      '(:interface cli))
       :type 'emacsctl-invalid-arguments))))

(ert-deftest emacsctl-base-operations-use-buffer-and-window-terminology ()
  (emacsctl-tests--with-registry
    (let* ((root (file-truename (make-temp-file "emacsctl-root" t)))
           (file (expand-file-name "inside.el" root))
           (outside (make-temp-file "emacsctl-outside"))
           buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file file (insert "one\ntwo\n"))
            (setq buffer
                  (emacsctl-call
                   "buffer.open"
                   '((path . "inside.el") (line . 2) (column . 1))
                   `(:interface cli :project-root ,root :owner test-owner)))
            (should (equal (alist-get 'file buffer) file))
            (should (equal (alist-get 'line buffer) 2))
            (should (seq-find
                     (lambda (entry) (equal (alist-get 'file entry) file))
                     (emacsctl-call "buffer.list" nil
                                    `(:interface cli :project-root ,root))))
            (should (seq-find
                     (lambda (entry)
                       (equal (alist-get 'buffer entry)
                              (file-name-nondirectory file)))
                     (emacsctl-call "window.list" nil
                                    `(:interface cli :project-root ,root))))
            (should-error
             (emacsctl-call "buffer.open" `((path . ,outside))
                            `(:interface cli :project-root ,root))
             :type 'emacsctl-operation-failed))
        (when (buffer-live-p (get-file-buffer file))
          (kill-buffer (get-file-buffer file)))
        (delete-directory root t)
        (when (file-exists-p outside) (delete-file outside))))))

(ert-deftest emacsctl-buffer-open-updates-visible-state-and-releases-owner ()
  (emacsctl-tests--with-registry
    (let* ((root (file-truename (make-temp-file "emacsctl-visible" t)))
           (file (expand-file-name "visible.el" root))
           buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file file (insert "one\ntwo\n"))
            (delete-other-windows)
            (let ((target (split-window-right))
                  (context `(:interface adapter :project-root ,root
                             :owner visible-owner)))
              (setq context (plist-put context :window target))
              (emacsctl-call "buffer.open" '((path . "visible.el")) context)
              (setq buffer (get-file-buffer file))
              (with-current-buffer buffer
                (goto-char (point-max))
                (push-mark (point-min) t t))
              (set-window-point target (point-min))
              (emacsctl-call
               "buffer.open" '((path . "visible.el") (line . 2) (column . 1))
               context)
              (should (= (window-point target)
                         (with-current-buffer buffer (point))))
              (should-not (buffer-local-value 'mark-active buffer))
              (set-window-buffer (selected-window) buffer)
              (should (emacsctl-release-owner 'visible-owner))
              (should (buffer-live-p buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest emacsctl-elisp-eval-is-hidden-and-disabled-by-default ()
  (emacsctl-tests--with-registry
    (let ((emacsctl-enable-elisp-eval nil))
      (should-not
       (seq-find (lambda (entry) (equal (alist-get 'name entry) "elisp.eval"))
                 (emacsctl-operations '(:interface cli))))
      (should-error
       (emacsctl-call "elisp.eval" '((code . "(+ 1 2)")) '(:interface cli))
       :type 'emacsctl-disabled-operation))
    (let ((emacsctl-enable-elisp-eval t))
      (should (equal (emacsctl-call
                      "elisp.eval" '((code . "(+ 1 2)")) '(:interface cli))
                     "3")))))

(ert-deftest emacsctl-dispatches-versioned-json-and-redacts-errors ()
  (emacsctl-tests--with-registry
    (emacsctl-register-operation
     "sample.fail" (lambda (_arguments _context) (error "secret detail"))
     :description "Fail." :effect 'read :parameters nil)
    (pcase-let* ((request (json-serialize
                           `((version . 1) (method . "call")
                             (operation . "sample.fail")
                             (arguments . ,(make-hash-table :test #'equal))
                             (cwd_base64 . "Lw=="))))
                 (`(,status . ,payload)
                  (emacsctl-tests--decode-dispatch
                   (emacsctl-server-dispatch
                    (base64-encode-string request t)))))
      (should (= status 5))
      (let ((response (json-parse-string payload :object-type 'alist
                                         :false-object nil)))
        (should-not (alist-get 'ok response))
        (should (equal (alist-get 'code (alist-get 'error response))
                       "internal_error"))
        (should-not (string-match-p "secret" payload))))
    (pcase-let* ((request (json-serialize
                           '((version . 2) (method . "operations")
                             (cwd_base64 . "Lw=="))))
                 (`(,status . ,payload)
                  (emacsctl-tests--decode-dispatch
                   (emacsctl-server-dispatch
                    (base64-encode-string request t)))))
      (should (= status 2))
      (should (string-match-p "unsupported_version" payload)))
    (dolist (arguments '("[]" "null"))
      (pcase-let* ((request
                    (format
                     "{\"version\":1,\"method\":\"call\",\"operation\":\"sample.fail\",\"arguments\":%s,\"cwd_base64\":\"Lw==\"}"
                     arguments))
                   (`(,status . ,payload)
                    (emacsctl-tests--decode-dispatch
                     (emacsctl-server-dispatch
                      (base64-encode-string request t)))))
        (should (= status 2))
        (should (string-match-p "invalid_request" payload))))))

(ert-deftest emacsctl-skill-reflects-the-live-operation-registry ()
  (emacsctl-tests--with-registry
    (emacsctl-register-operation
     "workspace.list" (lambda (_arguments _context) [])
     :description "List Doom workspaces." :effect 'read :parameters nil)
    (let ((skill (emacsctl-skill '(:interface cli))))
      (should (string-match-p "emacsctl call" skill))
      (should (string-match-p "workspace\\.list" skill))
      (should-not (string-match-p "elisp\\.eval" skill)))))

(ert-deftest emacsctl-launcher-frames-json-without-elisp-interpolation ()
  (let* ((directory (make-temp-file "emacsctl-cli" t))
         (client (expand-file-name "emacsclient" directory))
         (capture (expand-file-name "expression" directory))
         (launcher (expand-file-name
                    "bin/emacsctl"
                    (file-name-directory (locate-library "emacsctl-tests"))))
         (payload "{\"version\":1,\"ok\":true,\"result\":\"ok\"}")
         (response (format "\"0:%s\"\n" (base64-encode-string payload t))))
    (unwind-protect
        (progn
          (with-temp-file client
            (insert "#!/bin/sh\nprintf '%s' \"$2\" > \"$EMACSCTL_CAPTURE\"\nprintf '%s' \"$EMACSCTL_RESPONSE\"\n"))
          (set-file-modes client #o700)
          (let ((process-environment
                 (append (list (concat "EMACSCLIENT=" client)
                               (concat "EMACSCTL_CAPTURE=" capture)
                               (concat "EMACSCTL_RESPONSE=" response))
                         process-environment)))
            (with-temp-buffer
              (should (= (process-file launcher nil t nil
                                       "call" "sample.lookup"
                                       "{\"name\":\"');(error \\\"injected\\\");('\"}")
                         0))
              (should (equal (string-trim (buffer-string)) payload))))
          (with-temp-buffer
            (insert-file-contents capture)
            (let ((expression (buffer-string)))
              (should
               (string-match
                "(emacsctl-server-dispatch \\\"\\([A-Za-z0-9+/=]+\\)\\\")"
                expression))
              (should-not (string-match-p "injected" expression)))))
      (delete-directory directory t))))

(provide 'emacsctl-tests)
;;; emacsctl-tests.el ends here
