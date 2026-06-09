;;; test-heading-scenarios.el --- Dry-run heading rendering scenarios -*- lexical-binding: t; -*-

;;; Commentary:
;; Batch scenarios for OSC 66 heading rendering.  A stubbed screen-position
;; function simulates terminal rows (including the after-string reservation
;; rows of scaled headings and org folds), and a captured terminal-send
;; records every escape emission so the tests can assert exact coordinates,
;; widths, and erase/place pairing across simulated folds.

;;; Code:

(require 'cl-lib)
(require 'org)

(defvar kgfx-scn--sent nil
  "Escape strings captured from `kitty-gfx--terminal-send', oldest first.")

(defun kgfx-scn--capture (str)
  "Record STR instead of sending it to a terminal."
  (setq kgfx-scn--sent (append kgfx-scn--sent (list str))))

(defun kgfx-scn--screen-pos (ov &optional _win)
  "Simulated terminal (ROW . COL) for heading overlay OV.
Counts visible buffer lines from `point-min', adding the reservation
rows of scaled headings whose fold ellipsis is not active, mirroring
how a real terminal frame lays out the after-string lines."
  (let ((buf (overlay-buffer ov))
        (pos (overlay-start ov)))
    (with-current-buffer buf
      (unless (kitty-gfx--in-folded-region-p pos)
        (let ((row 1))
          (save-excursion
            (goto-char (point-min))
            (while (< (point) pos)
              (let ((bol (point))
                    (eol (line-end-position)))
                (unless (kitty-gfx--in-folded-region-p bol)
                  (setq row (1+ row))
                  (dolist (o (overlays-in bol (min (1+ eol) (point-max))))
                    (when (and (overlay-get o 'kitty-gfx-heading)
                               (overlay-get o 'after-string)
                               (not (kitty-gfx--in-folded-region-p eol)))
                      (setq row (+ row (1- (overlay-get o 'kitty-gfx-heading-cell-s))))))))
              (forward-line 1)))
          (cons row (1+ (save-excursion (goto-char pos) (current-column)))))))))

(defun kgfx-scn--refresh-cycle ()
  "Run heading refresh phases 1 and 2 against the selected window."
  (let ((win (selected-window)))
    (dolist (ov kitty-gfx--overlays)
      (when (overlay-get ov 'kitty-gfx-heading)
        (kitty-gfx--refresh-heading-overlay ov win 999)))
    (setq kitty-gfx--heading-flush-needed nil)
    (kitty-gfx--emit-heading-overlays (frame-terminal))))

(defun kgfx-scn--parse (str)
  "Parse captured escape STR into (KIND ROW COL PAYLOAD-OR-WIDTH), or nil."
  (cond
   ((string-match "\\`\e7\e\\[\\?7l\e\\[\\([0-9]+\\);\\([0-9]+\\)H\e\\[\\([0-9]+\\)X" str)
    (list 'erase
          (string-to-number (match-string 1 str))
          (string-to-number (match-string 2 str))
          (string-to-number (match-string 3 str))))
   ((string-match "\\`\e7\e\\[\\([0-9]+\\);\\([0-9]+\\)H.*\e\\]66;\\([^;]+\\);\\(.*\\)\a" str)
    (list 'place
          (string-to-number (match-string 1 str))
          (string-to-number (match-string 2 str))
          (match-string 4 str)))))

(defun kgfx-scn--events ()
  "Return parsed erase/place events from the capture, oldest first."
  (delq nil (mapcar #'kgfx-scn--parse kgfx-scn--sent)))

(defun kgfx-scn--places (events)
  "Return the place events from EVENTS, sorted by row."
  (sort (cl-remove-if-not (lambda (e) (eq (car e) 'place)) events)
        (lambda (a b) (< (nth 1 a) (nth 1 b)))))

(defun kgfx-scn--assert-erases-paired (events)
  "Assert every erase in EVENTS is the pre-erase of the following place.
The erase must share the place's row and column, and its width must
equal the placed block's scaled width."
  (while events
    (let ((ev (pop events)))
      (when (eq (car ev) 'erase)
        (let ((next (car events)))
          (cl-assert (and next (eq (car next) 'place))
                     nil "erase not followed by a place: %S" ev)
          (cl-assert (and (= (nth 1 ev) (nth 1 next))
                          (= (nth 2 ev) (nth 2 next)))
                     nil "erase %S not at its place position %S" ev next)
          (cl-assert (= (nth 3 ev) (* 2 (string-width (nth 3 next))))
                     nil "erase width %d != block width of %S" (nth 3 ev) next))))))

(defun kgfx-scn--heading-overlay (text)
  "Return the heading overlay whose heading text is TEXT."
  (cl-find-if (lambda (ov)
                (and (overlay-get ov 'kitty-gfx-heading)
                     (equal (overlay-get ov 'kitty-gfx-heading-text) text)))
              kitty-gfx--overlays))

(defun kgfx-scn-run ()
  "Run all heading rendering scenarios; signal on any failure."
  (cl-letf (((symbol-function 'kitty-gfx--terminal-send) #'kgfx-scn--capture)
            ((symbol-function 'kitty-gfx--overlay-screen-pos) #'kgfx-scn--screen-pos))
    (with-current-buffer (get-buffer-create "kgfx-scenario.org")
      (org-mode)
      (insert "* Test inline images\n"
              "Some body text\n"
              "** Inline images\n"
              "More text\n"
              "* Another section\n"
              "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n"
              "Line 6\nLine 7\nLine 8\nLine 9\nLine 10\n"
              "* LaTeX fragment preview test\n"
              "End of test file.\n")
      (set-window-buffer (selected-window) (current-buffer))
      (kitty-gfx--org-apply-heading-sizes)
      (setq kgfx-scn--sent nil)
      (kgfx-scn--refresh-cycle)
      (let* ((events (kgfx-scn--events))
             (places (kgfx-scn--places events)))
        (kgfx-scn--assert-erases-paired events)
        (cl-assert (equal (mapcar (lambda (p) (nth 3 p)) places)
                          '("Test inline images" "Inline images"
                            "Another section" "LaTeX fragment preview test"))
                   nil "unexpected initial placements: %S" places)
        (cl-assert (cl-every (lambda (p) (= (nth 2 p) 1)) places)
                   nil "heading with hidden stars must place at column 1: %S" places)
        (cl-assert (equal (mapcar (lambda (p) (nth 1 p)) places)
                          '(1 4 7 19))
                   nil "rows must account for reservation lines: %S" places)
        (dolist (p places)
          (let ((ov (kgfx-scn--heading-overlay (nth 3 p))))
            (cl-assert (equal (overlay-get ov 'display)
                              (make-string (overlay-get ov 'kitty-gfx-cols) ?\s))
                       nil "reservation must equal block width for %S" (nth 3 p)))))
      (goto-char (point-min))
      (search-forward "* Another section")
      (goto-char (line-beginning-position))
      (org-cycle)
      (kitty-gfx--on-org-cycle)
      (setq kgfx-scn--sent nil)
      (kgfx-scn--refresh-cycle)
      (let* ((events (kgfx-scn--events))
             (places (kgfx-scn--places events))
             (folded-ov (kgfx-scn--heading-overlay "Another section")))
        (kgfx-scn--assert-erases-paired events)
        (cl-assert (equal (mapcar (lambda (p) (nth 3 p)) places)
                          '("LaTeX fragment preview test"))
                   nil "only the moved heading should re-place: %S" places)
        (cl-assert (= (nth 1 (car places)) 8)
                   nil "moved heading must land at post-fold row 8: %S" places)
        (cl-assert (not (cl-find 19 events :key (lambda (e) (nth 1 e))))
                   nil "no escape may target the stale pre-fold row 19: %S" events)
        (cl-assert (equal (overlay-get folded-ov 'display) "Another section")
                   nil "collapsed heading must fall back to plain text")
        (cl-assert (null (overlay-get folded-ov 'kitty-gfx-last-row))
                   nil "collapsed heading must drop its cached position"))
      (goto-char (point-min))
      (search-forward "* Another section")
      (goto-char (line-beginning-position))
      (org-fold-show-subtree)
      (kitty-gfx--on-org-cycle)
      (setq kgfx-scn--sent nil)
      (kgfx-scn--refresh-cycle)
      (let* ((events (kgfx-scn--events))
             (places (kgfx-scn--places events)))
        (kgfx-scn--assert-erases-paired events)
        (cl-assert (equal (mapcar (lambda (p) (list (nth 1 p) (nth 3 p))) places)
                          '((7 "Another section") (19 "LaTeX fragment preview test")))
                   nil "unfold must re-place at restored rows: %S" places))
      (kill-buffer))
    (with-current-buffer (get-buffer-create "kgfx-scenario-wide.org")
      (org-mode)
      (insert "* " (make-string 60 ?w) "\nBody\n")
      (set-window-buffer (selected-window) (current-buffer))
      (kitty-gfx--org-apply-heading-sizes)
      (setq kgfx-scn--sent nil)
      (kgfx-scn--refresh-cycle)
      (let* ((events (kgfx-scn--events))
             (places (kgfx-scn--places events))
             (limit (1- (frame-width)))
             (ov (car kitty-gfx--overlays)))
        (kgfx-scn--assert-erases-paired events)
        (cl-assert (= (length places) 1) nil "wide heading must place once")
        (cl-assert (<= (* 2 (string-width (nth 3 (car places)))) limit)
                   nil "payload must be truncated to fit the window")
        (cl-assert (<= (length (overlay-get ov 'display)) limit)
                   nil "reservation must clamp to window width")
        (cl-assert (equal (overlay-get ov 'display)
                          (make-string (overlay-get ov 'kitty-gfx-cols) ?\s))
                   nil "clamped reservation must still equal block width")
        (cl-assert (cl-every (lambda (line) (<= (length line) limit))
                             (split-string (or (overlay-get ov 'after-string) "")
                                           "\n" t))
                   nil "after-string lines must clamp to window width"))
      (kill-buffer)))
  (message "kitty-gfx: heading scenarios passed"))

(when noninteractive
  (kgfx-scn-run))

(provide 'test-heading-scenarios)
;;; test-heading-scenarios.el ends here
