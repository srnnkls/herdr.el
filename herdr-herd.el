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
;; Membership lives in herdr, not in Emacs: a member's pane carries the
;; herd in its manual label, as `herd:NAME' ahead of whatever else the
;; label says.  Herdr persists that label across a restart and reports it
;; with the pane, so an agent joins or reads a herd with `herdr pane
;; rename' and `herdr pane list' and needs no editor running.  The label
;; is drawn only where a pane has no terminal title, which an agent pane
;; always has.

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

(defcustom herdr-herd-label-prefix "herd:"
  "What marks the herd a pane belongs to at the head of its label.
A pane label starting with this and a name puts that pane in that herd;
whatever follows the first space is the label's own text and survives
every herd command."
  :type 'string
  :group 'herdr-herd)

(defcustom herdr-herd-busy-states '("working" "blocked")
  "Agent states a herd will not prompt into.
A prompt sent to an agent in one of these interleaves with the turn it
is in the middle of."
  :type '(repeat string)
  :group 'herdr-herd)

(defcustom herdr-herd-name-stopwords
  '("a" "an" "and" "the" "for" "with" "from" "into" "of" "to" "in" "on"
    "feat" "feature" "fix" "chore" "refactor" "docs" "doc" "test" "tests"
    "wip" "branch" "branches" "change" "changes" "add" "adds" "update")
  "Words dropped from a terminal title before it becomes part of a name."
  :type '(repeat string)
  :group 'herdr-herd)

(defcustom herdr-herd-name-title-words 2
  "How many words of an agent's terminal title its derived name carries."
  :type 'natnum
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
You are part of a herd: a set of coding agents working in the same herdr
session, each in its own pane, that know each other by name.

Reach a peer by name with the herdr CLI:

    herdr agent prompt <name> \"<message>\"
    herdr agent read <name>          # what that peer's terminal shows
    herdr agent get <name>           # its state: idle, working, blocked, done

Membership is the pane's own label, so you can read and change it with
the same CLI:

    herdr pane list                  # a member's label starts with herd:<name>
    herdr pane rename <pane> \"herd:<name>\"   # join, or move to another herd
    herdr pane rename <pane> --clear          # leave every herd

`herdr --help' and `herdr --skill' are the authority for CLI syntax; do
not guess flags. Every control command needs HERDR_ENV=1 in this shell.

Messaging a peer interrupts it. Check `herdr agent get <name>' first and
prefer a peer that is idle or done; a peer that is working or blocked
will read your message in the middle of its own turn.

A peer name that no longer resolves means that agent exited or was
replaced. `herdr agent list' shows who is live. Do not invent names and
do not address a peer by pane id.

Say who you are when you write to a peer, keep messages short, and state
what you want back."
  "What a joining agent is told about being in a herd.
The live roster is appended to this when a member joins."
  :type 'string
  :group 'herdr-herd)

(defconst herdr-herd--name-limit 32
  "Longest agent name herdr accepts.")

;;;; The label a pane carries

(defun herdr-herd--split (label)
  "Return the herd LABEL names and what else it says, as a cons.
The car is nil for a label naming no herd, and the cdr is the label's
own text, which every herd command carries through untouched."
  (if (and (stringp label)
           (string-match (concat "\\`" (regexp-quote herdr-herd-label-prefix)
                                 "\\([^[:space:]]+\\)"
                                 "\\(?:[[:space:]]+\\(.*\\)\\)?\\'")
                         label))
      (cons (match-string 1 label) (match-string 2 label))
    (cons nil (and (stringp label) label))))

(defun herdr-herd--compose (herd rest)
  "Return the pane label putting a pane in HERD while it still says REST.
Nil for a pane that is in no herd and has nothing else to say, which is
what clears a label."
  (let ((parts (delq nil
                     (list (and herd (concat herdr-herd-label-prefix herd))
                           (and rest (not (string-empty-p rest)) rest)))))
    (and parts (string-join parts " "))))

(defun herdr-herd-of-entry (entry)
  "Return the name of the herd ENTRY's pane belongs to, or nil."
  (car (herdr-herd--split (alist-get 'pane_label entry))))

(defun herdr-herd--valid-name-p (name)
  "Return non-nil when NAME can head a pane label."
  (and (stringp name)
       (string-match-p "\\`[^[:space:]]+\\'" name)
       (not (string-prefix-p herdr-herd-label-prefix name))))

(defun herdr-herd--rename (entry label)
  "Give ENTRY's pane LABEL, clearing it when LABEL is nil."
  (herdr-with-session (alist-get 'session entry)
    (herdr-api-pane-rename (alist-get 'pane_id entry) :label label)))

(defun herdr-herd--put (entry herd)
  "Put ENTRY's pane in HERD, taking it out of every herd when HERD is nil."
  (let ((rest (cdr (herdr-herd--split (alist-get 'pane_label entry)))))
    (herdr-herd--rename entry (herdr-herd--compose herd rest))))

;;;; Reading the herds

(defun herdr-herd--entry-session (entry)
  "Return the session id herdr reports for ENTRY, or nil."
  (alist-get 'value (alist-get 'agent_session entry)))

(defun herdr-herd-live-agents ()
  "Return every live agent entry herdr reports a session for."
  (seq-filter #'herdr-herd--entry-session (herdr-sessions)))

(defun herdr-herds (&optional agents)
  "Return every herd as an alist of name to the entries in it.
AGENTS are the entries to read, the live ones by default.  Herds come
out in name order and members in the order herdr reports them."
  (let (herds)
    (dolist (entry (or agents (herdr-herd-live-agents)))
      (when-let* ((name (herdr-herd-of-entry entry)))
        (let ((cell (assoc name herds)))
          (if cell
              (setcdr cell (cons entry (cdr cell)))
            (push (cons name (list entry)) herds)))))
    (mapcar (lambda (herd) (cons (car herd) (nreverse (cdr herd))))
            (sort herds (lambda (a b) (string< (car a) (car b)))))))

(defun herdr-herd-names ()
  "Return the name of every herd that has a live member."
  (mapcar #'car (herdr-herds)))

(defun herdr-herd-member-entries (name &optional agents)
  "Return the live agent entries of the herd called NAME.
AGENTS are the entries to read, the live ones by default."
  (cdr (assoc name (herdr-herds agents))))

;;;; Deriving a name

(defun herdr-herd--slug (string)
  "Return STRING as lowercase words joined by hyphens, or nil when empty."
  (when (stringp string)
    (let ((slug (string-trim
                 (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase string))
                 "-+" "-+")))
      (unless (string-empty-p slug) slug))))

(defun herdr-herd--repository (directory)
  "Return the directory holding DIRECTORY's shared git directory, or nil."
  (when (and directory (file-directory-p directory))
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory)))
        (when (eq 0 (ignore-errors
                      (process-file "git" nil '(t nil) nil "rev-parse"
                                    "--path-format=absolute"
                                    "--git-common-dir")))
          (let ((git-dir (string-trim (buffer-string))))
            (unless (string-empty-p git-dir)
              (file-name-directory (directory-file-name git-dir)))))))))

(defun herdr-herd--project-slug (directory)
  "Return the slug of the repository DIRECTORY belongs to, or nil.
A linked worktree answers with the repository it was cut from rather than
with its own directory name."
  (when directory
    (if (herdr--same-directory-p directory "~")
        "home"
      (herdr-herd--slug
       (file-name-nondirectory
        (directory-file-name (or (herdr-herd--repository directory)
                                 directory)))))))

(defun herdr-herd--tail (title head)
  "Return the words of TITLE that follow HEAD in a name, or nil."
  (when-let* ((slug (herdr-herd--slug title)))
    (let ((room (- herdr-herd--name-limit (length head) 1))
          (seen (split-string head "-" t))
          (taken nil)
          (used 0))
      (catch 'full
        (dolist (word (split-string slug "-" t))
          (when (>= (length taken) herdr-herd-name-title-words)
            (throw 'full nil))
          (unless (or (member word herdr-herd-name-stopwords)
                      (member word seen)
                      (member word taken))
            (let ((cost (+ (length word) (if taken 1 0))))
              (when (> (+ used cost) room)
                (throw 'full nil))
              (push word taken)
              (setq used (+ used cost))))))
      (when taken (string-join (nreverse taken) "-")))))

(defun herdr-herd--lead (slug)
  "Return SLUG starting with a letter, as herdr requires."
  (if (string-match-p "\\`[a-z]" slug) slug (concat "a" slug)))

(defun herdr-herd-derive-name (entry)
  "Return an unused herdr agent name derived from ENTRY."
  (let* ((head (herdr-herd--lead
                (or (herdr-herd--project-slug (alist-get 'cwd entry))
                    (herdr-herd--slug (alist-get 'agent entry))
                    "agent")))
         (head (string-trim (substring head 0 (min (length head)
                                                   herdr-herd--name-limit))
                            "-+" "-+"))
         (tail (herdr-herd--tail (alist-get 'terminal_title_stripped entry)
                                 head)))
    (herdr-agent--available-name (if tail (concat head "-" tail) head)
                                 (herdr--entry-server entry))))

;;;; Joining

(defun herdr-herd--name (entry)
  "Return the name ENTRY's agent carries, naming it where it has none.
An agent that already has a name keeps it."
  (or (alist-get 'name entry)
      (let ((name (read-string "Agent name: " (herdr-herd-derive-name entry))))
        (herdr-agent-rename (herdr--entry-target entry) name)
        name)))

(defun herdr-herd--roster-line (entry)
  "Return ENTRY as one line of a roster."
  (format "  %-24s %-8s %s"
          (or (alist-get 'name entry) (herdr--entry-label entry))
          (or (alist-get 'agent entry) "?")
          (or (alist-get 'cwd entry) "")))

(defun herdr-herd--helper ()
  "Return what to tell a joining agent about the `herdr-herd' helper, or nil."
  (when-let* ((script (if (functionp herdr-herd-command)
                          (funcall herdr-herd-command)
                        herdr-herd-command)))
    (concat "\
A helper wrapping those commands is at

    " script "

    herdr-herd list                  # every herd and who is in it
    herdr-herd peers                 # your herd's other members
    herdr-herd of                    # the herd you are in
    herdr-herd join <herd>           # join, keeping the rest of your label
    herdr-herd leave                 # leave the herd you are in
    herdr-herd say <message>         # send it to every idle peer
    herdr-herd tell <name> <message> # send it to one peer

It defaults every pane to your own, so it needs no arguments to talk
about you. It is a convenience over the commands above and nothing more,
so use those directly whenever you prefer.")))

(defun herdr-herd--roster (herd self members)
  "Return the prompt telling SELF it is in HERD alongside MEMBERS."
  (let ((peers (seq-remove (lambda (entry)
                             (equal (alist-get 'name entry) self))
                           members)))
    (concat "/herd " herd " — you are " self "\n\n"
            herdr-herd-protocol "\n\n"
            (when-let* ((helper (herdr-herd--helper)))
              (concat helper "\n\n"))
            (if peers
                (concat "Your peers in herd " herd ":\n"
                        (string-join (mapcar #'herdr-herd--roster-line peers)
                                     "\n"))
              (concat "You are the only member of herd " herd " so far."))
            "\n")))

(defun herdr-herd--busy-p (entry)
  "Return non-nil when ENTRY's agent should not be prompted right now."
  (member (alist-get 'agent_status entry) herdr-herd-busy-states))

(defun herdr-herd--report (herd sent skipped verb)
  "Say that VERB reached SENT members of HERD and SKIPPED the rest."
  (if skipped
      (message "herd %s: %s %d, skipped %s" herd verb sent
               (string-join (mapcar (lambda (skip)
                                      (format "%s (%s)" (car skip) (cdr skip)))
                                    skipped)
                            ", "))
    (message "herd %s: %s %d member%s" herd verb sent
             (if (= 1 sent) "" "s")))
  skipped)

(defun herdr-herd--send (herd members text-function verb)
  "Send every idle member of HERD what TEXT-FUNCTION makes of it.
MEMBERS are the entries to reach.  VERB heads the report."
  (let ((sent 0)
        (skipped nil))
    (dolist (entry members)
      (if (herdr-herd--busy-p entry)
          (push (cons (or (alist-get 'name entry) (herdr--entry-label entry))
                      (alist-get 'agent_status entry))
                skipped)
        (herdr-agent-prompt (herdr--entry-target entry)
                            (funcall text-function entry))
        (setq sent (1+ sent))))
    (herdr-herd--report herd sent (nreverse skipped) verb)))

(defun herdr-herd--announce (herd)
  "Send every live member of HERD the current roster."
  (let ((members (herdr-herd-member-entries herd)))
    (herdr-herd--send
     herd members
     (lambda (entry)
       (herdr-herd--roster herd (alist-get 'name entry) members))
     "told")))

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
  "Return the name of the herd the section at point belongs to, or nil."
  (or (herdr-herd--section-value 'herdr-status-herd)
      (when-let* ((entry (herdr-herd--section-value 'herdr-status-agent)))
        (herdr-herd-of-entry entry))))

(defun herdr-herd--read-name (prompt &optional require)
  "Read a herd name with PROMPT, defaulting to the one at point.
REQUIRE non-nil refuses a name no herd carries."
  (let ((names (herdr-herd-names)))
    (when (and require (null names))
      (user-error "No herd has a live member"))
    (completing-read prompt names nil require nil nil (herdr-herd-at-point))))

(defun herdr-herd--entry-at-point ()
  "Return the agent entry the dashboard row at point stands for."
  (or (herdr-herd--section-value 'herdr-status-agent)
      (user-error "No agent at point")))

(defun herdr-herd--refresh ()
  "Redraw the dashboard when point is in one."
  (when (derived-mode-p 'herdr-status-mode)
    (herdr-status-refresh)))

;;;; Commands

;;;###autoload
(defun herdr-herd-add (entries herd)
  "Put ENTRIES in HERD and tell every member who is in it now."
  (interactive
   (list (list (herdr-herd--entry-at-point))
         (herdr-herd--read-name "Add to herd: ")))
  (unless (herdr-herd--valid-name-p herd)
    (user-error "A herd name carries no whitespace: %s" herd))
  (dolist (entry entries)
    (cond
     ((null (alist-get 'pane_id entry))
      (message "herd %s: herdr reports no pane for %s, skipped"
               herd (herdr--entry-label entry)))
     ((equal (herdr-herd-of-entry entry) herd)
      (message "herd %s: %s is already a member"
               herd (herdr--entry-label entry)))
     (t (herdr-herd--name entry)
        (herdr-herd--put entry herd))))
  (herdr-herd--refresh)
  (herdr-herd--announce herd))

;;;###autoload
(defun herdr-herd-add-many (entries herd)
  "Put several ENTRIES in HERD at once.
The rows the region covers are taken where there is one, and the live
agents are offered for completion where there is not."
  (interactive
   (list (herdr-herd--read-entries)
         (herdr-herd--read-name "Add to herd: ")))
  (herdr-herd-add entries herd))

(defun herdr-herd--region-entries ()
  "Return the agent entries of the dashboard rows the region covers."
  (when (and (use-region-p) (derived-mode-p 'herdr-status-mode))
    (let ((end (region-end))
          (entries nil))
      (save-excursion
        (goto-char (region-beginning))
        (while (< (point) end)
          (when-let* ((entry (herdr-status-entry-at-point))
                      ((alist-get 'agent entry))
                      ((not (member entry entries))))
            (push entry entries))
          (forward-line 1)))
      (nreverse entries))))

(defun herdr-herd--read-entries ()
  "Return the agent entries to act on, from the region or by completion."
  (or (herdr-herd--region-entries)
      (let* ((candidates (mapcar (lambda (entry)
                                   (cons (herdr--entry-label entry) entry))
                                 (herdr-herd-live-agents)))
             (chosen (completing-read-multiple
                      "Agents: " (mapcar #'car candidates) nil t)))
        (delq nil (mapcar (lambda (label) (cdr (assoc label candidates)))
                          chosen)))))

;;;###autoload
(defun herdr-herd-remove (entry)
  "Take ENTRY's agent out of the herd it is in."
  (interactive (list (herdr-herd--entry-at-point)))
  (let ((herd (or (herdr-herd-of-entry entry)
                  (user-error "%s is in no herd" (herdr--entry-label entry)))))
    (herdr-herd--put entry nil)
    (herdr-herd--refresh)
    (message "herd %s: %s removed" herd (herdr--entry-label entry))
    (when (herdr-herd-member-entries herd)
      (herdr-herd--announce herd))))

;;;###autoload
(defun herdr-herd-dissolve (herd)
  "Take every member out of HERD, leaving the agents running and named."
  (interactive (list (herdr-herd--read-name "Dissolve herd: " t)))
  (let ((members (herdr-herd-member-entries herd)))
    (when (yes-or-no-p (format "Dissolve herd %s (%d member%s)? "
                               herd (length members)
                               (if (= 1 (length members)) "" "s")))
      (dolist (entry members)
        (herdr-herd--put entry nil))
      (herdr-herd--refresh)
      (message "herd %s dissolved" herd))))

;;;###autoload
(defun herdr-herd-announce (herd)
  "Send every live member of HERD the current roster."
  (interactive (list (herdr-herd--read-name "Announce herd: " t)))
  (herdr-herd--announce herd))

;;;###autoload
(defun herdr-herd-broadcast (herd text)
  "Send TEXT to every live member of HERD."
  (interactive
   (let ((herd (herdr-herd--read-name "Broadcast to herd: " t)))
     (list herd (read-string (format "Prompt herd %s: " herd)))))
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
