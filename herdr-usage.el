;;; herdr-usage.el --- What an agent runs on and how much of it it holds -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Sören Nikolaus

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; An agent's usage is the model it answers with, the effort it answers
;; at, and how much of its context window it holds.  A pane reports these
;; as metadata tokens through herdr; a package that hears the agent more
;; closely answers ahead of them on `herdr-usage-functions'.  Whatever
;; draws an agent reads `herdr-usage', so every reader shows one answer.
;;
;; The context travels as a figure such as "136k/200k", which this file
;; both writes and reads.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom herdr-usage-model-token "model"
  "Metadata token naming the model an agent is currently answering with.
Herdr carries whatever a pane reports of itself, so the model arrives
the way any other self-reported field does."
  :type 'string
  :group 'herdr)

(defcustom herdr-usage-effort-token "effort"
  "Metadata token naming the reasoning effort an agent answers at.
A pane that reports no such token but writes its effort after the
model, as in \"Opus 5.5/high\", has it read from there instead."
  :type 'string
  :group 'herdr)

(defcustom herdr-usage-effort-levels '("low" "medium" "high" "xhigh" "max")
  "Effort levels a reported model may end in after a slash.
Only these are split off the model, so a model named by provider and
name, as in \"anthropic/claude\", stays whole."
  :type '(repeat string)
  :group 'herdr)

(defcustom herdr-usage-context-token "context"
  "Metadata token naming how much of its context window an agent holds.
The token carries a figure as `herdr-usage-figure' writes one."
  :type 'string
  :group 'herdr)

(defvar herdr-usage-functions nil
  "Functions answering what an agent runs on, ahead of what its pane reports.
Each receives an agent entry and returns nil or an alist of any of
`model' and `effort', strings, and `context', a cons of the tokens held
and the window they count against.  For each key the first function to
answer wins, and a key none answers is read from the pane's metadata
tokens.  The functions run for every row a dashboard draws, so each
should answer from what it holds.")

(defconst herdr-usage--scales '(("k" . 1000) ("M" . 1000000))
  "What a figure's suffix multiplies it by.")

(defun herdr-usage-count (tokens)
  "Return TOKENS as a count short enough for a column, as \"136k\" or \"1M\"."
  (cond
   ((>= tokens 1000000)
    (let ((millions (/ tokens 1000000.0)))
      (if (< (abs (- millions (round millions))) 0.05)
          (format "%dM" (round millions))
        (format "%.1fM" millions))))
   ((>= tokens 1000) (format "%dk" (round (/ tokens 1000.0))))
   (t (number-to-string tokens))))

(defun herdr-usage-figure (context)
  "Return CONTEXT, tokens held consed onto the window, as a figure."
  (format "%s/%s" (herdr-usage-count (car context)) (herdr-usage-count (cdr context))))

(defun herdr-usage--count-tokens (count)
  "Return the tokens COUNT, as `herdr-usage-count' writes one, stands for."
  (when (and count (string-match "\\`\\([0-9.]+\\)\\([kM]\\)?\\'" count))
    (round (* (string-to-number (match-string 1 count))
              (or (cdr (assoc (match-string 2 count) herdr-usage--scales)) 1)))))

(defun herdr-usage-parse (figure)
  "Return the tokens held and the window FIGURE names, as a cons, or nil."
  (when-let* (((stringp figure))
              (counts (split-string figure "/"))
              ((= (length counts) 2))
              (held (herdr-usage--count-tokens (car counts)))
              (window (herdr-usage--count-tokens (cadr counts)))
              ((> window 0)))
    (cons held window)))

(defun herdr-usage-share (context)
  "Return the fraction of its window CONTEXT holds, or nil."
  (when (and (consp context) (numberp (car context))
             (numberp (cdr context)) (> (cdr context) 0))
    (/ (float (car context)) (cdr context))))

(defun herdr-usage--token (entry token)
  "Return the non-empty string ENTRY reports under TOKEN, or nil."
  (when-let* ((value (alist-get (intern token) (alist-get 'tokens entry)))
              ((stringp value))
              ((not (string-empty-p value))))
    value))

(defun herdr-usage-reported (entry)
  "Return the usage ENTRY's pane reports in its metadata tokens.
The alist is shaped as `herdr-usage-functions' answer one."
  (let ((model (herdr-usage--token entry herdr-usage-model-token))
        (effort (herdr-usage--token entry herdr-usage-effort-token))
        (context (herdr-usage-parse
                  (herdr-usage--token entry herdr-usage-context-token))))
    (when (and model
               (string-match "\\`\\(.+\\)/\\([^/]+\\)\\'" model)
               (member (match-string 2 model) herdr-usage-effort-levels))
      (setq effort (or effort (match-string 2 model))
            model (match-string 1 model)))
    (delq nil (list (and model (cons 'model model))
                    (and effort (cons 'effort effort))
                    (and context (cons 'context context))))))

(defun herdr-usage (entry)
  "Return the model, effort and context ENTRY runs on, as an alist.
`herdr-usage-functions' answer first, and the pane's metadata tokens
stand in for a key none of them answers.  A key nothing answers is
left out."
  (let (usage)
    (cl-flet ((take (answer)
                (dolist (cell answer)
                  (when (and (consp cell) (cdr cell) (not (assq (car cell) usage)))
                    (push cell usage)))))
      (run-hook-wrapped 'herdr-usage-functions
                        (lambda (function)
                          (take (funcall function entry))
                          nil))
      (take (herdr-usage-reported entry)))
    (nreverse usage)))

(provide 'herdr-usage)
;;; herdr-usage.el ends here
