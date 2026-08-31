;;; herdr-claude-editor-tests.el --- Claude Emacs context tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'herdr-claude-editor)

(defmacro herdr-claude-editor-tests--with-state (&rest body)
  (declare (indent 0) (debug t))
  `(let ((emacsctl--buffers (make-hash-table :test #'eq))
         (herdr-claude-editor--diffs (make-hash-table :test #'eq))
         (herdr-claude-editor--selection-timers (make-hash-table :test #'eq))
         (herdr-claude-editor--selection-contexts (make-hash-table :test #'eq)))
     ,@body))

(defun herdr-claude-editor-tests--fire (timer)
  (apply (car timer) (cadr timer)))

(ert-deftest herdr-claude-editor-diffs-resolve-through-the-operation-registry ()
  (herdr-claude-editor-tests--with-state
    (let* ((root (make-temp-file "herdr-emacs-diff" t))
           (old-file (expand-file-name "old.el" root))
           (new-file (expand-file-name "new.el" root))
           (owner (make-symbol "owner"))
           resolved
           cancelled)
      (unwind-protect
          (progn
            (with-temp-file old-file (insert "old\n"))
            (cl-letf (((symbol-function 'herdr-claude-editor--start-ediff)
                       (lambda (&rest _) nil)))
              (should
               (eq (emacsctl-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "proposed") (name . "accept"))
                    `(:interface adapter :owner ,owner :project-root ,root
                      :resolve ,(lambda (result) (push result resolved))
                      :cancel ,(lambda (result) (push result cancelled))))
                   herdr-claude-editor-deferred))
              (let* ((diff (car (herdr-claude-editor--owner-diffs owner)))
                     (proposed (herdr-claude-editor--diff-proposed diff)))
                (with-current-buffer proposed
                  (erase-buffer)
                  (insert "edited proposal"))
                (should (herdr-claude-editor-accept-diff owner "accept"))
                (should-not (buffer-live-p proposed)))
              (should
               (eq (emacsctl-call
                    "diff.open"
                    `((old_path . ,old-file) (new_path . ,new-file)
                      (contents . "rejected") (name . "reject"))
                    `(:interface adapter :owner ,owner :project-root ,root
                      :resolve ,(lambda (result) (push result resolved))
                      :cancel ,(lambda (result) (push result cancelled))))
                   herdr-claude-editor-deferred))
              (should (herdr-claude-editor-reject-diff owner "reject")))
            (should-not cancelled)
            (should
             (equal (mapcar #'herdr-claude-editor-result-value
                            (nreverse resolved))
                    '("edited proposal" "Diff rejected")))
            (should-not (herdr-claude-editor--owner-diffs owner)))
        (herdr-claude-editor-cancel owner)
        (when-let* ((buffer (get-file-buffer old-file))) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest herdr-claude-editor-cancel-is-owner-local-and-retryable ()
  (herdr-claude-editor-tests--with-state
    (let* ((first (make-symbol "first-owner"))
           (second (make-symbol "second-owner"))
           (first-timer (list 'first))
           (second-timer (list 'second))
           (first-cancellations 0)
           (second-cancellations 0)
           cancelled)
      (puthash first (cons 'first-token first-timer)
               herdr-claude-editor--selection-timers)
      (puthash second (cons 'second-token second-timer)
               herdr-claude-editor--selection-timers)
      (puthash
       first
       (list (make-herdr-claude-editor--diff
              :owner first :name "first"
              :request (list :cancel (lambda (_result)
                                       (cl-incf first-cancellations)))
              :proposed-released-p t :old-released-p t
              :control-released-p t))
       herdr-claude-editor--diffs)
      (puthash
       second
       (list (make-herdr-claude-editor--diff
              :owner second :name "second"
              :request (list :cancel (lambda (_result)
                                       (cl-incf second-cancellations)))
              :proposed-released-p t :old-released-p t
              :control-released-p t))
       herdr-claude-editor--diffs)
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled))))
        (should (herdr-claude-editor-cancel first))
        (should (equal cancelled (list first-timer)))
        (should (= first-cancellations 1))
        (should (= second-cancellations 0))
        (should-not (gethash first herdr-claude-editor--diffs))
        (should (gethash second herdr-claude-editor--diffs))
        (should (gethash second herdr-claude-editor--selection-timers))
        (should (herdr-claude-editor-cancel second))
        (should (= second-cancellations 1)))
      (let* ((third (make-symbol "third-owner"))
             (proposed (generate-new-buffer " *herdr-cancel-veto*"))
             (veto (lambda () nil))
             (diff (make-herdr-claude-editor--diff
                    :owner third :name "third"
                    :request (list :cancel #'ignore)
                    :proposed proposed :old-released-p t
                    :control-released-p t)))
        (with-current-buffer proposed
          (add-hook 'kill-buffer-query-functions veto nil t))
        (puthash third (list diff) herdr-claude-editor--diffs)
        (should-not (herdr-claude-editor-cancel third))
        (should (equal (gethash third herdr-claude-editor--diffs)
                       (list diff)))
        (with-current-buffer proposed
          (remove-hook 'kill-buffer-query-functions veto t))
        (should (herdr-claude-editor-cancel third))
        (should-not (buffer-live-p proposed))))))

(ert-deftest herdr-claude-editor-selection-debounces-and-deduplicates-snapshots ()
  (herdr-claude-editor-tests--with-state
    (let* ((root (make-temp-file "herdr-emacs-selection" t))
           (file (expand-file-name "selection.el" root))
           (owner (make-symbol "owner"))
           buffer timers cancelled callbacks)
      (unwind-protect
          (progn
            (with-temp-file file (insert "first\nsecond\n"))
            (setq buffer (find-file-noselect file))
            (with-current-buffer buffer
              (goto-char (point-min))
              (set-mark (line-end-position))
              (setq mark-active t))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_delay _repeat callback &rest arguments)
                         (let ((timer (list callback arguments)))
                           (push timer timers)
                           timer)))
                      ((symbol-function 'cancel-timer)
                       (lambda (timer) (push timer cancelled))))
              (herdr-claude-editor-schedule-selection
               owner buffer root (lambda () t)
               (lambda (snapshot) (push snapshot callbacks)))
              (let ((superseded (car timers)))
                (herdr-claude-editor-schedule-selection
                 owner buffer root (lambda () t)
                 (lambda (snapshot) (push snapshot callbacks)))
                (should (equal cancelled (list superseded)))
                (herdr-claude-editor-tests--fire superseded)
                (should-not callbacks))
              (herdr-claude-editor-tests--fire (car timers))
              (should (= (length callbacks) 1))
              (should (equal (plist-get (car callbacks) :file) file))
              (herdr-claude-editor-schedule-selection
               owner buffer root (lambda () t)
               (lambda (snapshot) (push snapshot callbacks)))
              (herdr-claude-editor-tests--fire (car timers))
              (should (= (length callbacks) 1))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory root t)))))

(provide 'herdr-claude-editor-tests)
;;; herdr-claude-editor-tests.el ends here
