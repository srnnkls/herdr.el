#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
emacs=${EMACS:-emacs}

clean_bytecode() {
  find "$root" -maxdepth 1 -type f -name '*.elc' -delete
  find "$root/tools" -maxdepth 1 -type f -name '*.elc' -delete
}

cleanup() {
  clean_bytecode
}

emacs_with_packages() {
  "$emacs" -Q --batch -L "$root" \
    --eval "(progn (require 'package) (package-initialize))" "$@"
}

trap cleanup EXIT HUP INT TERM
clean_bytecode

"$emacs" -Q --batch --eval "(progn
  (require 'package)
  (setq package-archives '((\"gnu\" . \"https://elpa.gnu.org/packages/\")
                           (\"melpa\" . \"https://melpa.org/packages/\"))
        package-archive-priorities '((\"gnu\" . 10) (\"melpa\" . 5)))
  (package-initialize)
  (dolist (dependency '((websocket . (1 12))
                        (transient . (0 9 0))))
    (let ((name (car dependency))
          (minimum-version (cdr dependency)))
      (unless (package-installed-p name minimum-version)
        (unless package-archive-contents
          (package-refresh-contents))
        (if (assq name package-alist)
            (package-upgrade name)
          (package-install (cadr (assq name package-archive-contents)))))
      (unless (package-installed-p name minimum-version)
        (error \"%s %s or newer is required\"
               name (package-version-join minimum-version)))
      (require name))))"

for source in "$root"/*.el "$root"/tools/*.el; do
  case "$source" in
    *-tests.el) ;;
    *) emacs_with_packages --eval '(setq byte-compile-error-on-warn t)' \
         -f batch-byte-compile "$source" ;;
  esac
done

clean_bytecode

for suite in "$root"/*-tests.el; do
  case "$suite" in
    "$root/herdr-tests.el")
      emacs_with_packages -l "$suite" \
        --eval "(ert-run-tests-batch-and-exit '(not herdr-live-server-answers-ping))" ;;
    *) emacs_with_packages -l "$suite" -f ert-run-tests-batch-and-exit ;;
  esac
done
