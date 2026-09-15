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
          (agent_session . ((agent . "claude") (kind . "id")
                            (source . "herdr:claude") (value . "s1")))
          (name . "api-review") (terminal_title_stripped . "api-review")
          (terminal_id . "t1") (pane_id . "%1")
          (workspace_id . "w1") (tab_id . "tab1") (cwd . "/tmp/proj/"))
        '((kind . "herdr") (session . "alpha")
          (server_key . "/tmp/alpha.sock")
          (agent . "codex") (agent_status . "idle")
          (agent_session . ((agent . "codex") (kind . "id")
                            (source . "herdr:codex") (value . "s2")))
          (name . "docs") (terminal_id . "t2") (pane_id . "%2")
          (workspace_id . "w1") (tab_id . "tab1") (cwd . "/tmp/proj/"))
        '((kind . "herdr") (session . "beta")
          (server_key . "/tmp/beta.sock")
          (agent . "claude") (agent_status . "orbiting")
          (agent_session . ((agent . "claude") (kind . "id")
                            (source . "herdr:claude") (value . "s3")))
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
  (should (commandp 'herdr-project-status))
  (should (commandp 'herdr-status-toggle-project))
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

(ert-deftest herdr-status-sections-functions-insert-before-recent ()
  (let ((herdr-status-sections-functions
         (list (lambda (agents widths _tabs workspaces)
                 (magit-insert-section (herdr-status-tests-extra)
                   (magit-insert-heading (format "Extra %d" (length agents)))
                   (magit-insert-section (herdr-status-agent (car agents))
                     (magit-insert-heading
                       (herdr-status-agent-row (car agents) widths workspaces))))))))
    (herdr-status-tests--with-dashboard
      (herdr--record-session-target '("/tmp/alpha.sock" . "t1"))
      (herdr-status-refresh)
      (goto-char (point-min))
      (should (looking-at "Extra 3"))
      (forward-line 1)
      (should (looking-at " +. +api-review +. +claude"))
      (should (equal (herdr-status-target-at-point) '("/tmp/alpha.sock" . "t1")))
      (should (re-search-forward "^Recent 1" nil t)))))

(ert-deftest herdr-status-request-refresh-schedules-one-idle-redraw ()
  (let ((herdr-status-auto-refresh t)
        (herdr-status--timer nil))
    (herdr-status-tests--with-dashboard
      (unwind-protect
          (progn
            (herdr-status-request-refresh)
            (should (timerp herdr-status--timer))
            (let ((timer herdr-status--timer))
              (herdr-status-request-refresh)
              (should (eq herdr-status--timer timer))))
        (when herdr-status--timer
          (cancel-timer herdr-status--timer)
          (setq herdr-status--timer nil))))))

(ert-deftest herdr-status-lists-every-known-session ()
  (herdr-status-tests--with-dashboard
    (let ((sessions (herdr-status-tests--section-text "Sessions ")))
      (should (string-match-p "Sessions 2" sessions))
      (should (string-match-p "/tmp/alpha.sock" sessions))
      (should (string-match-p "/tmp/beta.sock" sessions)))))

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
      (should (string-match-p "Sessions 2" text))
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

(ert-deftest herdr-status-names-the-session-that-answered-nothing ()
  (herdr-status-tests--with-dashboard
    (cl-letf (((symbol-function 'herdr-available-p)
               (lambda () (equal herdr-session "alpha"))))
      (herdr-status-refresh))
    (goto-char (point-min))
    (should (re-search-forward "Sessions 2  · beta unreachable" nil t))))

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
    (dolist (heading '("Sessions " "Agents " "Panes "))
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
      (should (string-match-p "^ +shell .*%9 · herdr.el" panes))
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
                             (herdr-status--collect-sessions))
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
      (should (search-forward "Sessions 2" nil t))
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
    (should (re-search-forward
             (concat "^" (regexp-quote herdr-status-attached-glyph)
                     " ● api-review")
             nil t))
    (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                'herdr-status-attached))
    (should (eq (get-text-property (- (point) 2) 'font-lock-face)
                'herdr-status-label))
    (goto-char (point-min))
    (should (re-search-forward "^ +○ docs" nil t))
    (should (eq (get-text-property (- (point) 2) 'font-lock-face)
                'herdr-status-label-quiet))
    (goto-char (point-min))
    (should (re-search-forward
             (concat "^" (regexp-quote herdr-status-attached-glyph) " +shell")
             nil t))))

(ert-deftest herdr-status-drops-the-marker-column-when-the-glyph-is-nil ()
  (let ((herdr-status-attached-glyph nil))
    (herdr-status-tests--with-dashboard
      (cl-letf (((symbol-function 'herdr--entry-buffer)
                 (lambda (entry)
                   (when (equal (alist-get 'pane_id entry) "%1")
                     (current-buffer)))))
        (herdr-status-refresh))
      (goto-char (point-min))
      (should (re-search-forward "^● api-review" nil t))
      (should (eq (get-text-property (- (point) 2) 'font-lock-face)
                  'herdr-status-label))
      (goto-char (point-min))
      (should (re-search-forward "^○ docs" nil t))
      (should (eq (get-text-property (- (point) 2) 'font-lock-face)
                  'herdr-status-label-quiet)))))

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
        (should (re-search-forward "^ +shell" nil t))
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
    (should (re-search-forward "^ +shell" nil t))
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

;;;; Dispatch

(defun herdr-status-tests--suffix-command (prefix key)
  "Return the command PREFIX runs for KEY, or nil when it binds none.
Transient answers with either (CLASS . PLIST) or (LEVEL CLASS PLIST)
depending on its version."
  (when-let* ((suffix (ignore-errors (transient-get-suffix prefix key))))
    (or (plist-get (cdr suffix) :command)
        (and (> (length suffix) 2) (plist-get (nth 2 suffix) :command)))))

(ert-deftest herdr-status-dispatch-mirrors-the-keymap ()
  (dolist (key '("RET" "o" "P" "R" "d" "x" "f" "O" "t" "h" "g" "p" "q"))
    (let ((bound (keymap-lookup herdr-status-mode-map key))
          (offered (herdr-status-tests--suffix-command 'herdr-status-dispatch key)))
      (should (commandp bound))
      (should (eq bound offered)))))

(ert-deftest herdr-status-dispatch-closes-on-a-second-question-mark ()
  (should (eq 'transient-quit-one
              (herdr-status-tests--suffix-command 'herdr-status-dispatch "?")))
  (should (eq #'herdr-status-dispatch (keymap-lookup herdr-status-mode-map "?"))))

(ert-deftest herdr-herd-dispatch-offers-only-real-commands ()
  (dolist (key '("a" "A" "r" "d" "b" "R"))
    (should (commandp (herdr-status-tests--suffix-command 'herdr-herd-dispatch key)))))

(ert-deftest herdr-transient-keeps-the-anchor-memex-appends-after ()
  "`memex-herdr-setup' appends after the suffix keyed i and only when the
key it wants is free, so taking either silently costs the transcript entry."
  (should (herdr-status-tests--suffix-command 'herdr-transient "i"))
  (should-not (herdr-status-tests--suffix-command 'herdr-transient "v")))

(ert-deftest herdr-transient-shares-the-keys-of-the-actions-the-dashboard-has ()
  "Two menus disagreeing on the key for one action is worse than either."
  (pcase-dolist (`(,key ,dashboard ,global)
                 '(("P" herdr-status-prompt herdr-transient--prompt)
                   ("R" herdr-status-rename herdr-transient--rename)
                   ("x" herdr-status-stop herdr-transient--stop)))
    (should (eq dashboard (keymap-lookup herdr-status-mode-map key)))
    (should (eq global (herdr-status-tests--suffix-command 'herdr-transient key)))))

;;;; Herds

(defmacro herdr-status-tests--with-herds (labels &rest body)
  "Run BODY with LABELS on the fixture agents, keyed by agent name.
Herd membership is the pane label herdr reports, so a herd is set up by
labelling the panes the fixture agents occupy."
  (declare (indent 1) (debug (form body)))
  `(let ((entries (herdr-status-tests--entries))
         (table ,labels))
     (cl-letf (((symbol-function 'herdr-status-tests--entries)
                (lambda ()
                  (mapcar (lambda (entry)
                            (let ((label (cdr (assoc (alist-get 'name entry)
                                                     table))))
                              (cons (cons 'pane_label label) entry)))
                          entries))))
       ,@body)))

(defun herdr-status-tests--herd-section (name)
  "Return the section drawing the herd called NAME."
  (or (seq-find (lambda (section)
                  (and (eq (oref section type) 'herdr-status-herd)
                       (equal (cdr (oref section value)) name)))
                (herdr-status--sections magit-root-section))
      (error "No section for herd %s" name)))

(ert-deftest herdr-status-draws-no-herds-section-without-a-herd ()
  (herdr-status-tests--with-herds nil
    (herdr-status-tests--with-dashboard
      (goto-char (point-min))
      (should-not (search-forward "Herds" nil t)))))

(ert-deftest herdr-status-draws-a-herd-with-its-live-members ()
  (herdr-status-tests--with-herds
      '(("api-review" . "herd:refactor") ("docs" . "herd:refactor"))
    (herdr-status-tests--with-dashboard
      (let ((herds (herdr-status-tests--section-text "Herds 1")))
        (should (string-match-p "refactor  · 2 members" herds))
        (should (string-match-p "api-review" herds))
        (should (string-match-p "docs" herds))))))

(defun herdr-status-tests--herd-text (name)
  "Return the text the section drawing the herd NAME covers."
  (let ((section (herdr-status-tests--herd-section name)))
    (buffer-substring-no-properties (oref section start) (oref section end))))

(ert-deftest herdr-status-leaves-an-unlabelled-agent-out-of-every-herd ()
  (herdr-status-tests--with-herds '(("api-review" . "herd:refactor"))
    (herdr-status-tests--with-dashboard
      (should (string-match-p "refactor  · 1 member"
                              (herdr-status-tests--section-text "Herds 1")))
      (let ((herd (herdr-status-tests--herd-text "refactor")))
        (should (string-match-p "api-review" herd))
        (should-not (string-match-p "beta-work" herd))
        (should-not (string-match-p "docs" herd))))))

(ert-deftest herdr-status-reads-a-herd-past-the-rest-of-a-pane-label ()
  (herdr-status-tests--with-herds
      '(("api-review" . "herd:refactor  a label of its own"))
    (herdr-status-tests--with-dashboard
      (should (string-match-p "refactor  · 1 member"
                              (herdr-status-tests--section-text "Herds 1"))))))

(ert-deftest herdr-status-keeps-a-herd-collapsed-across-a-refresh ()
  (herdr-status-tests--with-herds '(("api-review" . "herd:refactor"))
    (herdr-status-tests--with-dashboard
      (should-not (oref (herdr-status-tests--herd-section "refactor") hidden))
      (magit-section-hide (herdr-status-tests--herd-section "refactor"))
      (herdr-status-refresh)
      (should (oref (herdr-status-tests--herd-section "refactor") hidden))
      (magit-section-show (herdr-status-tests--herd-section "refactor"))
      (herdr-status-refresh)
      (should-not (oref (herdr-status-tests--herd-section "refactor") hidden)))))

(ert-deftest herdr-status-visiting-shows-the-agent-without-moving-herdr ()
  (herdr-status-tests--with-dashboard
    (let (switched visited)
      (cl-letf (((symbol-function 'herdr-agent-switch)
                 (lambda (target) (setq switched target)))
                ((symbol-function 'herdr-visit)
                 (lambda (entry) (setq visited entry))))
        (goto-char (point-min))
        (should (re-search-forward "^ +● api-review" nil t))
        (herdr-status-visit)
        (should-not switched)
        (should (equal "t1" (alist-get 'terminal_id visited)))))))

(ert-deftest herdr-status-visiting-with-a-prefix-moves-herdr-too ()
  "Focusing the pane in herdr was its own key; it folded into the visit a
prefix argument makes, so the terminal and Emacs land on one agent."
  (herdr-status-tests--with-dashboard
    (let (switched visited)
      (cl-letf (((symbol-function 'herdr-agent-switch)
                 (lambda (target) (setq switched target)))
                ((symbol-function 'herdr-visit)
                 (lambda (entry) (setq visited entry))))
        (goto-char (point-min))
        (should (re-search-forward "^ +● api-review" nil t))
        (let ((current-prefix-arg '(4)))
          (call-interactively #'herdr-status-visit))
        (should-not visited)
        (should (equal '("/tmp/alpha.sock" . "t1") switched))))))

(ert-deftest herdr-status-stopping-lets-go-of-the-buffer-before-the-pane ()
  "A stopped pane leaves its terminal buffer showing a dead process, so
Emacs releases the attachment first and the two go together."
  (herdr-status-tests--with-dashboard
    (let (calls)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-resolve-session)
                 (lambda (_target) 'session))
                ((symbol-function 'herdr-agent-detach)
                 (lambda (session) (push (list 'detach session) calls)))
                ((symbol-function 'herdr-agent-stop)
                 (lambda (target) (push (list 'stop target) calls))))
        (goto-char (point-min))
        (should (re-search-forward "^ +● api-review" nil t))
        (herdr-status-stop))
      (should (equal '((detach session)
                       (stop ("/tmp/alpha.sock" . "t1")))
                     (nreverse calls))))))

(ert-deftest herdr-status-stopping-an-unattached-agent-still-closes-its-pane ()
  (herdr-status-tests--with-dashboard
    (let (calls)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'herdr-agent-resolve-session)
                 (lambda (_target) (user-error "Unknown agent: t1")))
                ((symbol-function 'herdr-agent-detach)
                 (lambda (&rest _) (ert-fail "detached what was not attached")))
                ((symbol-function 'herdr-agent-stop)
                 (lambda (target) (push (list 'stop target) calls))))
        (goto-char (point-min))
        (should (re-search-forward "^ +● api-review" nil t))
        (herdr-status-stop))
      (should (equal '((stop ("/tmp/alpha.sock" . "t1"))) calls)))))

(ert-deftest herdr-status-declining-the-question-stops-nothing ()
  (herdr-status-tests--with-dashboard
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'herdr-agent-stop)
               (lambda (&rest _) (ert-fail "stopped without being told to")))
              ((symbol-function 'herdr-agent-detach)
               (lambda (&rest _) (ert-fail "detached without being told to"))))
      (goto-char (point-min))
      (should (re-search-forward "^ +● api-review" nil t))
      (herdr-status-stop))))

(ert-deftest herdr-status-detaching-leaves-the-pane-running ()
  (herdr-status-tests--with-dashboard
    (let (calls)
      (cl-letf (((symbol-function 'herdr-agent-resolve-session)
                 (lambda (_target) 'session))
                ((symbol-function 'herdr-agent-detach)
                 (lambda (session) (push (list 'detach session) calls)))
                ((symbol-function 'herdr-agent-stop)
                 (lambda (&rest _) (ert-fail "detaching closed the pane"))))
        (goto-char (point-min))
        (should (re-search-forward "^ +● api-review" nil t))
        (herdr-status-detach))
      (should (equal '((detach session)) calls)))))

(ert-deftest herdr-status-detaching-what-emacs-never-attached-says-so ()
  (herdr-status-tests--with-dashboard
    (cl-letf (((symbol-function 'herdr-agent-resolve-session)
               (lambda (_target) (user-error "Unknown agent: t1")))
              ((symbol-function 'herdr-agent-detach)
               (lambda (&rest _) (ert-fail "detached what was not attached"))))
      (goto-char (point-min))
      (should (re-search-forward "^ +● api-review" nil t))
      (herdr-status-detach))))

;;;; Project scope

(defun herdr-status-tests--project-root (&optional directory)
  "Return the fixture project holding DIRECTORY."
  (seq-find (lambda (root) (herdr--directory-covers-p root directory))
            '("/tmp/proj/nested/" "/tmp/proj/" "/tmp/other/")))

(ert-deftest herdr-project-status-scopes-sections-and-preserves-recent-history ()
  (let* ((herdr-project-root-function #'herdr-status-tests--project-root)
         (snapshot (copy-tree (herdr-status-tests--snapshot "alpha"))))
    (setf (alist-get 'panes snapshot)
          (append (alist-get 'panes snapshot)
                  '(((pane_id . "%10") (cwd . "/tmp/proj/")
                     (foreground_cwd . "/tmp/other/"))
                    ((pane_id . "%11") (cwd . "/tmp/proj/nested/")))))
    (setf (alist-get 'foreground_cwd (nth 2 (alist-get 'panes snapshot)))
          "/tmp/proj/src/")
    (herdr-status-tests--with-herds
        '(("api-review" . "herd:local") ("beta-work" . "herd:foreign"))
      (herdr-status-tests--with-dashboard
        (save-window-excursion
          (let ((herdr-status-buffer-name (buffer-name))
                (herdr-status-sections-functions
                 (list (lambda (entries &rest _)
                         (should (= (length entries) 2))))))
            (setq default-directory "/tmp/proj/src/"
                  herdr--recent-session-targets
                  '(("/tmp/beta.sock" . "t3") ("/tmp/alpha.sock" . "t1")))
            (cl-letf (((symbol-function 'herdr-snapshot)
                       (lambda ()
                         (if (equal herdr-session "alpha")
                             snapshot
                           (herdr-status-tests--snapshot herdr-session)))))
              (herdr-project-status)
              (herdr-status-refresh))
            (should (string-match-p "/tmp/proj/" header-line-format))
            (should (string-match-p "Agents 2" (buffer-string)))
            (should (string-match-p "Recent 1" (buffer-string)))
            (should (string-match-p "Herds 1" (buffer-string)))
            (should (string-match-p "Panes 1" (buffer-string)))
            (let ((sessions (herdr-status-tests--section-text "Sessions ")))
              (should (string-match-p "Sessions 1" sessions))
              (should (string-match-p "/tmp/alpha.sock" sessions))
              (should-not (string-match-p "/tmp/beta.sock" sessions)))
            (should-not (string-match-p "beta-work\\|foreign\\|%10\\|%11"
                                        (buffer-string)))
            (should (equal herdr--recent-session-targets
                           '(("/tmp/beta.sock" . "t3")
                             ("/tmp/alpha.sock" . "t1"))))))))))

(ert-deftest herdr-project-status-captures-the-caller-and-toggles-repeatedly ()
  (let ((herdr-project-root-function #'herdr-status-tests--project-root))
    (herdr-status-tests--with-dashboard
      (save-window-excursion
        (let ((herdr-status-buffer-name (buffer-name)))
          (setq default-directory "/tmp/other/")
          (with-temp-buffer
            (setq default-directory "/tmp/proj/src/")
            (herdr-project-status))
          (should (equal default-directory "/tmp/proj/"))
          (should (string-match-p "Agents 2" (buffer-string)))
          (should (string-match-p "Sessions 1" (buffer-string)))
          (herdr-status-clear-filters)
          (should (string-match-p "Agents 2" (buffer-string)))
          (dotimes (_ 2)
            (herdr-status-toggle-project)
            (should (string-match-p "Global" header-line-format))
            (should (string-match-p "Agents 3" (buffer-string)))
            (should (string-match-p "Sessions 2" (buffer-string)))
            (herdr-status-toggle-project)
            (should (equal default-directory "/tmp/proj/"))
            (should (string-match-p "Agents 2" (buffer-string)))
            (should (string-match-p "Sessions 1" (buffer-string))))
          (with-temp-buffer
            (setq default-directory "/tmp/other/")
            (herdr-project-status))
          (should (string-match-p "Agents 1" (buffer-string)))
          (should (string-match-p "beta-work" (buffer-string)))
          (with-temp-buffer
            (setq default-directory "/tmp/proj/src/")
            (herdr-status))
          (should (string-match-p "Global" header-line-format))
          (herdr-status-toggle-project)
          (should (string-match-p "Agents 2" (buffer-string))))))))

(ert-deftest herdr-project-status-includes-a-session-with-only-a-matching-pane ()
  (let* ((herdr-project-root-function #'herdr-status-tests--project-root)
         (snapshot (copy-tree (herdr-status-tests--snapshot "beta")))
         (pane (copy-tree '((pane_id . "%9") (cwd . "/tmp/proj/src/")
                            (foreground_cwd)))))
    (push pane (alist-get 'panes snapshot))
    (herdr-status-tests--with-dashboard
      (save-window-excursion
        (let ((herdr-status-buffer-name (buffer-name)))
          (setq default-directory "/tmp/proj/")
          (cl-letf (((symbol-function 'herdr-sessions) (lambda () nil))
                    ((symbol-function 'herdr-snapshot)
                     (lambda ()
                       (if (equal herdr-session "beta")
                           snapshot
                         (herdr-status-tests--snapshot herdr-session)))))
            (herdr-project-status)
            (let ((sessions (herdr-status-tests--section-text "Sessions ")))
              (should (string-match-p "Sessions 1" sessions))
              (should (string-match-p "/tmp/beta.sock" sessions))
              (should-not (string-match-p "/tmp/alpha.sock" sessions)))
            (setf (alist-get 'foreground_cwd pane) "/tmp/other/")
            (herdr-status-refresh)
            (should (string-match-p "Sessions 0" (buffer-string)))
            (herdr-status-toggle-project)
            (should (string-match-p "Sessions 2" (buffer-string)))))))))

(ert-deftest herdr-project-status-scopes-the-readers-that-offer-a-target ()
  (let ((herdr-project-root-function #'herdr-status-tests--project-root))
    (herdr-status-tests--with-dashboard
      (save-window-excursion
        (let ((herdr-status-buffer-name (buffer-name)))
          (setq default-directory "/tmp/proj/src/")
          (herdr-project-status)
          (should (equal (mapcar #'herdr--entry-label (herdr-entries-in-scope))
                         '("api-review" "docs")))
          (should (equal (mapcar #'herdr--entry-label (herdr-herd-live-agents))
                         '("api-review" "docs")))
          (should (equal (mapcar #'herdr--entry-label (herdr-status-switch-agents))
                         '("api-review" "docs")))
          (herdr-status-toggle-project)
          (should (equal (mapcar #'herdr--entry-label (herdr-entries-in-scope))
                         '("api-review" "docs" "beta-work"))))))))

(ert-deftest herdr-project-status-rejects-a-missing-project-before-changing-view ()
  (let ((herdr-project-root-function (lambda (&optional _) nil)))
    (herdr-status-tests--with-dashboard
      (let ((herdr-status-buffer-name (buffer-name))
            (text (buffer-string)))
        (should-error (herdr-project-status) :type 'user-error)
        (should-error (herdr-status-toggle-project) :type 'user-error)
        (should (equal text (buffer-string)))
        (should (string-match-p "Global" header-line-format))))))

(provide 'herdr-status-tests)
;;; herdr-status-tests.el ends here
