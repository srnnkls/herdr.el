;;; herdr-core.el --- Socket client for the herdr API -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; Author: Sören Nikolaus <soeren@code17.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: terminals, tools, processes
;; URL: https://github.com/srnnkls/herdr.el

;;; Commentary:

;; Request/response and subscription plumbing for herdr's newline-delimited
;; JSON socket API.  The generated wrappers in herdr-api.el and the commands
;; in herdr.el sit on top of this.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(defcustom herdr-session nil
  "Name of the herdr session to talk to, or nil for the default session."
  :type '(choice (const :tag "Default session" nil) string))

(defcustom herdr-request-timeout 5.0
  "Seconds to wait for a response from the herdr API socket.
Bind this around calls that wait on the server, such as
`herdr-api-agent-wait' or `herdr-api-pane-wait-for-output'."
  :type 'number)

(define-error 'herdr-error "herdr error")
(define-error 'herdr-api-error "herdr API error" 'herdr-error)

(defvar herdr--request-counter 0)

(defun herdr-socket-file ()
  "Return the path of the herdr JSON API socket."
  (or herdr-socket-path
      (let ((dir (expand-file-name
                  "herdr" (or (getenv "XDG_CONFIG_HOME")
                              (expand-file-name "~/.config")))))
        (expand-file-name (if herdr-session
                              (format "herdr-%s.sock" herdr-session)
                            "herdr.sock")
                          dir))))

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

(defun herdr-subscribe (types callback)
  "Subscribe to herdr event TYPES and call CALLBACK for each event.
TYPES is a list of event type strings such as \"pane.agent_detected\".
CALLBACK receives the event alist.  Returns the subscription process;
`delete-process' on it unsubscribes."
  (let ((proc (herdr--connect))
        (pending ""))
    (set-process-filter
     proc
     (lambda (_proc chunk)
       (setq pending (concat pending chunk))
       (while (string-match "\n" pending)
         (let ((line (substring pending 0 (match-beginning 0))))
           (setq pending (substring pending (match-end 0)))
           (unless (string-empty-p line)
             (when-let* ((message (ignore-errors (herdr--decode line)))
                         (event (alist-get 'event message)))
               (funcall callback event)))))))
    (process-send-string
     proc (herdr--payload "events.subscribe"
                          `((subscriptions . ,(mapcar (lambda (type) `((type . ,type))) types)))))
    proc))

(provide 'herdr-core)
;;; herdr-core.el ends here
