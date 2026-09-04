;; -*- mode: eask; lexical-binding: t -*-

(package "herdr"
         "0.1.0"
         "Control persistent herdr terminal workspaces")

(website-url "https://github.com/srnnkls/herdr.el")
(license "GPL-3.0-or-later")

(keywords "terminals" "tools" "processes")

(package-file "herdr.el")

(source 'gnu)
(source 'nongnu)
(source 'melpa)

(depends-on "emacs" "29.1")
(depends-on "transient" "0.13.0")
(depends-on "magit-section" "4.0.0")

(development
 (depends-on "eat")
 (depends-on "flycheck")
 (depends-on "projectile"))

(load-paths ".")

(files "herdr*.el"
       "LICENSE"
       '(:exclude "herdr*-tests.el"))

(defconst herdr-test-file-spec
  '("herdr*-tests.el")
  "File spec for ERT suites excluded from the package files.")

(script "test"
        (let* ((default-directory (file-name-directory load-file-name))
               (files (eask-expand-file-specs herdr-test-file-spec)))
          (unless files
            (error "No test file matches %S under %s"
                   herdr-test-file-spec default-directory))
          (mapconcat #'identity
                     (cons "eask test ert"
                           (mapcar #'shell-quote-argument files))
                     " ")))

(add-hook 'eask-before-compile-hook
          (lambda ()
            (setq byte-compile-error-on-warn t)))
