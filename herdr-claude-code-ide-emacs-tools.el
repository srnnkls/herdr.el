;;; herdr-claude-code-ide-emacs-tools.el --- Emacs MCP tools -*- lexical-binding: t; -*-

(require 'xref)
(require 'project)
(require 'imenu)
(require 'herdr-claude-code-ide-mcp-server)

(declare-function treesit-buffer-root-node "treesit" ())
(declare-function treesit-node-type "treesit" (node))
(declare-function treesit-node-start "treesit" (node))
(declare-function treesit-node-end "treesit" (node))

(defun herdr-claude-code-ide-emacs-tools--text (object)
  `((content . (((type . "text") (text . ,(herdr-claude-code-ide-mcp-server--body object)))))))

(defun herdr-claude-code-ide-emacs-tools--references (identifier)
  (mapcar (lambda (xref)
            (let ((location (xref-item-location xref)))
              `((path . ,(xref-location-group location))
                (line . ,(xref-location-line location)))))
          (xref-backend-references (xref-find-backend) identifier)))

(defun herdr-claude-code-ide-emacs-tools--apropos (pattern)
  (mapcar (lambda (xref)
            (let ((location (xref-item-location xref)))
              `((path . ,(xref-location-group location))
                (line . ,(xref-location-line location)))))
          (xref-backend-apropos (xref-find-backend) pattern)))

(defun herdr-claude-code-ide-emacs-tools--imenu-position (position)
  (cond
   ((markerp position) (marker-position position))
   ((overlayp position) (overlay-start position))
   ((numberp position) position)))

(defun herdr-claude-code-ide-emacs-tools--symbols (&optional index)
  (apply #'append
         (mapcar
          (lambda (entry)
            (let ((name (car entry))
                  (position (cdr entry)))
              (cond
               ((or (equal name imenu--rescan-item) (equal position -99)) nil)
               ((herdr-claude-code-ide-emacs-tools--imenu-position position)
                (list `((name . ,name)
                        (position . ,(herdr-claude-code-ide-emacs-tools--imenu-position position)))))
               ((listp position)
                (herdr-claude-code-ide-emacs-tools--symbols position)))))
          (or index (imenu--make-index-alist)))))

(defun herdr-claude-code-ide-emacs-tools-register (context)
  (herdr-claude-code-ide-mcp-server-register-tool
   context "xref-references"
   '((type . "object") (properties . ((identifier . ((type . "string"))))) (required . ("identifier")))
   (lambda (_context arguments)
     (herdr-claude-code-ide-emacs-tools--text
      `((references . ,(herdr-claude-code-ide-emacs-tools--references
                        (herdr-claude-code-ide-mcp-server--value 'identifier arguments)))))))
  (herdr-claude-code-ide-mcp-server-register-tool
   context "xref-apropos"
   '((type . "object") (properties . ((pattern . ((type . "string"))))) (required . ("pattern")))
   (lambda (_context arguments)
     (herdr-claude-code-ide-emacs-tools--text
      `((references . ,(herdr-claude-code-ide-emacs-tools--apropos
                        (herdr-claude-code-ide-mcp-server--value 'pattern arguments)))))))
  (herdr-claude-code-ide-mcp-server-register-tool
   context "project-information"
   '((type . "object") (properties . ()) (required . ()))
   (lambda (tool-context _arguments)
     (herdr-claude-code-ide-emacs-tools--text
      `((root . ,(or (when-let ((project (project-current nil)))
                       (project-root project))
                     (plist-get tool-context :project-root)))))))
  (herdr-claude-code-ide-mcp-server-register-tool
   context "imenu-symbols"
   '((type . "object") (properties . ()) (required . ()))
   (lambda (_context _arguments)
     (herdr-claude-code-ide-emacs-tools--text
      `((symbols . ,(herdr-claude-code-ide-emacs-tools--symbols))))))
  (herdr-claude-code-ide-mcp-server-register-tool
   context "tree-sitter-information"
   '((type . "object") (properties . ()) (required . ()))
   (lambda (_context _arguments)
     (let ((root (treesit-buffer-root-node)))
       (herdr-claude-code-ide-emacs-tools--text
        `((type . ,(treesit-node-type root))
          (start . ,(treesit-node-start root))
          (end . ,(treesit-node-end root))))))))

(provide 'herdr-claude-code-ide-emacs-tools)
;;; herdr-claude-code-ide-emacs-tools.el ends here
