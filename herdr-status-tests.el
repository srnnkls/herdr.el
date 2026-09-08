;;; herdr-status-tests.el --- Tests for herdr-status.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l herdr-status-tests.el -f ert-run-tests-batch-and-exit
;;
;; The dashboard is rendered against stubbed snapshots, so no herdr server
;; is needed and no request leaves Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-status)
(require 'herdr-transient)

(defvar herdr-status-tests--agent-status-calls 0
  "How often the stubbed `herdr-agent-status' was called.")

(defvar herdr-status-tests--read-calls 0
  "How often either stubbed read was called.")

(defvar herdr-status-tests--reads nil
  "Every read of a run as (METHOD . PANE-ID), newest first.")

(defvar herdr-status-tests--pane-text
  (string-join
   '("⏺ The rebase landed clean."
     ""
     "✻ Worked for 12s"
     "※ recap: batch two is green; next is the completing-read layer."
     "──────────────────────────────────────────"
     "❯"
     "──────────────────────────────────────────"
     "  Opus 5 (1M context) | feat-x | 118366/200000 (59%)"
     "  -- INSERT -- ⏵⏵ auto mode on")
   "\n")
  "Pane text the stubbed read returns, chrome and all.")

(defun herdr-status-tests--entries ()
  "Return the agent entries the fake servers report."
  (list '((kind . "herdr") (session . "alpha")
          (server_key . "/tmp/alpha.sock")
          (agent . "claude") (agent_status . "working")
          (name . "api-review") (terminal_title_stripped . "api-review")
          (terminal_id . "t1") (pane_id . "%1")
          (workspace_id . "w1") (tab_id . "tab1") (cwd . "/tmp/proj/"))
        '((kind . "herdr") (session . "alpha")
          (server_key . "/tmp/alpha.sock")
          (agent . "codex") (agent_status . "idle")
          (name . "docs") (terminal_id . "t2") (pane_id . "%2")
          (workspace_id . "w1") (tab_id . "tab1") (cwd . "/tmp/proj/"))
        '((kind . "herdr") (session . "beta")
          (server_key . "/tmp/beta.sock")
          (agent . "claude") (agent_status . "orbiting")
          (name . "beta-work") (terminal_id . "t3") (pane_id . "%3")
          (workspace_id . "w9") (tab_id . "tab9") (cwd . "/tmp/other/"))))

(defun herdr-status-tests--snapshot (session)
  "Return the fake snapshot SESSION's server answers with."
  (if (equal session "alpha")
      '((version . "1.2.3")
        (protocol . 21)
        (focused_pane_id . "%1")
        (focused_tab_id . "tab1")
        (focused_workspace_id . "w1")
        (workspaces . (((workspace_id . "w1") (label . "herdr.el"))))
        (tabs . (((tab_id . "tab1") (label . "main"))))
        (panes . (((pane_id . "%1") (workspace_id . "w1"))
                  ((pane_id . "%2") (workspace_id . "w1"))
                  ((pane_id . "%9") (workspace_id . "w1") (label . "shell")))))
    '((version . "1.2.3")
      (protocol . 21)
      (focused_pane_id . "%3")
      (workspaces . (((workspace_id . "w9") (label . "other"))))
      (tabs . (((tab_id . "tab9") (label . "side"))))
      (panes . (((pane_id . "%3") (workspace_id . "w9")))))))

(defun herdr-status-tests--expand-section (section)
  "Expand SECTION and everything below it."
  (magit-section-show section)
  (dolist (child (copy-sequence (oref section children)))
    (herdr-status-tests--expand-section child)))

(defun herdr-status-tests--expand ()
  "Expand every section of the current dashboard buffer."
  (let ((inhibit-read-only t))
    (herdr-status-tests--expand-section magit-root-section)))

(defmacro herdr-status-tests--with-dashboard (&rest body)
  "Render a dashboard over the fake servers and run BODY inside it."
  (declare (indent 0) (debug (body)))
  `(let ((herdr--recent-session-targets nil)
         (herdr-status-tests--agent-status-calls 0)
         (herdr-status-tests--read-calls 0)
         (herdr-status-tests--reads nil)
         (buffer (generate-new-buffer " *herdr-status-test*")))
     (unwind-protect
         (cl-letf (((symbol-function 'herdr-all-sessions)
                    (lambda () (list "alpha" "beta")))
                   ((symbol-function 'herdr-server-key)
                    (lambda () (format "/tmp/%s.sock" herdr-session)))
                   ((symbol-function 'herdr-available-p) (lambda () t))
                   ((symbol-function 'herdr-snapshot)
                    (lambda () (herdr-status-tests--snapshot herdr-session)))
                   ((symbol-function 'herdr-sessions)
                    #'herdr-status-tests--entries)
                   ((symbol-function 'herdr--entry-buffer) (lambda (_) nil))
                   ((symbol-function 'herdr-agent-status)
                    (lambda (_target)
                      (cl-incf herdr-status-tests--agent-status-calls)
                      '((provider . "limen") (availability . "connected"))))
                   ((symbol-function 'herdr-api-agent-read)
                    (lambda (_source pane &rest _)
                      (cl-incf herdr-status-tests--read-calls)
                      (push (cons 'agent pane) herdr-status-tests--reads)
                      `((type . "pane_read")
                        (read . ((pane_id . ,pane)
                                 (text . ,herdr-status-tests--pane-text))))))
                   ((symbol-function 'herdr-api-pane-read)
                    (lambda (pane _source &rest _)
                      (cl-incf herdr-status-tests--read-calls)
                      (push (cons 'pane pane) herdr-status-tests--reads)
                      `((type . "pane_read")
                        (read . ((pane_id . ,pane)
                                 (text . ,herdr-status-tests--pane-text)))))))
           (with-current-buffer buffer
             (herdr-status-mode)
             (herdr-status-refresh)
             ,@body))
       (kill-buffer buffer))))

(defun herdr-status-tests--visible-text ()
  "Return only the dashboard text no section hides."
  (let ((pos (point-min))
        (parts nil))
    (while (< pos (point-max))
      (let ((next (next-single-char-property-change pos 'invisible)))
        (unless (get-char-property pos 'invisible)
          (push (buffer-substring-no-properties pos (min next (point-max)))
                parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun herdr-status-tests--tail (heading)
  "Return the dashboard text from HEADING to the end of the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil)) (search-forward heading))
    (buffer-substring-no-properties (line-beginning-position) (point-max))))

(defun herdr-status-tests--section-text (heading)
  "Return the dashboard text from HEADING up to the next blank line."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil)) (search-forward heading))
    (buffer-substring-no-properties
     (line-beginning-position)
     (or (save-excursion (re-search-forward "^\n" nil t)) (point-max)))))

(ert-deftest herdr-status-is-an-interactive-command ()
  (should (commandp 'herdr-status))
  (should (commandp 'herdr-status-refresh))
  (should (commandp 'herdr-status-filter)))

(ert-deftest herdr-status-renders-agent-state-ahead-of-the-name ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should (re-search-forward "^ +● api-review +✳ claude +alpha +%1" nil t))))

(ert-deftest herdr-status-marks-each-agent-with-its-vendor-glyph ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should (re-search-forward "✳ claude" nil t))
    (should (equal (get-text-property (match-beginning 0) 'font-lock-face)
                   '(herdr-status-kind-glyph herdr-status-kind-claude)))
    (goto-char (point-min))
    (should (re-search-forward "⌬ codex" nil t))
    (should (equal (get-text-property (match-beginning 0) 'font-lock-face)
                   '(herdr-status-kind-glyph herdr-status-kind-codex)))))

(ert-deftest herdr-status-leaves-magit-its-own-visibility-indicators ()
  (let ((magit-section-visibility-indicators
         '((magit-fringe-bitmap> . magit-fringe-bitmapv) ("…" . t))))
    (with-temp-buffer
      (herdr-status-mode)
      (should (equal magit-section-visibility-indicators
                     '((magit-fringe-bitmap> . magit-fringe-bitmapv)
                       ("…" . t))))
      (should (= left-margin-width 0)))))

(ert-deftest herdr-status-takes-margin-arrows-when-asked-for-them ()
  (let ((herdr-status-visibility-indicators '((?▸ . ?▾) (?▸ . ?▾))))
    (with-temp-buffer
      (herdr-status-mode)
      (should (equal magit-section-visibility-indicators
                     herdr-status-visibility-indicators))
      (should (> left-margin-width 0)))))

(ert-deftest herdr-status-keeps-an-unmarked-kind-in-the-kind-column ()
  (let ((herdr-status-kind-marks '(("claude" "✳" . herdr-status-kind-claude))))
    (should (equal (herdr-status--kind-column '((agent . "codex")) 6)
                   "  codex "))
    (should (equal (herdr-status--kind-column '((agent . "claude")) 6)
                   (concat (propertize "✳" 'font-lock-face
                                       'herdr-status-kind-claude)
                           " claude")))))

(ert-deftest herdr-status-rows-carry-pane-and-workspace-metadata ()
  (herdr-status-tests--with-dashboard
    (let ((agents (herdr-status-tests--section-text "Agents ")))
      (should (string-match-p "%1" agents))
      (should (string-match-p "herdr.el" agents))
      (should (string-match-p "/tmp/proj/" agents)))))

(ert-deftest herdr-status-expanded-agents-show-terminal-and-adapter-fields ()
  (let ((herdr-status-show-details t))
   (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "terminal_id +t1" text))
      (should (string-match-p "tab +main" text))
      (should (string-match-p "provider +limen" text))))))

(ert-deftest herdr-status-lists-every-known-server ()
  (herdr-status-tests--with-dashboard
    (let ((servers (herdr-status-tests--section-text "Servers ")))
      (should (string-match-p "Servers 2" servers))
      (should (string-match-p "/tmp/alpha.sock" servers))
      (should (string-match-p "/tmp/beta.sock" servers)))))

(ert-deftest herdr-status-panes-section-excludes-panes-running-an-agent ()
  (herdr-status-tests--with-dashboard
    (let ((panes (herdr-status-tests--tail "Panes ")))
      (should (string-match-p "Panes 1" panes))
      (should (string-match-p "%9" panes))
      (should-not (string-match-p "%1" panes)))))

(ert-deftest herdr-status-recent-section-follows-the-mru-order ()
  (herdr-status-tests--with-dashboard
    (setq herdr--recent-session-targets
          '(("/tmp/beta.sock" . "t3") ("/tmp/alpha.sock" . "t1")))
    (herdr-status-refresh)
    (let ((recent (herdr-status-tests--section-text "Recent ")))
      (should (string-match-p "Recent 2" recent))
      (should (< (string-match "beta-work" recent)
                 (string-match "api-review" recent))))))

(ert-deftest herdr-status-filters-compose-conjunctively ()
  (herdr-status-tests--with-dashboard
    (setq herdr-status--filters
          (list (cons 'agent-kind
                      (lambda (entry) (equal (alist-get 'agent entry) "claude")))
                (cons 'agent-state
                      (lambda (entry)
                        (equal (alist-get 'agent_status entry) "working")))))
    (herdr-status-refresh)
    (let ((agents (herdr-status-tests--section-text "Agents ")))
      (should (string-match-p "Agents 1/3" agents))
      (should (string-match-p "api-review" agents))
      (should-not (string-match-p "beta-work" agents))
      (should-not (string-match-p "docs" agents)))))

(ert-deftest herdr-status-registers-custom-predicates-by-name ()
  (herdr-status-tests--with-dashboard
    (let ((herdr-status-predicates
           (cons (cons 'only-codex
                       (lambda ()
                         (lambda (entry)
                           (equal (alist-get 'agent entry) "codex"))))
                 herdr-status-predicates)))
      (herdr-status-add-filter 'only-codex)
      (should (equal (mapcar #'car herdr-status--filters) '(only-codex)))
      (let ((agents (herdr-status-tests--section-text "Agents ")))
        (should (string-match-p "Agents 1/3" agents))
        (should (string-match-p "docs" agents))))))

(ert-deftest herdr-status-filters-survive-a-refresh ()
  (herdr-status-tests--with-dashboard
    (setq herdr-status--filters
          (list (cons 'attached (lambda (_entry) nil))))
    (herdr-status-refresh)
    (herdr-status-refresh)
    (should (equal (mapcar #'car herdr-status--filters) '(attached)))
    (should (string-match-p "Agents 0/3"
                            (herdr-status-tests--section-text "Agents ")))))

(ert-deftest herdr-status-clearing-filters-restores-every-agent ()
  (herdr-status-tests--with-dashboard
    (setq herdr-status--filters
          (list (cons 'attached (lambda (_entry) nil))))
    (herdr-status-refresh)
    (herdr-status-clear-filters)
    (should (null herdr-status--filters))
    (should (string-match-p "Agents 3"
                            (herdr-status-tests--section-text "Agents ")))))

(ert-deftest herdr-status-refresh-issues-no-per-agent-requests ()
  (herdr-status-tests--with-dashboard
    (should (= herdr-status-tests--agent-status-calls 0))))

(ert-deftest herdr-status-adapter-detail-is-fetched-once-per-refresh ()
  (let ((herdr-status-show-details t))
   (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (let ((expanded herdr-status-tests--agent-status-calls))
      (should (= expanded 3))
      (herdr-status-tests--expand)
      (should (= herdr-status-tests--agent-status-calls expanded))))))

(ert-deftest herdr-status-renders-an-unreachable-server-without-signalling ()
  (let ((herdr--recent-session-targets nil)
        (buffer (generate-new-buffer " *herdr-status-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-all-sessions) (lambda () '("gone")))
                  ((symbol-function 'herdr-server-key) (lambda () "/tmp/gone.sock"))
                  ((symbol-function 'herdr-available-p) (lambda () nil))
                  ((symbol-function 'herdr-sessions) (lambda () nil)))
          (with-current-buffer buffer
            (herdr-status-mode)
            (herdr-status-refresh)
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "/tmp/gone.sock" text))
              (should (string-match-p "Agents 0" text)))))
      (kill-buffer buffer))))

(ert-deftest herdr-status-state-face-falls-back-to-unknown ()
  (should (eq (herdr-status--state-face "working") 'herdr-status-state-working))
  (should (eq (herdr-status--state-face "orbiting")
              'herdr-status-state-unknown)))

(ert-deftest herdr-status-commands-reject-a-section-without-an-agent ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should-error (herdr-status--entry-at-point) :type 'user-error)
    (goto-char (point-min))
    (should (re-search-forward "^ +● " nil t))
    (should (equal (alist-get 'terminal_id (herdr-status--entry-at-point))
                   "t1"))))

(ert-deftest herdr-status-hands-the-transient-the-agent-at-point ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should-not (herdr-status-target-at-point))
    (should (re-search-forward "^ +● " nil t))
    (should (equal (herdr-status-target-at-point) '("/tmp/alpha.sock" . "t1")))
    (should (equal (herdr-transient--target) '("/tmp/alpha.sock" . "t1")))))

(ert-deftest herdr-status-opens-with-every-instance-collapsed ()
  (herdr-status-tests--with-dashboard
    (let ((text (herdr-status-tests--visible-text)))
      (should (string-match-p "Servers 2" text))
      (should-not (string-match-p "/tmp/alpha.sock" text))
      (should (string-match-p "Panes 1" text))
      (should-not (string-match-p "%9" text))
      (should (string-match-p "● api-review" text))
      (should-not (string-match-p "reachable" text))
      (should-not (string-match-p "protocol" text))
      (should-not (string-match-p "terminal_id" text)))))

(ert-deftest herdr-status-expanding-an-instance-reveals-its-body ()
  (let ((herdr-status-show-details t))
   (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (let ((text (herdr-status-tests--visible-text)))
      (should (string-match-p "reachable +yes" text))
      (should (string-match-p "terminal_id +t1" text))))))

(ert-deftest herdr-status-preview-shows-what-the-agent-last-said ()
  (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "^ ┃ ⏺ The rebase landed clean\\." text))
      (should (string-match-p "✻ Worked for 12s" text))
      (should (string-match-p "※ recap: batch two is green" text))
      (should-not (string-match-p "❯" text))
      (should-not (string-match-p "auto mode on" text))
      (should-not (string-match-p "118366/200000" text)))))

(ert-deftest herdr-status-orders-the-agents-by-the-column-asked-for ()
  (herdr-status-tests--with-dashboard
    (should (equal (mapcar #'herdr--entry-label (herdr-status--visible-agents))
                   '("api-review" "docs" "beta-work")))
    (herdr-status-sort-by "name")
    (should (equal (mapcar #'herdr--entry-label (herdr-status--visible-agents))
                   '("api-review" "beta-work" "docs")))
    (should (string-match-p "· by name ↓"
                            (herdr-status-tests--section-text "Agents ")))
    (herdr-status-sort-by "name")
    (should (equal (mapcar #'herdr--entry-label (herdr-status--visible-agents))
                   '("docs" "beta-work" "api-review")))
    (should (string-match-p "· by name ↑"
                            (herdr-status-tests--section-text "Agents ")))
    (herdr-status-sort-clear)
    (should (equal (mapcar #'herdr--entry-label (herdr-status--visible-agents))
                   '("api-review" "docs" "beta-work")))))

(ert-deftest herdr-status-sorts-working-agents-to-the-top-by-state ()
  (herdr-status-tests--with-dashboard
    (herdr-status-sort-by "state")
    (should (equal (mapcar #'herdr-status--state
                           (herdr-status--visible-agents))
                   '("working" "idle" "orbiting")))))

(ert-deftest herdr-status-orders-panes-by-their-number-not-their-text ()
  (should (string-lessp (herdr-status--pane-key '((pane_id . "w6:p9")))
                        (herdr-status--pane-key '((pane_id . "w6:p10"))))))

(ert-deftest herdr-status-sort-commands-refuse-outside-the-dashboard ()
  (with-temp-buffer
    (should-error (herdr-status-sort-by "name") :type 'user-error))
  (herdr-status-tests--with-dashboard
    (should-error (herdr-status-sort-reverse) :type 'user-error)))

(ert-deftest herdr-status-toggles-the-details-of-one-dashboard ()
  (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (should-not (string-match-p "terminal_id +t1" (buffer-string)))
    (herdr-status-toggle-details)
    (herdr-status-tests--expand)
    (should herdr-status-show-details)
    (should (local-variable-p 'herdr-status-show-details))
    (should (string-match-p "terminal_id +t1" (buffer-string)))
    (herdr-status-toggle-details)
    (should-not (string-match-p "terminal_id +t1" (buffer-string)))))

(ert-deftest herdr-status-refuses-to-toggle-details-elsewhere ()
  (with-temp-buffer
    (should-error (herdr-status-toggle-details) :type 'user-error)))

(ert-deftest herdr-status-preview-drops-tool-calls-and-their-output ()
  (should (equal (herdr-status--preview-lines
                  (string-join
                   '("⏺ Read(herdr-status.el)"
                     "  ⎿  Read 240 lines"
                     "⏺ Bash(git status)"
                     "  ⎿  nothing to commit"
                     "• Ran cargo test"
                     "  └ 41 passed"
                     "⏺ The suite is green; nothing left to fix.")
                   "\n"))
                 '("⏺ The suite is green; nothing left to fix."))))

(ert-deftest herdr-status-counts-the-agents-someone-is-waiting-on ()
  (cl-letf (((symbol-function 'herdr-status-tests--entries)
             (let ((entries (herdr-status-tests--entries)))
               (lambda ()
                 (cons (cons '(agent_status . "blocked")
                             (assq-delete-all 'agent_status
                                              (copy-alist (car entries))))
                       (cdr entries))))))
    (herdr-status-tests--with-dashboard
      (goto-char (point-min))
      (should (re-search-forward "Agents 3 .*· 1 blocked" nil t)))))

(ert-deftest herdr-status-names-the-server-that-answered-nothing ()
  (herdr-status-tests--with-dashboard
    (cl-letf (((symbol-function 'herdr-available-p)
               (lambda () (equal herdr-session "alpha"))))
      (herdr-status-refresh))
    (goto-char (point-min))
    (should (re-search-forward "Servers 2  · beta unreachable" nil t))))

(ert-deftest herdr-status-airs-the-preview-and-folds-the-air-away ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should (re-search-forward "^ +● api-review" nil t))
    (forward-line 1)
    (should (equal (get-text-property (line-end-position) 'line-height)
                   (list (+ (default-line-height) herdr-status-preview-spacing)
                         0)))
    (should-not (invisible-p (line-end-position)))
    (magit-section-hide (magit-section-at (line-beginning-position 0)))
    (should (invisible-p (line-end-position)))))

(ert-deftest herdr-status-quiets-only-the-lines-the-harness-wrote ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should (re-search-forward "✻ Worked for 12s" nil t))
    (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                'herdr-status-preview-status))
    (goto-char (point-min))
    (should (re-search-forward "The rebase landed clean" nil t))
    (should-not (eq (get-text-property (match-beginning 0) 'font-lock-face)
                    'herdr-status-preview-status))))

(ert-deftest herdr-status-leaves-window-margins-alone-without-arrows ()
  (let ((set nil))
    (cl-letf (((symbol-function 'set-window-margins)
               (lambda (&rest arguments) (push arguments set))))
      (with-temp-buffer
        (herdr-status-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (herdr-status--widen-fringe)
        (should-not set)))))

(ert-deftest herdr-status-refuses-to-redraw-from-inside-its-own-requests ()
  (herdr-status-tests--with-dashboard
    (let ((depth 0)
          (deepest 0))
      (cl-letf* ((snapshot (symbol-function 'herdr-snapshot))
                 ((symbol-function 'herdr-snapshot)
                  (lambda (&rest arguments)
                    (cl-incf depth)
                    (setq deepest (max deepest depth))
                    (when (< depth 3)
                      (herdr-status--refresh-buffers))
                    (prog1 (apply snapshot arguments)
                      (cl-decf depth)))))
        (herdr-status-refresh)
        (should (= deepest 1))))))

(ert-deftest herdr-status-heads-the-agents-section-like-every-other ()
  (herdr-status-tests--with-dashboard
    (dolist (heading '("Servers " "Agents " "Panes "))
      (goto-char (point-min))
      (let ((case-fold-search nil))
        (should (search-forward heading nil t)))
      (should (eq (get-text-property (line-beginning-position) 'font-lock-face)
                  'magit-section-heading)))))

(ert-deftest herdr-status-reads-a-bare-pane-through-pane-read ()
  (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (should (equal (assoc-default "%9" (mapcar (lambda (read)
                                                 (cons (cdr read) (car read)))
                                               herdr-status-tests--reads))
                   'pane))
    (should (equal (assoc-default "%1" (mapcar (lambda (read)
                                                 (cons (cdr read) (car read)))
                                               herdr-status-tests--reads))
                   'agent))))

(ert-deftest herdr-status-leaves-a-bare-pane-out-of-the-markdown-renderer ()
  (let ((rendered 0))
    (cl-letf (((symbol-function 'memex-markdown-render)
               (lambda (markdown &optional _code)
                 (cl-incf rendered)
                 markdown)))
      (herdr-status-tests--with-dashboard
        (herdr-status-tests--expand)
        (should (= rendered 3))))))

(ert-deftest herdr-status-previews-a-pane-without-the-agent-rule ()
  (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (let ((panes (herdr-status-tests--tail "Panes ")))
      (should (string-match-p "^ +%9" panes))
      (should (string-match-p "^   ⏺ The rebase landed clean\\." panes))
      (should-not (string-match-p "┃" panes))
      (should-not (string-match-p "workspace_id" panes)))))

(ert-deftest herdr-status-shows-pane-metadata-once-details-are-on ()
  (let ((herdr-status-show-details t))
    (herdr-status-tests--with-dashboard
      (herdr-status-tests--expand)
      (let ((panes (herdr-status-tests--tail "Panes ")))
        (should (string-match-p "workspace_id +w1" panes))
        (should-not (string-match-p "server_key" panes))))))

(ert-deftest herdr-status-preview-keeps-the-blank-between-paragraphs ()
  (should (equal (herdr-status--preview-lines
                  (string-join '("" "" "first paragraph" "" ""
                                 "⏺ Read(x.el)" "" "second paragraph" "")
                               "\n"))
                 '("first paragraph" "" "second paragraph"))))

(ert-deftest herdr-status-preview-draws-markdown-where-a-renderer-exists ()
  (let ((herdr-status-preview-markdown t))
    (cl-letf (((symbol-function 'memex-markdown-render)
               (lambda (markdown &optional _code)
                 (replace-regexp-in-string "\\*\\*" "" markdown))))
      (should (equal (herdr-status--render-preview '("**bold** words"))
                     '("bold words"))))
    (cl-letf (((symbol-function 'memex-markdown-render)
               (lambda (&rest _) (error "no renderer here"))))
      (should (equal (herdr-status--render-preview '("**bold** words"))
                     '("**bold** words")))))
  (let ((herdr-status-preview-markdown nil))
    (cl-letf (((symbol-function 'memex-markdown-render)
               (lambda (&rest _) "rendered")))
      (should (equal (herdr-status--render-preview '("**bold** words"))
                     '("**bold** words"))))))

(ert-deftest herdr-status-preview-keeps-only-what-was-said ()
  (should (equal
           (herdr-status--preview-lines
            (string-join
             '("› is henia installed globally?"
               "• I’ll check whether henia is on your PATH and where it points."
               "│ whence -a henia"
               "• No—henia isn’t on your PATH.  There is a local build."
               "─ Conversation recap ──────────────────────────────────────────"
               "Henia builds and lints local artifacts; Phora deploys."
               "gpt-6-astra high · ~/projects/henia")
             "\n"))
           '("› is henia installed globally?"
             "• I’ll check whether henia is on your PATH and where it points."
             "• No—henia isn’t on your PATH.  There is a local build."
             "Henia builds and lints local artifacts; Phora deploys."))))

(ert-deftest herdr-status-preview-is-fetched-once-per-refresh ()
  (herdr-status-tests--with-dashboard
    (should (= herdr-status-tests--read-calls 1))
    (herdr-status-tests--expand)
    (should (= herdr-status-tests--read-calls 4))
    (herdr-status-tests--expand)
    (should (= herdr-status-tests--read-calls 4))))

(ert-deftest herdr-status-preview-can-be-turned-off ()
  (let ((herdr-status-preview-lines 0))
    (herdr-status-tests--with-dashboard
      (herdr-status-tests--expand)
      (should (= herdr-status-tests--read-calls 0))
      (should-not (string-match-p
                   "The rebase landed clean"
                   (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest herdr-status-shows-the-name-the-harness-assigned ()
  (let ((herdr-status-show-details t))
   (herdr-status-tests--with-dashboard
    (herdr-status-tests--expand)
    (should (string-match-p "terminal_title_stripped +api-review"
                            (buffer-substring-no-properties
                             (point-min) (point-max)))))))

(ert-deftest herdr-status-lists-a-server-only-disk-knows-about ()
  (let ((herdr-session 'shared)
        (herdr-project-sessions nil)
        (herdr-session-alist nil))
    (cl-letf (((symbol-function 'herdr-available-sessions)
               (lambda () '(shared "cmw")))
              ((symbol-function 'herdr-server-key)
               (lambda () (format "/tmp/%s.sock" (or (herdr-session-name) "shared"))))
              ((symbol-function 'herdr-available-p) (lambda () nil)))
      (should (equal (mapcar (lambda (record) (alist-get 'key record))
                             (herdr-status--collect-servers))
                     '("/tmp/shared.sock" "/tmp/cmw.sock"))))))

(ert-deftest herdr-status-claims-the-selected-window ()
  (let ((herdr-status-buffer-name " *herdr-status-display-test*")
        (display-buffer-alist
         '((".*" (display-buffer-in-side-window) (side . right)))))
    (cl-letf (((symbol-function 'herdr-status-refresh) #'ignore))
      (unwind-protect
          (save-window-excursion
            (let ((origin (selected-window)))
              (herdr-status)
              (should (eq (selected-window) origin))
              (should (equal (buffer-name (window-buffer origin))
                             herdr-status-buffer-name))))
        (when-let* ((buffer (get-buffer herdr-status-buffer-name)))
          (kill-buffer buffer))))))

(defun herdr-status-tests--indicator-at-point ()
  "Return the visibility indicator overlay on the current line, if any."
  (cl-some (lambda (overlay) (overlay-get overlay 'magit-vis-indicator))
           (overlays-in (line-beginning-position) (line-end-position))))

(ert-deftest herdr-status-draws-collapse-indicators-on-the-first-render ()
  (let ((magit-section-visibility-indicators
         '((magit-fringe-bitmap> . magit-fringe-bitmapv) ("…" . t))))
    (herdr-status-tests--with-dashboard
      (herdr-status-refresh)
      (goto-char (point-min))
      (should (search-forward "Servers 2" nil t))
      (should (herdr-status-tests--indicator-at-point))
      (goto-char (point-min))
      (should (re-search-forward "^ +○ docs" nil t))
      (should (herdr-status-tests--indicator-at-point)))))

(ert-deftest herdr-status-keeps-its-own-fringe-width ()
  (with-temp-buffer
    (herdr-status-mode)
    (should (memq #'herdr-status--widen-fringe
                  (buffer-local-value 'window-configuration-change-hook
                                      (current-buffer))))))

(ert-deftest herdr-status-marks-the-entries-emacs-has-a-buffer-for ()
  (herdr-status-tests--with-dashboard
    (cl-letf (((symbol-function 'herdr--entry-buffer)
               (lambda (entry)
                 (when (member (alist-get 'pane_id entry) '("%1" "%9"))
                   (current-buffer)))))
      (herdr-status-refresh))
    (goto-char (point-min))
    (should (re-search-forward "^▎● api-review" nil t))
    (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                'herdr-status-attached))
    (should (eq (get-text-property (- (point) 2) 'font-lock-face)
                'herdr-status-label))
    (goto-char (point-min))
    (should (re-search-forward "^ +○ docs" nil t))
    (should (eq (get-text-property (- (point) 2) 'font-lock-face)
                'herdr-status-label-quiet))
    (goto-char (point-min))
    (should (re-search-forward "^▎ +%9" nil t))))

(ert-deftest herdr-status-rows-name-the-server-they-run-on ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should (re-search-forward "^ +● api-review +✳ claude +alpha +%1 · herdr\\.el" nil t))
    (goto-char (point-min))
    (should (re-search-forward "^ +● beta-work +✳ claude +beta +%3 · other" nil t))))

(ert-deftest herdr-status-omits-the-server-column-for-a-lone-server ()
  (let ((herdr--recent-session-targets nil)
        (buffer (generate-new-buffer " *herdr-status-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'herdr-all-sessions) (lambda () '("alpha")))
                  ((symbol-function 'herdr-server-key)
                   (lambda () "/tmp/alpha.sock"))
                  ((symbol-function 'herdr-available-p) (lambda () t))
                  ((symbol-function 'herdr-snapshot)
                   (lambda () (herdr-status-tests--snapshot "alpha")))
                  ((symbol-function 'herdr-sessions)
                   (lambda () (list (car (herdr-status-tests--entries))))))
          (with-current-buffer buffer
            (herdr-status-mode)
            (herdr-status-refresh)
            (goto-char (point-min))
            (should (re-search-forward
                     "^ +● api-review +✳ claude +%1 · herdr\\.el" nil t))))
      (kill-buffer buffer))))

(ert-deftest herdr-status-visits-the-pane-at-point ()
  (herdr-status-tests--with-dashboard
    (let ((visited nil))
      (cl-letf (((symbol-function 'herdr-visit)
                 (lambda (entry) (setq visited entry))))
        (goto-char (point-min))
        (should (re-search-forward "^ +%9" nil t))
        (herdr-status-visit)
        (should (equal (alist-get 'pane_id visited) "%9"))
        (should (equal (alist-get 'server_key visited) "/tmp/alpha.sock"))))))

(ert-deftest herdr-status-visiting-a-server-attaches-its-whole-session ()
  (herdr-status-tests--with-dashboard
    (let ((attached 'none))
      (cl-letf (((symbol-function 'herdr-attach-session)
                 (lambda (session) (setq attached session) nil))
                ((symbol-function 'herdr-status-refresh) #'ignore))
        (goto-char (point-min))
        (should (re-search-forward "^beta +/tmp/beta\\.sock" nil t))
        (herdr-status-visit)
        (should (equal attached "beta"))))))

(ert-deftest herdr-status-target-is-nil-outside-the-dashboard ()
  (with-temp-buffer
    (should-not (herdr-status-target-at-point))))

(ert-deftest herdr-status-hands-out-the-entry-at-point ()
  (herdr-status-tests--with-dashboard
    (goto-char (point-min))
    (should-not (herdr-status-entry-at-point))
    (should (re-search-forward "^ +● " nil t))
    (should (equal (alist-get 'cwd (herdr-status-entry-at-point))
                   "/tmp/proj/"))
    (goto-char (point-min))
    (should (re-search-forward "^ +%9" nil t))
    (should (equal (alist-get 'pane_id (herdr-status-entry-at-point)) "%9"))))

(ert-deftest herdr-status-rows-show-where-the-agent-is-running ()
  (herdr-status-tests--with-dashboard
    (cl-letf (((symbol-function 'herdr-status-tests--entries)
               (lambda ()
                 (list '((kind . "herdr") (session . "alpha")
                         (server_key . "/tmp/alpha.sock")
                         (agent . "claude") (agent_status . "working")
                         (name . "api-review") (terminal_id . "t1")
                         (pane_id . "%1") (workspace_id . "w1")
                         (tab_id . "tab1") (cwd . "/tmp/proj/")
                         (foreground_cwd . "/tmp/proj/.worktrees/feat-x"))))))
      (herdr-status-refresh))
    (let ((agents (herdr-status-tests--section-text "Agents ")))
      (should (string-match-p "/tmp/proj/\\.worktrees/feat-x" agents)))))

(ert-deftest herdr-status-entry-is-nil-outside-the-dashboard ()
  (with-temp-buffer
    (should-not (herdr-status-entry-at-point))))

(provide 'herdr-status-tests)
;;; herdr-status-tests.el ends here
