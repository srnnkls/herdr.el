;;; herdr-core.el --- Socket client for the herdr API -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Keywords: terminals, tools, processes
;; URL: https://github.com/srnnkls/herdr.el

;;; Commentary:

;; Request/response and subscription plumbing for herdr's newline-delimited
;; JSON socket API.  The generated wrappers in herdr-api.el and the commands
;; in herdr.el sit on top of this.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function projectile-project-root "ext:projectile" (&optional dir))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

(defgroup herdr nil
  "Control herdr terminal workspaces from Emacs."
  :group 'external
  :prefix "herdr-")

(defcustom herdr-executable "herdr"
  "Name of, or path to, the herdr executable."
  :type 'string)

(defcustom herdr-socket-path nil
  "Path to the herdr JSON API socket.
When nil the path is derived from `herdr-session' and the herdr
configuration directory."
  :type '(choice (const :tag "Derive from session" nil) file))

(defcustom herdr-session 'shared
  "Which herdr server Emacs talks to.
`shared' uses the default session - the one a bare `herdr' attaches to -
so Emacs sessions sit next to the terminal ones in the herdr UI.
`emacs' keeps Emacs on a session of its own, named by
`herdr-emacs-session-name', leaving the shared session to hand-run
agents.  A string names a session directly."
  :type '(choice (const :tag "Shared default session" shared)
                 (const :tag "Session of its own" emacs)
                 (string :tag "Named session")))

(defcustom herdr-emacs-session-name "emacs"
  "Name of the session `herdr-session' set to `emacs' uses."
  :type 'string)

(defcustom herdr-project-sessions nil
  "Projects assigned to a herdr session, as (PROJECT-ROOT . SESSION).
This is the explicit half of session routing; `herdr-assign-project'
and `herdr-assign-project-session' maintain it.  SESSION takes the
values `herdr-session' does.

  (setq herdr-project-sessions
        \\='((\"~/work/backend\" . \"work\")
          (\"~/src/herdr.el\" . \"private\")))"
  :type '(alist :key-type directory
                :value-type (choice (const shared) (const emacs) string)))

(defcustom herdr-session-alist nil
  "Rules deriving a herdr session for projects nothing was assigned to.
Each entry is (MATCHER . SESSION).  MATCHER is a directory whose tree
the rule covers, or a function called with a directory that returns
non-nil when the rule applies.  The first matching rule wins;
`herdr-session' is the answer when none do.

  (setq herdr-session-alist
        \\='((\"~/work\" . \"work\")
          (\"~/src\"  . \"private\")))"
  :type '(alist :key-type (choice directory function)
                :value-type (choice (const shared) (const emacs) string)))

(defcustom herdr-state-file (locate-user-emacs-file "herdr/project-sessions.eld")
  "File the assignments made with `herdr-assign-project' persist in.
Point this at your setup's durable state directory - Doom's
`doom-state-dir', say - since `locate-user-emacs-file' lands in the
cache directory there.  Assignments written in configuration through
`herdr-project-sessions' need no file and win over the stored ones."
  :type 'file)

(defcustom herdr-project-root-function #'herdr-project-root
  "Function returning the project root a directory belongs to, or nil.
The default asks projectile, then project.el."
  :type 'function)

(defcustom herdr-auto-start-server t
  "Whether Emacs starts a headless herdr server when none is running."
  :type 'boolean)

(defcustom herdr-server-start-timeout 15.0
  "Seconds to wait for a herdr server Emacs started to answer."
  :type 'number)

(defcustom herdr-request-timeout 5.0
  "Seconds to wait for a response from the herdr API socket.
Bind this around calls that wait on the server, such as
`herdr-api-agent-wait' or `herdr-api-pane-wait-for-output'."
  :type 'number)

(define-error 'herdr-error "herdr error")
(define-error 'herdr-api-error "herdr API error" 'herdr-error)

(defvar herdr--request-counter 0)

(defun herdr-session-name (&optional session)
  "Return the name of SESSION, or nil when it is the default one.
SESSION defaults to `herdr-session' and takes the same values."
  (pcase (or session herdr-session)
    ((or 'nil 'shared) nil)
    ('emacs herdr-emacs-session-name)
    ((and (pred stringp) name) name)
    (other (signal 'herdr-error (list (format "invalid herdr session: %S" other))))))

(defun herdr-project-root (&optional directory)
  "Return the root of the project holding DIRECTORY, or nil.
Asks projectile when it is loaded, otherwise project.el."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name (or directory default-directory)))))
    (or (and (featurep 'projectile)
             (fboundp 'projectile-project-root)
             (projectile-project-root))
        (and (require 'project nil t)
             (when-let* ((project (project-current)))
               (project-root project))))))

(defun herdr--same-directory-p (a b)
  "Return non-nil when A and B name the same directory.
Compares by name so assignments survive directories that are not on
disk right now, and by identity when both are."
  (let ((a (file-name-as-directory (expand-file-name a)))
        (b (file-name-as-directory (expand-file-name b))))
    (or (string-equal a b)
        (and (file-directory-p a) (file-directory-p b) (file-equal-p a b)))))

(defvar herdr--stored-assignments nil
  "Cons of the state file last read and the assignments it held.")

(defun herdr--read-state-file ()
  "Return the assignments in `herdr-state-file', or nil when it has none."
  (when (and herdr-state-file (file-readable-p herdr-state-file))
    (with-temp-buffer
      (insert-file-contents herdr-state-file)
      (condition-case nil
          (let ((stored (read (current-buffer))))
            (and (listp stored) stored))
        (error nil)))))

(defun herdr-stored-assignments ()
  "Return the assignments saved in `herdr-state-file'.
The file is read again whenever `herdr-state-file' names another one."
  (unless (equal (car herdr--stored-assignments) herdr-state-file)
    (setq herdr--stored-assignments (cons herdr-state-file (herdr--read-state-file))))
  (cdr herdr--stored-assignments))

(defun herdr-save-assignments ()
  "Write the stored assignments to `herdr-state-file'."
  (when herdr-state-file
    (make-directory (file-name-directory herdr-state-file) t)
    (with-temp-file herdr-state-file
      (let ((print-length nil) (print-level nil))
        (prin1 (herdr-stored-assignments) (current-buffer))
        (insert "\n")))
    herdr-state-file))

(defun herdr-project-assignments ()
  "Return every project assignment, configured ones before stored ones."
  (append herdr-project-sessions (herdr-stored-assignments)))

(defun herdr-project-session (&optional directory)
  "Return the session DIRECTORY's project was assigned to, or nil.
An assignment matches its project root, and otherwise the deepest
assigned root the directory sits under, so a root that projectile and
project.el disagree about still resolves."
  (when-let* ((assignments (herdr-project-assignments)))
    (let* ((directory (expand-file-name (or directory default-directory)))
           (root (funcall herdr-project-root-function directory))
           (covering (cl-sort (cl-remove-if-not
                               (lambda (assignment)
                                 (herdr--directory-covers-p (car assignment) directory))
                               (copy-sequence assignments))
                              #'> :key (lambda (assignment) (length (car assignment))))))
      (or (when root
            (cdr (cl-find-if (lambda (assignment)
                               (herdr--same-directory-p (car assignment) root))
                             assignments)))
          (cdar covering)))))

(defun herdr--directory-covers-p (parent directory)
  "Return non-nil when DIRECTORY is PARENT or below it.
Compares by name, so a rule covers directories that are not checked
out yet."
  (string-prefix-p (file-name-as-directory (expand-file-name parent))
                   (file-name-as-directory (expand-file-name directory))))

(defun herdr--derived-session (directory)
  "Return the session `herdr-session-alist' derives for DIRECTORY, or nil."
  (cdr (cl-find-if
        (lambda (rule)
          (let ((matcher (car rule)))
            (if (functionp matcher)
                (funcall matcher directory)
              (herdr--directory-covers-p matcher directory))))
        herdr-session-alist)))

(defun herdr-session-for (&optional directory)
  "Return the herdr session DIRECTORY belongs to.
An assignment in `herdr-project-sessions' wins, then a rule in
`herdr-session-alist', then `herdr-session'."
  (let ((directory (expand-file-name (or directory default-directory))))
    (or (herdr-project-session directory)
        (herdr--derived-session directory)
        herdr-session)))

(defun herdr-assign-project (root session &optional no-save)
  "Assign the project at ROOT to herdr SESSION.
A nil SESSION drops the assignment.  The store is written to
`herdr-state-file' unless NO-SAVE is non-nil.  Returns SESSION."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (assignments (cl-remove-if (lambda (assignment)
                                      (herdr--same-directory-p (car assignment) root))
                                    (herdr-stored-assignments))))
    (when session (push (cons root session) assignments))
    (setq herdr--stored-assignments (cons herdr-state-file assignments))
    (unless no-save (herdr-save-assignments))
    session))

(defmacro herdr-with-session (session &rest body)
  "Run BODY talking to SESSION.
A nil SESSION leaves the current choice alone, so callers can pass
whatever an entry carries."
  (declare (indent 1) (debug (form body)))
  (let ((value (make-symbol "session"))
        (current (make-symbol "current-session")))
    `(let* ((,value ,session)
            (,current herdr-session)
            (herdr-session (or ,value ,current))
            (herdr-socket-path (if (and ,value (not (equal ,value ,current)))
                                   nil
                                 herdr-socket-path)))
       ,@body)))

(defun herdr-known-sessions ()
  "Return every session Emacs may talk to, `herdr-session' first."
  (delete-dups (append (list herdr-session)
                       (mapcar #'cdr (herdr-project-assignments))
                       (mapcar #'cdr herdr-session-alist))))

(defun herdr-socket-file ()
  "Return the path of the herdr JSON API socket."
  (or herdr-socket-path
      (let ((dir (expand-file-name
                  "herdr" (or (getenv "XDG_CONFIG_HOME")
                              (expand-file-name "~/.config"))))
            (session (herdr-session-name)))
        (expand-file-name "herdr.sock"
                          (if session
                              (expand-file-name session (expand-file-name "sessions" dir))
                            dir)))))

(defun herdr-server-key ()
  "Return the canonical identity of the herdr server in scope."
  (let* ((socket (expand-file-name (herdr-socket-file)))
         (parent (file-name-directory socket))
         (basename (file-name-nondirectory socket)))
    (if-let* ((target (file-symlink-p socket)))
        (file-truename (expand-file-name target parent))
      (if (file-exists-p socket)
          (file-truename socket)
        (expand-file-name basename (file-truename parent))))))

(defun herdr-session-server-key (session)
  "Return the canonical identity of the server SESSION is served by.
A session designator and an explicit `herdr-socket-path' both name a
server, and the designator is the one that answers here, so a caller
holding a session never reads the socket another scope left behind."
  (let ((herdr-session session)
        (herdr-socket-path nil))
    (herdr-server-key)))

(defun herdr-global-args ()
  "Return the herdr CLI flags selecting the session Emacs talks to.
A session flag carries the server's data directory as well as its
socket, which HERDR_SOCKET_PATH alone does not; an explicit
`herdr-socket-path' is left to speak for itself."
  (unless herdr-socket-path
    (when-let* ((session (herdr-session-name)))
      (list "--session" session))))

(defun herdr-process-environment ()
  "Return `process-environment' pointing herdr commands at our socket.
The herdr CLI derives both its API and client sockets from
HERDR_SOCKET_PATH, so an attach started from Emacs reaches the same
server `herdr-request' does."
  (cons (format "HERDR_SOCKET_PATH=%s" (herdr-socket-file)) process-environment))

(defun herdr--params (pairs)
  "Return PAIRS without the entries whose value is nil.
Pass `:false' or `:null' to send those JSON values explicitly."
  (cl-remove-if-not #'cdr pairs))

(defun herdr--connect ()
  "Open a connection to the herdr API socket."
  (let ((path (herdr-socket-file)))
    (unless (file-exists-p path)
      (signal 'herdr-error (list (format "no herdr socket at %s" path))))
    (condition-case err
        (make-network-process :name "herdr-api"
                              :family 'local
                              :service path
                              :coding 'utf-8-unix
                              :noquery t
                              :buffer (generate-new-buffer " *herdr-api*"))
      (file-error
       (signal 'herdr-error
               (list (format "cannot reach herdr at %s: %s"
                             path (error-message-string err))))))))

(defun herdr--payload (method params)
  "Return the request line sending METHOD with PARAMS."
  (concat (json-serialize `((id . ,(format "emacs:%d" (cl-incf herdr--request-counter)))
                            (method . ,method)
                            (params . ,params)))
          "\n"))

(defun herdr--decode (line)
  "Return the parsed herdr response LINE."
  (json-parse-string line :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun herdr--read-line (proc timeout)
  "Read one newline-terminated response line from PROC within TIMEOUT seconds."
  (let ((deadline (+ (float-time) timeout))
        (line nil))
    (while (not line)
      (with-current-buffer (process-buffer proc)
        (goto-char (point-min))
        (cond
         ((search-forward "\n" nil t)
          (setq line (buffer-substring-no-properties (point-min) (1- (point)))))
         ((> (float-time) deadline)
          (signal 'herdr-error (list "timed out waiting for herdr response")))
         ((not (process-live-p proc))
          (signal 'herdr-error (list "herdr closed the connection without a response")))
         (t (accept-process-output proc 0.05)))))
    line))

(defun herdr-request (method &optional params timeout)
  "Send METHOD with PARAMS to herdr and return the result alist.
PARAMS is an alist with symbol keys.  TIMEOUT defaults to
`herdr-request-timeout'.  Signals `herdr-api-error' when herdr
answers with an error, and `herdr-error' when it cannot be reached."
  (let ((proc (herdr--connect)))
    (unwind-protect
        (progn
          (process-send-string proc (herdr--payload method params))
          (let ((response (herdr--decode
                           (herdr--read-line proc (or timeout herdr-request-timeout)))))
            (when-let* ((err (alist-get 'error response)))
              (signal 'herdr-api-error
                      (list (alist-get 'code err) (alist-get 'message err))))
            (alist-get 'result response)))
      (let ((buffer (process-buffer proc)))
        (delete-process proc)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun herdr-available-p ()
  "Return non-nil when a herdr server answers on the API socket."
  (condition-case nil
      (and (herdr-request "ping") t)
    (herdr-error nil)))

(defun herdr-start-server ()
  "Start a headless herdr server and wait for it to answer.
Returns non-nil once it does.  The server is detached from Emacs, so
it outlives this session the way a herdr server started from a shell
does."
  (unless (executable-find herdr-executable)
    (signal 'herdr-error
            (list (format "herdr executable not found: %s" herdr-executable))))
  (let ((command (format "%s >/dev/null 2>&1 &"
                         (mapconcat #'shell-quote-argument
                                    (append (list herdr-executable)
                                            (herdr-global-args)
                                            (list "server"))
                                    " ")))
        (process-environment (herdr-process-environment)))
    (call-process-shell-command command nil 0)
    (let ((deadline (+ (float-time) herdr-server-start-timeout)))
      (while (and (< (float-time) deadline) (not (herdr-available-p)))
        (sleep-for 0.1))
      (herdr-available-p))))

(defun herdr-start-server-if-needed ()
  "Return non-nil once a herdr server answers on our socket.
A server that already answers is left alone.  Otherwise one is started
detached, unless `herdr-auto-start-server' is nil, and this waits up to
`herdr-server-start-timeout' seconds for it to come up.  Signals
`herdr-error' when no server can be reached."
  (or (herdr-available-p)
      (and herdr-auto-start-server (herdr-start-server))
      (signal 'herdr-error
              (list (format "no herdr server answering on %s" (herdr-socket-file))))))

(defun herdr-subscribe (types callback)
  "Subscribe to herdr event TYPES and call CALLBACK for each event.
TYPES is a list of event type strings such as \"pane.agent_detected\".
CALLBACK receives the event alist.  Returns the subscription process;
`delete-process' on it unsubscribes."
  (let ((proc (herdr--connect))
        (pending "")
        (subscriptions (vconcat (mapcar (lambda (type) `((type . ,type))) types))))
    (set-process-filter
     proc
     (lambda (_proc chunk)
       (setq pending (concat pending chunk))
       (while (string-match "\n" pending)
         (let ((line (substring pending 0 (match-beginning 0))))
           (setq pending (substring pending (match-end 0)))
           (unless (string-empty-p line)
             (when-let* ((message (ignore-errors (herdr--decode line)))
                         ((alist-get 'event message)))
               (funcall callback (alist-get 'data message))))))))
    (process-send-string proc
                         (herdr--payload "events.subscribe"
                                         `((subscriptions . ,subscriptions))))
    proc))

(provide 'herdr-core)
;;; herdr-core.el ends here
