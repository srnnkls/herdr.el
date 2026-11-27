;;; herdr-usage-tests.el --- Agent usage tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'herdr-usage)

(ert-deftest herdr-usage-writes-a-figure-short-enough-for-a-column ()
  (should (equal (herdr-usage-figure '(135600 . 200000)) "136k/200k"))
  (should (equal (herdr-usage-figure '(1000 . 1000000)) "1k/1M"))
  (should (equal (herdr-usage-figure '(1240000 . 1000000)) "1.2M/1M"))
  (should (equal (herdr-usage-figure '(940 . 200000)) "940/200k"))
  (should (equal (herdr-usage-count 258400) "258k")))

(ert-deftest herdr-usage-reads-back-the-figure-it-writes ()
  (should (equal (herdr-usage-parse "136k/200k") '(136000 . 200000)))
  (should (equal (herdr-usage-parse "1.2M/1M") '(1200000 . 1000000)))
  (should (equal (herdr-usage-parse "940/200k") '(940 . 200000)))
  (should-not (herdr-usage-parse "half full"))
  (should-not (herdr-usage-parse "1k/0"))
  (should-not (herdr-usage-parse "1k/2k/3k"))
  (should-not (herdr-usage-parse nil)))

(ert-deftest herdr-usage-shares-a-window ()
  (should (= (herdr-usage-share '(50000 . 200000)) 0.25))
  (should-not (herdr-usage-share '(1 . 0)))
  (should-not (herdr-usage-share nil)))

(ert-deftest herdr-usage-reads-what-a-pane-reports ()
  (should (equal (herdr-usage-reported
                  '((tokens . ((model . "Opus 5.5/xhigh") (context . "136k/200k")))))
                 '((model . "Opus 5.5") (effort . "xhigh")
                   (context . (136000 . 200000)))))
  (should (equal (herdr-usage-reported
                  '((tokens . ((model . "Opus 5.5/xhigh") (effort . "low")))))
                 '((model . "Opus 5.5") (effort . "low"))))
  (should (equal (herdr-usage-reported
                  '((tokens . ((model . "anthropic/claude-sonnet")))))
                 '((model . "anthropic/claude-sonnet"))))
  (should-not (herdr-usage-reported '((tokens . ((model . "") (context . ""))))))
  (should-not (herdr-usage-reported '((pane_id . "%1"))))
  (let ((herdr-usage-context-token "held"))
    (should (equal (herdr-usage-reported '((tokens . ((held . "1k/1M")))))
                   '((context . (1000 . 1000000)))))))

(ert-deftest herdr-usage-takes-each-key-from-the-first-function-answering-it ()
  (let ((entry '((pane_id . "%1")
                 (tokens . ((model . "Opus 5.5/high") (context . "201k/200k")))))
        (herdr-usage-functions
         (list (lambda (_) '((context . (201000 . 1000000)) (model)))
               (lambda (_) '((context . (1 . 2)) (effort . "max"))))))
    (should (equal (herdr-usage entry)
                   '((context . (201000 . 1000000))
                     (effort . "max")
                     (model . "Opus 5.5"))))))

(ert-deftest herdr-usage-falls-back-to-the-pane-when-nothing-answers ()
  (let ((herdr-usage-functions (list #'ignore)))
    (should (equal (herdr-usage '((tokens . ((context . "48k/258k")))))
                   '((context . (48000 . 258000)))))
    (should-not (herdr-usage '((pane_id . "%1"))))))

(provide 'herdr-usage-tests)
;;; herdr-usage-tests.el ends here
