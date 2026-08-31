;;; herdr-claude-editor-tests.el --- Claude IDE editor tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'flymake)
(require 'herdr-claude-editor)

(defmacro herdr-claude-editor-tests--with-registries (&rest body)
  (declare (indent 0) (debug t))
  `(let ((herdr-claude-editor--views (make-hash-table :test #'eq))
         (herdr-claude-editor--diffs (make-hash-table :test #'eq))
         (herdr-claude-editor--selection-timers (make-hash-table :test #'eq))
         (herdr-claude-editor--selection-contexts (make-hash-table :test #'eq)))
     ,@body))

(defun herdr-claude-editor-tests--result-value (result)
  (and (herdr-claude-editor-result-p result)
       (herdr-claude-editor-result-value result)))

(defun herdr-claude-editor-tests--fire (timer)
  (apply (car timer) (cadr timer)))

(ert-deftest herdr-claude-editor-confines-paths-to-the-project-root ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (file-truename (make-temp-file "herdr-editor-root" t)))
           (inside (expand-file-name "lib/inside.el" root))
           (outside (make-temp-file "herdr-editor-outside"))
           (link (expand-file-name "linked.el" root))
           (linked-directory (expand-file-name "linked-directory" root)))
      (unwind-protect
          (progn
            (make-directory (file-name-directory inside) t)
            (with-temp-file inside (insert "inside\n"))
            (make-symbolic-link outside link)
            (make-symbolic-link (file-name-directory outside) linked-directory)
            (should (equal (herdr-claude-editor--path "lib/inside.el" root)
                           inside))
            (should (equal (herdr-claude-editor--path inside root) inside))
            (should-not (herdr-claude-editor--path "../escaped.el" root))
            (should-not (herdr-claude-editor--path outside root))
            (should-not (herdr-claude-editor--path link root))
            (should-not
             (herdr-claude-editor--path
              (expand-file-name (file-name-nondirectory outside) linked-directory)
              root))
            (should-not (herdr-claude-editor--path 7 root)))
        (delete-directory root t)
        (when (file-exists-p outside) (delete-file outside))))))

(ert-deftest herdr-claude-editor-open-and-close-preserves-shared-views ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (make-temp-file "herdr-editor-views" t))
           (file (expand-file-name "shared.el" root))
           (first (make-symbol "first-owner"))
           (second (make-symbol "second-owner"))
           buffer)
      (unwind-protect
          (save-window-excursion
            (with-temp-file file (insert "one\ntwo\nthree\n"))
            (let ((opened
                   (herdr-claude-editor-dispatch
                    first root 'open-file
                    '(:path "shared.el" :start-line 2 :end-line 2) nil)))
              (should (eq (herdr-claude-editor-result-kind opened) 'text))
              (should (equal (herdr-claude-editor-tests--result-value opened)
                             "Opened file")))
            (setq buffer (get-file-buffer file))
            (should (buffer-live-p buffer))
            (with-current-buffer buffer
              (should (equal (buffer-substring-no-properties
                              (region-beginning) (region-end))
                             "two")))
            (herdr-claude-editor-dispatch
             first root 'open-file '(:path "shared.el") nil)
            (herdr-claude-editor-dispatch
             second root 'open-file '(:path "shared.el") nil)
            (should (herdr-claude-editor-view-member-p first file))
            (should (herdr-claude-editor-view-member-p second file))
            (herdr-claude-editor-dispatch
             first root 'close-tab '(:path "shared.el") nil)
            (should-not (herdr-claude-editor-view-member-p first file))
            (should (herdr-claude-editor-view-member-p second file))
            (should (buffer-live-p buffer))
            (herdr-claude-editor-dispatch
             second root 'close-tab `(:path ,file) nil)
            (should-not (herdr-claude-editor-view-member-p second file))
            (should-not (buffer-live-p buffer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest herdr-claude-editor-cancel-is-owner-local ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (make-temp-file "herdr-editor-cancel" t))
           (first-file (expand-file-name "first.el" root))
           (second-file (expand-file-name "second.el" root))
           (first (make-symbol "first-owner"))
           (second (make-symbol "second-owner"))
           (first-timer (list 'first))
           (second-timer (list 'second))
           cancelled
           (first-cancellations 0)
           (second-cancellations 0))
      (unwind-protect
          (save-window-excursion
            (with-temp-file first-file (insert "first\n"))
            (with-temp-file second-file (insert "second\n"))
            (herdr-claude-editor-dispatch
             first root 'open-file '(:path "first.el") nil)
            (herdr-claude-editor-dispatch
             second root 'open-file '(:path "second.el") nil)
            (puthash first (cons 'first-token first-timer)
                     herdr-claude-editor--selection-timers)
            (puthash second (cons 'second-token second-timer)
                     herdr-claude-editor--selection-timers)
            (puthash first 'first-context
                     herdr-claude-editor--selection-contexts)
            (puthash second 'second-context
                     herdr-claude-editor--selection-contexts)
            (puthash
             first
             (list
              (make-herdr-claude-editor--diff
               :owner first :tab-name "first"
               :request (list :cancel
                              (lambda (_result)
                                (cl-incf first-cancellations)))
               :proposed-released-p t :old-released-p t
               :control-released-p t))
             herdr-claude-editor--diffs)
            (puthash
             second
             (list
              (make-herdr-claude-editor--diff
               :owner second :tab-name "second"
               :request (list :cancel
                              (lambda (_result)
                                (cl-incf second-cancellations)))
               :proposed-released-p t :old-released-p t
               :control-released-p t))
             herdr-claude-editor--diffs)
            (cl-letf (((symbol-function 'cancel-timer)
                       (lambda (timer) (push timer cancelled))))
              (herdr-claude-editor-cancel first)
              (should (equal cancelled (list first-timer)))
              (should (= first-cancellations 1))
              (should (= second-cancellations 0))
              (should-not (gethash first herdr-claude-editor--views))
              (should (gethash second herdr-claude-editor--views))
              (should-not (gethash first herdr-claude-editor--diffs))
              (should (gethash second herdr-claude-editor--diffs))
              (should-not
               (gethash first herdr-claude-editor--selection-timers))
              (should
               (gethash second herdr-claude-editor--selection-timers))
              (should-not
               (gethash first herdr-claude-editor--selection-contexts))
              (should (eq (gethash second
                                   herdr-claude-editor--selection-contexts)
                          'second-context))
              (herdr-claude-editor-cancel second)
              (should (= second-cancellations 1))
              (let* ((third (make-symbol "third-owner"))
                     (proposed (generate-new-buffer " *herdr-cancel-veto*"))
                     (veto (lambda () nil))
                     (diff
                      (make-herdr-claude-editor--diff
                       :owner third :tab-name "third"
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
                (should-not (gethash third herdr-claude-editor--diffs))
                (should-not (buffer-live-p proposed)))))
        (dolist (file (list first-file second-file))
          (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer)))
        (delete-directory root t)))))

(ert-deftest herdr-claude-editor-deferred-diffs-accept-edits-and-reject-distinctly ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (make-temp-file "herdr-editor-diff" t))
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
               (eq (herdr-claude-editor--open-diff
                    owner root
                    `(:old-path ,old-file :new-path ,new-file
                      :contents "proposed" :tab-name "accept")
                    (list :resolve (lambda (result) (push result resolved))
                          :cancel (lambda (result) (push result cancelled))))
                   herdr-claude-editor-deferred))
              (let* ((diff (car (herdr-claude-editor--owner-diffs owner)))
                     (proposed (herdr-claude-editor--diff-proposed diff)))
                (with-current-buffer proposed
                  (erase-buffer)
                  (insert "edited proposal"))
                (should (herdr-claude-editor-accept-diff owner "accept"))
                (should-not (buffer-live-p proposed)))
              (should
               (eq (herdr-claude-editor--open-diff
                    owner root
                    `(:old-path ,old-file :new-path ,new-file
                      :contents "rejected proposal" :tab-name "reject")
                    (list :resolve (lambda (result) (push result resolved))
                          :cancel (lambda (result) (push result cancelled))))
                   herdr-claude-editor-deferred))
              (let* ((diff (car (herdr-claude-editor--owner-diffs owner)))
                     (proposed (herdr-claude-editor--diff-proposed diff)))
                (should (herdr-claude-editor-reject-diff owner "reject"))
                (should-not (buffer-live-p proposed))))
            (should-not cancelled)
            (should
             (equal (mapcar #'herdr-claude-editor-tests--result-value
                            (nreverse resolved))
                    '("edited proposal" "Diff rejected")))
            (should-not (herdr-claude-editor--owner-diffs owner)))
        (herdr-claude-editor-cancel owner)
        (when-let* ((buffer (get-file-buffer old-file))) (kill-buffer buffer))
        (delete-directory root t)))))


(ert-deftest herdr-claude-editor-rolls-back-a-failed-diff-start ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (make-temp-file "herdr-editor-rollback" t))
           (old-file (expand-file-name "old.el" root))
           (new-file (expand-file-name "new.el" root))
           (owner (make-symbol "owner"))
           resolved
           cancelled)
      (unwind-protect
          (progn
            (with-temp-file old-file (insert "old\n"))
            (cl-letf (((symbol-function 'herdr-claude-editor--start-ediff)
                       (lambda (&rest _) (error "ediff startup failed"))))
              (should-error
               (herdr-claude-editor--open-diff
                owner root
                `(:old-path ,old-file :new-path ,new-file
                  :contents "new" :tab-name "failed")
                (list :resolve (lambda (result) (push result resolved))
                      :cancel (lambda (result) (push result cancelled))))
               :type 'error))
            (should-not resolved)
            (should-not cancelled)
            (should-not (herdr-claude-editor--owner-diffs owner))
            (should-not (get-file-buffer old-file))
            (should-not
             (seq-find
              (lambda (buffer)
                (string-match-p "herdr diff failed" (buffer-name buffer)))
              (buffer-list))))
        (herdr-claude-editor-cancel owner)
        (when-let* ((buffer (get-file-buffer old-file))) (kill-buffer buffer))
        (delete-directory root t)))))

(ert-deftest herdr-claude-editor-execute-requires-explicit-opt-in ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root default-directory)
           (owner (make-symbol "owner"))
           (marker 'herdr-claude-editor-tests--execution-marker)
           (had-value (plist-member (symbol-plist marker) 'value))
           (old-value (get marker 'value))
           (code
            "(put 'herdr-claude-editor-tests--execution-marker 'value \"ran\")\n(concat (get 'herdr-claude-editor-tests--execution-marker 'value) \" done\")"))
      (unwind-protect
          (progn
            (cl-remprop marker 'value)
            (let ((herdr-claude-enable-elisp-tool nil))
              (let ((result
                     (herdr-claude-editor-dispatch
                      owner root 'execute (list :code code) nil)))
                (should (eq (car result)
                            herdr-claude-editor--invalid-params))
                (should-not (get marker 'value))))
            (let ((herdr-claude-enable-elisp-tool t))
              (let ((result
                     (herdr-claude-editor-dispatch
                      owner root 'execute (list :code code) nil)))
                (should (eq (herdr-claude-editor-result-kind result) 'text))
                (should (equal (herdr-claude-editor-tests--result-value result)
                               "ran done"))
                (should (equal (get marker 'value) "ran")))))
        (if had-value
            (put marker 'value old-value)
          (cl-remprop marker 'value))))))

(ert-deftest herdr-claude-editor-normalizes-flymake-plain-and-flycheck-diagnostics ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (file-truename (make-temp-file "herdr-editor-diagnostics" t)))
           (outside-root
            (file-truename (make-temp-file "herdr-editor-diagnostics-outside" t)))
           (file (expand-file-name "visited.el" root))
           (outside-file (expand-file-name "outside.el" outside-root))
           visited
           outside
           flymake-record
           called)
      (unwind-protect
          (progn
            (with-temp-file file (insert "one\ntwo\nthree\nfour\n"))
            (with-temp-file outside-file (insert "outside\n"))
            (setq visited (find-file-noselect file)
                  outside (find-file-noselect outside-file))
            (with-current-buffer visited
              (goto-char (point-min))
              (forward-line 1)
              (forward-char 1)
              (setq flymake-record
                    (flymake-make-diagnostic
                     visited (point) (1+ (point)) :error "flymake error")))
            (cl-letf (((symbol-function 'flycheck-error-message)
                       (lambda (record) (plist-get record :message)))
                      ((symbol-function 'flycheck-error-line)
                       (lambda (record) (plist-get record :line)))
                      ((symbol-function 'flycheck-error-column)
                       (lambda (record) (plist-get record :column)))
                      ((symbol-function 'flycheck-error-level)
                       (lambda (record) (plist-get record :level))))
              (let ((diagnostics
                     (herdr-claude-editor-collect-diagnostics
                      `((flymake . ,(lambda (buffer)
                                      (push (cons 'flymake buffer) called)
                                      (list flymake-record)))
                        (plain . ,(lambda (buffer)
                                    (push (cons 'plain buffer) called)
                                    '((:message "plain issue" :line 3 :column 4))))
                        (flycheck . ,(lambda (buffer)
                                       (push (cons 'flycheck buffer) called)
                                       '((:message "flycheck warning"
                                          :line 4 :column 2 :level warning)))))
                      (list visited outside (generate-new-buffer
                                             " *herdr non-file diagnostics*"))
                      root)))
                (should
                 (equal diagnostics
                        `((:file ,file :message "flymake error"
                           :line 2 :column 1 :severity "error")
                          (:file ,file :message "plain issue"
                           :line 3 :column 4 :severity "info")
                          (:file ,file :message "flycheck warning"
                           :line 4 :column 2 :severity "warning"))))
                (should (= (length called) 3))
                (should (cl-every (lambda (entry) (eq (cdr entry) visited))
                                  called))
                (should
                 (equal (sort (mapcar #'car called)
                              (lambda (left right)
                                (string< (symbol-name left)
                                         (symbol-name right))))
                        '(flycheck flymake plain))))))
        (dolist (buffer (buffer-list))
          (when (or (eq buffer visited) (eq buffer outside)
                    (string= (buffer-name buffer)
                             " *herdr non-file diagnostics*"))
            (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory outside-root t)))))

(ert-deftest herdr-claude-editor-diagnostics-use-only-visited-project-buffers ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (file-truename (make-temp-file "herdr-editor-visited" t)))
           (outside-root
            (file-truename (make-temp-file "herdr-editor-visited-outside" t)))
           (file (expand-file-name "visited.el" root))
           (unvisited-file (expand-file-name "unvisited.el" root))
           (outside-file (expand-file-name "outside.el" outside-root))
           (non-file (generate-new-buffer " *herdr diagnostics non-file*"))
           visited
           outside
           boundary)
      (unwind-protect
          (progn
            (with-temp-file file (insert "visited\n"))
            (with-temp-file unvisited-file (insert "unvisited\n"))
            (with-temp-file outside-file (insert "outside\n"))
            (setq visited (find-file-noselect file)
                  outside (find-file-noselect outside-file))
            (cl-letf (((symbol-function 'buffer-list)
                       (lambda () (list visited outside non-file)))
                      ((symbol-function
                        'herdr-claude-editor-collect-diagnostics)
                       (lambda (providers buffers project)
                         (setq boundary (list providers buffers project))
                         (list (list :file file :message "visited")))))
              (let ((result
                     (herdr-claude-editor-dispatch
                      (make-symbol "owner") root 'diagnostics
                      (list :uri (concat "file://" unvisited-file)) nil)))
                (should (eq (herdr-claude-editor-result-kind result)
                            'diagnostics))
                (should
                 (equal (append (herdr-claude-editor-result-value result) nil)
                        (list (list :file file :message "visited"))))))
            (should (equal (mapcar #'car (car boundary))
                           '(flymake flycheck)))
            (should (equal (cadr boundary) (list visited)))
            (should (equal (caddr boundary) root))
            (should-not (get-file-buffer unvisited-file)))
        (dolist (buffer (list visited outside non-file))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (delete-directory root t)
        (delete-directory outside-root t)))))


(ert-deftest herdr-claude-editor-selection-debounces-and-deduplicates-snapshots ()
  (herdr-claude-editor-tests--with-registries
    (let* ((root (make-temp-file "herdr-editor-selection" t))
           (file (expand-file-name "selection.el" root))
           (owner (make-symbol "owner"))
           buffer
           timers
           cancelled
           callbacks)
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
              (should-not
               (gethash owner herdr-claude-editor--selection-timers))
              (herdr-claude-editor-schedule-selection
               owner buffer root (lambda () t)
               (lambda (snapshot) (push snapshot callbacks)))
              (herdr-claude-editor-tests--fire (car timers))
              (should (= (length callbacks) 1))
              (should (= (hash-table-count
                          herdr-claude-editor--selection-contexts)
                         1))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory root t)))))



(provide 'herdr-claude-editor-tests)
;;; herdr-claude-editor-tests.el ends here
