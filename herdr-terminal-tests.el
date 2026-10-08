;;; herdr-terminal-tests.el --- Tests for herdr-terminal.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'herdr-terminal)
(defvar ghostel--input-mode)

(defmacro herdr-terminal-tests--as (mode &rest body)
  "Run BODY in a buffer answering as MODE, shown in a window."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert "$ run\nthe screen\n")
     (setq-local eat-terminal 'stub)
     (cl-letf (((symbol-function 'derived-mode-p)
                (lambda (&rest modes) (car (memq ,mode modes))))
               ((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
       ,@body)))

(ert-deftest herdr-terminal-goto-prompt-lands-on-the-cursor-not-the-end ()
  (with-temp-buffer
    (insert "$ run\nsome output that scrolled past the prompt\n")
    (let ((cursor 8)
          (focused 0))
      (setq-local ghostel--cursor-char-pos cursor)
      (cl-letf (((symbol-function 'derived-mode-p)
                 (lambda (&rest modes) (memq 'ghostel-mode modes))))
        (let ((herdr-terminal-focus-functions
               (list (lambda () (setq focused (1+ focused))))))
          (goto-char (point-max))
          (should (equal (herdr-terminal-goto-prompt) cursor))
          (should (= (point) cursor))
          (should (= focused 1))))
      ;; A cursor the buffer has since outgrown is not jumped to.
      (setq-local ghostel--cursor-char-pos (+ (point-max) 10))
      (cl-letf (((symbol-function 'derived-mode-p)
                 (lambda (&rest modes) (memq 'ghostel-mode modes))))
        (goto-char (point-min))
        (should (= (herdr-terminal-goto-prompt) (point-min)))))))

(ert-deftest herdr-terminal-a-screen-is-the-text-of-its-buffer ()
  (let ((repainted 0))
    (cl-letf (((symbol-function 'ghostel-force-redraw)
               (lambda () (setq repainted (1+ repainted)))))
      (herdr-terminal-tests--as 'ghostel-mode
        (should (equal (herdr-terminal-screen) "$ run\nthe screen\n"))
        (should (= repainted 1))))
    (herdr-terminal-tests--as 'vterm-mode
      (should (equal (herdr-terminal-screen) "$ run\nthe screen\n")))
    (herdr-terminal-tests--as 'eat-mode
      (should (equal (herdr-terminal-screen) "$ run\nthe screen\n")))))

(ert-deftest herdr-terminal-a-screen-no-window-shows-is-not-answered ()
  (cl-letf (((symbol-function 'ghostel-force-redraw) #'ignore))
    (with-temp-buffer
      (insert "stale")
      (cl-letf (((symbol-function 'derived-mode-p)
                 (lambda (&rest modes) (car (memq 'ghostel-mode modes)))))
        (should-not (herdr-terminal-screen))))))

(ert-deftest herdr-terminal-a-buffer-in-no-known-mode-answers-nothing ()
  (herdr-terminal-tests--as 'text-mode
    (should-not (herdr-terminal-screen))
    (should-not (herdr-terminal-send "typed"))
    (should-not (herdr-terminal-paste "pasted"))))

(ert-deftest herdr-terminal-bytes-reach-the-backend-the-buffer-belongs-to ()
  (let (written)
    (cl-letf (((symbol-function 'ghostel-send-string)
               (lambda (text) (push (cons 'ghostel-send text) written)))
              ((symbol-function 'ghostel-paste-string)
               (lambda (text) (push (cons 'ghostel-paste text) written)))
              ((symbol-function 'vterm-send-string)
               (lambda (text &optional paste)
                 (push (cons (if paste 'vterm-paste 'vterm-send) text) written)))
              ((symbol-function 'eat-term-send-string)
               (lambda (_terminal text) (push (cons 'eat-send text) written)))
              ((symbol-function 'eat-term-send-string-as-yank)
               (lambda (_terminal text) (push (cons 'eat-paste text) written))))
      (dolist (mode '(ghostel-mode vterm-mode eat-mode))
        (herdr-terminal-tests--as mode
          (should (herdr-terminal-send "typed"))
          (should (herdr-terminal-paste "pasted")))))
    (should (equal (nreverse written)
                   '((ghostel-send . "typed") (ghostel-paste . "pasted")
                     (vterm-send . "typed") (vterm-paste . "pasted")
                     (eat-send . "typed") (eat-paste . "pasted"))))))

(ert-deftest herdr-terminal-freeze-holds-a-ghostel-screen-until-thawed ()
  (let (calls)
    (with-temp-buffer
      (setq-local major-mode 'ghostel-mode)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel-copy-mode)
                 (lambda () (push 'freeze calls) (setq ghostel--input-mode 'copy)))
                ((symbol-function 'ghostel-readonly-exit)
                 (lambda () (push 'thaw calls) (setq ghostel--input-mode 'semi-char))))
        (should (herdr-terminal-screen-p))
        (let ((thaw (herdr-terminal-freeze)))
          (should (eq ghostel--input-mode 'copy))
          (should-not (herdr-terminal-freeze))
          (funcall thaw))
        (should (eq ghostel--input-mode 'semi-char))))
    (should (equal (nreverse calls) '(freeze thaw)))))

(ert-deftest herdr-terminal-freeze-holds-a-screen-read-in-emacs-mode ()
  (let (calls)
    (with-temp-buffer
      (setq-local major-mode 'ghostel-mode)
      (setq-local ghostel--input-mode 'emacs)
      (setq-local ghostel--pre-readonly-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel-copy-mode)
                 (lambda ()
                   (push 'freeze calls)
                   (setq ghostel--pre-readonly-mode ghostel--input-mode
                         ghostel--input-mode 'copy)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda ()
                   (push 'read calls)
                   (setq ghostel--pre-readonly-mode ghostel--input-mode
                         ghostel--input-mode 'emacs)))
                ((symbol-function 'ghostel-readonly-exit)
                 (lambda () (push 'exit calls))))
        (let ((thaw (herdr-terminal-freeze)))
          (should (eq ghostel--input-mode 'copy))
          (funcall thaw))
        (should (eq ghostel--input-mode 'emacs))
        (should (eq ghostel--pre-readonly-mode 'semi-char))))
    (should (equal (nreverse calls) '(freeze read)))))

(ert-deftest herdr-terminal-freeze-leaves-other-buffers-alone ()
  (with-temp-buffer
    (should-not (herdr-terminal-screen-p))
    (should-not (herdr-terminal-freeze))))

(provide 'herdr-terminal-tests)
;;; herdr-terminal-tests.el ends here
