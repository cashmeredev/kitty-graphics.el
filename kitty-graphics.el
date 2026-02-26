;;; kitty-graphics.el --- Display images in terminal Emacs via Kitty graphics protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026
;;
;; Author: cashmere
;; Version: 0.2.0
;; URL: https://git.cashmere.rs/kitty-graphics.git
;; Keywords: terminals, images, multimedia
;; Package-Requires: ((emacs "27.1"))

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;;; Commentary:
;;
;; Display images in terminal Emacs (emacs -nw) using the Kitty graphics
;; protocol with direct placements.
;;
;; Architecture: image data is transmitted once via `a=t' (stored in the
;; terminal without display).  Overlays reserve blank space in Emacs
;; buffers.  After each redisplay, direct placements (`a=p' with cursor
;; positioning) are emitted via `send-string-to-terminal' at the correct
;; screen positions.  Each placement uses a unique placement ID (`p=PID')
;; so repeated placements replace rather than accumulate.
;;
;; Requires: Kitty >= 0.20.0 (direct placement support).
;; Important: Launch Emacs with TERM=xterm-256color for proper color support.
;;
;; Usage:
;;   (require 'kitty-graphics)
;;   (kitty-graphics-mode 1)
;;   ;; Then org-mode C-c C-x C-v, image-mode, eww images all work.

;;; Code:

(require 'cl-lib)

;; Forward declarations for optional dependencies
(declare-function org-element-context "org-element" ())
(declare-function org-element-type "org-element" (element))
(declare-function org-element-property "org-element" (property element))
(declare-function org-attach-dir "org-attach" (&optional create-if-not-exists-p))
(declare-function org-link-preview "org" (&optional arg beg end))
(declare-function org-link-preview-region "org" (&optional include-linked refresh beg end))
(declare-function org-fold-folded-p "org-fold" (&optional pos spec-or-alias))
(declare-function org--latex-preview-region "org" (beg end))
(declare-function org-clear-latex-preview "org" (&optional beg end))
(declare-function org--make-preview-overlay "org" (beg end movefile imagetype))
(declare-function doc-view-mode-p "doc-view" ())
(declare-function doc-view-goto-page "doc-view" (page))
(declare-function doc-view-insert-image "doc-view" (file &rest args))
(declare-function doc-view-enlarge "doc-view" (factor))
(declare-function doc-view-scale-reset "doc-view" ())
(defvar doc-view--current-cache-dir)
(defvar doc-view--image-file-pattern)
(declare-function dired-get-file-for-visit "dired" ())
(declare-function image-mode-setup-winprops "image-mode" ())
(declare-function shr-rescale-image "shr" (data &optional content-type width height max-width max-height))
(defvar org-image-actual-width)
(defvar org-preview-latex-image-directory)
(defvar org-format-latex-options)
(declare-function org-combine-plists "org-macs" (&rest plists))
(defvar image-mode-map)

;;;; Customization

(defgroup kitty-graphics nil
  "Display images in terminal Emacs via Kitty graphics."
  :group 'multimedia
  :prefix "kitty-gfx-")

(defcustom kitty-gfx-max-width 120
  "Maximum image width in terminal columns for inline images.
For full-window modes like doc-view, the window size is used instead."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-max-height 40
  "Maximum image height in terminal rows for inline images.
For full-window modes like doc-view, the window size is used instead."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-chunk-size 4096
  "Maximum base64 chunk size for image transfer."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-render-delay 0.016
  "Delay in seconds before re-rendering images after redisplay.
This debounces rapid redisplay events.  Default is ~1 frame at 60fps."
  :type 'number
  :group 'kitty-graphics)

(defcustom kitty-gfx-debug nil
  "When non-nil, log debug info to *kitty-gfx-debug* buffer."
  :type 'boolean
  :group 'kitty-graphics)

(defvar kitty-gfx--log-file "/tmp/kitty-gfx.log"
  "File path for debug log output.")

(defun kitty-gfx--log (fmt &rest args)
  "Log to `kitty-gfx--log-file' when `kitty-gfx-debug' is non-nil."
  (when kitty-gfx-debug
    (let ((msg (concat (format-time-string "%H:%M:%S ") (apply #'format fmt args) "\n")))
      (append-to-file msg nil kitty-gfx--log-file))))

;;;; Constants — kept for reference if switching back to Unicode placeholders
;; (defconst kitty-gfx--placeholder-char #x10EEEE)
;; (defconst kitty-gfx--diacritics [...])

;;;; Internal state

;; Forward declaration — defined by `define-minor-mode' below.
(defvar kitty-graphics-mode)

(defvar kitty-gfx--next-id 1
  "Next image ID to assign (1-4294967295).
With direct placements, any uint32 ID works — no 256-color constraint.")

(defvar kitty-gfx--image-cache (make-hash-table :test 'equal)
  "Maps file paths to (image-id . (cols . rows)).")

(defvar-local kitty-gfx--overlays nil
  "Image overlays in this buffer.")

(defvar kitty-gfx--render-timer nil
  "Timer for deferred re-rendering.")

(defvar kitty-gfx--cell-pixel-width nil
  "Terminal cell width in pixels (queried on startup).")

(defvar kitty-gfx--cell-pixel-height nil
  "Terminal cell height in pixels (queried on startup).")

;; kitty-gfx--placeholder-width removed — direct placements don't use placeholders

(defvar kitty-gfx--next-placement-id 1
  "Next placement ID (p=PID) for direct placements.
Each overlay gets a unique PID so repeated placements replace
rather than accumulate.")

;;;; Terminal detection

(defun kitty-gfx--supported-p ()
  "Return non-nil if the terminal supports Kitty graphics."
  (and (not (display-graphic-p))
       (or (getenv "KITTY_PID")
           (equal (getenv "TERM_PROGRAM") "kitty")
           (equal (getenv "TERM_PROGRAM") "WezTerm")
           (equal (getenv "TERM_PROGRAM") "ghostty"))))

(defun kitty-gfx--query-cell-size ()
  "Query terminal for cell size in pixels using CSI 16 t (XTWINOPS).
The terminal responds with CSI 6 ; HEIGHT ; WIDTH t.
Falls back to reasonable defaults if query fails or times out."
  (unless (and kitty-gfx--cell-pixel-width kitty-gfx--cell-pixel-height)
    (condition-case nil
        (let ((response "")
              (done nil)
              (deadline (+ (float-time) 0.5)))  ; 500ms timeout
          ;; Send CSI 16 t — request cell size in pixels
          (send-string-to-terminal "\e[16t")
          ;; Read response characters until we get the full sequence
          ;; Expected: ESC [ 6 ; HEIGHT ; WIDTH t
          (while (and (not done) (< (float-time) deadline))
            (let ((ch (with-timeout (0.1 nil)
                        (read-event nil nil 0.1))))
              (when ch
                (setq response (concat response (string ch)))
                ;; Check if response ends with 't' (end of CSI response)
                (when (string-suffix-p "t" response)
                  (setq done t)))))
          ;; Parse the response: ESC [ 6 ; HEIGHT ; WIDTH t
          (when (string-match "\e\\[6;\\([0-9]+\\);\\([0-9]+\\)t" response)
            (let ((h (string-to-number (match-string 1 response)))
                  (w (string-to-number (match-string 2 response))))
              (when (and (> w 0) (> h 0))
                (setq kitty-gfx--cell-pixel-width w
                      kitty-gfx--cell-pixel-height h)
                (kitty-gfx--log "cell-size query: %dx%d pixels" w h)))))
      (error nil))
    ;; Fallback if query failed
    (unless kitty-gfx--cell-pixel-width
      (setq kitty-gfx--cell-pixel-width 8))
    (unless kitty-gfx--cell-pixel-height
      (setq kitty-gfx--cell-pixel-height 16))
    (kitty-gfx--log "cell-size final: %dx%d"
                     kitty-gfx--cell-pixel-width kitty-gfx--cell-pixel-height)))

;;;; Synchronized output

(defun kitty-gfx--sync-begin ()
  "Begin synchronized output (BSU).
The terminal buffers output until `kitty-gfx--sync-end' is called,
preventing partial rendering and flicker."
  (ignore-errors (send-string-to-terminal "\e[?2026h")))

(defun kitty-gfx--sync-end ()
  "End synchronized output (ESU).
Flushes buffered output to the terminal all at once."
  (ignore-errors (send-string-to-terminal "\e[?2026l")))

;;;; Protocol layer

(defun kitty-gfx--transmit-image (id base64-data)
  "Transmit image data to terminal with `a=t' (store only, no display).
ID is the image ID to assign.  BASE64-DATA is the PNG data, base64-encoded.
After this call, the image is stored in the terminal and can be placed
with `kitty-gfx--place-image'."
  (let* ((chunk-size kitty-gfx-chunk-size)
         (len (length base64-data))
         (offset 0)
         (first t))
    (while (< offset len)
      (let* ((end (min (+ offset chunk-size) len))
             (chunk (substring base64-data offset end))
             (more (if (< end len) 1 0))
             (ctrl (if first
                       (format "a=t,q=2,f=100,i=%d,m=%d" id more)
                     (format "m=%d,q=2" more))))
        (send-string-to-terminal (format "\e_G%s;%s\e\\" ctrl chunk))
        (setq offset end
              first nil)))
    (kitty-gfx--log "transmitted image: id=%d b64-len=%d" id len)))

(defun kitty-gfx--delete-by-id (id)
  "Delete image with ID and free data."
  (ignore-errors
    (send-string-to-terminal (format "\e_Ga=d,d=I,i=%d,q=2\e\\" id))))

(defun kitty-gfx--delete-all-images ()
  "Delete all visible placements and free data."
  (ignore-errors
    (send-string-to-terminal "\e_Ga=d,d=A,q=2\e\\")))

;;;; Direct placement (the core rendering mechanism)

(defun kitty-gfx--alloc-placement-id ()
  "Allocate a unique placement ID."
  (let ((pid kitty-gfx--next-placement-id))
    (setq kitty-gfx--next-placement-id (1+ kitty-gfx--next-placement-id))
    (when (> kitty-gfx--next-placement-id 4294967295)
      (setq kitty-gfx--next-placement-id 1))
    pid))

(defun kitty-gfx--place-image (image-id placement-id cols rows term-row term-col)
  "Place image IMAGE-ID at terminal position TERM-ROW, TERM-COL.
PLACEMENT-ID is the unique placement ID (p=PID) — reusing the same PID
replaces the previous placement, preventing accumulation.
COLS x ROWS is the size in terminal cells.
Uses direct placement: move cursor, then `a=p' with `c' and `r' params."
  (kitty-gfx--log "place: id=%d pid=%d cols=%d rows=%d row=%d col=%d"
                   image-id placement-id cols rows term-row term-col)
  (send-string-to-terminal
   (format "\e7\e[%d;%dH\e_Gq=2,a=p,i=%d,p=%d,c=%d,r=%d\e\\\e8"
           term-row term-col image-id placement-id cols rows)))

;;;; Position mapping

(defun kitty-gfx--in-folded-region-p (pos)
  "Non-nil if POS is inside a folded region (collapsed heading, block, etc.).
Checks org-fold (org 9.6+, text-property based) first, then falls
back to overlay-based invisibility for legacy org and outline-mode.
Ignores cosmetic invisibility like hidden link brackets (`org-link')."
  (or
   ;; org-fold (org 9.6+): text-property based folding.
   ;; org-fold-folded-p only checks structural folds (outline, block,
   ;; drawer), not cosmetic link bracket hiding.
   (and (fboundp 'org-fold-folded-p)
        (condition-case nil
            (org-fold-folded-p pos)
          (error nil)))
   ;; Legacy / non-org overlay-based folding (outline-mode, etc.)
   (let ((inv (get-char-property pos 'invisible)))
     (and inv (not (eq inv 'org-link))))))

(defun kitty-gfx--overlay-screen-pos (ov)
  "Return (TERM-ROW . TERM-COL) for overlay OV, or nil if not visible.
Coordinates are 1-indexed terminal positions.
Returns nil when the overlay position is inside a folded region
\(e.g., a collapsed org heading), even if the position is within
the window's scroll range."
  (let* ((buf (overlay-buffer ov))
         (pos (overlay-start ov))
         (win (and buf (get-buffer-window buf))))
    (when (and win pos
               (pos-visible-in-window-p pos win)
               ;; Check that the text isn't hidden by structural folding
               ;; (outline, org-fold, etc.) but allow cosmetic invisibility
               ;; like org-link bracket hiding.
               (not (kitty-gfx--in-folded-region-p pos)))
      (let* ((edges (window-edges win))
             (win-top (nth 1 edges))
             (win-left (nth 0 edges))
             (win-pos (posn-at-point pos win)))
        (when win-pos
          (let ((col-row (posn-col-row win-pos)))
            (when col-row
              (cons (+ win-top (cdr col-row) 1)
                    (+ win-left (car col-row) 1)))))))))

;;;; Refresh cycle

(defun kitty-gfx--refresh ()
  "Re-place all visible images after redisplay using direct placements.
Relies on placement IDs (p=PID) — re-placing with the same PID
replaces the previous placement without needing to delete first.
Caches last position per overlay to skip redundant re-placements.
Deletes placements for overlays that scrolled out of view.
All terminal output is wrapped in synchronized output (BSU/ESU)
to prevent flicker."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    (kitty-gfx--sync-begin)
    (unwind-protect
        (walk-windows
         (lambda (win)
           (with-current-buffer (window-buffer win)
             (when kitty-gfx--overlays
               (let* ((edges (window-edges win))
                      (win-bottom (nth 3 edges)))
                 (dolist (ov kitty-gfx--overlays)
                   (when (overlay-buffer ov)
                     (kitty-gfx--refresh-overlay ov win-bottom)))))))
         nil 'visible)
      (kitty-gfx--sync-end))))

(defun kitty-gfx--refresh-overlay (ov win-bottom)
  "Refresh a single overlay OV.  WIN-BOTTOM is the window's bottom edge.
Places the image if visible and position changed, or deletes placement
if the overlay scrolled out of view."
  (let ((pos (kitty-gfx--overlay-screen-pos ov))
        (rows (overlay-get ov 'kitty-gfx-rows))
        (last-row (overlay-get ov 'kitty-gfx-last-row))
        (last-col (overlay-get ov 'kitty-gfx-last-col)))
    (if (and pos (<= (car pos) win-bottom))
        ;; Visible (start is on screen) — place if position changed
        (let ((new-row (car pos))
              (new-col (cdr pos)))
          (unless (and (eql new-row last-row)
                       (eql new-col last-col))
            (overlay-put ov 'kitty-gfx-last-row new-row)
            (overlay-put ov 'kitty-gfx-last-col new-col)
            (kitty-gfx--place-image
             (overlay-get ov 'kitty-gfx-id)
             (overlay-get ov 'kitty-gfx-pid)
             (overlay-get ov 'kitty-gfx-cols)
             rows new-row new-col)))
      ;; Not visible or overflows — delete if was placed
      (when last-row
        (overlay-put ov 'kitty-gfx-last-row nil)
        (overlay-put ov 'kitty-gfx-last-col nil)
        (kitty-gfx--delete-placement
         (overlay-get ov 'kitty-gfx-id)
         (overlay-get ov 'kitty-gfx-pid))))))

(defun kitty-gfx--schedule-refresh ()
  "Schedule an image refresh after the current redisplay completes."
  (when kitty-gfx--render-timer
    (cancel-timer kitty-gfx--render-timer))
  (setq kitty-gfx--render-timer
        (run-at-time kitty-gfx-render-delay nil
                     (lambda ()
                       (setq kitty-gfx--render-timer nil)
                       (kitty-gfx--refresh)))))

(defun kitty-gfx--on-window-scroll (win _new-start)
  "Handle window scroll for image refresh."
  (when (buffer-local-value 'kitty-gfx--overlays (window-buffer win))
    (kitty-gfx--schedule-refresh)))

(defun kitty-gfx--on-buffer-change (_frame-or-window)
  "Handle buffer change for image refresh.
Clears visible placements first since the displayed buffer changed."
  (kitty-gfx--sync-begin)
  (unwind-protect
      (progn
        (ignore-errors
          (send-string-to-terminal "\e_Ga=d,d=a,q=2\e\\"))
        ;; Reset position cache so images get re-placed
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (dolist (ov kitty-gfx--overlays)
              (when (overlay-buffer ov)
                (overlay-put ov 'kitty-gfx-last-row nil)
                (overlay-put ov 'kitty-gfx-last-col nil))))))
    (kitty-gfx--sync-end))
  (kitty-gfx--schedule-refresh))

(defun kitty-gfx--on-window-change (_frame)
  "Handle window configuration change for image refresh.
Clears visible placements first since window layout changed."
  (kitty-gfx--sync-begin)
  (unwind-protect
      (progn
        (ignore-errors
          (send-string-to-terminal "\e_Ga=d,d=a,q=2\e\\"))
        ;; Reset position cache so images get re-placed
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (dolist (ov kitty-gfx--overlays)
              (when (overlay-buffer ov)
                (overlay-put ov 'kitty-gfx-last-row nil)
                (overlay-put ov 'kitty-gfx-last-col nil))))))
    (kitty-gfx--sync-end))
  (kitty-gfx--schedule-refresh))

(defun kitty-gfx--on-redisplay ()
  "Post-command hook to schedule image refresh."
  (kitty-gfx--schedule-refresh))

;;;; Image processing

(defun kitty-gfx--read-file-base64 (file)
  "Read FILE and return base64-encoded string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (base64-encode-region (point-min) (point-max) t)
    (buffer-string)))

(defun kitty-gfx--image-pixel-size (file)
  "Return (WIDTH . HEIGHT) in pixels for image FILE, or nil."
  (let ((identify (or (executable-find "identify")
                      (executable-find "magick"))))
    (when identify
      (with-temp-buffer
        (let ((args (if (string-suffix-p "magick" identify)
                        (list identify nil t nil "identify" "-format" "%w %h"
                              (concat file "[0]"))  ; first frame only
                      (list identify nil t nil "-format" "%w %h"
                            (concat file "[0]")))))
          (let ((exit-code (apply #'call-process args)))
            (kitty-gfx--log "identify: exit=%d output=%S" exit-code (buffer-string))
            (when (zerop exit-code)
              (goto-char (point-min))
              (when (looking-at "\\([0-9]+\\) \\([0-9]+\\)")
                (let ((w (string-to-number (match-string 1)))
                      (h (string-to-number (match-string 2))))
                  (kitty-gfx--log "identify: %dx%d pixels" w h)
                  (cons w h))))))))))

(defun kitty-gfx--convert-to-png (file)
  "Convert FILE to PNG if needed.  Returns path to PNG file.
Returns FILE unchanged if it is already PNG or if conversion fails."
  (if (string-suffix-p ".png" file t)
      file
    (let ((convert (or (executable-find "magick")
                       (executable-find "convert"))))
      (if (not convert)
          file  ; no converter available, try sending as-is
        (let ((out (make-temp-file "kitty-gfx-" nil ".png")))
          (if (string-suffix-p "magick" convert)
              (call-process convert nil nil nil "convert" file out)
            (call-process convert nil nil nil file out))
          ;; Check that conversion produced a non-empty file
          (if (and (file-exists-p out)
                   (> (file-attribute-size (file-attributes out)) 0))
              out
            (ignore-errors (delete-file out))
            file))))))

(defun kitty-gfx--compute-cell-dims (pixel-w pixel-h max-cols max-rows)
  "Compute (COLS . ROWS) in terminal cells for image placement.
With direct placements, COLS and ROWS map directly to terminal columns/rows."
  (let* ((cw (or kitty-gfx--cell-pixel-width 8))
         (ch (or kitty-gfx--cell-pixel-height 16))
         (img-cols (max 1 (ceiling (/ (float pixel-w) cw))))
         (img-rows (max 1 (ceiling (/ (float pixel-h) ch))))
         (scale (min (if (> img-cols max-cols)
                         (/ (float max-cols) img-cols) 1.0)
                     (if (> img-rows max-rows)
                         (/ (float max-rows) img-rows) 1.0)))
         (cols (max 1 (min (round (* img-cols scale)) max-cols)))
         (rows (max 1 (min (round (* img-rows scale)) max-rows))))
    (kitty-gfx--log "cell-dims: pixel=%dx%d cw=%d ch=%d img=%dx%d scale=%.2f result=%dx%d"
                     pixel-w pixel-h cw ch img-cols img-rows scale cols rows)
    (cons cols rows)))

;;;; Overlay management

(defun kitty-gfx--alloc-id ()
  "Allocate a new image ID (1-4294967295)."
  (let ((id kitty-gfx--next-id))
    (setq kitty-gfx--next-id (1+ kitty-gfx--next-id))
    (when (> kitty-gfx--next-id 4294967295)
      (setq kitty-gfx--next-id 1))
    id))

(defun kitty-gfx--make-blank-display (cols rows)
  "Create a blank display string of COLS terminal columns x ROWS lines.
Each line is propertized with face `default' to prevent org-link
underline/color from bleeding through the overlay."
  (mapconcat (lambda (_) (propertize (make-string cols ?\s) 'face 'default))
             (number-sequence 1 rows) "\n"))

(defun kitty-gfx--make-overlay (beg end image-id cols rows)
  "Create overlay from BEG to END for image IMAGE-ID (COLS x ROWS).
The overlay's display property shows blank space that the terminal
fills with the image via direct placement."
  (let ((ov (make-overlay beg end nil t nil))
        (pid (kitty-gfx--alloc-placement-id)))
    (overlay-put ov 'display
                 (concat (kitty-gfx--make-blank-display cols rows) "\n"))
    (overlay-put ov 'face 'default)  ; override inherited faces (org-link underline etc.)
    (overlay-put ov 'kitty-gfx t)
    (overlay-put ov 'kitty-gfx-id image-id)
    (overlay-put ov 'kitty-gfx-pid pid)
    (overlay-put ov 'kitty-gfx-cols cols)
    (overlay-put ov 'kitty-gfx-rows rows)
    ;; Don't set evaporate — zero-width overlays (beg==end) would be
    ;; deleted immediately if evaporate is set.
    (push ov kitty-gfx--overlays)
    ov))

(defun kitty-gfx--delete-placement (id pid)
  "Delete a specific placement PID of image ID from terminal.
Uses d=i (lowercase) to remove the placement but keep stored image
data so the image can be re-placed without retransmitting."
  (ignore-errors
    (send-string-to-terminal
     (format "\e_Ga=d,d=i,i=%d,p=%d,q=2\e\\" id pid))))

(defun kitty-gfx--remove-overlay (ov)
  "Remove overlay OV and delete its placement from terminal."
  (when (overlay-buffer ov)
    (condition-case nil
        (let ((id (overlay-get ov 'kitty-gfx-id))
              (pid (overlay-get ov 'kitty-gfx-pid)))
          (when (and id pid)
            (kitty-gfx--delete-placement id pid)))
      (error nil))
    (delete-overlay ov))
  (setq kitty-gfx--overlays (delq ov kitty-gfx--overlays)))

;;;; Public API

;;;###autoload
(defun kitty-gfx-display-image (file &optional beg end max-cols max-rows)
  "Display image FILE in the current buffer.
BEG/END span the overlay region.  MAX-COLS/MAX-ROWS limit size."
  (interactive "fImage file: ")
  (unless (kitty-gfx--supported-p)
    (user-error "Terminal does not support Kitty graphics"))
  (let* ((max-c (or max-cols kitty-gfx-max-width))
         (max-r (or max-rows kitty-gfx-max-height))
         (abs-file (expand-file-name file))
         (cached (gethash abs-file kitty-gfx--image-cache))
         (image-id (if cached (car cached) (kitty-gfx--alloc-id)))
         (dims (cond
                (cached (cdr cached))
                (t (let ((px (kitty-gfx--image-pixel-size abs-file)))
                     (if px
                         (kitty-gfx--compute-cell-dims
                          (car px) (cdr px) max-c max-r)
                       (cons (min 40 max-c) (min 15 max-r)))))))
         (cols (car dims))
         (rows (cdr dims))
         (start (or beg (point)))
         (stop (or end (point))))
    (kitty-gfx--log "display-image: file=%s id=%d cols=%d rows=%d beg=%s end=%s cached=%s"
                    abs-file image-id cols rows start stop (if cached "yes" "no"))
    ;; Transmit image if not cached
    (unless cached
      (let* ((png (kitty-gfx--convert-to-png abs-file))
             (b64 (kitty-gfx--read-file-base64 png)))
        (kitty-gfx--log "transmit: id=%d b64-len=%d png=%s" image-id (length b64) png)
        (kitty-gfx--transmit-image image-id b64)
        (puthash abs-file (cons image-id dims) kitty-gfx--image-cache)
        (when (and png (not (string= png abs-file)))
          (delete-file png t))))
    ;; Create overlay with blank space
    (kitty-gfx--make-overlay start stop image-id cols rows)
    ;; Schedule initial render
    (kitty-gfx--schedule-refresh)))

(defun kitty-gfx--display-image-centered (file max-cols max-rows
                                                &optional win-cols win-rows
                                                scale)
  "Display FILE centered in the current buffer.
MAX-COLS and MAX-ROWS are the maximum image dimensions at scale 1.0.
WIN-COLS and WIN-ROWS are the available window dimensions for centering;
they default to MAX-COLS and MAX-ROWS if not provided.
SCALE (default 1.0) multiplies the computed cell dims for zoom.
The buffer should be writable (caller handles `inhibit-read-only')."
  (let* ((s (or scale 1.0))
         (wc (or win-cols max-cols))
         (wr (or win-rows max-rows))
         (abs-file (expand-file-name file))
         (px (kitty-gfx--image-pixel-size abs-file))
         ;; Compute natural cell dims (capped at max)
         (base-dims (if px
                        (kitty-gfx--compute-cell-dims
                         (car px) (cdr px) max-cols max-rows)
                      (cons (min 40 max-cols) (min 15 max-rows))))
         ;; Apply zoom scale
         (img-cols (max 1 (round (* s (car base-dims)))))
         (img-rows (max 1 (round (* s (cdr base-dims)))))
         (h-pad (max 0 (/ (- wc img-cols) 2)))
         (v-pad (max 0 (/ (- wr img-rows) 2))))
    ;; Vertical centering: newlines before the image
    (dotimes (_ v-pad) (insert "\n"))
    ;; Horizontal centering: spaces to shift the overlay start column
    (insert (make-string h-pad ?\s))
    (let* ((img-start (point))
           (_ (insert "\n"))
           ;; Ensure image is transmitted (use cache for data, not dims)
           (cached (gethash abs-file kitty-gfx--image-cache))
           (image-id (if cached (car cached) (kitty-gfx--alloc-id))))
      (unless cached
        (let* ((png (kitty-gfx--convert-to-png abs-file))
               (b64 (kitty-gfx--read-file-base64 png)))
          (kitty-gfx--transmit-image image-id b64)
          (puthash abs-file (cons image-id (cons img-cols img-rows))
                   kitty-gfx--image-cache)
          (when (and png (not (string= png abs-file)))
            (delete-file png t))))
      ;; Create overlay at the scaled dimensions
      (kitty-gfx--make-overlay img-start (point) image-id img-cols img-rows)
      (kitty-gfx--schedule-refresh))))

(defun kitty-gfx-remove-images (&optional beg end)
  "Remove all kitty-gfx overlays in region BEG..END (defaults to whole buffer)."
  (interactive)
  (dolist (ov (overlays-in (or beg (point-min)) (or end (point-max))))
    (when (overlay-get ov 'kitty-gfx)
      (kitty-gfx--remove-overlay ov))))

(defun kitty-gfx-clear-all ()
  "Remove all images from all buffers and the terminal."
  (interactive)
  ;; Walk all buffers, not just current
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when kitty-gfx--overlays
        (kitty-gfx-remove-images))))
  (kitty-gfx--delete-all-images)
  (clrhash kitty-gfx--image-cache)
  (setq kitty-gfx--next-id 1)
  (setq kitty-gfx--next-placement-id 1))

;;;; Minor mode

;;;###autoload
(define-minor-mode kitty-graphics-mode
  "Display images in terminal Emacs via Kitty graphics protocol."
  :global t
  :lighter " KittyGfx"
  (if kitty-graphics-mode
      (if (kitty-gfx--supported-p)
          (progn
            (kitty-gfx--delete-all-images)  ; clear stale state
            (kitty-gfx--query-cell-size)
            (kitty-gfx--install-hooks)
            (kitty-gfx--install-integrations)
            (message "Kitty graphics mode enabled"))
        (setq kitty-graphics-mode nil)
        (message "Kitty graphics: terminal not supported"))
    (kitty-gfx--uninstall-hooks)
    (kitty-gfx--uninstall-integrations)
    (kitty-gfx--delete-all-images)))

(defun kitty-gfx--install-hooks ()
  "Install redisplay hooks for image refresh."
  (add-hook 'window-scroll-functions #'kitty-gfx--on-window-scroll)
  (add-hook 'window-size-change-functions #'kitty-gfx--on-window-change)
  (add-hook 'window-buffer-change-functions #'kitty-gfx--on-buffer-change)
  (add-hook 'post-command-hook #'kitty-gfx--on-redisplay))

(defun kitty-gfx--uninstall-hooks ()
  "Remove redisplay hooks."
  (remove-hook 'window-scroll-functions #'kitty-gfx--on-window-scroll)
  (remove-hook 'window-size-change-functions #'kitty-gfx--on-window-change)
  (remove-hook 'window-buffer-change-functions #'kitty-gfx--on-buffer-change)
  (remove-hook 'post-command-hook #'kitty-gfx--on-redisplay))

;;;; Org-mode integration

(defun kitty-gfx--on-org-cycle (&rest _args)
  "Handle org visibility cycling.
Deletes all current-buffer placements from the terminal, clears the
position cache, then schedules a refresh that re-places only the
overlays that are still visible (not inside a fold)."
  (when (and kitty-graphics-mode kitty-gfx--overlays)
    (kitty-gfx--sync-begin)
    (unwind-protect
        (dolist (ov kitty-gfx--overlays)
          (when (overlay-buffer ov)
            ;; Delete this overlay's terminal placement
            (let ((id (overlay-get ov 'kitty-gfx-id))
                  (pid (overlay-get ov 'kitty-gfx-pid)))
              (when (and id pid)
                (kitty-gfx--delete-placement id pid)))
            ;; Clear position cache so visible images get re-placed
            (overlay-put ov 'kitty-gfx-last-row nil)
            (overlay-put ov 'kitty-gfx-last-col nil)))
      (kitty-gfx--sync-end))
    (kitty-gfx--schedule-refresh)))

(defun kitty-gfx--image-file-p (file)
  "Return non-nil if FILE has an image extension."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext)
                     '("png" "jpg" "jpeg" "gif" "bmp" "svg"
                       "webp" "tiff" "tif")))))

(defun kitty-gfx--org-display-inline-images-tty (&optional _include-linked beg end)
  "Display inline images in org buffer via Kitty graphics.
Scans for file:, attachment:, and relative path links."
  (when (derived-mode-p 'org-mode)
    (let ((start (or beg (point-min)))
          (stop (or end (point-max))))
      (save-restriction
        (widen)
        (save-excursion
          (goto-char start)
          ;; Match file:, attachment:, relative (./) and absolute (/) paths
          (while (re-search-forward
                  "\\[\\[\\(file:\\|attachment:\\|[./~]\\)" stop t)
            (let* ((context (org-element-context))
                   (type (org-element-type context)))
              (when (eq type 'link)
                (let* ((link-beg (org-element-property :begin context))
                       (link-end (org-element-property :end context))
                       (path (org-element-property :path context))
                       (link-type (org-element-property :type context))
                       (file (cond
                              ((string= link-type "file") path)
                              ((string= link-type "attachment")
                               (ignore-errors
                                 (require 'org-attach)
                                 (when-let ((dir (org-attach-dir)))
                                   (expand-file-name path dir))))
                              (t path))))
                  (when (and file
                             (file-exists-p (expand-file-name file))
                             (kitty-gfx--image-file-p file)
                             (not (cl-some (lambda (ov)
                                             (overlay-get ov 'kitty-gfx))
                                           (overlays-in link-beg link-end))))
                    (condition-case err
                        (kitty-gfx-display-image
                         (expand-file-name file) link-beg link-end
                         kitty-gfx-max-width kitty-gfx-max-height)
                      (error
                       (message "kitty-gfx: %s: %s"
                                 file (error-message-string err))))))))))))))


(defun kitty-gfx--org-display-advice (orig-fn &rest args)
  "Around advice for `org-display-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (apply #'kitty-gfx--org-display-inline-images-tty args)
    (apply orig-fn args)))

(defun kitty-gfx--org-remove-advice (orig-fn &rest args)
  "Around advice for `org-remove-inline-images'."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    (kitty-gfx-remove-images))
  (apply orig-fn args))

(defun kitty-gfx--org-toggle-advice (orig-fn &rest args)
  "Around advice for `org-toggle-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (if (cl-some (lambda (ov) (overlay-get ov 'kitty-gfx))
                   (overlays-in (point-min) (point-max)))
          (kitty-gfx-remove-images)
        (kitty-gfx--org-display-inline-images-tty))
    (apply orig-fn args)))

;; org 10.0+ uses org-link-preview instead of org-toggle-inline-images

(defun kitty-gfx--org-link-preview-advice (orig-fn &optional arg beg end)
  "Around advice for `org-link-preview' (org 10.0+).
With prefix ARG \\[universal-argument], clear previews."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (cond
       ;; C-u = clear
       ((equal arg '(4))
        (kitty-gfx-remove-images beg end))
       ;; C-u C-u C-u = clear whole buffer
       ((equal arg '(64))
        (kitty-gfx-remove-images))
       ;; Otherwise display images
       (t
        (kitty-gfx--org-display-inline-images-tty nil beg end)))
    (funcall orig-fn arg beg end)))

(defun kitty-gfx--org-link-preview-region-advice (orig-fn &optional include-linked refresh beg end)
  "Around advice for `org-link-preview-region' (org 10.0+)."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (kitty-gfx--org-display-inline-images-tty include-linked beg end)
    (funcall orig-fn include-linked refresh beg end)))

;;;; LaTeX fragment preview integration

(defun kitty-gfx--org-latex-preview-advice (orig-fn &optional arg beg end)
  "Around advice for `org-latex-preview'.
Bypasses org's `display-graphic-p' guard so LaTeX fragments are
rendered to images via dvipng/dvisvgm and displayed via Kitty
graphics.  The image generation pipeline does not require a GUI."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (cond
       ;; C-u = clear previews in region/subtree
       ((equal arg '(4))
        (kitty-gfx--org-clear-latex-preview beg end))
       ;; C-u C-u = clear all previews in buffer
       ((equal arg '(16))
        (kitty-gfx--org-clear-latex-preview))
       ;; Default = generate and display previews
       (t
        (let ((start (or beg (if (use-region-p) (region-beginning) (point-min))))
              (stop (or end (if (use-region-p) (region-end) (point-max)))))
          ;; In terminal, face attributes may return "unspecified-fg" which
          ;; breaks org-latex-color-format.  Force concrete colors.
          (let ((org-format-latex-options
                 (org-combine-plists
                  org-format-latex-options
                  (list :foreground
                        (let ((fg (face-attribute 'default :foreground nil)))
                          (if (and (stringp fg)
                                   (not (string-prefix-p "unspecified" fg)))
                              fg
                            "Black"))
                        :background "Transparent"))))
            ;; Suppress clear-image-cache which requires a GUI frame.
            (cl-letf (((symbol-function 'clear-image-cache) #'ignore))
              (org--latex-preview-region start stop))))))
    (funcall orig-fn arg beg end)))

(defun kitty-gfx--org-make-preview-overlay-advice (orig-fn beg end movefile imagetype)
  "Around advice for `org--make-preview-overlay'.
Intercepts LaTeX preview overlay creation to display the generated
image via Kitty graphics instead of an Emacs image spec."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when (and movefile (file-exists-p movefile))
        ;; Don't create duplicate overlays at the same position
        (unless (cl-some (lambda (ov) (overlay-get ov 'kitty-gfx))
                         (overlays-in beg end))
          (kitty-gfx-display-image movefile beg end)
          ;; Tag the most recently created overlay with org properties
          ;; so org-clear-latex-preview can find and clean it up.
          (when-let ((ov (car kitty-gfx--overlays)))
            (overlay-put ov 'org-overlay-type 'org-latex-overlay)
            (overlay-put ov 'modification-hooks
                         (list (lambda (o after &rest _)
                                 (when after
                                   (kitty-gfx--remove-overlay o)))))
            ov)))
    (funcall orig-fn beg end movefile imagetype)))

(defun kitty-gfx--org-clear-latex-preview (&optional beg end)
  "Remove Kitty graphics LaTeX preview overlays in region BEG..END."
  (let ((start (or beg (point-min)))
        (stop (or end (point-max))))
    (dolist (ov (overlays-in start stop))
      (when (and (overlay-get ov 'kitty-gfx)
                 (eq (overlay-get ov 'org-overlay-type) 'org-latex-overlay))
        (kitty-gfx--remove-overlay ov)))))

;;;; image-mode integration

(defun kitty-gfx--image-mode-advice (orig-fn &rest args)
  "Around advice for `image-mode'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (major-mode-suspend)
        (setq major-mode 'image-mode
              mode-name "Image[Kitty]")
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map (if (boundp 'image-mode-map) image-mode-map
                                   special-mode-map))
          (define-key map (kbd "q") #'kill-current-buffer)
          (use-local-map map))
        (setq-local buffer-read-only t)
        (when-let ((file (buffer-file-name)))
          (when (kitty-gfx--image-file-p file)
            (kitty-gfx-display-image
             file (point-min) (point-max)
             (min (- (window-body-width) 2) kitty-gfx-max-width)
             (min (- (window-body-height) 2) kitty-gfx-max-height))))
        (run-mode-hooks 'image-mode-hook))
    (apply orig-fn args)))

;;;; shr integration (eww, mu4e, gnus)

(defun kitty-gfx--shr-put-image-advice (orig-fn spec alt &rest args)
  "Around advice for `shr-put-image'.
SPEC is an image descriptor — typically a create-image result.
We extract the :file or :data from the image properties."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (let* ((start (point))
             ;; shr image spec is (image . PROPS) from `create-image'
             (props (and (consp spec) (cdr spec)))
             (data (plist-get props :data))
             (url (plist-get props :file))
             (type (plist-get props :type)))
        (insert (or alt "[image]"))
        (let ((end (point)))
          (condition-case err
              (let* ((suffix (cond
                              ((eq type 'jpeg) ".jpg")
                              ((eq type 'gif) ".gif")
                              ((eq type 'webp) ".webp")
                              ((eq type 'svg) ".svg")
                              (t ".png")))
                     (file (cond
                            (url (when (file-exists-p url) url))
                            (data
                             (let ((tmp (make-temp-file "kitty-shr-" nil suffix)))
                               (with-temp-file tmp
                                 (set-buffer-multibyte nil)
                                 (insert data))
                               tmp))))
                     (temp-p (and data file)))
                (when file
                  (kitty-gfx-display-image file start end)
                  (when temp-p (delete-file file t))))
            (error
             (kitty-gfx--log "shr-put-image error: %s" (error-message-string err))))))
    (apply orig-fn spec alt args)))

;;;; doc-view integration

(defun kitty-gfx--doc-view-mode-p-advice (orig-fn type)
  "Around advice for `doc-view-mode-p'.
Bypasses the `display-graphic-p' check so doc-view's conversion
pipeline runs in terminal mode with Kitty graphics.
TYPE is the document type symbol (pdf, dvi, ps, etc.)."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      ;; Run the original with display-graphic-p temporarily forced to t.
      ;; This bypasses the GUI guard while keeping all the per-type
      ;; tool availability checks intact.
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (funcall orig-fn type))
    (funcall orig-fn type)))

(defvar-local kitty-gfx--doc-view-overlay nil
  "The Kitty graphics overlay used for doc-view page display.")

(defvar-local kitty-gfx--doc-view-scale 1.0
  "Zoom scale factor for doc-view page display.
Values > 1.0 zoom in, < 1.0 zoom out.")

(defvar-local kitty-gfx--doc-view-current-file nil
  "Path to the current doc-view page image file.
Stored so zoom commands can re-render without querying `doc-view-current-image'.")

(defun kitty-gfx--doc-view-insert-image-advice (orig-fn file &rest args)
  "Around advice for `doc-view-insert-image'.
Displays the page image via Kitty graphics instead of an Emacs
image spec.  FILE is the path to the page PNG."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when (and file (file-exists-p file))
        ;; Remember current file for zoom commands
        (setq kitty-gfx--doc-view-current-file file)
        ;; Remove previous page image
        (when kitty-gfx--doc-view-overlay
          (kitty-gfx--remove-overlay kitty-gfx--doc-view-overlay)
          (setq kitty-gfx--doc-view-overlay nil))
        ;; Clear the buffer (removes "Welcome to DocView!" text)
        (let* ((inhibit-read-only t)
               (win-w (- (window-body-width) 1))
               (win-h (- (window-body-height) 1)))
          (erase-buffer)
          (kitty-gfx--display-image-centered
           file win-w win-h win-w win-h
           kitty-gfx--doc-view-scale)
          (setq kitty-gfx--doc-view-overlay (car kitty-gfx--overlays)))
        (goto-char (point-min)))
    (apply orig-fn file args)))

(defun kitty-gfx--doc-view-enlarge-advice (orig-fn factor)
  "Around advice for `doc-view-enlarge'.
Updates `kitty-gfx--doc-view-scale' and re-renders the page."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when kitty-gfx--doc-view-current-file
        (setq kitty-gfx--doc-view-scale
              (* kitty-gfx--doc-view-scale factor))
        (kitty-gfx--doc-view-insert-image-advice
         nil kitty-gfx--doc-view-current-file))
    (funcall orig-fn factor)))

(defun kitty-gfx--doc-view-scale-reset-advice (orig-fn &rest args)
  "Around advice for `doc-view-scale-reset'.
Resets `kitty-gfx--doc-view-scale' to 1.0 and re-renders the page."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when kitty-gfx--doc-view-current-file
        (setq kitty-gfx--doc-view-scale 1.0)
        (kitty-gfx--doc-view-insert-image-advice
         nil kitty-gfx--doc-view-current-file))
    (apply orig-fn args)))

;;;; Dired integration

;;;###autoload
(defun kitty-gfx-dired-preview ()
  "Preview the image file at point in dired.
Opens a side window with the image displayed via Kitty graphics.
Press `q' in the preview buffer to close it."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a dired buffer"))
  (let ((file (dired-get-file-for-visit)))
    (unless (kitty-gfx--image-file-p file)
      (user-error "Not an image file"))
    (let* ((buf-name (format "*kitty-preview: %s*" (file-name-nondirectory file)))
           (buf (get-buffer-create buf-name))
           (win (display-buffer-in-side-window
                 buf '((side . right) (window-width . 0.5)))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "  %s\n\n" (file-name-nondirectory file))))
        (setq-local buffer-read-only t)
        (let ((map (make-sparse-keymap)))
          (define-key map (kbd "q")
                      (lambda () (interactive)
                        (let ((win (get-buffer-window (current-buffer))))
                          (kitty-gfx-remove-images)
                          (kill-buffer (current-buffer))
                          (when (window-live-p win)
                            (delete-window win)))))
          (use-local-map map))
        (kitty-gfx-display-image
         file (point-min) (point-max)
         (min (- (window-width win) 2) kitty-gfx-max-width)
         (min (- (window-height win) 3) kitty-gfx-max-height))
        (goto-char (point-min))))))

;;;; Dirvish integration

;; Forward declarations for dirvish
(declare-function dirvish-define-preview "dirvish" (&rest args))
(declare-function dirvish--special-buffer "dirvish" (type dv &optional new))
(defvar dirvish-image-exts)
(defvar dirvish-preview-dispatchers)
(defvar dirvish--available-preview-dispatchers)

(defun kitty-gfx--dirvish-preview (file _ext preview-window _dv)
  "Dirvish preview dispatcher for images in terminal via Kitty graphics.
FILE is the file to preview, PREVIEW-WINDOW is the target window.
Returns a buffer recipe, or nil if not in terminal or not an image."
  (when (and kitty-graphics-mode
             (not (display-graphic-p))
             (kitty-gfx--supported-p))
    (let* ((buf-name (format " *kitty-dirvish: %s*" (file-name-nondirectory file)))
           (buf (get-buffer-create buf-name))
           (max-cols (min (- (window-width preview-window) 2) kitty-gfx-max-width))
           (max-rows (min (- (window-height preview-window) 3) kitty-gfx-max-height)))
      (with-current-buffer buf
        ;; Clean up any previous images in this buffer
        (let ((inhibit-read-only t))
          (kitty-gfx-remove-images)
          (erase-buffer)
          (insert (format "\n  %s\n\n" (file-name-nondirectory file))))
        (setq-local buffer-read-only t)
        (kitty-gfx-display-image file (point-min) (point-max) max-cols max-rows)
        (goto-char (point-min)))
      ;; Return buffer recipe for dirvish dispatch
      `(buffer . ,buf))))

(defun kitty-gfx--install-dirvish ()
  "Install kitty-graphics as a dirvish preview dispatcher.
Registers `kitty-image' dispatcher and prepends it to the dispatcher list."
  (with-eval-after-load 'dirvish
    ;; Register our dispatcher in dirvish's registry.
    ;; dirvish-define-preview is a macro that creates dirvish-NAME-dp function
    ;; and adds to dirvish--available-preview-dispatchers.
    ;; We simulate what the macro does since we can't use it at load time
    ;; (dirvish may not be loaded yet).
    (unless (assq 'kitty-image dirvish--available-preview-dispatchers)
      (push (cons 'kitty-image
                   (list :doc "Preview images using Kitty graphics protocol"
                         :require nil))
            dirvish--available-preview-dispatchers))
    ;; Create the dispatcher function that dirvish expects
    (defalias 'dirvish-kitty-image-dp
      (lambda (file ext preview-window dv)
        (when (and (boundp 'dirvish-image-exts)
                   (member ext dirvish-image-exts))
          (kitty-gfx--dirvish-preview file ext preview-window dv))))
    ;; Prepend kitty-image to dispatchers if not already there
    (unless (memq 'kitty-image dirvish-preview-dispatchers)
      (setq dirvish-preview-dispatchers
            (cons 'kitty-image dirvish-preview-dispatchers)))
    (kitty-gfx--log "dirvish: installed kitty-image dispatcher")))

(defun kitty-gfx--uninstall-dirvish ()
  "Remove kitty-graphics dirvish preview dispatcher."
  (when (boundp 'dirvish-preview-dispatchers)
    (setq dirvish-preview-dispatchers
          (delq 'kitty-image dirvish-preview-dispatchers)))
  (when (boundp 'dirvish--available-preview-dispatchers)
    (setq dirvish--available-preview-dispatchers
          (assq-delete-all 'kitty-image dirvish--available-preview-dispatchers)))
  (fmakunbound 'dirvish-kitty-image-dp))

;;;; Integration install/uninstall

(defun kitty-gfx--install-integrations ()
  "Install advice on org-mode, image-mode, shr, dirvish."
  (with-eval-after-load 'org
    (advice-add 'org-display-inline-images :around
                #'kitty-gfx--org-display-advice)
    (advice-add 'org-remove-inline-images :around
                #'kitty-gfx--org-remove-advice)
    (advice-add 'org-toggle-inline-images :around
                #'kitty-gfx--org-toggle-advice)
    ;; org 10.0+: org-link-preview replaces org-toggle-inline-images
    (when (fboundp 'org-link-preview)
      (advice-add 'org-link-preview :around
                  #'kitty-gfx--org-link-preview-advice))
    (when (fboundp 'org-link-preview-region)
      (advice-add 'org-link-preview-region :around
                  #'kitty-gfx--org-link-preview-region-advice))
    ;; Refresh images when org cycles heading visibility
    (add-hook 'org-cycle-hook #'kitty-gfx--on-org-cycle)
    ;; LaTeX fragment preview in terminal
    (advice-add 'org-latex-preview :around
                #'kitty-gfx--org-latex-preview-advice)
    (advice-add 'org--make-preview-overlay :around
                #'kitty-gfx--org-make-preview-overlay-advice))
  (with-eval-after-load 'image-mode
    (advice-add 'image-mode :around
                #'kitty-gfx--image-mode-advice))
  (with-eval-after-load 'shr
    (advice-add 'shr-put-image :around
                #'kitty-gfx--shr-put-image-advice))
  (with-eval-after-load 'doc-view
    (advice-add 'doc-view-mode-p :around
                #'kitty-gfx--doc-view-mode-p-advice)
    (advice-add 'doc-view-insert-image :around
                #'kitty-gfx--doc-view-insert-image-advice)
    (advice-add 'doc-view-enlarge :around
                #'kitty-gfx--doc-view-enlarge-advice)
    (advice-add 'doc-view-scale-reset :around
                #'kitty-gfx--doc-view-scale-reset-advice))
  (kitty-gfx--install-dirvish))

(defun kitty-gfx--uninstall-integrations ()
  "Remove all advice."
  (advice-remove 'org-display-inline-images #'kitty-gfx--org-display-advice)
  (advice-remove 'org-remove-inline-images #'kitty-gfx--org-remove-advice)
  (advice-remove 'org-toggle-inline-images #'kitty-gfx--org-toggle-advice)
  (when (fboundp 'org-link-preview)
    (advice-remove 'org-link-preview #'kitty-gfx--org-link-preview-advice))
  (when (fboundp 'org-link-preview-region)
    (advice-remove 'org-link-preview-region #'kitty-gfx--org-link-preview-region-advice))
  (remove-hook 'org-cycle-hook #'kitty-gfx--on-org-cycle)
  (advice-remove 'org-latex-preview #'kitty-gfx--org-latex-preview-advice)
  (advice-remove 'org--make-preview-overlay #'kitty-gfx--org-make-preview-overlay-advice)
  (advice-remove 'doc-view-mode-p #'kitty-gfx--doc-view-mode-p-advice)
  (advice-remove 'doc-view-insert-image #'kitty-gfx--doc-view-insert-image-advice)
  (advice-remove 'doc-view-enlarge #'kitty-gfx--doc-view-enlarge-advice)
  (advice-remove 'doc-view-scale-reset #'kitty-gfx--doc-view-scale-reset-advice)
  (advice-remove 'image-mode #'kitty-gfx--image-mode-advice)
  (advice-remove 'shr-put-image #'kitty-gfx--shr-put-image-advice)
  (kitty-gfx--uninstall-dirvish))

;;;; Buffer cleanup

(defun kitty-gfx--kill-buffer-hook ()
  "Clean up images when buffer is killed."
  (when (and kitty-graphics-mode kitty-gfx--overlays)
    (dolist (ov kitty-gfx--overlays)
      (condition-case nil
          (when-let ((id (overlay-get ov 'kitty-gfx-id)))
            (kitty-gfx--delete-by-id id))
        (error nil)))
    (setq kitty-gfx--overlays nil)))

(add-hook 'kill-buffer-hook #'kitty-gfx--kill-buffer-hook)

(provide 'kitty-graphics)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; kitty-graphics.el ends here
