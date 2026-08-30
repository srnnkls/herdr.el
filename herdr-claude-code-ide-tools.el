;;; herdr-claude-code-ide-tools.el --- Claude Code IDE tools for herdr -*- lexical-binding: t; -*-

;;; Commentary:

;; Implements Claude Code IDE file, diagnostic, diff, and evaluation tools.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ediff)
(require 'herdr-claude-code-ide-mcp)
(require 'herdr-claude-code-ide-diagnostics)

(defcustom herdr-claude-code-ide-tools-enable-elisp nil
  "Whether the executeCode tool may evaluate Emacs Lisp."
  :type 'boolean
  :group 'herdr-claude-code-ide)

(defvar herdr-claude-code-ide-tools--views (make-hash-table :test #'eq)
  "Views indexed by IDE adapter.")

(cl-defstruct herdr-claude-code-ide-tools--view
  "A file view owned by an IDE adapter."
  generation buffer window owned-buffer-p)

(cl-defstruct herdr-claude-code-ide-tools--diff
  "A deferred IDE diff request and its resources."
  adapter client generation request-id tab-name proposed old old-owned-p completion control
  control-completion hook-removed-p response-sent-p proposed-released-p old-released-p
  control-released-p)

(defun herdr-claude-code-ide-tools--value (key object)
  "Return KEY from OBJECT, accepting symbol and string keys."
  (or (alist-get key object nil nil #'eq)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun herdr-claude-code-ide-tools--invalid (&optional message)
  "Return an invalid-parameters response with optional MESSAGE."
  (herdr-claude-code-ide-mcp-invalid-params message))

(defun herdr-claude-code-ide-tools--path (value root)
  "Return VALUE as a regular path below ROOT, or nil."
  (when (stringp value)
    (let ((path (expand-file-name value root)))
      (when (and (file-in-directory-p path root)
                 (not (file-symlink-p path)))
        path))))

(defun herdr-claude-code-ide-tools--view-table (adapter &optional create)
  "Return ADAPTER's view table, creating it when CREATE is non-nil."
  (or (gethash adapter herdr-claude-code-ide-tools--views)
      (and create
           (puthash adapter (make-hash-table :test #'equal)
                    herdr-claude-code-ide-tools--views))))

(defun herdr-claude-code-ide-tools-view-member-p (adapter file)
  "Return non-nil when ADAPTER owns a view of FILE."
  (when-let* ((views (herdr-claude-code-ide-tools--view-table adapter))
              (view (gethash (expand-file-name file) views)))
    view))

(defun herdr-claude-code-ide-tools--result (text)
  "Return a successful MCP result containing TEXT."
  `((content . [((type . "text") (text . ,text))])))

(defun herdr-claude-code-ide-tools--selection (buffer start end start-text end-text)
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

(defun herdr-claude-code-ide-tools--open-file (adapter arguments)
  "Open the file requested by ARGUMENTS for ADAPTER."
  (let* ((root (herdr-claude-code-ide-mcp--adapter-root adapter))
         (start (herdr-claude-code-ide-tools--value 'startLine arguments))
         (end (herdr-claude-code-ide-tools--value 'endLine arguments))
         (start-text (herdr-claude-code-ide-tools--value 'startText arguments))
         (end-text (herdr-claude-code-ide-tools--value 'endText arguments))
         (file (herdr-claude-code-ide-tools--path
                (herdr-claude-code-ide-tools--value 'filePath arguments) root)))
    (if (or (not file) (and start (not (integerp start)))
            (and end (not (integerp end)))
            (and start-text (not (stringp start-text)))
            (and end-text (not (stringp end-text))))
        (herdr-claude-code-ide-tools--invalid)
      (let* ((existing (get-file-buffer file))
             (buffer (or existing (find-file-noselect file)))
             (window (or (get-buffer-window buffer 0) (selected-window)))
             (view (make-herdr-claude-code-ide-tools--view
                    :generation (herdr-claude-code-ide-mcp-adapter-client-generation adapter)
                    :buffer buffer :window window :owned-buffer-p (null existing))))
        (set-window-buffer window buffer)
        (puthash file view (herdr-claude-code-ide-tools--view-table adapter t))
        (herdr-claude-code-ide-tools--selection buffer start end start-text end-text)
        (herdr-claude-code-ide-tools--result "Opened file")))))

(defun herdr-claude-code-ide-tools--other-member-p (adapter file)
  "Return non-nil when another ADAPTER owns FILE."
  (let (found)
    (maphash (lambda (other views)
               (when (and (not (eq other adapter)) (gethash file views))
                 (setq found t)))
             herdr-claude-code-ide-tools--views)
    found))

(defun herdr-claude-code-ide-tools--release-view (adapter file view)
  "Release VIEW of FILE owned by ADAPTER."
  (let ((buffer (herdr-claude-code-ide-tools--view-buffer view))
        (window (herdr-claude-code-ide-tools--view-window view)))
    (when (and (window-live-p window) (eq (window-buffer window) buffer))
      (set-window-buffer window (other-buffer buffer t)))
    (when (and (herdr-claude-code-ide-tools--view-owned-buffer-p view)
               (herdr-claude-code-ide-tools--other-member-p adapter file))
      (maphash (lambda (other views)
                 (when-let* (((not (eq other adapter)))
                             (other-view (gethash file views)))
                   (setf (herdr-claude-code-ide-tools--view-owned-buffer-p other-view) t)))
               herdr-claude-code-ide-tools--views))
    (when (and (herdr-claude-code-ide-tools--view-owned-buffer-p view)
               (buffer-live-p buffer) (not (buffer-modified-p buffer))
               (not (herdr-claude-code-ide-tools--other-member-p adapter file))
               (null (get-buffer-window-list buffer nil 0)))
      (kill-buffer buffer))
    t))

(defun herdr-claude-code-ide-tools--release-views (adapter)
  "Release every view owned by ADAPTER."
  (let ((views (herdr-claude-code-ide-tools--view-table adapter)))
    (when views
      (maphash (lambda (file view)
                 (when (herdr-claude-code-ide-tools--release-view adapter file view)
                   (remhash file views)))
               (copy-hash-table views))
      (when (= (hash-table-count views) 0)
        (remhash adapter herdr-claude-code-ide-tools--views)))
    (not (herdr-claude-code-ide-tools--view-table adapter))))

(defun herdr-claude-code-ide-tools--flymake (buffer)
  "Return Flymake diagnostics for BUFFER."
  (with-current-buffer buffer
    (if (fboundp 'flymake-diagnostics) (flymake-diagnostics) nil)))

(defun herdr-claude-code-ide-tools--flycheck (buffer)
  "Return Flycheck diagnostics for BUFFER."
  (with-current-buffer buffer
    (if (and (fboundp 'flycheck-current-errors) (bound-and-true-p flycheck-mode))
        (flycheck-current-errors) nil)))

(defun herdr-claude-code-ide-tools--diagnostics (adapter arguments)
  "Return project diagnostics requested by ARGUMENTS for ADAPTER."
  (let ((uri (herdr-claude-code-ide-tools--value 'uri arguments)))
    (if (and uri (not (stringp uri)))
        (herdr-claude-code-ide-tools--invalid)
      (let* ((root (herdr-claude-code-ide-mcp--adapter-root adapter))
             (buffers (seq-filter
                       (lambda (buffer)
                         (when-let* ((file (buffer-file-name buffer)))
                           (herdr-claude-code-ide-diagnostics--project-file-p file root)))
                       (buffer-list))))
        (let ((diagnostics
               (herdr-claude-code-ide-diagnostics-collect-diagnostics
                `((flymake . ,#'herdr-claude-code-ide-tools--flymake)
                  (flycheck . ,#'herdr-claude-code-ide-tools--flycheck))
                buffers root)))
          `((content . ,(vconcat diagnostics))))))))

(defun herdr-claude-code-ide-tools--untrack-diff (diff)
  "Remove fully released DIFF from its adapter state."
  (let ((adapter (herdr-claude-code-ide-tools--diff-adapter diff)))
    (when (and (herdr-claude-code-ide-tools--diff-response-sent-p diff)
               (herdr-claude-code-ide-tools--diff-proposed-released-p diff)
               (herdr-claude-code-ide-tools--diff-old-released-p diff)
               (herdr-claude-code-ide-tools--diff-control-released-p diff))
      (setf (herdr-claude-code-ide-mcp-adapter-diffs adapter)
            (delq diff (herdr-claude-code-ide-mcp-adapter-diffs adapter))
            (herdr-claude-code-ide-mcp-adapter-pending adapter)
            (delq diff (herdr-claude-code-ide-mcp-adapter-pending adapter))))))

(defun herdr-claude-code-ide-tools--remove-diff-hook (diff)
  "Remove completion hooks installed for DIFF."
  (unless (herdr-claude-code-ide-tools--diff-hook-removed-p diff)
    (when-let* ((buffer (herdr-claude-code-ide-tools--diff-proposed diff))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook
                     (herdr-claude-code-ide-tools--diff-completion diff) t)))
    (when-let* ((buffer (herdr-claude-code-ide-tools--diff-control diff))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (remove-hook 'ediff-after-quit-hook-internal
                     (herdr-claude-code-ide-tools--diff-control-completion diff) t)))
    (setf (herdr-claude-code-ide-tools--diff-hook-removed-p diff) t)))

(defun herdr-claude-code-ide-tools--release-diff-resources (diff &optional killed)
  "Release DIFF resources, treating proposed buffers as killed when KILLED."
  (herdr-claude-code-ide-tools--remove-diff-hook diff)
  (unless (herdr-claude-code-ide-tools--diff-control-released-p diff)
    (let ((control (herdr-claude-code-ide-tools--diff-control diff)))
      (if (not (buffer-live-p control))
          (setf (herdr-claude-code-ide-tools--diff-control-released-p diff) t)
        (setf (herdr-claude-code-ide-tools--diff-control-released-p diff) t)
        (condition-case err
            (with-current-buffer control
              (let ((ediff-control-buffer control))
                (ediff-really-quit nil)))
          (error
           (setf (herdr-claude-code-ide-tools--diff-control-released-p diff) nil)
           (signal (car err) (cdr err))))
        (unless (buffer-live-p control)
          (setq ediff-session-registry (delq control ediff-session-registry))
          (dolist (buffer (list (herdr-claude-code-ide-tools--diff-old diff)
                                (herdr-claude-code-ide-tools--diff-proposed diff)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq ediff-this-buffer-ediff-sessions
                      (delq control ediff-this-buffer-ediff-sessions))))))
        (setf (herdr-claude-code-ide-tools--diff-control-released-p diff)
              (not (buffer-live-p control))))))
  (unless (herdr-claude-code-ide-tools--diff-proposed-released-p diff)
    (let ((buffer (herdr-claude-code-ide-tools--diff-proposed diff)))
      (if (or killed (not (buffer-live-p buffer)))
          (setf (herdr-claude-code-ide-tools--diff-proposed-released-p diff) t)
        (kill-buffer buffer)
        (setf (herdr-claude-code-ide-tools--diff-proposed-released-p diff)
              (not (buffer-live-p buffer))))))
  (unless (herdr-claude-code-ide-tools--diff-old-released-p diff)
    (let ((old (herdr-claude-code-ide-tools--diff-old diff)))
      (if (and (herdr-claude-code-ide-tools--diff-old-owned-p diff)
               (buffer-live-p old) (not (buffer-modified-p old))
               (null (get-buffer-window-list old nil 0)))
          (progn
            (kill-buffer old)
            (setf (herdr-claude-code-ide-tools--diff-old-released-p diff)
                  (not (buffer-live-p old))))
        (setf (herdr-claude-code-ide-tools--diff-old-released-p diff) t)))))

(defun herdr-claude-code-ide-tools--finish-diff (diff response &optional killed)
  "Send RESPONSE and release DIFF resources, with optional KILLED buffer."
  (unless (herdr-claude-code-ide-tools--diff-response-sent-p diff)
    (if (herdr-claude-code-ide-mcp-client-open-p
         (herdr-claude-code-ide-tools--diff-client diff))
        (when (herdr-claude-code-ide-mcp-send-deferred
               (herdr-claude-code-ide-tools--diff-client diff) response)
          (setf (herdr-claude-code-ide-tools--diff-response-sent-p diff) t))
      (setf (herdr-claude-code-ide-tools--diff-response-sent-p diff) t)))
  (when (herdr-claude-code-ide-tools--diff-response-sent-p diff)
    (herdr-claude-code-ide-tools--release-diff-resources diff killed))
  (herdr-claude-code-ide-tools--untrack-diff diff)
  (and (herdr-claude-code-ide-tools--diff-response-sent-p diff)
       (herdr-claude-code-ide-tools--diff-proposed-released-p diff)
       (herdr-claude-code-ide-tools--diff-old-released-p diff)
       (herdr-claude-code-ide-tools--diff-control-released-p diff)))

(defun herdr-claude-code-ide-tools--complete-diff (diff accept &optional killed)
  "Complete DIFF as ACCEPT, with optional KILLED proposed buffer."
  (let ((adapter (herdr-claude-code-ide-tools--diff-adapter diff)))
    (when (and (eq (herdr-claude-code-ide-tools--diff-client diff)
                   (herdr-claude-code-ide-mcp-adapter-current-client adapter))
               (= (herdr-claude-code-ide-tools--diff-generation diff)
                  (herdr-claude-code-ide-mcp-adapter-client-generation adapter)))
      (herdr-claude-code-ide-tools--finish-diff
       diff
       (herdr-claude-code-ide-mcp--response
        (herdr-claude-code-ide-tools--diff-request-id diff)
        (if accept
            (herdr-claude-code-ide-tools--result
             (if (buffer-live-p (herdr-claude-code-ide-tools--diff-proposed diff))
                 (with-current-buffer (herdr-claude-code-ide-tools--diff-proposed diff)
                   (buffer-string))
               ""))
          (herdr-claude-code-ide-tools--result "Diff rejected")))
       killed))))

(defun herdr-claude-code-ide-tools--find-diff (adapter client tab-name)
  "Return ADAPTER's deferred diff for CLIENT and TAB-NAME."
  (seq-find (lambda (diff)
              (and (herdr-claude-code-ide-tools--diff-p diff)
                   (equal tab-name (herdr-claude-code-ide-tools--diff-tab-name diff))
                   (eq client (herdr-claude-code-ide-tools--diff-client diff))))
            (herdr-claude-code-ide-mcp-adapter-diffs adapter)))

(defun herdr-claude-code-ide-tools-accept-diff (adapter client tab-name)
  "Accept ADAPTER's deferred diff named TAB-NAME for CLIENT."
  (when-let* ((diff (herdr-claude-code-ide-tools--find-diff adapter client tab-name)))
    (herdr-claude-code-ide-tools--complete-diff diff t)))

(defun herdr-claude-code-ide-tools-reject-diff (adapter client tab-name)
  "Reject ADAPTER's deferred diff named TAB-NAME for CLIENT."
  (when-let* ((diff (herdr-claude-code-ide-tools--find-diff adapter client tab-name)))
    (herdr-claude-code-ide-tools--complete-diff diff nil)))

(defun herdr-claude-code-ide-tools--cancel-diff (diff)
  "Finish DIFF with a cancelled-request response."
  (herdr-claude-code-ide-tools--finish-diff
   diff
   (herdr-claude-code-ide-mcp--error
    (herdr-claude-code-ide-tools--diff-request-id diff) -32800 "Request cancelled")))

(defun herdr-claude-code-ide-tools--cancel (adapter)
  "Cancel deferred work and release views owned by ADAPTER."
  (let ((committed
         (cl-some (lambda (diff)
                    (and (herdr-claude-code-ide-tools--diff-p diff)
                         (herdr-claude-code-ide-tools--diff-response-sent-p diff)))
                  (herdr-claude-code-ide-mcp-adapter-diffs adapter))))
    (catch 'incomplete
      (dolist (diff (copy-sequence (herdr-claude-code-ide-mcp-adapter-diffs adapter)))
        (when (herdr-claude-code-ide-tools--diff-p diff)
          (let ((response-sent (herdr-claude-code-ide-tools--diff-response-sent-p diff)))
            (condition-case nil
                (let ((complete (herdr-claude-code-ide-tools--cancel-diff diff)))
                  (when (and (not response-sent)
                             (herdr-claude-code-ide-tools--diff-response-sent-p diff))
                    (setq committed t))
                  (unless complete
                    (throw 'incomplete (and committed :committed))))
              (error
               (throw 'incomplete
                      (and (or committed
                               (herdr-claude-code-ide-tools--diff-response-sent-p diff))
                           :committed)))))))
      (if (herdr-claude-code-ide-tools--release-views adapter)
          t
        (and committed :committed)))))

(defun herdr-claude-code-ide-tools--bind-diff-control (diff control)
  "Associate DIFF with Ediff CONTROL and install completion handling."
  (setf (herdr-claude-code-ide-tools--diff-control diff) control)
  (if (herdr-claude-code-ide-tools--diff-response-sent-p diff)
      (herdr-claude-code-ide-tools--release-diff-resources diff)
    (when (and control (buffer-live-p control))
      (setf (herdr-claude-code-ide-tools--diff-control-released-p diff) nil)
      (with-current-buffer control
        (add-hook 'ediff-after-quit-hook-internal
                  (herdr-claude-code-ide-tools--diff-control-completion diff) nil t)))
    (unless (and control (buffer-live-p control))
      (setf (herdr-claude-code-ide-tools--diff-control-released-p diff) t)))
  diff)

(defun herdr-claude-code-ide-tools--start-ediff (diff old proposed)
  "Start Ediff for DIFF between OLD and PROPOSED buffers."
  (let ((capture
         (lambda ()
           (herdr-claude-code-ide-tools--bind-diff-control diff ediff-control-buffer))))
    (add-hook 'ediff-startup-hook capture)
    (unwind-protect
        (progn
          (ediff-buffers old proposed)
          nil)
      (remove-hook 'ediff-startup-hook capture))))

(defun herdr-claude-code-ide-tools--open-diff (adapter arguments)
  "Open the deferred diff requested by ARGUMENTS for ADAPTER."
  (let* ((root (herdr-claude-code-ide-mcp--adapter-root adapter))
         (old-path (herdr-claude-code-ide-tools--path
                    (herdr-claude-code-ide-tools--value 'old_file_path arguments) root))
         (new (herdr-claude-code-ide-tools--path
               (herdr-claude-code-ide-tools--value 'new_file_path arguments) root))
         (contents (herdr-claude-code-ide-tools--value 'new_file_contents arguments))
         (tab-name (herdr-claude-code-ide-tools--value 'tab_name arguments)))
    (if (not (and old-path new (stringp contents) (stringp tab-name)
                  herdr-claude-code-ide-mcp--request-client))
        (herdr-claude-code-ide-tools--invalid)
      (let* ((old-existing (get-file-buffer old-path))
             (old (or old-existing (find-file-noselect old-path)))
             (proposed (generate-new-buffer (format " *herdr diff %s*" tab-name)))
             (diff (make-herdr-claude-code-ide-tools--diff
                    :adapter adapter :client herdr-claude-code-ide-mcp--request-client
                    :generation (herdr-claude-code-ide-mcp-adapter-client-generation adapter)
                    :request-id herdr-claude-code-ide-mcp--request-id :tab-name tab-name
                    :proposed proposed :old old :old-owned-p (null old-existing))))
        (with-current-buffer proposed (insert contents))
        (let ((completion (lambda () (herdr-claude-code-ide-tools--complete-diff diff t t)))
              (control-completion (lambda () (herdr-claude-code-ide-tools--cancel-diff diff))))
          (setf (herdr-claude-code-ide-tools--diff-completion diff) completion
                (herdr-claude-code-ide-tools--diff-control-completion diff) control-completion)
          (with-current-buffer proposed (add-hook 'kill-buffer-hook completion nil t)))
        (herdr-claude-code-ide-mcp-track-pending
         adapter herdr-claude-code-ide-mcp--request-client diff diff)
        (condition-case err
            (let ((control (herdr-claude-code-ide-tools--start-ediff diff old proposed)))
              (unless (herdr-claude-code-ide-tools--diff-control diff)
                (herdr-claude-code-ide-tools--bind-diff-control diff control))
              herdr-claude-code-ide-mcp--deferred)
          (error
           (if (herdr-claude-code-ide-tools--diff-response-sent-p diff)
               herdr-claude-code-ide-mcp--deferred
             (setf (herdr-claude-code-ide-tools--diff-response-sent-p diff) t)
             (condition-case nil
                 (herdr-claude-code-ide-tools--finish-diff diff nil)
               (error nil))
             (signal (car err) (cdr err)))))))))

(defun herdr-claude-code-ide-tools--close-diffs (adapter &optional tab-name)
  "Close ADAPTER diffs, optionally limited to TAB-NAME."
  (dolist (diff (copy-sequence (herdr-claude-code-ide-mcp-adapter-diffs adapter)))
    (when (and (herdr-claude-code-ide-tools--diff-p diff)
               (or (null tab-name)
                   (equal tab-name (herdr-claude-code-ide-tools--diff-tab-name diff))))
      (herdr-claude-code-ide-tools--cancel-diff diff)))
  (herdr-claude-code-ide-tools--result "Closed diff tabs"))

(defun herdr-claude-code-ide-tools--execute (arguments)
  "Evaluate Emacs Lisp supplied in ARGUMENTS."
  (let ((code (herdr-claude-code-ide-tools--value 'code arguments))
        (position 0)
        value)
    (if (not (stringp code))
        (herdr-claude-code-ide-tools--invalid)
      (condition-case err
          (while t
            (pcase-let ((`(,form . ,next) (read-from-string code position)))
              (setq value (eval form t)
                    position next)))
        (end-of-file
         (unless (string-match-p "\\`\\(?:[ \t\n\r]+\\|;[^\n]*\\)*\\'"
                                 (substring code position))
           (signal (car err) (cdr err)))))
      (herdr-claude-code-ide-tools--result (format "%s" value)))))

(defun herdr-claude-code-ide-tools--dispatch (adapter name arguments)
  "Dispatch NAME and ARGUMENTS for ADAPTER."
  (cond ((not (listp arguments)) (herdr-claude-code-ide-tools--invalid))
        ((equal name "openFile") (herdr-claude-code-ide-tools--open-file adapter arguments))
        ((equal name "getDiagnostics") (herdr-claude-code-ide-tools--diagnostics adapter arguments))
        ((equal name "close_tab") (herdr-claude-code-ide-tools--close-tab adapter arguments))
        ((equal name "openDiff") (herdr-claude-code-ide-tools--open-diff adapter arguments))
        ((equal name "closeAllDiffTabs") (herdr-claude-code-ide-tools--close-diffs adapter))
        ((and herdr-claude-code-ide-tools-enable-elisp (equal name "executeCode"))
         (herdr-claude-code-ide-tools--execute arguments))
        (t (herdr-claude-code-ide-tools--invalid))))

(defun herdr-claude-code-ide-tools-install (adapter)
  "Install Claude IDE tools on ADAPTER."
  (setf (herdr-claude-code-ide-mcp-adapter-tool-list adapter)
        (lambda ()
          (seq-remove (lambda (tool)
                        (and (not herdr-claude-code-ide-tools-enable-elisp)
                             (equal (herdr-claude-code-ide-tools--value 'name tool)
                                    "executeCode")))
                      (herdr-claude-code-ide-mcp--default-tools)))
        (herdr-claude-code-ide-mcp-adapter-tool-call adapter)
        #'herdr-claude-code-ide-tools--dispatch
        (herdr-claude-code-ide-mcp-adapter-cancel-work adapter)
        #'herdr-claude-code-ide-tools--cancel)
  adapter)

(defun herdr-claude-code-ide-tools--close-tab (adapter arguments)
  "Close the tab or diff requested by ARGUMENTS for ADAPTER."
  (let* ((root (herdr-claude-code-ide-mcp--adapter-root adapter))
         (value (herdr-claude-code-ide-tools--value 'path arguments))
         (tab-name (herdr-claude-code-ide-tools--value 'tab_name arguments))
         (file (and value (herdr-claude-code-ide-tools--path value root))))
    (if (or (and value (not file)) (and tab-name (not (stringp tab-name))))
        (herdr-claude-code-ide-tools--invalid)
      (when-let* ((views (and file (herdr-claude-code-ide-tools--view-table adapter)))
                  (view (gethash file views)))
        (when (herdr-claude-code-ide-tools--release-view adapter file view)
          (remhash file views)))
      (when tab-name (herdr-claude-code-ide-tools--close-diffs adapter tab-name))
      (herdr-claude-code-ide-tools--result "Closed tab"))))

(provide 'herdr-claude-code-ide-tools)
;;; herdr-claude-code-ide-tools.el ends here
