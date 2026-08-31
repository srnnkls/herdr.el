;;; herdr-claude-editor.el --- Claude editor operations for Herdr -*- lexical-binding: t; -*-

;;; Commentary:

;; Implements Claude file, diagnostic, diff, and evaluation operations.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ediff)
(require 'flymake)

(declare-function flycheck-error-message "flycheck" (error))
(declare-function flycheck-error-line "flycheck" (error))
(declare-function flycheck-error-column "flycheck" (error))
(declare-function flycheck-error-level "flycheck" (error))

(defcustom herdr-claude-enable-elisp-tool nil
  "Whether the evaluation tool may run Emacs Lisp."
  :type 'boolean
  :group 'herdr-claude)

(defvar herdr-claude-editor--views (make-hash-table :test #'eq)
  "Views indexed by opaque protocol owner.")
(defvar herdr-claude-editor--diffs (make-hash-table :test #'eq)
  "Deferred diffs indexed by opaque protocol owner.")
(defvar herdr-claude-editor--selection-timers (make-hash-table :test #'eq)
  "Selection debounce timers indexed by opaque protocol owner.")
(defvar herdr-claude-editor--selection-contexts (make-hash-table :test #'eq)
  "Last selection snapshots indexed by opaque protocol owner.")

(cl-defstruct herdr-claude-editor--view
  "A file view owned by one protocol owner."
  buffer window owned-buffer-p)

(cl-defstruct herdr-claude-editor--diff
  "A deferred editor diff and its resources."
  owner request tab-name proposed old old-owned-p completion control
  control-completion hook-removed-p response-sent-p proposed-released-p old-released-p
  control-released-p)

(cl-defstruct herdr-claude-editor-result
  "A normalized editor operation result."
  kind value)

(defconst herdr-claude-editor--invalid-params 'herdr-claude-editor--invalid-params)
(defconst herdr-claude-editor-deferred 'herdr-claude-editor-deferred)

(defun herdr-claude-editor--invalid (&optional message)
  "Return an invalid-parameters result with optional MESSAGE."
  (cons herdr-claude-editor--invalid-params (or message "Invalid params")))

(defun herdr-claude-editor--path (value root)
  "Return VALUE as a regular path below ROOT, or nil."
  (when (stringp value)
    (let ((path (expand-file-name value root)))
      (when (and (file-in-directory-p path root)
                 (not (file-symlink-p path)))
        path))))

(defun herdr-claude-editor--view-table (owner &optional create)
  "Return OWNER's view table, creating it when CREATE is non-nil."
  (or (gethash owner herdr-claude-editor--views)
      (and create
           (puthash owner (make-hash-table :test #'equal)
                    herdr-claude-editor--views))))

(defun herdr-claude-editor-view-member-p (owner file)
  "Return non-nil when OWNER owns a view of FILE."
  (when-let* ((views (herdr-claude-editor--view-table owner))
              (view (gethash (expand-file-name file) views)))
    view))

(defun herdr-claude-editor--result (text)
  "Return a successful editor result containing TEXT."
  (make-herdr-claude-editor-result :kind 'text :value text))

(defun herdr-claude-editor--selection (buffer start end start-text end-text)
  "Select a region in BUFFER using START, END, START-TEXT, and END-TEXT."
  (with-current-buffer buffer
    (let (begin finish)
      (goto-char (point-min))
      (when start (forward-line (1- (max 1 start))))
      (setq begin (point))
      (when start-text
        (unless (search-forward start-text (and start (line-end-position)) t)
          (setq begin nil))
        (when begin (setq begin (match-beginning 0))))
      (goto-char (or begin (point-min)))
      (cond
       (end
        (goto-char (point-min))
        (forward-line (1- (max 1 end)))
        (setq finish (line-end-position))
        (when end-text
          (when (search-forward end-text finish t)
            (setq finish (match-end 0)))))
       (end-text
        (when (search-forward end-text nil t)
          (setq finish (match-end 0))))
       (start (setq finish (line-end-position)))
       (t (setq finish (point-max))))
      (when (and begin finish)
        (goto-char finish)
        (push-mark begin t t)))))

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
                        (if (and file (herdr-claude-editor--project-file-p file root))
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

(defun herdr-claude-editor--open-file (owner root arguments)
  "Open the file requested by ARGUMENTS below ROOT for OWNER."
  (let* ((start (plist-get arguments :start-line))
         (end (plist-get arguments :end-line))
         (start-text (plist-get arguments :start-text))
         (end-text (plist-get arguments :end-text))
         (file (herdr-claude-editor--path (plist-get arguments :path) root)))
    (if (or (not file) (and start (not (integerp start)))
            (and end (not (integerp end)))
            (and start-text (not (stringp start-text)))
            (and end-text (not (stringp end-text))))
        (herdr-claude-editor--invalid)
      (let* ((existing (get-file-buffer file))
             (views (herdr-claude-editor--view-table owner t))
             (previous (gethash file views))
             (buffer (or existing (find-file-noselect file)))
             (window (or (get-buffer-window buffer 0) (selected-window)))
             (view (make-herdr-claude-editor--view
                    :buffer buffer :window window
                    :owned-buffer-p
                    (or (null existing)
                        (and previous
                             (herdr-claude-editor--view-owned-buffer-p previous))))))
        (set-window-buffer window buffer)
        (puthash file view views)
        (herdr-claude-editor--selection buffer start end start-text end-text)
        (herdr-claude-editor--result "Opened file")))))

(defun herdr-claude-editor--other-member-p (owner file)
  "Return non-nil when another OWNER owns FILE."
  (let (found)
    (maphash (lambda (other views)
               (when (and (not (eq other owner)) (gethash file views))
                 (setq found t)))
             herdr-claude-editor--views)
    found))

(defun herdr-claude-editor--release-view (owner file view)
  "Release VIEW of FILE owned by OWNER."
  (let ((buffer (herdr-claude-editor--view-buffer view))
        (window (herdr-claude-editor--view-window view)))
    (when (and (window-live-p window) (eq (window-buffer window) buffer))
      (set-window-buffer window (other-buffer buffer t)))
    (when (and (herdr-claude-editor--view-owned-buffer-p view)
               (herdr-claude-editor--other-member-p owner file))
      (maphash (lambda (other views)
                 (when-let* (((not (eq other owner)))
                             (other-view (gethash file views)))
                   (setf (herdr-claude-editor--view-owned-buffer-p other-view) t)))
               herdr-claude-editor--views))
    (when (and (herdr-claude-editor--view-owned-buffer-p view)
               (buffer-live-p buffer) (not (buffer-modified-p buffer))
               (not (herdr-claude-editor--other-member-p owner file))
               (null (get-buffer-window-list buffer nil 0)))
      (kill-buffer buffer))
    t))

(defun herdr-claude-editor--release-views (owner)
  "Release every view owned by OWNER."
  (let ((views (herdr-claude-editor--view-table owner)))
    (when views
      (maphash (lambda (file view)
                 (when (herdr-claude-editor--release-view owner file view)
                   (remhash file views)))
               (copy-hash-table views))
      (when (= (hash-table-count views) 0)
        (remhash owner herdr-claude-editor--views)))
    (not (herdr-claude-editor--view-table owner))))

(defun herdr-claude-editor--project-file-p (file root)
  "Return non-nil when FILE is beneath ROOT."
  (let ((file (expand-file-name file))
        (root (expand-file-name root)))
    (file-in-directory-p (if (file-exists-p file) (file-truename file) file)
                         (if (file-exists-p root) (file-truename root) root))))

(defun herdr-claude-editor--severity (severity)
  "Return a normalized string for SEVERITY."
  (cond
   ((and severity (symbolp severity))
    (if (keywordp severity)
        (substring (symbol-name severity) 1)
      (symbol-name severity)))
   ((stringp severity) severity)
   (t "info")))

(defun herdr-claude-editor--position (buffer position)
  "Return BUFFER's line and column at POSITION."
  (with-current-buffer buffer
    (save-excursion
      (goto-char position)
      (list (line-number-at-pos) (current-column)))))

(defun herdr-claude-editor--diagnostic
    (file message line column severity)
  "Return FILE's MESSAGE at LINE and COLUMN with SEVERITY."
  (list :file file :message message :line line :column column
        :severity (herdr-claude-editor--severity severity)))

(defun herdr-claude-editor--normalize-flymake (file diagnostic)
  "Normalize Flymake DIAGNOSTIC for FILE."
  (let* ((buffer (flymake-diagnostic-buffer diagnostic))
         (position (herdr-claude-editor--position
                    buffer (flymake-diagnostic-beg diagnostic))))
    (herdr-claude-editor--diagnostic
     file (flymake-diagnostic-text diagnostic) (car position) (cadr position)
     (flymake-diagnostic-type diagnostic))))

(defun herdr-claude-editor--normalize-flycheck (file diagnostic)
  "Normalize Flycheck DIAGNOSTIC for FILE."
  (herdr-claude-editor--diagnostic
   file (flycheck-error-message diagnostic) (flycheck-error-line diagnostic)
   (flycheck-error-column diagnostic) (flycheck-error-level diagnostic)))

(defun herdr-claude-editor--normalize-diagnostic (file diagnostic provider)
  "Normalize DIAGNOSTIC from PROVIDER for FILE."
  (cond
   ((eq provider 'flymake)
    (herdr-claude-editor--normalize-flymake file diagnostic))
   ((eq provider 'flycheck)
    (herdr-claude-editor--normalize-flycheck file diagnostic))
   (t
    (when-let* ((message (or (plist-get diagnostic :message)
                             (plist-get diagnostic :text))))
      (herdr-claude-editor--diagnostic
       file message (plist-get diagnostic :line) (plist-get diagnostic :column)
       (or (plist-get diagnostic :severity) (plist-get diagnostic :level)))))))

(defun herdr-claude-editor-collect-diagnostics (providers buffers root)
  "Collect diagnostics from BUFFERS beneath ROOT using PROVIDERS."
  (let (diagnostics)
    (dolist (buffer buffers)
      (when-let* ((file (buffer-file-name buffer))
                  ((herdr-claude-editor--project-file-p file root)))
        (dolist (provider providers)
          (dolist (diagnostic (funcall (cdr provider) buffer))
            (when-let* ((normalized
                         (herdr-claude-editor--normalize-diagnostic
                          file diagnostic (car provider))))
              (push normalized diagnostics))))))
    (nreverse diagnostics)))

(defun herdr-claude-editor--flymake (buffer)
  "Return Flymake diagnostics for BUFFER."
  (with-current-buffer buffer
    (if (fboundp 'flymake-diagnostics) (flymake-diagnostics) nil)))

(defun herdr-claude-editor--flycheck (buffer)
  "Return Flycheck diagnostics for BUFFER."
  (with-current-buffer buffer
    (if (and (fboundp 'flycheck-current-errors) (bound-and-true-p flycheck-mode))
        (flycheck-current-errors) nil)))

(defun herdr-claude-editor--diagnostics (root arguments)
  "Return project diagnostics requested by ARGUMENTS below ROOT."
  (let ((uri (plist-get arguments :uri)))
    (if (and uri (not (stringp uri)))
        (herdr-claude-editor--invalid)
      (let ((buffers (seq-filter
                      (lambda (buffer)
                        (when-let* ((file (buffer-file-name buffer)))
                          (herdr-claude-editor--project-file-p file root)))
                      (buffer-list))))
        (make-herdr-claude-editor-result
         :kind 'diagnostics
         :value (vconcat
                 (herdr-claude-editor-collect-diagnostics
                  `((flymake . ,#'herdr-claude-editor--flymake)
                    (flycheck . ,#'herdr-claude-editor--flycheck))
                  buffers root)))))))

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

(defun herdr-claude-editor--find-diff (owner tab-name)
  "Return OWNER's deferred diff named TAB-NAME."
  (seq-find (lambda (diff)
              (and (herdr-claude-editor--diff-p diff)
                   (equal tab-name (herdr-claude-editor--diff-tab-name diff))))
            (herdr-claude-editor--owner-diffs owner)))

(defun herdr-claude-editor-accept-diff (owner tab-name)
  "Accept OWNER's deferred diff named TAB-NAME."
  (when-let* ((diff (herdr-claude-editor--find-diff owner tab-name)))
    (herdr-claude-editor--complete-diff diff t)))

(defun herdr-claude-editor-reject-diff (owner tab-name)
  "Reject OWNER's deferred diff named TAB-NAME."
  (when-let* ((diff (herdr-claude-editor--find-diff owner tab-name)))
    (herdr-claude-editor--complete-diff diff nil)))

(defun herdr-claude-editor--cancel-diff (diff)
  "Cancel DIFF and release its resources."
  (herdr-claude-editor--finish-diff diff nil nil t))

(defun herdr-claude-editor-cancel (owner)
  "Cancel work and release views owned by opaque OWNER."
  (herdr-claude-editor-cancel-selection owner)
  (let ((diffs-released t))
    (dolist (diff (copy-sequence (herdr-claude-editor--owner-diffs owner)))
      (when (and (herdr-claude-editor--diff-p diff)
                 (not (herdr-claude-editor--cancel-diff diff)))
        (setq diffs-released nil)))
    (and diffs-released
         (null (herdr-claude-editor--owner-diffs owner))
         (herdr-claude-editor--release-views owner))))

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
  (let* ((old-path (herdr-claude-editor--path (plist-get arguments :old-path) root))
         (new (herdr-claude-editor--path (plist-get arguments :new-path) root))
         (contents (plist-get arguments :contents))
         (tab-name (plist-get arguments :tab-name)))
    (if (not (and old-path new (stringp contents) (stringp tab-name) request))
        (herdr-claude-editor--invalid)
      (let* ((old-existing (get-file-buffer old-path))
             (old (or old-existing (find-file-noselect old-path)))
             (proposed (generate-new-buffer (format " *herdr diff %s*" tab-name)))
             (diff (make-herdr-claude-editor--diff
                    :owner owner :request request :tab-name tab-name
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

(defun herdr-claude-editor--close-diffs (owner &optional tab-name)
  "Close OWNER diffs, optionally limited to TAB-NAME."
  (dolist (diff (copy-sequence (herdr-claude-editor--owner-diffs owner)))
    (when (and (herdr-claude-editor--diff-p diff)
               (or (null tab-name)
                   (equal tab-name (herdr-claude-editor--diff-tab-name diff))))
      (herdr-claude-editor--cancel-diff diff)))
  (herdr-claude-editor--result "Closed diff tabs"))

(defun herdr-claude-editor--execute (arguments)
  "Evaluate Emacs Lisp supplied in ARGUMENTS."
  (let ((code (plist-get arguments :code))
        (position 0)
        value)
    (if (not (stringp code))
        (herdr-claude-editor--invalid)
      (condition-case err
          (while t
            (pcase-let ((`(,form . ,next) (read-from-string code position)))
              (setq value (eval form t)
                    position next)))
        (end-of-file
         (unless (string-match-p "\\`\\(?:[ \t\n\r]+\\|;[^\n]*\\)*\\'"
                                 (substring code position))
           (signal (car err) (cdr err)))))
      (herdr-claude-editor--result (format "%s" value)))))

(defun herdr-claude-editor-dispatch (owner root operation arguments request)
  "Run normalized OPERATION with ARGUMENTS below ROOT for OWNER and REQUEST."
  (pcase operation
    ('open-file (herdr-claude-editor--open-file owner root arguments))
    ('diagnostics (herdr-claude-editor--diagnostics root arguments))
    ('close-tab (herdr-claude-editor--close-tab owner root arguments))
    ('open-diff (herdr-claude-editor--open-diff owner root arguments request))
    ('close-diffs (herdr-claude-editor--close-diffs owner))
    ('execute
     (if herdr-claude-enable-elisp-tool
         (herdr-claude-editor--execute arguments)
       (herdr-claude-editor--invalid)))
    (_ (herdr-claude-editor--invalid))))

(defun herdr-claude-editor--close-tab (owner root arguments)
  "Close the tab or diff described by ARGUMENTS below ROOT for OWNER."
  (let* ((value (plist-get arguments :path))
         (tab-name (plist-get arguments :tab-name))
         (file (and value (herdr-claude-editor--path value root))))
    (if (or (and value (not file)) (and tab-name (not (stringp tab-name))))
        (herdr-claude-editor--invalid)
      (when-let* ((views (and file (herdr-claude-editor--view-table owner)))
                  (view (gethash file views)))
        (when (herdr-claude-editor--release-view owner file view)
          (remhash file views)))
      (when tab-name (herdr-claude-editor--close-diffs owner tab-name))
      (herdr-claude-editor--result "Closed tab"))))

(provide 'herdr-claude-editor)
;;; herdr-claude-editor.el ends here
