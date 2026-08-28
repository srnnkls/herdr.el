;;; herdr-api-gen.el --- Generate herdr-api.el from the herdr schema -*- lexical-binding: t; -*-

;;; Commentary:

;; Regenerate the API wrappers from the schema of the installed herdr:
;;
;;   herdr api schema --json > /tmp/herdr-api.schema.json
;;   emacs -Q --batch -l tools/herdr-api-gen.el \
;;         --eval '(herdr-api-gen "/tmp/herdr-api.schema.json" "herdr-api.el")'

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst herdr-api-gen-streaming-methods '("events.subscribe")
  "Methods whose responses keep streaming after the first line.")

(defun herdr-api-gen--symbol (name)
  "Return the Lisp argument name for JSON property NAME."
  (intern (string-replace "_" "-" name)))

(defun herdr-api-gen--function (method)
  "Return the Lisp function name for API METHOD."
  (intern (concat "herdr-api-" (string-replace "." "-" (string-replace "_" "-" method)))))

(defun herdr-api-gen--resolve (ref defs)
  "Return the definition REF points at inside DEFS."
  (alist-get (intern (car (last (split-string ref "/")))) defs))

(defun herdr-api-gen--params (method-entry defs)
  "Return (REQUIRED OPTIONAL) property names for METHOD-ENTRY resolved in DEFS."
  (let* ((ref (alist-get '$ref (alist-get 'params (alist-get 'properties method-entry))))
         (params (and ref (herdr-api-gen--resolve ref defs)))
         (properties (mapcar (lambda (property) (symbol-name (car property)))
                             (alist-get 'properties params)))
         (required (alist-get 'required params)))
    (list (cl-remove-if-not (lambda (name) (member name required)) properties)
          (cl-remove-if (lambda (name) (member name required)) properties))))

(defun herdr-api-gen--fill (text)
  "Return TEXT with every paragraph filled to fit a docstring."
  (with-temp-buffer
    (insert text)
    (let ((fill-column 72))
      (fill-region (point-min) (point-max)))
    (buffer-string)))

(defun herdr-api-gen--docstring (method required optional)
  "Return the docstring for METHOD taking REQUIRED and OPTIONAL properties."
  (let ((upcase (lambda (names)
                  (mapconcat (lambda (name) (upcase (symbol-name (herdr-api-gen--symbol name))))
                             names ", "))))
    (concat (format "Call the herdr API method `%s'.\n" method)
            (when required
              (herdr-api-gen--fill
               (format "\n%s %s required.\n" (funcall upcase required)
                       (if (cdr required) "are" "is"))))
            (when optional
              (concat
               (herdr-api-gen--fill
                (format "\nKeyword arguments: %s.\n" (funcall upcase optional)))
               "Omitted (nil) keys are left out of the request;\npass `:false' to send a literal false.\n"))
            (when (member method herdr-api-gen-streaming-methods)
              "\nOnly the acknowledgement is returned; use `herdr-subscribe' to
receive the events that follow.\n")
            "\nReturn the result alist.")))

(defun herdr-api-gen--form (method required optional)
  "Return the defun form wrapping METHOD with REQUIRED and OPTIONAL properties."
  (let* ((name (herdr-api-gen--function method))
         (args (append (mapcar #'herdr-api-gen--symbol required)
                       (when optional
                         (cons '&key (mapcar #'herdr-api-gen--symbol optional)))))
         (pairs (mapcar (lambda (property)
                          `(cons ',(intern property)
                                 ,(if (and (equal method "agent.start")
                                           (equal property "args"))
                                      `(and ,(herdr-api-gen--symbol property)
                                            (vconcat ,(herdr-api-gen--symbol property)))
                                    (herdr-api-gen--symbol property))))
                        (append required optional)))
         (body (if pairs
                   `(herdr-request ,method (herdr--params (list ,@pairs)))
                 `(herdr-request ,method))))
    `(,(if optional 'cl-defun 'defun) ,name ,args
      ,(herdr-api-gen--docstring method required optional)
      ,body)))

(defun herdr-api-gen (schema-file out-file)
  "Write Lisp wrappers for every method in SCHEMA-FILE to OUT-FILE."
  (let* ((schema (with-temp-buffer
                   (insert-file-contents schema-file)
                   (json-parse-buffer :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)))
         (request (alist-get 'request (alist-get 'schemas schema)))
         (defs (alist-get '$defs request))
         (protocol (alist-get 'protocol schema))
         (forms (mapcar
                 (lambda (entry)
                   (let* ((method (alist-get 'const (alist-get 'method (alist-get 'properties entry))))
                          (params (herdr-api-gen--params entry defs)))
                     (herdr-api-gen--form method (nth 0 params) (nth 1 params))))
                 (alist-get 'oneOf request))))
    (with-temp-file out-file
      (insert ";;; herdr-api.el --- Wrappers for the herdr socket API -*- lexical-binding: t; -*-\n\n"
              ";;; Commentary:\n\n"
              (format ";; Generated by tools/herdr-api-gen.el from herdr protocol %s.\n" protocol)
              ";; Every method of the herdr socket API gets one function; see\n"
              ";; https://herdr.dev/docs/socket-api/ for what each of them does.\n"
              ";; Do not edit by hand: regenerate after a herdr upgrade.\n\n"
              ";;; Code:\n\n"
              "(require 'cl-lib)\n(require 'herdr-core)\n\n"
              (format "(defconst herdr-api-protocol %s\n  \"herdr socket protocol version these wrappers were generated from.\")\n\n"
                      protocol))
      (let ((print-quoted t))
        (dolist (form forms)
          (insert (pp-to-string form) "\n")))
      (insert "(provide 'herdr-api)\n;;; herdr-api.el ends here\n")
      (goto-char (point-min))
      (while (search-forward "\\n" nil t) (replace-match "\n"))
      (goto-char (point-min))
      (while (re-search-forward "^(defun \\(herdr-api-[^ ]+\\) nil$" nil t)
        (replace-match "(defun \\1 ()")))
    (with-current-buffer (find-file-noselect out-file)
      (emacs-lisp-mode)
      (let ((indent-tabs-mode nil))
        (indent-region (point-min) (point-max))
        (untabify (point-min) (point-max)))
      (save-buffer)
      (kill-buffer))
    (length forms)))

(provide 'herdr-api-gen)
;;; herdr-api-gen.el ends here
