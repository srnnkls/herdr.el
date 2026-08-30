;;; herdr-claude-code-ide-diagnostics.el --- Claude Code IDE diagnostics for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;;; Commentary:

;; Diagnostic collection and normalization for Claude Code IDE clients.

;;; Code:

(require 'cl-lib)
(require 'flymake)

(declare-function flycheck-error-message "flycheck" (error))
(declare-function flycheck-error-line "flycheck" (error))
(declare-function flycheck-error-column "flycheck" (error))
(declare-function flycheck-error-level "flycheck" (error))

(defun herdr-claude-code-ide-diagnostics--project-file-p (file root)
  "Return non-nil when FILE is beneath ROOT."
  (let ((file (expand-file-name file))
        (root (expand-file-name root)))
    (file-in-directory-p (if (file-exists-p file) (file-truename file) file)
                         (if (file-exists-p root) (file-truename root) root))))

(defun herdr-claude-code-ide-diagnostics--severity (severity)
  "Return a normalized string for SEVERITY."
  (cond ((and severity (symbolp severity))
         (if (keywordp severity)
             (substring (symbol-name severity) 1)
           (symbol-name severity)))
        ((stringp severity) severity)
        (t "info")))

(defun herdr-claude-code-ide-diagnostics--position (buffer position)
  "Return BUFFER's line and column at POSITION."
  (with-current-buffer buffer
    (save-excursion
      (goto-char position)
      (list (line-number-at-pos) (current-column)))))

(defun herdr-claude-code-ide-diagnostics--normalize-flymake (file diagnostic)
  "Normalize Flymake DIAGNOSTIC for FILE."
  (let* ((buffer (flymake-diagnostic-buffer diagnostic))
         (position (herdr-claude-code-ide-diagnostics--position
                    buffer (flymake-diagnostic-beg diagnostic))))
    `((filePath . ,file)
      (message . ,(flymake-diagnostic-text diagnostic))
      (line . ,(car position))
      (column . ,(cadr position))
      (severity . ,(herdr-claude-code-ide-diagnostics--severity
                    (flymake-diagnostic-type diagnostic))))))

(defun herdr-claude-code-ide-diagnostics--normalize-flycheck (file diagnostic)
  "Normalize Flycheck DIAGNOSTIC for FILE."
  `((filePath . ,file)
    (message . ,(flycheck-error-message diagnostic))
    (line . ,(flycheck-error-line diagnostic))
    (column . ,(flycheck-error-column diagnostic))
    (severity . ,(herdr-claude-code-ide-diagnostics--severity
                  (flycheck-error-level diagnostic)))))

(defun herdr-claude-code-ide-diagnostics--normalize (file diagnostic provider)
  "Normalize DIAGNOSTIC from PROVIDER for FILE."
  (cond ((eq provider 'flymake)
         (herdr-claude-code-ide-diagnostics--normalize-flymake file diagnostic))
        ((eq provider 'flycheck)
         (herdr-claude-code-ide-diagnostics--normalize-flycheck file diagnostic))
        (t
         (let ((message (or (plist-get diagnostic :message)
                            (plist-get diagnostic :text))))
           (when message
             `((filePath . ,file)
               (message . ,message)
               (line . ,(plist-get diagnostic :line))
               (column . ,(plist-get diagnostic :column))
               (severity . ,(herdr-claude-code-ide-diagnostics--severity
                             (or (plist-get diagnostic :severity)
                                 (plist-get diagnostic :level))))))))))

(defun herdr-claude-code-ide-diagnostics-collect-diagnostics (providers buffers root)
  "Collect diagnostics from BUFFERS beneath ROOT.
PROVIDERS maps names to functions and calls them for matching buffers.
Returns normalized records."
  (let (diagnostics)
    (dolist (buffer buffers)
      (when-let* ((file (buffer-file-name buffer))
                  ((herdr-claude-code-ide-diagnostics--project-file-p file root)))
        (dolist (provider providers)
          (dolist (diagnostic (funcall (cdr provider) buffer))
            (when-let* ((normalized
                         (herdr-claude-code-ide-diagnostics--normalize
                          file diagnostic (car provider))))
              (push normalized diagnostics))))))
    (nreverse diagnostics)))

(provide 'herdr-claude-code-ide-diagnostics)
;;; herdr-claude-code-ide-diagnostics.el ends here
