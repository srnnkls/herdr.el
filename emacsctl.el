;;; emacsctl.el --- Emacs interface for agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Provides a small, extensible operation registry for local agent clients.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'json)
(require 'project)
(require 'seq)
(require 'subr-x)

(defgroup emacsctl nil
  "Emacs operations exposed to local agents."
  :group 'external)

(defcustom emacsctl-enable-elisp-eval nil
  "Whether `elisp.eval' may evaluate arbitrary Emacs Lisp."
  :type 'boolean
  :group 'emacsctl)

(defconst emacsctl-protocol-version 1
  "Current emacsctl request and response protocol version.")

(define-error 'emacsctl-error "emacsctl error")
(define-error 'emacsctl-invalid-request "Invalid emacsctl request" 'emacsctl-error)
(define-error 'emacsctl-unsupported-version "Unsupported emacsctl version" 'emacsctl-error)
(define-error 'emacsctl-unknown-operation "Unknown emacsctl operation" 'emacsctl-error)
(define-error 'emacsctl-disabled-operation "Disabled emacsctl operation" 'emacsctl-error)
(define-error 'emacsctl-invalid-arguments "Invalid emacsctl arguments" 'emacsctl-error)
(define-error 'emacsctl-operation-failed "emacsctl operation failed" 'emacsctl-error)

(cl-defstruct (emacsctl--operation
               (:constructor emacsctl--make-operation))
  name handler description parameters effect interfaces enabled-p deferred)

(cl-defstruct (emacsctl--owned-buffer
               (:constructor emacsctl--make-owned-buffer))
  buffer window owned-p)

(defvar emacsctl--operations (make-hash-table :test #'equal)
  "Registered operations keyed by dotted name.")

(defvar emacsctl--buffers (make-hash-table :test #'eq)
  "File buffers opened for each opaque owner.")

(defun emacsctl--valid-name-p (name)
  "Return non-nil when NAME is a valid dotted operation name."
  (and (stringp name)
       (string-match-p "\\`[a-z][a-z0-9-]*\\(?:\\.[a-z][a-z0-9-]*\\)+\\'" name)))

(cl-defun emacsctl-register-operation
    (name handler &key description parameters (effect 'read) (interfaces '(cli))
          enabled-p deferred)
  "Register NAME with HANDLER and replace an existing descriptor.
DESCRIPTION documents it.  PARAMETERS declares its arguments.  EFFECT is `read'
or `write'.  INTERFACES controls discovery.  ENABLED-P gates invocation, and
DEFERRED marks callback-based operations."
  (unless (emacsctl--valid-name-p name)
    (signal 'wrong-type-argument (list 'emacsctl-operation-name name)))
  (unless (functionp handler)
    (signal 'wrong-type-argument (list 'functionp handler)))
  (unless (memq effect '(read write))
    (signal 'wrong-type-argument (list '(member read write) effect)))
  (let ((operation
         (emacsctl--make-operation
          :name name :handler handler :description (or description "")
          :parameters parameters :effect effect :interfaces interfaces
          :enabled-p enabled-p :deferred deferred)))
    (puthash name operation emacsctl--operations)
    operation))

(defun emacsctl-unregister-operation (name)
  "Unregister the operation named NAME."
  (remhash name emacsctl--operations))

(defun emacsctl--parameter-name (parameter)
  "Return PARAMETER's symbol name."
  (intern (plist-get parameter :name)))

(defun emacsctl--json-type-p (value type)
  "Return non-nil when VALUE has declared JSON TYPE."
  (pcase type
    ('string (stringp value))
    ('integer (integerp value))
    ('number (numberp value))
    ('boolean (or (eq value t) (eq value :json-false)))
    ('object (and (listp value) (seq-every-p #'consp value)))
    ('array (vectorp value))
    ('null (eq value :json-null))
    (_ nil)))

(defun emacsctl--validate-arguments (operation arguments)
  "Validate ARGUMENTS against OPERATION and return them."
  (unless (listp arguments)
    (signal 'emacsctl-invalid-arguments '("Arguments must be a JSON object")))
  (let* ((parameters (emacsctl--operation-parameters operation))
         (known (mapcar #'emacsctl--parameter-name parameters)))
    (dolist (entry arguments)
      (unless (and (consp entry) (memq (car entry) known))
        (signal 'emacsctl-invalid-arguments
                (list (format "Unknown argument: %s" (car-safe entry))))))
    (dolist (parameter parameters)
      (let* ((name (emacsctl--parameter-name parameter))
             (entry (assq name arguments)))
        (when (and (plist-get parameter :required) (null entry))
          (signal 'emacsctl-invalid-arguments
                  (list (format "Missing argument: %s" name))))
        (when (and entry
                   (not (emacsctl--json-type-p
                         (cdr entry) (plist-get parameter :type))))
          (signal 'emacsctl-invalid-arguments
                  (list (format "Invalid argument: %s" name)))))))
  arguments)

(defun emacsctl--enabled-p (operation context)
  "Return non-nil when OPERATION is enabled for CONTEXT."
  (let ((predicate (emacsctl--operation-enabled-p operation)))
    (or (null predicate) (funcall predicate context))))

(defun emacsctl--available-p (operation context)
  "Return non-nil when OPERATION is available in CONTEXT."
  (let ((interface (plist-get context :interface)))
    (and (or (null interface)
             (memq interface (emacsctl--operation-interfaces operation)))
         (emacsctl--enabled-p operation context))))

(defun emacsctl--parameter-schema (parameter)
  "Return the JSON schema fragment for PARAMETER."
  `((type . ,(symbol-name (plist-get parameter :type)))
    ,@(when-let* ((description (plist-get parameter :description)))
        `((description . ,description)))))

(defun emacsctl--operation-schema (operation)
  "Return OPERATION as a JSON-serializable descriptor."
  (let ((properties nil)
        (required nil))
    (dolist (parameter (emacsctl--operation-parameters operation))
      (let ((name (emacsctl--parameter-name parameter)))
        (push (cons name (emacsctl--parameter-schema parameter)) properties)
        (when (plist-get parameter :required)
          (push (symbol-name name) required))))
    `((name . ,(emacsctl--operation-name operation))
      (description . ,(emacsctl--operation-description operation))
      (effect . ,(symbol-name (emacsctl--operation-effect operation)))
      (input_schema . ((type . "object")
                       (properties . ,(nreverse properties))
                       (required . ,(vconcat (nreverse required)))
                       (additionalProperties . :json-false))))))

(defun emacsctl-operations (&optional context)
  "Return descriptors available for optional CONTEXT."
  (let (operations)
    (maphash
     (lambda (_name operation)
       (when (and (emacsctl--available-p operation context)
                  (or (not (eq (plist-get context :interface) 'cli))
                      (not (emacsctl--operation-deferred operation))))
         (push (emacsctl--operation-schema operation) operations)))
     emacsctl--operations)
    (sort operations
          (lambda (left right)
            (string< (alist-get 'name left) (alist-get 'name right))))))

(defun emacsctl-call (name arguments &optional context)
  "Invoke operation NAME with ARGUMENTS and optional CONTEXT."
  (let ((operation (gethash name emacsctl--operations)))
    (unless operation
      (signal 'emacsctl-unknown-operation (list "Unknown operation")))
    (unless (emacsctl--available-p operation context)
      (signal 'emacsctl-disabled-operation (list "Operation is disabled")))
    (when (and (eq (plist-get context :interface) 'cli)
               (emacsctl--operation-deferred operation))
      (signal 'emacsctl-disabled-operation
              (list "Deferred operation is unavailable through the CLI")))
    (funcall (emacsctl--operation-handler operation)
             (emacsctl--validate-arguments operation arguments)
             context)))

(defun emacsctl-project-file-p (file root)
  "Return non-nil when local FILE is beneath ROOT."
  (when (and (stringp file) (stringp root) (not (file-remote-p file)))
    (let ((file (expand-file-name file root))
          (root (file-name-as-directory (expand-file-name root))))
      (and (not (file-symlink-p file))
           (file-in-directory-p
            (if (file-exists-p file)
                (file-truename file)
              (file-truename (file-name-directory file)))
            (file-truename root))))))

(defun emacsctl-project-path (value root)
  "Return local VALUE below ROOT as an absolute path, or nil."
  (when (and (stringp value) (emacsctl-project-file-p value root))
    (expand-file-name value root)))

(defun emacsctl--buffer-record (buffer)
  "Return a JSON record describing BUFFER."
  (with-current-buffer buffer
    `((name . ,(buffer-name buffer))
      (file . ,buffer-file-name)
      (major_mode . ,(symbol-name major-mode))
      (modified . ,(if (buffer-modified-p) t :json-false)))))

(defun emacsctl--buffer-list (_arguments context)
  "List visible buffers under the project in CONTEXT."
  (let ((root (plist-get context :project-root)))
    (vconcat
     (delq nil
           (mapcar
            (lambda (buffer)
              (with-current-buffer buffer
                (when (and (not (string-prefix-p " " (buffer-name buffer)))
                           (or (null buffer-file-name)
                               (null root)
                               (emacsctl-project-file-p buffer-file-name root)))
                  (emacsctl--buffer-record buffer))))
            (buffer-list))))))

(defun emacsctl--select-position
    (buffer line column end-line start-text end-text)
  "Select a location in BUFFER from LINE, COLUMN, and END-LINE.
START-TEXT and END-TEXT refine the selection bounds."
  (with-current-buffer buffer
    (setq mark-active nil)
    (goto-char (point-min))
    (when line (forward-line (1- (max 1 line))))
    (when column (move-to-column column))
    (let ((begin (point))
          finish)
      (when start-text
        (unless (search-forward start-text (and line (line-end-position)) t)
          (setq begin nil))
        (when begin (setq begin (match-beginning 0))))
      (goto-char (or begin (point-min)))
      (cond
       (end-line
        (goto-char (point-min))
        (forward-line (1- (max 1 end-line)))
        (setq finish (line-end-position))
        (when end-text
          (when (search-forward end-text finish t)
            (setq finish (match-end 0)))))
       (end-text
        (when (search-forward end-text nil t)
          (setq finish (match-end 0)))))
      (if (and begin finish)
          (progn (goto-char finish) (push-mark begin t t))
        (goto-char (or begin (point-min)))))))

(defun emacsctl--owner-buffers (owner &optional create)
  "Return OWNER's buffer table, creating it when CREATE is non-nil."
  (or (gethash owner emacsctl--buffers)
      (and create
           (puthash owner (make-hash-table :test #'equal) emacsctl--buffers))))

(defun emacsctl--remember-buffer (owner file record)
  "Remember that OWNER opened FILE through RECORD."
  (when owner
    (puthash file record (emacsctl--owner-buffers owner t))))

(defun emacsctl--other-buffer-owner-p (owner file)
  "Return non-nil when an owner other than OWNER tracks FILE."
  (let (found)
    (maphash
     (lambda (other files)
       (when (and (not (eq other owner)) (gethash file files))
         (setq found t)))
     emacsctl--buffers)
    found))

(defun emacsctl--buffer-open (arguments context)
  "Open the file in ARGUMENTS using CONTEXT."
  (let* ((root (plist-get context :project-root))
         (file (and root (emacsctl-project-path (alist-get 'path arguments) root)))
         (line (alist-get 'line arguments))
         (column (alist-get 'column arguments))
         (end-line (alist-get 'end_line arguments))
         (start-text (alist-get 'start_text arguments))
         (end-text (alist-get 'end_text arguments))
         (owner (plist-get context :owner)))
    (unless file
      (signal 'emacsctl-operation-failed '("Path is outside the project")))
    (let* ((existing (get-file-buffer file))
           (owned (and owner (emacsctl--owner-buffers owner)))
           (previous (and owned (gethash file owned)))
           (buffer (or existing (find-file-noselect file)))
           (window (or (get-buffer-window buffer 0)
                       (or (plist-get context :window) (selected-window))))
           (record (emacsctl--make-owned-buffer
                  :buffer buffer :window window
                  :owned-p (or (null existing)
                               (and previous
                                    (emacsctl--owned-buffer-owned-p previous))))))
      (when (window-live-p window) (set-window-buffer window buffer))
      (emacsctl--select-position buffer line column end-line start-text end-text)
      (when (window-live-p window)
        (set-window-point window (with-current-buffer buffer (point))))
      (emacsctl--remember-buffer owner file record)
      (with-current-buffer buffer
        `((buffer . ,(buffer-name buffer))
          (file . ,file)
          (line . ,(line-number-at-pos))
          (column . ,(current-column)))))))

(defun emacsctl-release-buffer (owner file)
  "Release OWNER's tracked FILE buffer and return non-nil on completion."
  (when-let* ((files (emacsctl--owner-buffers owner))
              (record (gethash file files)))
    (let ((buffer (emacsctl--owned-buffer-buffer record))
          (window (emacsctl--owned-buffer-window record)))
      (when (and (window-live-p window) (eq (window-buffer window) buffer))
        (set-window-buffer window (other-buffer buffer t)))
      (when (and (emacsctl--owned-buffer-owned-p record)
                 (emacsctl--other-buffer-owner-p owner file))
        (maphash
         (lambda (other other-files)
           (when-let* (((not (eq other owner)))
                       (other-record (gethash file other-files)))
             (setf (emacsctl--owned-buffer-owned-p other-record) t)))
         emacsctl--buffers))
      (when (and (emacsctl--owned-buffer-owned-p record)
                 (buffer-live-p buffer)
                 (not (buffer-modified-p buffer))
                 (not (emacsctl--other-buffer-owner-p owner file))
                 (null (get-buffer-window-list buffer nil 0)))
        (kill-buffer buffer))
      (when (or (not (emacsctl--owned-buffer-owned-p record))
                (not (buffer-live-p buffer))
                (buffer-modified-p buffer)
                (emacsctl--other-buffer-owner-p owner file)
                (get-buffer-window-list buffer nil 0))
        (remhash file files))
      (when (= (hash-table-count files) 0)
        (remhash owner emacsctl--buffers))
      (not (gethash file files)))))

(defun emacsctl-release-owner (owner)
  "Release buffers tracked for opaque OWNER without killing modified buffers."
  (when-let* ((files (emacsctl--owner-buffers owner)))
    (maphash (lambda (file _record) (emacsctl-release-buffer owner file))
             (copy-hash-table files))
    (when (= (hash-table-count files) 0)
      (remhash owner emacsctl--buffers)))
  (null (emacsctl--owner-buffers owner)))

(defun emacsctl--buffer-release (arguments context)
  "Release the buffer in ARGUMENTS using CONTEXT."
  (let* ((root (plist-get context :project-root))
         (file (and root (emacsctl-project-path (alist-get 'path arguments) root))))
    (unless file
      (signal 'emacsctl-operation-failed '("Path is outside the project")))
    (emacsctl-release-buffer (plist-get context :owner) file)
    "Released buffer"))

(defun emacsctl--window-list (_arguments context)
  "List windows from the frame in CONTEXT."
  (let ((frame (or (plist-get context :frame) (selected-frame))))
    (vconcat
     (mapcar
      (lambda (window)
        (let ((buffer (window-buffer window)))
          `((buffer . ,(buffer-name buffer))
            (file . ,(buffer-local-value 'buffer-file-name buffer))
            (selected . ,(if (eq window (selected-window)) t :json-false))
            (start . ,(window-start window)))))
      (window-list frame 'nomini)))))

(defun emacsctl--diagnostic-severity (type)
  "Return normalized Flymake TYPE."
  (let ((name (if (symbolp type) (symbol-name type) "info")))
    (string-remove-prefix ":" name)))

(defun emacsctl--diagnostic-record (diagnostic)
  "Return a JSON record for Flymake DIAGNOSTIC."
  (let ((buffer (flymake-diagnostic-buffer diagnostic)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (flymake-diagnostic-beg diagnostic))
        `((file . ,buffer-file-name)
          (message . ,(flymake-diagnostic-text diagnostic))
          (line . ,(line-number-at-pos))
          (column . ,(current-column))
          (severity . ,(emacsctl--diagnostic-severity
                        (flymake-diagnostic-type diagnostic))))))))

(defun emacsctl--diagnostic-list (_arguments context)
  "List visited project diagnostics using CONTEXT."
  (let ((root (plist-get context :project-root))
        diagnostics)
    (dolist (buffer (buffer-list))
      (when-let* ((file (buffer-file-name buffer))
                  ((or (null root) (emacsctl-project-file-p file root))))
        (with-current-buffer buffer
          (when (fboundp 'flymake-diagnostics)
            (dolist (diagnostic (flymake-diagnostics))
              (push (emacsctl--diagnostic-record diagnostic) diagnostics))))))
    (vconcat (nreverse diagnostics))))

(defun emacsctl--eval (arguments _context)
  "Evaluate the code in ARGUMENTS."
  (let ((code (alist-get 'code arguments))
        (position 0)
        value)
    (condition-case err
        (while t
          (pcase-let ((`(,form . ,next) (read-from-string code position)))
            (setq value (eval form t)
                  position next)))
      (end-of-file
       (unless (string-match-p "\\`\\(?:[ \t\n\r]+\\|;[^\n]*\\)*\\'"
                               (substring code position))
         (signal (car err) (cdr err)))))
    (prin1-to-string value)))

(defun emacsctl--project-root (directory)
  "Return a canonical project root for DIRECTORY."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (project (project-current nil default-directory)))
    (file-truename (if project (project-root project) default-directory))))

(defun emacsctl-skill (&optional context)
  "Return the current agent skill for optional CONTEXT."
  (concat
   "# emacsctl\n\n"
   "Use `emacsctl` to inspect or operate the local Emacs session.\n\n"
   "## Commands\n\n"
   "```text\n"
   "emacsctl operations\n"
   "emacsctl call OPERATION [JSON|-]\n"
   "emacsctl skill\n"
   "```\n\n"
   "`call` accepts `{}` by default; `-` reads one JSON object from stdin. "
   "Normal output is one JSON object.\n\n"
   "## Operations\n\n"
   (mapconcat
    (lambda (operation)
      (format "- `%s` (%s): %s"
              (alist-get 'name operation)
              (alist-get 'effect operation)
              (alist-get 'description operation)))
    (emacsctl-operations context) "\n")
   "\n\n"
   "## Authority\n\n"
   "This interface uses the current user's local Emacs server. It reduces "
   "accidental misuse and payload quoting errors; it is not a sandbox.\n"))

(defun emacsctl--success (operation result)
  "Return a successful envelope for OPERATION and RESULT."
  `((version . ,emacsctl-protocol-version) (ok . t)
    ,@(when operation `((operation . ,operation)))
    (result . ,result)))

(defun emacsctl--failure (operation code message)
  "Return a failure envelope for OPERATION with CODE and MESSAGE."
  `((version . ,emacsctl-protocol-version) (ok . :json-false)
    ,@(when operation `((operation . ,operation)))
    (error . ((code . ,code) (message . ,message)))))

(defun emacsctl--dispatch-error (condition operation)
  "Map CONDITION for OPERATION to a status and envelope."
  (let* ((type (car condition))
         (message (or (cadr condition) "Operation failed"))
         (mapping
          (cond
           ((eq type 'emacsctl-unsupported-version) '(2 . "unsupported_version"))
           ((eq type 'emacsctl-invalid-request) '(2 . "invalid_request"))
           ((eq type 'emacsctl-unknown-operation) '(3 . "unknown_operation"))
           ((eq type 'emacsctl-disabled-operation) '(3 . "disabled_operation"))
           ((eq type 'emacsctl-invalid-arguments) '(3 . "invalid_arguments"))
           ((eq type 'emacsctl-operation-failed) '(5 . "operation_failed"))
           (t '(5 . "internal_error")))))
    (cons (car mapping)
          (emacsctl--failure operation (cdr mapping)
                             (if (eq (car mapping) 5)
                                 (if (eq type 'emacsctl-operation-failed)
                                     message
                                   "Internal error")
                               message)))))

(defun emacsctl--decode-request (encoded)
  "Decode and validate the Base64 JSON request ENCODED."
  (unless (and (stringp encoded)
               (string-match-p "\\`[A-Za-z0-9+/]*=\\{0,2\\}\\'" encoded))
    (signal 'emacsctl-invalid-request '("Malformed request encoding")))
  (condition-case nil
      (json-parse-string
       (decode-coding-string (base64-decode-string encoded) 'utf-8)
       :object-type 'alist :array-type 'array :null-object :json-null
       :false-object :json-false)
    (error (signal 'emacsctl-invalid-request '("Malformed JSON request")))))

(defun emacsctl--request-context (request)
  "Build an invocation context from REQUEST."
  (let ((encoded (alist-get 'cwd_base64 request)))
    (unless (stringp encoded)
      (signal 'emacsctl-invalid-request '("Missing working directory")))
    (let ((directory
           (condition-case nil
               (decode-coding-string (base64-decode-string encoded) 'utf-8)
             (error (signal 'emacsctl-invalid-request
                            '("Malformed working directory"))))))
      (unless (file-directory-p directory)
        (signal 'emacsctl-invalid-request '("Working directory does not exist")))
      `(:interface cli :source cli :project-root ,(emacsctl--project-root directory)
        :frame ,(selected-frame) :window ,(selected-window)))))

(defun emacsctl--dispatch (request)
  "Dispatch parsed REQUEST and return a status plus payload."
  (let ((operation (alist-get 'operation request)))
    (condition-case condition
        (progn
          (unless (equal (alist-get 'version request) emacsctl-protocol-version)
            (signal 'emacsctl-unsupported-version '("Unsupported protocol version")))
          (let ((method (alist-get 'method request))
                (context (emacsctl--request-context request)))
            (pcase method
              ("operations"
               (cons 0 (emacsctl--success nil (vconcat (emacsctl-operations context)))))
              ("call"
               (unless (and (stringp operation)
                            (listp (alist-get 'arguments request)))
                 (signal 'emacsctl-invalid-request '("Invalid call request")))
               (cons 0 (emacsctl--success
                        operation
                        (emacsctl-call operation (alist-get 'arguments request) context))))
              ("skill" (cons 0 (emacsctl-skill context)))
              (_ (signal 'emacsctl-invalid-request '("Unknown method"))))))
      (error (emacsctl--dispatch-error condition operation)))))

(defun emacsctl-server-dispatch (encoded-request)
  "Dispatch ENCODED-REQUEST and return `STATUS:BASE64(PAYLOAD)'."
  (let* ((response
          (condition-case condition
              (emacsctl--dispatch (emacsctl--decode-request encoded-request))
            (error (emacsctl--dispatch-error condition nil))))
         (status (car response))
         (value (cdr response))
         (payload (if (stringp value)
                      value
                    (json-serialize value :null-object nil
                                    :false-object :json-false))))
    (format "%d:%s" status
            (base64-encode-string (encode-coding-string payload 'utf-8) t))))

(emacsctl-register-operation
 "buffer.list" #'emacsctl--buffer-list
 :description "List live non-internal Emacs buffers."
 :effect 'read :parameters nil :interfaces '(cli adapter))

(emacsctl-register-operation
 "buffer.open" #'emacsctl--buffer-open
 :description "Open a local file in an Emacs buffer."
 :effect 'write
 :parameters '((:name "path" :type string :required t
                :description "Project-relative or absolute file path.")
               (:name "line" :type integer :description "One-based start line.")
               (:name "column" :type integer :description "Zero-based start column.")
               (:name "end_line" :type integer :description "One-based end line.")
               (:name "start_text" :type string :description "Text locating the start.")
               (:name "end_text" :type string :description "Text locating the end."))
 :interfaces '(cli adapter))

(emacsctl-register-operation
 "buffer.release" #'emacsctl--buffer-release
 :description "Release an adapter-owned Emacs buffer."
 :effect 'write :interfaces '(adapter)
 :parameters '((:name "path" :type string :required t)))

(emacsctl-register-operation
 "window.list" #'emacsctl--window-list
 :description "List windows in the selected Emacs frame."
 :effect 'read :parameters nil)

(emacsctl-register-operation
 "diagnostic.list" #'emacsctl--diagnostic-list
 :description "List Flymake diagnostics from visited project buffers."
 :effect 'read
 :parameters '((:name "uri" :type string :description "Optional file URI."))
 :interfaces '(cli adapter))

(emacsctl-register-operation
 "elisp.eval" #'emacsctl--eval
 :description "Evaluate explicitly enabled Emacs Lisp."
 :effect 'write :parameters '((:name "code" :type string :required t))
 :enabled-p (lambda (_context) emacsctl-enable-elisp-eval))

(provide 'emacsctl)
;;; emacsctl.el ends here
