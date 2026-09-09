;;; herdr-herd-tests.el --- Tests for herdr-herd.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l herdr-herd-tests.el -f ert-run-tests-batch-and-exit
;;
;; Every herdr call is stubbed, so no server is contacted and no pane is
;; renamed or prompted.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-herd)

(defvar herdr-herd-tests--repositories
  '(("/tmp/projects/herdr.el/.worktrees/feat-native/" . "/tmp/projects/herdr.el/")
    ("/tmp/projects/sira/scopes/active/durable-compaction/" . "/tmp/projects/sira/")
    ("/tmp/projects/memex/" . "/tmp/projects/memex/")
    ("/tmp/projects/nmnm/" . "/tmp/projects/nmnm/")
    ("/tmp/dotfiles/" . "/tmp/dotfiles/"))
  "What git reports as the shared repository of each test directory.")

(defun herdr-herd-tests--entry (cwd title &rest keys)
  "Return an agent entry in CWD whose terminal shows TITLE.
KEYS may carry `:agent', `:name', `:status', `:session', `:pane' and
`:label'."
  (let ((agent (or (plist-get keys :agent) "claude"))
        (session (or (plist-get keys :session) "session-1")))
    `((kind . "herdr")
      (session . "alpha")
      (server_key . "/tmp/alpha.sock")
      (agent . ,agent)
      (agent_status . ,(or (plist-get keys :status) "idle"))
      (agent_session . ((agent . ,agent) (kind . "id")
                        (source . ,(concat "herdr:" agent))
                        (value . ,session)))
      (name . ,(plist-get keys :name))
      (pane_label . ,(plist-get keys :label))
      (terminal_title_stripped . ,title)
      (terminal_id . ,(concat "term-" session))
      (pane_id . ,(or (plist-get keys :pane) "w1:p1"))
      (cwd . ,cwd))))

(defvar herdr-herd-tests--renames nil
  "Pane renames the stubs recorded, newest first, as (PANE . LABEL).")

(defvar herdr-herd-tests--agent-renames nil
  "Agent renames the stubs recorded, newest first.")

(defvar herdr-herd-tests--prompts nil
  "Prompts the stubs recorded, newest first.")

(defmacro herdr-herd-tests--with-stubs (agents &rest body)
  "Run BODY with AGENTS as the live agents and every herdr call stubbed."
  (declare (indent 1) (debug (form body)))
  `(let ((herdr-herd-tests--renames nil)
         (herdr-herd-tests--agent-renames nil)
         (herdr-herd-tests--prompts nil))
     (cl-letf (((symbol-function 'herdr-sessions) (lambda () ,agents))
               ((symbol-function 'herdr-herd--repository)
                (lambda (directory)
                  (cdr (assoc directory herdr-herd-tests--repositories))))
               ((symbol-function 'herdr-agent--occupied-names) (lambda (_) nil))
               ((symbol-function 'herdr-api-pane-rename)
                (lambda (pane &rest keys)
                  (push (cons pane (plist-get keys :label))
                        herdr-herd-tests--renames)
                  nil))
               ((symbol-function 'herdr-agent-rename)
                (lambda (target name)
                  (push (cons target name) herdr-herd-tests--agent-renames)
                  name))
               ((symbol-function 'herdr-agent-prompt)
                (lambda (target text)
                  (push (cons target text) herdr-herd-tests--prompts)
                  text))
               ((symbol-function 'herdr-status-refresh) #'ignore))
       ,@body)))

;;;; The label a pane carries

(ert-deftest herdr-herd-a-label-names-the-herd-ahead-of-its-own-text ()
  (should (equal '("refactor" . nil) (herdr-herd--split "herd:refactor")))
  (should (equal '("refactor" . "my own label")
                 (herdr-herd--split "herd:refactor my own label")))
  (should (equal '(nil . "my own label") (herdr-herd--split "my own label")))
  (should (equal '(nil . nil) (herdr-herd--split nil))))

(ert-deftest herdr-herd-a-label-keeps-what-it-already-said ()
  (should (equal "herd:refactor" (herdr-herd--compose "refactor" nil)))
  (should (equal "herd:refactor mine" (herdr-herd--compose "refactor" "mine")))
  (should (equal "mine" (herdr-herd--compose nil "mine")))
  (should-not (herdr-herd--compose nil nil)))

(ert-deftest herdr-herd-a-name-with-whitespace-is-refused ()
  (should (herdr-herd--valid-name-p "refactor"))
  (should-not (herdr-herd--valid-name-p "two words"))
  (should-not (herdr-herd--valid-name-p "herd:nested")))

(ert-deftest herdr-herd-joining-preserves-the-label-a-pane-already-had ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one" :label "hand written")))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-add (list entry) "refactor")
      (should (equal '("w1:p1" . "herd:refactor hand written")
                     (car herdr-herd-tests--renames))))))

(ert-deftest herdr-herd-leaving-clears-a-label-that-said-nothing-else ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one" :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-remove entry)
      (should (equal '("w1:p1" . nil) (car herdr-herd-tests--renames))))))

(ert-deftest herdr-herd-leaving-keeps-the-rest-of-a-label ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one"
                                        :label "herd:refactor hand written")))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-remove entry)
      (should (equal '("w1:p1" . "hand written")
                     (car herdr-herd-tests--renames))))))

;;;; Reading the herds

(ert-deftest herdr-herd-herds-come-from-the-labels-agents-carry ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "a" :name "one"
                                      :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (two (herdr-herd-tests--entry "/tmp/projects/nmnm/" "b" :name "two"
                                      :session "s2" :pane "w2:p1"
                                      :label "herd:refactor notes"))
        (loose (herdr-herd-tests--entry "/tmp/dotfiles/" "c" :name "three"
                                        :session "s3" :pane "w3:p1")))
    (herdr-herd-tests--with-stubs (list one two loose)
      (should (equal '("refactor") (herdr-herd-names)))
      (should (equal '("one" "two")
                     (mapcar (lambda (entry) (alist-get 'name entry))
                             (herdr-herd-member-entries "refactor"))))
      (should-not (herdr-herd-of-entry loose)))))

(ert-deftest herdr-herd-herds-come-out-in-name-order ()
  (let ((z (herdr-herd-tests--entry "/tmp/dotfiles/" "z" :name "z"
                                    :session "s1" :label "herd:zeta"))
        (a (herdr-herd-tests--entry "/tmp/projects/nmnm/" "a" :name "a"
                                    :session "s2" :label "herd:alpha")))
    (herdr-herd-tests--with-stubs (list z a)
      (should (equal '("alpha" "zeta") (herdr-herd-names))))))

(ert-deftest herdr-herd-a-closed-pane-leaves-the-herd-it-was-in ()
  (herdr-herd-tests--with-stubs nil
    (should-not (herdr-herd-names))
    (should-not (herdr-herd-member-entries "refactor"))))

;;;; Deriving an agent name

(ert-deftest herdr-herd-names-carry-the-repository-and-the-task ()
  (pcase-dolist
      (`(,cwd ,title ,expected)
       '(("/tmp/projects/herdr.el/.worktrees/feat-native/"
          "improve-search-navigation-display" "herdr-el-improve-search")
         ("/tmp/projects/memex/"
          "Incremental index building cost model" "memex-incremental-index")
         ("/tmp/projects/memex/"
          "two-phase-checkpoint-state" "memex-two-phase")
         ("/tmp/projects/sira/scopes/active/durable-compaction/"
          "feat/unified-kv-model branch changes" "sira-unified-kv")
         ("/tmp/dotfiles/"
          "Doom Emacs cooked package with SPC o keybindings"
          "dotfiles-doom-emacs")
         ("/tmp/projects/nmnm/" "nmnm" "nmnm")))
    (herdr-herd-tests--with-stubs nil
      (should (equal expected
                     (herdr-herd-derive-name
                      (herdr-herd-tests--entry cwd title)))))))

(ert-deftest herdr-herd-names-stay-inside-herdr-s-grammar ()
  (herdr-herd-tests--with-stubs nil
    (let ((name (herdr-herd-derive-name
                 (herdr-herd-tests--entry
                  "/tmp/projects/memex/"
                  "Extraordinarily Long Title Of Considerable Length Indeed"))))
      (should (herdr-agent--name-valid-p name))
      (should (<= (length name) 32)))))

(ert-deftest herdr-herd-names-fall-back-to-the-harness-without-a-title ()
  (herdr-herd-tests--with-stubs nil
    (should (equal "claude"
                   (herdr-herd-derive-name
                    (herdr-herd-tests--entry nil nil))))))

;;;; Joining

(ert-deftest herdr-herd-adding-names-only-an-unnamed-agent ()
  (let ((named (herdr-herd-tests--entry "/tmp/projects/memex/" "index work"
                                        :name "chosen-by-hand" :session "s1"
                                        :pane "w1:p1"))
        (unnamed (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                          :session "s2" :pane "w2:p1")))
    (herdr-herd-tests--with-stubs (list named unnamed)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &optional initial &rest _) initial)))
        (herdr-herd-add (list named unnamed) "refactor"))
      (should (equal 1 (length herdr-herd-tests--agent-renames)))
      (should (equal "nmnm" (cdr (car herdr-herd-tests--agent-renames))))
      (should (equal '("w1:p1" "w2:p1")
                     (sort (mapcar #'car herdr-herd-tests--renames) #'string<))))))

(ert-deftest herdr-herd-adding-the-same-agent-twice-renames-no-pane ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index work"
                                        :name "one" :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-add (list entry) "refactor")
      (should-not herdr-herd-tests--renames))))

(ert-deftest herdr-herd-a-name-with-whitespace-never-reaches-herdr ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one")))
    (herdr-herd-tests--with-stubs (list entry)
      (should-error (herdr-herd-add (list entry) "two words") :type 'user-error)
      (should-not herdr-herd-tests--renames))))

(ert-deftest herdr-herd-announcing-tells-every-member-of-its-peers ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (two (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                      :name "two" :session "s2" :pane "w2:p1"
                                      :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list one two)
      (herdr-herd-announce "refactor")
      (let ((texts (mapcar #'cdr herdr-herd-tests--prompts)))
        (should (equal 2 (length texts)))
        (should (seq-find (lambda (text)
                            (and (string-match-p "you are one" text)
                                 (string-match-p "^  two " text)))
                          texts))
        (should (seq-find (lambda (text)
                            (and (string-match-p "you are two" text)
                                 (string-match-p "^  one " text)))
                          texts))))))

(ert-deftest herdr-herd-the-roster-tells-a-member-the-raw-cli-form ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list one)
      (herdr-herd-announce "refactor")
      (let ((text (cdr (car herdr-herd-tests--prompts))))
        (should (string-match-p "herdr pane rename" text))
        (should (string-match-p "herdr agent prompt" text))))))

(ert-deftest herdr-herd-announcing-skips-an-agent-mid-turn ()
  (let ((busy (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                       :name "one" :session "s1" :pane "w1:p1"
                                       :status "working" :label "herd:refactor"))
        (idle (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                       :name "two" :session "s2" :pane "w2:p1"
                                       :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list busy idle)
      (herdr-herd-announce "refactor")
      (should (equal 1 (length herdr-herd-tests--prompts)))
      (should (string-match-p "you are two"
                              (cdr (car herdr-herd-tests--prompts)))))))

(ert-deftest herdr-herd-broadcast-reaches-only-the-idle-members ()
  (let ((idle (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                       :name "one" :session "s1" :pane "w1:p1"
                                       :label "herd:refactor"))
        (busy (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                       :name "two" :session "s2" :pane "w2:p1"
                                       :status "blocked" :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list idle busy)
      (herdr-herd-broadcast "refactor" "ping")
      (should (equal '("ping") (mapcar #'cdr herdr-herd-tests--prompts))))))

;;;; Dissolving

(ert-deftest herdr-herd-dissolving-clears-every-member-s-label ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (two (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                      :name "two" :session "s2" :pane "w2:p1"
                                      :label "herd:refactor keep me")))
    (herdr-herd-tests--with-stubs (list one two)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (herdr-herd-dissolve "refactor"))
      (should (equal '(("w1:p1" . nil) ("w2:p1" . "keep me"))
                     (sort herdr-herd-tests--renames
                           (lambda (a b) (string< (car a) (car b)))))))))

(provide 'herdr-herd-tests)
;;; herdr-herd-tests.el ends here
