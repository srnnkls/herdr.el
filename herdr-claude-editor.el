;;; herdr-claude-editor.el --- Claude Emacs context and diffs -*- lexical-binding: t; -*-

;;; Commentary:

;; Implements Claude selection notifications and interactive Emacs diffs.

;;; Code:

(require 'cl-lib)
(require 'ediff)
(require 'emacsctl)
(require 'seq)

(defvar herdr-claude-editor--diffs (make-hash-table :test #'eq)
  "Deferred diffs indexed by opaque protocol owner.")
(defvar herdr-claude-editor--selection-timers (make-hash-table :test #'eq)
  "Selection debounce timers indexed by opaque protocol owner.")
(defvar herdr-claude-editor--selection-contexts (make-hash-table :test #'eq)
  "Last selection snapshots indexed by opaque protocol owner.")

(cl-defstruct herdr-claude-editor--diff
  "A deferred Emacs diff and its resources."
  owner request name proposed old old-owned-p completion control
  control-completion hook-removed-p response-sent-p proposed-released-p old-released-p
  control-released-p)

(cl-defstruct herdr-claude-editor-result
  "A normalized Emacs operation result."
  kind value)

(defconst herdr-claude-editor-deferred 'herdr-claude-editor-deferred)

(defun herdr-claude-editor--result (text)
  "Return a successful Emacs result containing TEXT."
  (make-herdr-claude-editor-result :kind 'text :value text))

(defun herdr-claude-editor-context-snapshot (&optional buffer)
  "Return BUFFER's normalized file and selection context."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((first (min (point) (if mark-active (mark) (point))))
           (last (max (point) (if mark-active (mark) (point))))
           (start-line (line-number-at-pos first))
           (end-line (line-number-at-pos last))
           (start-column (save-excursion (goto-char first) (current-column)))
           (end-column (save-excursion (goto-char last) (current-column))))
      (list :file buffer-file-name
            :text (buffer-substring-no-properties first last)
            :start-line (1- start-line) :start-column start-column
            :end-line (1- end-line) :end-column end-column))))

(defun herdr-claude-editor-mention (&optional buffer)
  "Return BUFFER's normalized at-mention location."
  (with-current-buffer (or buffer (current-buffer))
    (let ((first (min (point) (if mark-active (mark) (point))))
          (last (max (point) (if mark-active (mark) (point)))))
      (list :file buffer-file-name
            :start-line (line-number-at-pos first)
            :end-line (line-number-at-pos last)))))

(defun herdr-claude-editor-cancel-selection (owner)
  "Cancel OWNER's pending selection notification."
  (when-let* ((entry (gethash owner herdr-claude-editor--selection-timers)))
    (cancel-timer (cdr entry)))
  (remhash owner herdr-claude-editor--selection-timers)
  (remhash owner herdr-claude-editor--selection-contexts))

(defun herdr-claude-editor-schedule-selection
    (owner buffer root current-p callback)
  "Debounce BUFFER selection for OWNER below ROOT.
CURRENT-P validates ownership before CALLBACK receives a normalized snapshot."
  (let ((token (make-symbol "selection")))
    (when-let* ((previous (gethash owner herdr-claude-editor--selection-timers)))
      (cancel-timer (cdr previous)))
    (puthash
     owner
     (cons token
           (run-at-time
            0.1 nil
            (lambda ()
              (when-let* ((entry (gethash owner herdr-claude-editor--selection-timers))
                          ((eq token (car entry))))
                (remhash owner herdr-claude-editor--selection-timers)
                (if (and (funcall current-p) (buffer-live-p buffer))
                    (with-current-buffer buffer
                      (let ((file buffer-file-name))
                        (if (and file (emacsctl-project-file-p file root))
                            (let ((snapshot (herdr-claude-editor-context-snapshot buffer)))
                              (unless (equal snapshot
                                             (gethash owner
                                                      herdr-claude-editor--selection-contexts))
                                (puthash owner snapshot
                                         herdr-claude-editor--selection-contexts)
                                (funcall callback snapshot)))
                          (remhash owner herdr-claude-editor--selection-contexts))))
                  (remhash owner herdr-claude-editor--selection-contexts))))))
     herdr-claude-editor--selection-timers)))

(defun herdr-claude-editor--owner-diffs (owner)
  "Return deferred diffs owned by OWNER."
  (gethash owner herdr-claude-editor--diffs))

(defun herdr-claude-editor--track-diff (owner diff)
  "Track DIFF for OWNER."
  (puthash owner (cons diff (delq diff (gethash owner herdr-claude-editor--diffs)))
           herdr-claude-editor--diffs)
  diff)

(defun herdr-claude-editor--untrack-diff (diff)
  "Remove fully released DIFF from its owner state."
  (let ((owner (herdr-claude-editor--diff-owner diff)))
    (when (and (herdr-claude-editor--diff-response-sent-p diff)
               (herdr-claude-editor--diff-proposed-released-p diff)
               (herdr-claude-editor--diff-old-released-p diff)
               (herdr-claude-editor--diff-control-released-p diff))
      (let ((diffs (delq diff (gethash owner herdr-claude-editor--diffs))))
        (if diffs
            (puthash owner diffs herdr-claude-editor--diffs)
          (remhash owner herdr-claude-editor--diffs))))))

(defun herdr-claude-editor--remove-diff-hook (diff)
  "Remove completion hooks installed for DIFF."
  (unless (herdr-claude-editor--diff-hook-removed-p diff)
    (when-let* ((buffer (herdr-claude-editor--diff-proposed diff))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook
                     (herdr-claude-editor--diff-completion diff) t)))
    (when-let* ((buffer (herdr-claude-editor--diff-control diff))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (remove-hook 'ediff-after-quit-hook-internal
                     (herdr-claude-editor--diff-control-completion diff) t)))
    (setf (herdr-claude-editor--diff-hook-removed-p diff) t)))

(defun herdr-claude-editor--release-diff-resources (diff &optional killed)
  "Release DIFF resources, treating proposed buffers as killed when KILLED."
  (herdr-claude-editor--remove-diff-hook diff)
  (unless (herdr-claude-editor--diff-control-released-p diff)
    (let ((control (herdr-claude-editor--diff-control diff)))
      (if (not (buffer-live-p control))
          (setf (herdr-claude-editor--diff-control-released-p diff) t)
        (setf (herdr-claude-editor--diff-control-released-p diff) t)
        (condition-case err
            (with-current-buffer control
              (let ((ediff-control-buffer control))
                (ediff-really-quit nil)))
          (error
           (setf (herdr-claude-editor--diff-control-released-p diff) nil)
           (signal (car err) (cdr err))))
        (unless (buffer-live-p control)
          (setq ediff-session-registry (delq control ediff-session-registry))
          (dolist (buffer (list (herdr-claude-editor--diff-old diff)
                                (herdr-claude-editor--diff-proposed diff)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq ediff-this-buffer-ediff-sessions
                      (delq control ediff-this-buffer-ediff-sessions))))))
        (setf (herdr-claude-editor--diff-control-released-p diff)
              (not (buffer-live-p control))))))
  (unless (herdr-claude-editor--diff-proposed-released-p diff)
    (let ((buffer (herdr-claude-editor--diff-proposed diff)))
      (if (or killed (not (buffer-live-p buffer)))
          (setf (herdr-claude-editor--diff-proposed-released-p diff) t)
        (kill-buffer buffer)
        (setf (herdr-claude-editor--diff-proposed-released-p diff)
              (not (buffer-live-p buffer))))))
  (unless (herdr-claude-editor--diff-old-released-p diff)
    (let ((old (herdr-claude-editor--diff-old diff)))
      (if (and (herdr-claude-editor--diff-old-owned-p diff)
               (buffer-live-p old) (not (buffer-modified-p old))
               (null (get-buffer-window-list old nil 0)))
          (progn
            (kill-buffer old)
            (setf (herdr-claude-editor--diff-old-released-p diff)
                  (not (buffer-live-p old))))
        (setf (herdr-claude-editor--diff-old-released-p diff) t)))))

(defun herdr-claude-editor--finish-diff
    (diff &optional result killed cancelled)
  "Complete DIFF with RESULT, then release its resources.
KILLED records an already killed proposed buffer.  When CANCELLED is non-nil,
reject the pending request."
  (unless (herdr-claude-editor--diff-response-sent-p diff)
    (let* ((request (herdr-claude-editor--diff-request diff))
           (callback (plist-get request (if cancelled :cancel :resolve))))
      (when callback
        (condition-case nil
            (funcall callback result)
          (error nil)))
      (setf (herdr-claude-editor--diff-response-sent-p diff) t)))
  (herdr-claude-editor--release-diff-resources diff killed)
  (herdr-claude-editor--untrack-diff diff)
  (and (herdr-claude-editor--diff-response-sent-p diff)
       (herdr-claude-editor--diff-proposed-released-p diff)
       (herdr-claude-editor--diff-old-released-p diff)
       (herdr-claude-editor--diff-control-released-p diff)))

(defun herdr-claude-editor--complete-diff (diff accept &optional killed)
  "Complete DIFF as ACCEPT, with optional KILLED proposed buffer."
  (herdr-claude-editor--finish-diff
   diff
   (herdr-claude-editor--result
    (if accept
        (if (buffer-live-p (herdr-claude-editor--diff-proposed diff))
            (with-current-buffer (herdr-claude-editor--diff-proposed diff)
              (buffer-string))
          "")
      "Diff rejected"))
   killed))

(defun herdr-claude-editor--find-diff (owner name)
  "Return OWNER's deferred diff named NAME."
  (seq-find (lambda (diff)
              (and (herdr-claude-editor--diff-p diff)
                   (equal name (herdr-claude-editor--diff-name diff))))
            (herdr-claude-editor--owner-diffs owner)))

(defun herdr-claude-editor-accept-diff (owner name)
  "Accept OWNER's deferred diff named NAME."
  (when-let* ((diff (herdr-claude-editor--find-diff owner name)))
    (herdr-claude-editor--complete-diff diff t)))

(defun herdr-claude-editor-reject-diff (owner name)
  "Reject OWNER's deferred diff named NAME."
  (when-let* ((diff (herdr-claude-editor--find-diff owner name)))
    (herdr-claude-editor--complete-diff diff nil)))

(defun herdr-claude-editor--cancel-diff (diff)
  "Cancel DIFF and release its resources."
  (herdr-claude-editor--finish-diff diff nil nil t))

(defun herdr-claude-editor-cancel (owner)
  "Cancel diffs, selections, and buffers owned by opaque OWNER."
  (herdr-claude-editor-cancel-selection owner)
  (let ((diffs-released t))
    (dolist (diff (copy-sequence (herdr-claude-editor--owner-diffs owner)))
      (when (and (herdr-claude-editor--diff-p diff)
                 (not (herdr-claude-editor--cancel-diff diff)))
        (setq diffs-released nil)))
    (and diffs-released
         (null (herdr-claude-editor--owner-diffs owner))
         (emacsctl-release-owner owner))))

(defun herdr-claude-editor--bind-diff-control (diff control)
  "Associate DIFF with Ediff CONTROL and install completion handling."
  (setf (herdr-claude-editor--diff-control diff) control)
  (if (herdr-claude-editor--diff-response-sent-p diff)
      (herdr-claude-editor--release-diff-resources diff)
    (when (and control (buffer-live-p control))
      (setf (herdr-claude-editor--diff-control-released-p diff) nil)
      (with-current-buffer control
        (add-hook 'ediff-after-quit-hook-internal
                  (herdr-claude-editor--diff-control-completion diff) nil t)))
    (unless (and control (buffer-live-p control))
      (setf (herdr-claude-editor--diff-control-released-p diff) t)))
  diff)

(defun herdr-claude-editor--start-ediff (diff old proposed)
  "Start Ediff for DIFF between OLD and PROPOSED buffers."
  (let ((capture
         (lambda ()
           (herdr-claude-editor--bind-diff-control diff ediff-control-buffer))))
    (add-hook 'ediff-startup-hook capture)
    (unwind-protect
        (progn
          (ediff-buffers old proposed)
          nil)
      (remove-hook 'ediff-startup-hook capture))))

(defun herdr-claude-editor--open-diff (owner root arguments request)
  "Open ARGUMENTS as a deferred diff below ROOT for OWNER and REQUEST."
  (let* ((old-path (emacsctl-project-path (plist-get arguments :old-path) root))
         (new (emacsctl-project-path (plist-get arguments :new-path) root))
         (contents (plist-get arguments :contents))
         (name (plist-get arguments :name)))
    (if (not (and old-path new (stringp contents) (stringp name) request))
        (signal 'emacsctl-operation-failed
                '("Diff paths are outside the project"))
      (let* ((old-existing (get-file-buffer old-path))
             (old (or old-existing (find-file-noselect old-path)))
             (proposed (generate-new-buffer (format " *herdr diff %s*" name)))
             (diff (make-herdr-claude-editor--diff
                    :owner owner :request request :name name
                    :proposed proposed :old old :old-owned-p (null old-existing))))
        (with-current-buffer proposed (insert contents))
        (let ((completion (lambda () (herdr-claude-editor--complete-diff diff t t)))
              (control-completion (lambda () (herdr-claude-editor--cancel-diff diff))))
          (setf (herdr-claude-editor--diff-completion diff) completion
                (herdr-claude-editor--diff-control-completion diff) control-completion)
          (with-current-buffer proposed (add-hook 'kill-buffer-hook completion nil t)))
        (herdr-claude-editor--track-diff owner diff)
        (condition-case err
            (let ((control (herdr-claude-editor--start-ediff diff old proposed)))
              (unless (herdr-claude-editor--diff-control diff)
                (herdr-claude-editor--bind-diff-control diff control))
              herdr-claude-editor-deferred)
          (error
           (if (herdr-claude-editor--diff-response-sent-p diff)
               herdr-claude-editor-deferred
             (setf (herdr-claude-editor--diff-response-sent-p diff) t)
             (condition-case nil
                 (herdr-claude-editor--finish-diff diff)
               (error nil))
             (signal (car err) (cdr err)))))))))

(defun herdr-claude-editor--close-diffs (owner &optional name)
  "Close OWNER diffs, optionally limited to NAME."
  (dolist (diff (copy-sequence (herdr-claude-editor--owner-diffs owner)))
    (when (and (herdr-claude-editor--diff-p diff)
               (or (null name)
                   (equal name (herdr-claude-editor--diff-name diff))))
      (herdr-claude-editor--cancel-diff diff)))
  (herdr-claude-editor--result "Closed diffs"))

(defun herdr-claude-editor--diff-open-operation (arguments context)
  "Open a diff from ARGUMENTS using adapter CONTEXT."
  (herdr-claude-editor--open-diff
   (plist-get context :owner)
   (plist-get context :project-root)
   (list :old-path (alist-get 'old_path arguments)
         :new-path (alist-get 'new_path arguments)
         :contents (alist-get 'contents arguments)
         :name (alist-get 'name arguments))
   (list :resolve (plist-get context :resolve)
         :cancel (plist-get context :cancel))))

(defun herdr-claude-editor--diff-close-operation (arguments context)
  "Close the diff in ARGUMENTS using adapter CONTEXT."
  (herdr-claude-editor--close-diffs
   (plist-get context :owner) (alist-get 'name arguments)))

(defun herdr-claude-editor--diff-close-all-operation (_arguments context)
  "Close all diffs owned by adapter CONTEXT."
  (herdr-claude-editor--close-diffs (plist-get context :owner)))

(emacsctl-register-operation
 "diff.open" #'herdr-claude-editor--diff-open-operation
 :description "Open an editable Emacs diff."
 :effect 'write :interfaces '(adapter) :deferred t
 :parameters '((:name "old_path" :type string :required t)
               (:name "new_path" :type string :required t)
               (:name "contents" :type string :required t)
               (:name "name" :type string :required t)))

(emacsctl-register-operation
 "diff.close" #'herdr-claude-editor--diff-close-operation
 :description "Close an adapter-owned Emacs diff."
 :effect 'write :interfaces '(adapter)
 :parameters '((:name "name" :type string :required t)))

(emacsctl-register-operation
 "diff.close-all" #'herdr-claude-editor--diff-close-all-operation
 :description "Close all adapter-owned Emacs diffs."
 :effect 'write :interfaces '(adapter) :parameters nil)

(provide 'herdr-claude-editor)
;;; herdr-claude-editor.el ends here
