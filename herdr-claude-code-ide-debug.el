;;; herdr-claude-code-ide-debug.el --- Claude IDE protocol debugging -*- lexical-binding: t; -*-

(require 'herdr-claude-code-ide-mcp)

(defgroup herdr-claude-code-ide nil
  "Herdr Claude Code IDE integration."
  :group 'herdr)

(defvar herdr-claude-code-ide-debug--log-buffer-name "*herdr-claude-code-ide-protocol*")
(defvar herdr-claude-code-ide-debug--log-buffer nil)

(defun herdr-claude-code-ide-debug--set-raw-protocol-logging (symbol value)
  (set-default symbol value)
  (if value
      (progn
        (add-hook 'herdr-claude-code-ide-mcp--incoming-observers
                  #'herdr-claude-code-ide-debug--incoming)
        (add-hook 'herdr-claude-code-ide-mcp--outgoing-observers
                  #'herdr-claude-code-ide-debug--outgoing))
    (remove-hook 'herdr-claude-code-ide-mcp--incoming-observers
                 #'herdr-claude-code-ide-debug--incoming)
    (remove-hook 'herdr-claude-code-ide-mcp--outgoing-observers
                 #'herdr-claude-code-ide-debug--outgoing)
    (when (buffer-live-p herdr-claude-code-ide-debug--log-buffer)
      (kill-buffer herdr-claude-code-ide-debug--log-buffer))
    (unless (buffer-live-p herdr-claude-code-ide-debug--log-buffer)
      (setq herdr-claude-code-ide-debug--log-buffer nil))))

(defcustom herdr-claude-code-ide-raw-protocol-logging nil
  "When non-nil, log raw protocol payloads.
Raw protocol data can expose sensitive project and user content."
  :type 'boolean
  :group 'herdr-claude-code-ide
  :set #'herdr-claude-code-ide-debug--set-raw-protocol-logging)

(defun herdr-claude-code-ide-debug-log-buffer ()
  "Return the Claude IDE protocol log buffer."
  (or (and (buffer-live-p herdr-claude-code-ide-debug--log-buffer)
           herdr-claude-code-ide-debug--log-buffer)
      (setq herdr-claude-code-ide-debug--log-buffer
            (generate-new-buffer herdr-claude-code-ide-debug--log-buffer-name))))

(defun herdr-claude-code-ide-debug--record (direction adapter client text)
  (when herdr-claude-code-ide-raw-protocol-logging
    (with-current-buffer (herdr-claude-code-ide-debug-log-buffer)
      (goto-char (point-max))
      (insert (format "%s adapter=%S generation=%s %s\n"
                      direction
                      (herdr-claude-code-ide-mcp-adapter-session-key adapter)
                      (herdr-claude-code-ide-mcp-client-generation client)
                      text)))))

(defun herdr-claude-code-ide-debug--incoming (adapter client text)
  (herdr-claude-code-ide-debug--record "incoming" adapter client text))

(defun herdr-claude-code-ide-debug--outgoing (adapter client text)
  (herdr-claude-code-ide-debug--record "outgoing" adapter client text))

(defun herdr-claude-code-ide-debug-enable ()
  "Enable raw Claude IDE protocol logging."
  (interactive)
  (customize-set-variable 'herdr-claude-code-ide-raw-protocol-logging t))

(defun herdr-claude-code-ide-debug-disable ()
  "Disable raw Claude IDE protocol logging."
  (interactive)
  (customize-set-variable 'herdr-claude-code-ide-raw-protocol-logging nil))

(provide 'herdr-claude-code-ide-debug)
;;; herdr-claude-code-ide-debug.el ends here
