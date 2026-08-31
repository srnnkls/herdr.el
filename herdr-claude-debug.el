;;; herdr-claude-debug.el --- Claude protocol debugging -*- lexical-binding: t; -*-

;;; Commentary:

;; Debug controls for the Claude protocol integration.

;;; Code:

(require 'herdr-claude)

(defvar herdr-claude-debug--log-buffer-name "*herdr-claude-protocol*"
  "Name of the raw Claude IDE protocol log buffer.")
(defvar herdr-claude-debug--log-buffer nil
  "Raw Claude IDE protocol log buffer.")

(defun herdr-claude-debug--set-raw-protocol-logging (symbol value)
  "Set SYMBOL to VALUE and update raw protocol logging hooks."
  (set-default symbol value)
  (if value
      (progn
        (add-hook 'herdr-claude-protocol--incoming-observers
                  #'herdr-claude-debug--incoming)
        (add-hook 'herdr-claude-protocol--outgoing-observers
                  #'herdr-claude-debug--outgoing))
    (remove-hook 'herdr-claude-protocol--incoming-observers
                 #'herdr-claude-debug--incoming)
    (remove-hook 'herdr-claude-protocol--outgoing-observers
                 #'herdr-claude-debug--outgoing)
    (when (buffer-live-p herdr-claude-debug--log-buffer)
      (kill-buffer herdr-claude-debug--log-buffer))
    (unless (buffer-live-p herdr-claude-debug--log-buffer)
      (setq herdr-claude-debug--log-buffer nil))))

(defcustom herdr-claude-protocol-logging nil
  "When non-nil, log raw protocol payloads.
Raw protocol data can expose sensitive project and user content."
  :type 'boolean
  :group 'herdr-claude
  :set #'herdr-claude-debug--set-raw-protocol-logging)

(defun herdr-claude-debug-log-buffer ()
  "Return the Claude IDE protocol log buffer."
  (or (and (buffer-live-p herdr-claude-debug--log-buffer)
           herdr-claude-debug--log-buffer)
      (setq herdr-claude-debug--log-buffer
            (generate-new-buffer herdr-claude-debug--log-buffer-name))))

(defun herdr-claude-debug--record (direction state client text)
  "Record DIRECTION TEXT for STATE and CLIENT."
  (when herdr-claude-protocol-logging
    (with-current-buffer (herdr-claude-debug-log-buffer)
      (goto-char (point-max))
      (insert (format "%s session=%S generation=%s %s\n"
                      direction
                      (when-let* ((session (herdr-claude-protocol-state-session state)))
                        (herdr-agent-session-key session))
                      (herdr-claude-protocol-client-generation client)
                      text)))))

(defun herdr-claude-debug--incoming (state client text)
  "Record incoming TEXT for STATE and CLIENT."
  (herdr-claude-debug--record "incoming" state client text))

(defun herdr-claude-debug--outgoing (state client text)
  "Record outgoing TEXT for STATE and CLIENT."
  (herdr-claude-debug--record "outgoing" state client text))

;;;###autoload
(defun herdr-claude-debug-open-log ()
  "Display the raw Claude protocol log."
  (interactive)
  (pop-to-buffer (herdr-claude-debug-log-buffer)))

(defun herdr-claude-debug-enable ()
  "Enable raw Claude IDE protocol logging."
  (interactive)
  (customize-set-variable 'herdr-claude-protocol-logging t))

(defun herdr-claude-debug-disable ()
  "Disable raw Claude IDE protocol logging."
  (interactive)
  (customize-set-variable 'herdr-claude-protocol-logging nil))

(provide 'herdr-claude-debug)
;;; herdr-claude-debug.el ends here
