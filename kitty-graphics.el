;;; kitty-graphics.el --- Display images in terminal Emacs via Kitty graphics protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2025
;;
;; Author: vterm-graphics contributors
;; Version: 0.1.0
;; URL: https://git.cashmere.rs/vterm-graphics.git
;; Keywords: terminals, images, multimedia
;; Package-Requires: ((emacs "27.1"))

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
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
(declare-function image-mode-setup-winprops "image-mode" ())
(declare-function shr-rescale-image "shr" (data &optional content-type width height max-width max-height))
(defvar org-image-actual-width)
(defvar image-mode-map)

;;;; Customization

(defgroup kitty-graphics nil
  "Display images in terminal Emacs via Kitty graphics."
  :group 'multimedia
  :prefix "kitty-gfx-")

(defcustom kitty-gfx-max-width 80
  "Maximum image width in terminal columns."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-max-height 24
  "Maximum image height in terminal rows."
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
  "Try to determine terminal cell size in pixels.
Falls back to reasonable defaults (8x16) if query fails."
  ;; Use Kitty's XTWINOPS CSI 16 t to query cell size.
  ;; The terminal responds with CSI 6 ; height ; width t
  ;; For now, use sensible defaults — async query is complex in Emacs.
  ;; TODO: Parse response from CSI 16 t if we can make it work.
  (unless kitty-gfx--cell-pixel-width
    (setq kitty-gfx--cell-pixel-width 8))
  (unless kitty-gfx--cell-pixel-height
    (setq kitty-gfx--cell-pixel-height 16)))

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

(defun kitty-gfx--overlay-screen-pos (ov)
  "Return (TERM-ROW . TERM-COL) for overlay OV, or nil if not visible.
Coordinates are 1-indexed terminal positions."
  (let* ((buf (overlay-buffer ov))
         (pos (overlay-start ov))
         (win (and buf (get-buffer-window buf))))
    (when (and win pos (pos-visible-in-window-p pos win))
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
Deletes placements for overlays that scrolled out of view."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    (walk-windows
     (lambda (win)
       (with-current-buffer (window-buffer win)
         (when kitty-gfx--overlays
           (let* ((edges (window-edges win))
                  (win-bottom (nth 3 edges)))
             (dolist (ov kitty-gfx--overlays)
               (when (overlay-buffer ov)
                 (let ((pos (kitty-gfx--overlay-screen-pos ov))
                       (rows (overlay-get ov 'kitty-gfx-rows))
                       (last-row (overlay-get ov 'kitty-gfx-last-row))
                       (last-col (overlay-get ov 'kitty-gfx-last-col)))
                   (if (and pos (<= (+ (car pos) rows) (1+ win-bottom)))
                       ;; Visible and fits — place if position changed
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
                        (overlay-get ov 'kitty-gfx-pid)))))))))))
     nil 'visible)))

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
  (ignore-errors
    (send-string-to-terminal "\e_Ga=d,d=a,q=2\e\\"))
  (kitty-gfx--schedule-refresh))

(defun kitty-gfx--on-window-change (_frame)
  "Handle window configuration change for image refresh.
Clears visible placements first since window layout changed."
  (ignore-errors
    (send-string-to-terminal "\e_Ga=d,d=a,q=2\e\\"))
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

;;;; image-mode integration

(defun kitty-gfx--image-mode-advice (orig-fn &rest args)
  "Around advice for `image-mode'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (major-mode-suspend)
        (setq major-mode 'image-mode
              mode-name "Image[Kitty]")
        (use-local-map (if (boundp 'image-mode-map) image-mode-map
                         (make-sparse-keymap)))
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
             (url (plist-get props :file)))
        (insert (or alt "[image]"))
        (let ((end (point)))
          (condition-case nil
              (let ((file (cond
                           (url (when (file-exists-p url) url))
                           (data
                            (let ((tmp (make-temp-file "kitty-shr-" nil ".png")))
                              (with-temp-file tmp
                                (set-buffer-multibyte nil)
                                (insert data))
                              tmp)))))
                (when file
                  (kitty-gfx-display-image file start end)
                  (when data (delete-file file t))))
            (error nil))))
    (apply orig-fn spec alt args)))

;;;; Integration install/uninstall

(defun kitty-gfx--install-integrations ()
  "Install advice on org-mode, image-mode, shr."
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
                  #'kitty-gfx--org-link-preview-region-advice)))
  (with-eval-after-load 'image-mode
    (advice-add 'image-mode :around
                #'kitty-gfx--image-mode-advice))
  (with-eval-after-load 'shr
    (advice-add 'shr-put-image :around
                #'kitty-gfx--shr-put-image-advice)))

(defun kitty-gfx--uninstall-integrations ()
  "Remove all advice."
  (advice-remove 'org-display-inline-images #'kitty-gfx--org-display-advice)
  (advice-remove 'org-remove-inline-images #'kitty-gfx--org-remove-advice)
  (advice-remove 'org-toggle-inline-images #'kitty-gfx--org-toggle-advice)
  (when (fboundp 'org-link-preview)
    (advice-remove 'org-link-preview #'kitty-gfx--org-link-preview-advice))
  (when (fboundp 'org-link-preview-region)
    (advice-remove 'org-link-preview-region #'kitty-gfx--org-link-preview-region-advice))
  (advice-remove 'image-mode #'kitty-gfx--image-mode-advice)
  (advice-remove 'shr-put-image #'kitty-gfx--shr-put-image-advice))

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
