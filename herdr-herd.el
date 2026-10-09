;;; herdr-herd.el --- Sets of agents aware of each other -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A herd is a named set of agents that know each other's names and know
;; the herdr CLI is how they reach one another.  Joining one sends the
;; member a roster; nothing is written into the project it works in, so a
;; harness without a skill mechanism joins on the same terms as Claude.
;;
;; A herd belongs to one herdr session, because `herdr agent prompt'
;; reaches one server: agents on different sessions never share a herd
;; however alike their labels.  A herd is therefore named by the cons of
;; its session and its own name.
;;
;; Membership lives in herdr, not in Emacs: a member's pane carries the
;; metadata token `herd', reported under the source
;; `herdr-herd-metadata-source'.  Neither the pane's label nor the
;; agent's name is touched, and peers reach each other by pane id, which
;; every `herdr agent' command takes.  Herdr reports the token with the
;; pane and the agent, so an agent joins or reads a herd with `herdr pane
;; report-metadata' and `herdr pane list' and needs no editor running.
;; The token lasts as long as the pane, a handoff included; a server
;; restart starts the panes, and so the herds, over.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'herdr-agent)

(declare-function herdr-status-refresh "herdr-status" ())
(declare-function herdr-status-entry-at-point "herdr-status" ())

(defgroup herdr-herd nil
  "Sets of herdr agents made aware of each other."
  :group 'herdr)

(defconst herdr-herd-metadata-source "herdr-herd"
  "The source herd membership is reported to herdr under.")

(defcustom herdr-herd-notice-prefix "[herd "
  "What opens a one-line notice sent to a herd's members.
The herd's name and a closing bracket follow it, so an agent, or a hook
reading the prompt an agent received, can tell a notice from a task."
  :type 'string
  :group 'herdr-herd)

(defcustom herdr-herd-busy-states '("working" "blocked")
  "Agent states a herd will not prompt into.
A prompt sent to an agent in one of these interleaves with the turn it
is in the middle of."
  :type '(repeat string)
  :group 'herdr-herd)

(defcustom herdr-herd-command
  (lambda ()
    (when-let* ((library (locate-library "herdr-herd")))
      (let ((script (expand-file-name
                     "bin/herdr-herd" (file-name-directory library))))
        (and (file-executable-p script) script))))
  "How a joining agent is told to reach the `herdr-herd' helper.
A function of no arguments returning its path, a path, or nil to tell
agents only the plain `herdr' commands the helper wraps."
  :type '(choice (const :tag "Do not mention it" nil) function file)
  :group 'herdr-herd)

(defcustom herdr-herd-protocol "\
You are in a herd: agents in this herdr session, reached by pane.
  herdr agent prompt <pane> \"<msg>\"   # interrupts; `herdr agent get <pane>' first
  herdr agent read <pane>
Join or leave: herdr pane report-metadata <pane> --source herdr-herd
--token herd=<herd> | --clear-token herd. Needs HERDR_ENV=1; `herdr
--help' for syntax. Lines opening `[herd' are notices: do not reply.
Name yourself and keep messages short."
  "What a joining agent is told about being in a herd.
The live roster is appended to this when a member joins."
  :type 'string
  :group 'herdr-herd)

(defvar herdr-herd-protocol-functions nil
  "Functions returning further paragraphs of the herd protocol, or nil.
Each is called with the herd and runs after `herdr-herd-protocol' in
what a joining member is told.")

(defvar herdr-herd-sent-functions nil
  "Functions called with the entry and text of every prompt a herd command sends.")

;;;; The label a pane carries

(defun herdr-herd-label-token (label prefix)
  "Return what the word of LABEL opening with PREFIX says after it.
Nil where no word does."
  (when (stringp label)
    (seq-some (lambda (word)
                (and (string-prefix-p prefix word)
                     (substring word (length prefix))))
              (split-string label))))

(defun herdr-herd-label-with-token (label prefix value)
  "Return LABEL with its word opening with PREFIX saying VALUE after it.
The word keeps its place, is added at the end where there was none, and
is dropped when VALUE is nil; every other word stays.  Nil for a label
left with no word, which is what clears a label."
  (let* ((word (and value (concat prefix value)))
         (placed nil)
         (words (delq nil
                      (mapcar (lambda (each)
                                (if (string-prefix-p prefix each)
                                    (prog1 (and (not placed) word)
                                      (setq placed t))
                                  each))
                              (and (stringp label) (split-string label)))))
         (words (if (and word (not placed)) (append words (list word)) words)))
    (and words (string-join words " "))))

(defun herdr-herd--valid-name-p (name)
  "Return non-nil when NAME can name a herd or a member of one."
  (and (stringp name)
       (string-match-p "\\`[^[:space:]]+\\'" name)))

(defun herdr-herd--rename (entry label)
  "Give ENTRY's pane LABEL, clearing it when LABEL is nil."
  (herdr-with-session (alist-get 'session entry)
    (herdr-api-pane-rename (alist-get 'pane_id entry) :label label)))

(defun herdr-herd--put (entry herd)
  "Put ENTRY's pane in HERD, taking it out of every herd when HERD is nil."
  (herdr-with-session (alist-get 'session entry)
    (herdr-api-pane-report-metadata
     (alist-get 'pane_id entry) herdr-herd-metadata-source
     :tokens `((herd . ,(or herd ""))))))

(defun herdr-herd--with-membership (entry herd)
  "Return ENTRY as herdr reports it once it is in HERD."
  (cons (cons 'tokens (cons (cons 'herd herd)
                            (assq-delete-all
                             'herd (copy-alist (alist-get 'tokens entry)))))
        entry))

;;;; Reading the herds

(defun herdr-herd--agent-session (entry)
  "Return the id of the agent session herdr reports for ENTRY, or nil.
This is the harness's own session, not the herdr session ENTRY lives on."
  (alist-get 'value (alist-get 'agent_session entry)))

(defun herdr-herd-live-agents (&optional session)
  "Return every live agent entry herdr reports an agent session for.
SESSION keeps only the agents on that herdr session."
  (seq-filter (lambda (entry)
                (and (herdr-herd--agent-session entry)
                     (or (null session)
                         (equal (herdr-herd--session-label
                                 (alist-get 'session entry))
                                (herdr-herd--session-label session)))))
              (herdr-entries-in-scope)))

(defun herdr-herd--session-label (session)
  "Return the name SESSION goes under, the shared one included."
  (or (herdr-session-name session) "shared"))

(defun herdr-herd-label (herd)
  "Return HERD as one string, its session included where one is named."
  (let ((session (herdr-herd--session-label (car herd))))
    (if (equal session "shared")
        (cdr herd)
      (format "%s/%s" session (cdr herd)))))

(defun herdr-herd-of-entry (entry)
  "Return the herd ENTRY's pane belongs to, or nil.
A herd is the cons of the session it lives on and its own name."
  (when-let* ((name (alist-get 'herd (alist-get 'tokens entry))))
    (cons (alist-get 'session entry) name)))

(defun herdr-herd--same-p (one other)
  "Return non-nil when ONE and OTHER name the same herd."
  (and one other
       (equal (herdr-herd--session-label (car one))
              (herdr-herd--session-label (car other)))
       (equal (cdr one) (cdr other))))

(defun herdr-herds (&optional agents)
  "Return every herd as an alist of herd to the entries in it.
AGENTS are the entries to read, the live ones by default.  Herds come out
in session and then name order, members in the order herdr reports them."
  (let (herds)
    (dolist (entry (or agents (herdr-herd-live-agents)))
      (when-let* ((herd (herdr-herd-of-entry entry)))
        (let ((cell (seq-find (lambda (cell) (herdr-herd--same-p (car cell) herd))
                              herds)))
          (if cell
              (setcdr cell (cons entry (cdr cell)))
            (push (cons herd (list entry)) herds)))))
    (mapcar (lambda (herd) (cons (car herd) (nreverse (cdr herd))))
            (sort herds
                  (lambda (a b)
                    (let ((one (herdr-herd-label (car a)))
                          (other (herdr-herd-label (car b))))
                      (string< one other)))))))

(defun herdr-herd-names (&optional session)
  "Return the name of every herd with a live member on SESSION.
Every session's names when SESSION is nil."
  (delete-dups
   (delq nil
         (mapcar (lambda (herd)
                   (when (or (null session)
                             (equal (herdr-herd--session-label (car (car herd)))
                                    (herdr-herd--session-label session)))
                     (cdr (car herd))))
                 (herdr-herds)))))

(defun herdr-herd-member-entries (herd &optional agents)
  "Return the live agent entries of HERD, the cons of a session and a name.
AGENTS are the entries to read, the live ones by default."
  (cdr (seq-find (lambda (cell) (herdr-herd--same-p (car cell) herd))
                 (herdr-herds agents))))

(defun herdr-herd-entry-brief (entry)
  "Return ENTRY as its name, harness and pane, for a one-line notice."
  (format "%s (%s, %s)"
          (herdr--entry-label entry)
          (or (alist-get 'agent entry) "?")
          (alist-get 'pane_id entry)))

(defun herdr-herd--roster-line (entry)
  "Return ENTRY as one line of a roster: its pane, name and harness."
  (format "  %-8s %s (%s)"
          (or (alist-get 'pane_id entry) "?")
          (herdr--entry-label entry)
          (or (alist-get 'agent entry) "?")))

(defun herdr-herd--helper ()
  "Return what to tell a joining agent about the `herdr-herd' helper, or nil."
  (when-let* ((script (if (functionp herdr-herd-command)
                          (funcall herdr-herd-command)
                        herdr-herd-command)))
    (concat "Helper: " script
            " list|peers|of|join <herd>|leave|say <msg>|tell <pane> <msg>")))

(defun herdr-herd--roster (herd self members)
  "Return the prompt telling SELF, an entry, it is in HERD alongside MEMBERS."
  (let ((peers (seq-remove (lambda (entry) (herdr-herd--same-pane-p entry self))
                           members))
        (name (cdr herd)))
    (concat "/herd " name " — you are " (herdr--entry-label self)
            " in pane " (alist-get 'pane_id self) "\n"
            herdr-herd-protocol "\n"
            (mapconcat (lambda (paragraph) (concat paragraph "\n"))
                       (delq nil (mapcar (lambda (function) (funcall function herd))
                                         herdr-herd-protocol-functions))
                       "")
            (when-let* ((helper (herdr-herd--helper)))
              (concat helper "\n"))
            (if peers
                (concat "Peers:\n"
                        (string-join (mapcar #'herdr-herd--roster-line peers)
                                     "\n"))
              "No peers yet.")
            "\n")))

(defun herdr-herd-notice (herd text)
  "Return TEXT as a one-line notice to a member of HERD.
It opens with `herdr-herd-notice-prefix' and HERD's name, which the
protocol tells a member not to answer."
  (format "%s%s] %s" herdr-herd-notice-prefix (cdr herd) text))

(defun herdr-herd--same-pane-p (one other)
  "Return non-nil when entries ONE and OTHER name the same pane."
  (and (equal (alist-get 'pane_id one) (alist-get 'pane_id other))
       (equal (herdr--entry-server one) (herdr--entry-server other))))

(defun herdr-herd--members-with (herd entries)
  "Return HERD's live members with ENTRIES ahead of them.
ENTRIES are members herdr may not report as such yet."
  (append entries
          (seq-remove (lambda (member)
                        (seq-some (lambda (entry)
                                    (herdr-herd--same-pane-p member entry))
                                  entries))
                      (herdr-herd-member-entries herd))))

(defun herdr-herd--busy-p (entry)
  "Return non-nil when ENTRY's agent should not be prompted right now."
  (member (alist-get 'agent_status entry) herdr-herd-busy-states))

(defun herdr-herd--report (herd sent skipped verb)
  "Say that VERB reached SENT members of HERD and SKIPPED the rest."
  (if skipped
      (message "herd %s: %s %d, skipped %s" (herdr-herd-label herd) verb sent
               (string-join (mapcar (lambda (skip)
                                      (format "%s (%s)" (car skip) (cdr skip)))
                                    skipped)
                            ", "))
    (message "herd %s: %s %d member%s" (herdr-herd-label herd) verb sent
             (if (= 1 sent) "" "s")))
  skipped)

(defun herdr-herd--send (herd members text-function verb)
  "Send every idle member of HERD what TEXT-FUNCTION makes of it.
MEMBERS are the entries to reach.  VERB heads the report."
  (let ((sent 0)
        (skipped nil))
    (dolist (entry members)
      (if (herdr-herd--busy-p entry)
          (push (cons (herdr--entry-label entry)
                      (alist-get 'agent_status entry))
                skipped)
        (let ((text (funcall text-function entry)))
          (herdr-agent-prompt (herdr--entry-target entry) text)
          (run-hook-with-args 'herdr-herd-sent-functions entry text))
        (setq sent (1+ sent))))
    (herdr-herd--report herd sent (nreverse skipped) verb)))

(defun herdr-herd--announce (herd)
  "Send every live member of HERD the current roster."
  (let ((members (herdr-herd-member-entries herd)))
    (herdr-herd--send
     herd members
     (lambda (entry)
       (herdr-herd--roster herd entry members))
     "told")))

(defun herdr-herd--welcome (herd joined)
  "Tell JOINED the roster of HERD and the other members who joined."
  (let* ((members (herdr-herd--members-with herd joined))
         (others (seq-remove (lambda (member)
                               (seq-some (lambda (entry)
                                           (herdr-herd--same-pane-p member entry))
                                         joined))
                             members)))
    (herdr-herd--send herd joined
                      (lambda (entry)
                        (herdr-herd--roster herd entry members))
                      "welcomed")
    (when others
      (herdr-herd--send
       herd others
       (lambda (_entry)
         (herdr-herd-notice
          herd (string-join
                (mapcar (lambda (entry)
                          (format "%s joined." (herdr-herd-entry-brief entry)))
                        joined)
                " ")))
       "told"))))

;;;; Reading the dashboard

(defun herdr-herd--section-value (type)
  "Return the value of the section at point of TYPE, walking up to it."
  (let ((section (magit-current-section))
        (found nil))
    (while (and section (not found))
      (when (eq (oref section type) type)
        (setq found (oref section value)))
      (setq section (oref section parent)))
    found))

(defun herdr-herd-at-point ()
  "Return the herd the section at point belongs to, or nil."
  (or (herdr-herd--section-value 'herdr-status-herd)
      (when-let* ((entry (herdr-herd--section-value 'herdr-status-agent)))
        (herdr-herd-of-entry entry))))

(defun herdr-herd-session-at-point ()
  "Return the herdr session the section at point belongs to, or `unknown'.
An agent row, a herd, and a session row each name one; anywhere else in
the dashboard names none, and a caller needing one asks."
  (cond
   ((herdr-herd--section-value 'herdr-status-herd)
    (car (herdr-herd--section-value 'herdr-status-herd)))
   ((herdr-herd--section-value 'herdr-status-agent)
    (alist-get 'session (herdr-herd--section-value 'herdr-status-agent)))
   ((herdr-herd--section-value 'herdr-status-session)
    (herdr-herd--session-of-key
     (herdr-herd--section-value 'herdr-status-session)))
   (t 'unknown)))

(defun herdr-herd--session-of-key (key)
  "Return the session designator whose server KEY identifies."
  (or (seq-find (lambda (session)
                  (equal (herdr-with-session session (herdr-server-key)) key))
                (herdr-all-sessions))
      'unknown))

(defun herdr-herd--read-session (&optional prompt)
  "Return the session point names, asking with PROMPT where it names none."
  (let ((session (herdr-herd-session-at-point)))
    (if (eq session 'unknown)
        (herdr-read-session (or prompt "Session"))
      session)))

(defun herdr-herd--read (prompt &optional require)
  "Read a herd with PROMPT, taking the session point names or asking for it.
REQUIRE non-nil refuses a name that session carries no herd under."
  (let* ((at-point (herdr-herd-at-point))
         (session (herdr-herd--read-session))
         (names (herdr-herd-names session))
         (default (when (and at-point
                             (equal (herdr-herd--session-label (car at-point))
                                    (herdr-herd--session-label session)))
                    (cdr at-point))))
    (when (and require (null names))
      (user-error "The %s session has no herd with a live member"
                  (herdr-herd--session-label session)))
    (cons session
          (completing-read (format-prompt
                            (format "%s (%s session)" prompt
                                    (herdr-herd--session-label session))
                            default)
                           names nil require nil nil default))))

(defun herdr-herd--read-entries (session &optional prompt)
  "Return the agent entries to act on, from the region or by completion.
Only the agents on SESSION are offered, since a herd reaches one server;
completion asks with PROMPT."
  (or (herdr-herd--region-entries session)
      (let* ((candidates (mapcar (lambda (entry)
                                   (cons (herdr--entry-label entry) entry))
                                 (herdr-herd-live-agents session)))
             (chosen (progn
                       (unless candidates
                         (user-error "The %s session runs no agent"
                                     (herdr-herd--session-label session)))
                       (completing-read-multiple
                        (or prompt (format "Agents (%s session): "
                                           (herdr-herd--session-label session)))
                        (mapcar #'car candidates) nil t))))
        (delq nil (mapcar (lambda (label) (cdr (assoc label candidates)))
                          chosen)))))

(defun herdr-herd--region-entries (session)
  "Return the agent entries of the rows the region covers, on SESSION."
  (when (and (use-region-p) (derived-mode-p 'herdr-status-mode))
    (let ((end (region-end))
          (label (herdr-herd--session-label session))
          (entries nil))
      (save-excursion
        (goto-char (region-beginning))
        (while (< (point) end)
          (when-let* ((entry (herdr-status-entry-at-point))
                      ((alist-get 'agent entry))
                      ((equal (herdr-herd--session-label
                               (alist-get 'session entry))
                              label))
                      ((not (member entry entries))))
            (push entry entries))
          (forward-line 1)))
      (nreverse entries))))

(defun herdr-herd--refresh ()
  "Redraw the dashboard when point is in one."
  (when (derived-mode-p 'herdr-status-mode)
    (herdr-status-refresh)))

;;;; Commands

;;;###autoload
(defun herdr-herd-add (entries herd)
  "Put ENTRIES in HERD and tell every member who is in it now.
HERD is the cons of a herdr session and a name.  An entry on another
session is refused: a herd reaches one server, so a member elsewhere
could neither be reached nor reach back."
  (interactive
   (let* ((herd (herdr-herd--read "Add to herd"))
          (at-point (herdr-herd--section-value 'herdr-status-agent)))
     (list (if at-point
               (list at-point)
             (herdr-herd--read-entries (car herd)))
           herd)))
  (unless (herdr-herd--valid-name-p (cdr herd))
    (user-error "A herd name carries no whitespace: %s" (cdr herd)))
  (let ((label (herdr-herd--session-label (car herd)))
        (joined nil))
    (dolist (entry entries)
      (cond
       ((null (alist-get 'pane_id entry))
        (message "herd %s: herdr reports no pane for %s, skipped"
                 (herdr-herd-label herd) (herdr--entry-label entry)))
       ((not (equal (herdr-herd--session-label (alist-get 'session entry)) label))
        (message "herd %s: %s runs on the %s session, skipped"
                 (herdr-herd-label herd) (herdr--entry-label entry)
                 (herdr-herd--session-label (alist-get 'session entry))))
       ((herdr-herd--same-p (herdr-herd-of-entry entry) herd)
        (message "herd %s: %s is already a member"
                 (herdr-herd-label herd) (herdr--entry-label entry)))
       (t (herdr-herd--put entry (cdr herd))
          (push (herdr-herd--with-membership entry (cdr herd)) joined))))
    (herdr-herd--refresh)
    (when joined
      (herdr-herd--welcome herd (nreverse joined)))))

;;;###autoload
(defun herdr-herd-enlist (session herd)
  "Put the agent SESSION is starting in HERD, and welcome it once it is ready.
SESSION is an agent session started without waiting, whose pane herdr
already reports.  Its tokens go on now, so the dashboard draws it in
HERD from the start; the roster waits for the agent to take a prompt."
  (let* ((entry `((session . ,(car herd))
                  (pane_id . ,(herdr-agent-session-pane session))
                  (agent . ,(herdr-agent-session-kind session))
                  (cwd . ,(herdr-agent-session-project session)))))
    (herdr-herd--put entry (cdr herd))
    (herdr-agent-when-ready
     session
     (lambda (_session)
       (when-let* ((joined (seq-find
                            (lambda (member)
                              (equal (alist-get 'pane_id member)
                                     (alist-get 'pane_id entry)))
                            (herdr-herd-member-entries herd))))
         (herdr-herd--welcome herd (list joined)))))))

;;;###autoload
(defun herdr-herd-add-many (entries herd)
  "Put several ENTRIES in HERD at once.
The rows the region covers are taken where there is one, and the agents
of HERD's session are offered for completion where there is not."
  (interactive
   (let ((herd (herdr-herd--read "Add to herd")))
     (list (herdr-herd--read-entries (car herd)) herd)))
  (herdr-herd-add entries herd))

;;;###autoload
(defun herdr-herd-remove (entry)
  "Take ENTRY's agent out of the herd it is in."
  (interactive (list (or (herdr-herd--section-value 'herdr-status-agent)
                         (user-error "No agent at point"))))
  (let ((herd (or (herdr-herd-of-entry entry)
                  (user-error "%s is in no herd" (herdr--entry-label entry)))))
    (herdr-herd--put entry nil)
    (herdr-herd--refresh)
    (message "herd %s: %s removed"
             (herdr-herd-label herd) (herdr--entry-label entry))
    (when-let* ((members (seq-remove (lambda (member)
                                       (herdr-herd--same-pane-p member entry))
                                     (herdr-herd-member-entries herd))))
      (herdr-herd--send herd members
                        (lambda (_member)
                          (herdr-herd-notice
                           herd (format "%s left." (herdr--entry-label entry))))
                        "told"))))

;;;###autoload
(defun herdr-herd-dissolve (herd)
  "Take every member out of HERD, leaving the agents running and named."
  (interactive (list (herdr-herd--read "Dissolve herd" t)))
  (let ((members (herdr-herd-member-entries herd)))
    (when (yes-or-no-p (format "Dissolve herd %s (%d member%s)? "
                               (herdr-herd-label herd) (length members)
                               (if (= 1 (length members)) "" "s")))
      (dolist (entry members)
        (herdr-herd--put entry nil))
      (herdr-herd--refresh)
      (message "herd %s dissolved" (herdr-herd-label herd)))))

;;;###autoload
(defun herdr-herd-announce (herd)
  "Send every live member of HERD the current roster."
  (interactive (list (herdr-herd--read "Announce herd" t)))
  (herdr-herd--announce herd))

;;;###autoload
(defun herdr-herd-broadcast (herd text)
  "Send TEXT to every live member of HERD."
  (interactive
   (let ((herd (herdr-herd--read "Broadcast to herd" t)))
     (list herd (read-string (format "Prompt herd %s: "
                                     (herdr-herd-label herd))))))
  (herdr-herd--send herd (herdr-herd-member-entries herd)
                    (lambda (_entry) text) "sent to")
  (herdr-herd--refresh))

(defun herdr-herd--dispatch-description ()
  "Return how many herds there are, for the menu heading."
  (let ((herds (herdr-herds)))
    (if herds
        (format "herds  ·  %d" (length herds))
      "herds  ·  none yet")))

;;;###autoload
(transient-define-prefix herdr-herd-dispatch ()
  "Manage the herds agents belong to."
  [:description herdr-herd--dispatch-description
                ["Membership"
                 ("a" "add agent at point" herdr-herd-add)
                 ("A" "add several" herdr-herd-add-many)
                 ("r" "remove agent at point" herdr-herd-remove)
                 ("d" "dissolve" herdr-herd-dissolve)]
                ["Tell"
                 ("b" "broadcast" herdr-herd-broadcast)
                 ("R" "re-announce roster" herdr-herd-announce)]])

(provide 'herdr-herd)
;;; herdr-herd.el ends here
