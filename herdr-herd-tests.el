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
KEYS may carry `:agent', `:name', `:status', `:session', `:pane', `:label'
and `:on', the herdr session the agent runs on."
  (let ((agent (or (plist-get keys :agent) "claude"))
        (session (or (plist-get keys :session) "session-1")))
    `((kind . "herdr")
      (session . ,(or (plist-get keys :on) "alpha"))
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

(ert-deftest herdr-herd-a-label-word-is-read-and-rewritten-in-place ()
  (should (equal "finished,exited"
                 (herdr-herd-label-token "herd:limen notify:finished,exited wip"
                                         "notify:")))
  (should-not (herdr-herd-label-token "herd:limen wip" "notify:"))
  (should-not (herdr-herd-label-token nil "notify:"))
  (should (equal "herd:limen notify:prompt wip"
                 (herdr-herd-label-with-token
                  "herd:limen notify:finished,exited wip" "notify:" "prompt")))
  (should (equal "herd:limen wip notify:prompt"
                 (herdr-herd-label-with-token "herd:limen wip" "notify:" "prompt")))
  (should (equal "herd:limen wip"
                 (herdr-herd-label-with-token
                  "herd:limen notify:finished wip" "notify:" nil)))
  (should (equal "notify:prompt"
                 (herdr-herd-label-with-token nil "notify:" "prompt")))
  (should-not (herdr-herd-label-with-token "notify:finished" "notify:" nil)))

(ert-deftest herdr-herd-a-name-with-whitespace-is-refused ()
  (should (herdr-herd--valid-name-p "refactor"))
  (should-not (herdr-herd--valid-name-p "two words"))
  (should-not (herdr-herd--valid-name-p "herd:nested")))

(ert-deftest herdr-herd-joining-preserves-the-label-a-pane-already-had ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one" :label "hand written")))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-add (list entry) '("alpha" . "refactor"))
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
                             (herdr-herd-member-entries '("alpha" . "refactor")))))
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
    (should-not (herdr-herd-member-entries '("alpha" . "refactor")))))

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
        (herdr-herd-add (list named unnamed) '("alpha" . "refactor")))
      (should (equal 1 (length herdr-herd-tests--agent-renames)))
      (should (equal "nmnm" (cdr (car herdr-herd-tests--agent-renames))))
      (should (equal '("w1:p1" "w2:p1")
                     (sort (mapcar #'car herdr-herd-tests--renames) #'string<))))))

(ert-deftest herdr-herd-adding-the-same-agent-twice-renames-no-pane ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index work"
                                        :name "one" :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-add (list entry) '("alpha" . "refactor"))
      (should-not herdr-herd-tests--renames))))

(ert-deftest herdr-herd-a-name-with-whitespace-never-reaches-herdr ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one")))
    (herdr-herd-tests--with-stubs (list entry)
      (should-error (herdr-herd-add (list entry) '("alpha" . "two words")) :type 'user-error)
      (should-not herdr-herd-tests--renames))))

(ert-deftest herdr-herd-joining-tells-the-joiner-the-roster-and-the-others-one-line ()
  (let ((old (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (new (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                      :name "two" :session "s2" :pane "w2:p1")))
    (herdr-herd-tests--with-stubs (list old new)
      (herdr-herd-add (list new) '("alpha" . "refactor"))
      (let ((to-old (cdr (assoc (herdr--entry-target old) herdr-herd-tests--prompts)))
            (to-new (cdr (assoc (herdr--entry-target new) herdr-herd-tests--prompts))))
        (should (equal 2 (length herdr-herd-tests--prompts)))
        (should (equal "[herd refactor] two joined (claude, /tmp/projects/nmnm/). No reply needed."
                       to-old))
        (should (string-match-p "you are two" to-new))
        (should (string-match-p "herdr agent prompt" to-new))
        (should (string-match-p "^  one " to-new))))))

(ert-deftest herdr-herd-the-roster-carries-what-protocol-functions-add ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                        :name "one" :label "herd:refactor"))
        (herdr-herd-protocol-functions
         (list (lambda (herd) (format "Extra about %s." (cdr herd)))
               #'ignore)))
    (herdr-herd-tests--with-stubs (list entry)
      (herdr-herd-announce '("alpha" . "refactor"))
      (should (string-match-p "\n\nExtra about refactor\\.\n\n"
                              (cdr (car herdr-herd-tests--prompts)))))))

(ert-deftest herdr-herd-leaving-tells-the-others-one-line ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (two (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                      :name "two" :session "s2" :pane "w2:p1"
                                      :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list one two)
      (herdr-herd-remove two)
      (should (equal (list (cons (herdr--entry-target one)
                                 "[herd refactor] two left. No reply needed."))
                     herdr-herd-tests--prompts)))))

(ert-deftest herdr-herd-announcing-tells-every-member-of-its-peers ()
  (let ((one (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                      :name "one" :session "s1" :pane "w1:p1"
                                      :label "herd:refactor"))
        (two (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                      :name "two" :session "s2" :pane "w2:p1"
                                      :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list one two)
      (herdr-herd-announce '("alpha" . "refactor"))
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
      (herdr-herd-announce '("alpha" . "refactor"))
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
      (herdr-herd-announce '("alpha" . "refactor"))
      (should (equal 1 (length herdr-herd-tests--prompts)))
      (should (string-match-p "you are two"
                              (cdr (car herdr-herd-tests--prompts)))))))

(ert-deftest herdr-herd-sending-tells-sent-functions-who-got-what ()
  (let ((idle (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                       :name "one" :session "s1" :pane "w1:p1"
                                       :label "herd:refactor"))
        (busy (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                       :name "two" :session "s2" :pane "w2:p1"
                                       :status "working" :label "herd:refactor"))
        (seen nil))
    (herdr-herd-tests--with-stubs (list idle busy)
      (let ((herdr-herd-sent-functions
             (list (lambda (entry text)
                     (push (cons (alist-get 'name entry) text) seen)))))
        (herdr-herd-broadcast '("alpha" . "refactor") "ping"))
      (should (equal seen '(("one" . "ping")))))))

(ert-deftest herdr-herd-broadcast-reaches-only-the-idle-members ()
  (let ((idle (herdr-herd-tests--entry "/tmp/projects/memex/" "index"
                                       :name "one" :session "s1" :pane "w1:p1"
                                       :label "herd:refactor"))
        (busy (herdr-herd-tests--entry "/tmp/projects/nmnm/" "nmnm"
                                       :name "two" :session "s2" :pane "w2:p1"
                                       :status "blocked" :label "herd:refactor")))
    (herdr-herd-tests--with-stubs (list idle busy)
      (herdr-herd-broadcast '("alpha" . "refactor") "ping")
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
        (herdr-herd-dissolve '("alpha" . "refactor")))
      (should (equal '(("w1:p1" . nil) ("w2:p1" . "keep me"))
                     (sort herdr-herd-tests--renames
                           (lambda (a b) (string< (car a) (car b)))))))))


;;;; The session a herd lives on

(ert-deftest herdr-herd-a-herd-is-named-by-its-session-and-its-name ()
  (should (equal "refactor" (herdr-herd-label '(shared . "refactor"))))
  (should (equal "cmw/refactor" (herdr-herd-label '("cmw" . "refactor"))))
  (should (herdr-herd--same-p '(nil . "a") '(shared . "a")))
  (should-not (herdr-herd--same-p '("cmw" . "a") '("gf" . "a")))
  (should-not (herdr-herd--same-p '("cmw" . "a") '("cmw" . "b"))))

(ert-deftest herdr-herd-alike-labels-on-two-sessions-are-two-herds ()
  "`herdr agent prompt' reaches one server, so a member on another session
could neither be reached nor reach back."
  (let ((here (herdr-herd-tests--entry "/tmp/projects/memex/" "a" :name "one"
                                       :session "s1" :label "herd:refactor"))
        (there (herdr-herd-tests--entry "/tmp/projects/nmnm/" "b" :name "two"
                                        :session "s2" :label "herd:refactor"
                                        :on "beta")))
    (herdr-herd-tests--with-stubs (list here there)
      (should (equal 2 (length (herdr-herds))))
      (should (equal '("one")
                     (mapcar (lambda (entry) (alist-get 'name entry))
                             (herdr-herd-member-entries '("alpha" . "refactor")))))
      (should (equal '("two")
                     (mapcar (lambda (entry) (alist-get 'name entry))
                             (herdr-herd-member-entries '("beta" . "refactor"))))))))

(ert-deftest herdr-herd-names-are-those-of-one-session ()
  (let ((here (herdr-herd-tests--entry "/tmp/projects/memex/" "a" :name "one"
                                       :session "s1" :label "herd:here"))
        (there (herdr-herd-tests--entry "/tmp/projects/nmnm/" "b" :name "two"
                                        :session "s2" :label "herd:there"
                                        :on "beta")))
    (herdr-herd-tests--with-stubs (list here there)
      (should (equal '("here") (herdr-herd-names "alpha")))
      (should (equal '("there") (herdr-herd-names "beta")))
      (should (equal '("here" "there") (sort (herdr-herd-names) #'string<))))))

(ert-deftest herdr-herd-adding-an-agent-of-another-session-is-refused ()
  (let ((here (herdr-herd-tests--entry "/tmp/projects/memex/" "a" :name "one"
                                       :session "s1" :pane "w1:p1"))
        (there (herdr-herd-tests--entry "/tmp/projects/nmnm/" "b" :name "two"
                                        :session "s2" :pane "w2:p1"
                                        :on "beta")))
    (herdr-herd-tests--with-stubs (list here there)
      (herdr-herd-add (list here there) '("alpha" . "refactor"))
      (should (equal '("w1:p1") (mapcar #'car herdr-herd-tests--renames))))))

(ert-deftest herdr-herd-live-agents-narrow-to-one-session ()
  (let ((here (herdr-herd-tests--entry "/tmp/projects/memex/" "a" :name "one"
                                       :session "s1"))
        (there (herdr-herd-tests--entry "/tmp/projects/nmnm/" "b" :name "two"
                                        :session "s2" :on "beta")))
    (herdr-herd-tests--with-stubs (list here there)
      (should (equal '("one")
                     (mapcar (lambda (entry) (alist-get 'name entry))
                             (herdr-herd-live-agents "alpha"))))
      (should (equal 2 (length (herdr-herd-live-agents)))))))

(ert-deftest herdr-herd-the-session-comes-from-point-where-point-names-one ()
  (let ((entry (herdr-herd-tests--entry "/tmp/projects/memex/" "a" :name "one"
                                        :label "herd:refactor")))
    (cl-letf (((symbol-function 'herdr-herd--section-value)
               (lambda (type)
                 (when (eq type 'herdr-status-agent) entry)))
              ((symbol-function 'herdr-read-session)
               (lambda (&rest _) (error "asked for a session it already knew"))))
      (should (equal "alpha" (herdr-herd-session-at-point)))
      (should (equal '("alpha" . "refactor") (herdr-herd-at-point))))))

(ert-deftest herdr-herd-the-session-is-asked-for-where-point-names-none ()
  "Off an agent, a herd and a session there is nothing to take the session
from, and a herd on the wrong server can reach nobody."
  (let (asked)
    (cl-letf (((symbol-function 'herdr-herd--section-value) (lambda (_) nil))
              ((symbol-function 'herdr-read-session)
               (lambda (&rest _) (setq asked t) "cmw")))
      (should (eq 'unknown (herdr-herd-session-at-point)))
      (should (equal "cmw" (herdr-herd--read-session)))
      (should asked))))

(ert-deftest herdr-herd-a-session-row-names-its-own-session ()
  (cl-letf (((symbol-function 'herdr-herd--section-value)
             (lambda (type)
               (when (eq type 'herdr-status-session) "/tmp/cmw.sock")))
            ((symbol-function 'herdr-all-sessions) (lambda () '(shared "cmw")))
            ((symbol-function 'herdr-server-key)
             (lambda () (if (equal herdr-session "cmw")
                            "/tmp/cmw.sock"
                          "/tmp/shared.sock"))))
    (should (equal "cmw" (herdr-herd-session-at-point)))))

(provide 'herdr-herd-tests)
;;; herdr-herd-tests.el ends here
