;;; kitty-graphics.el --- Display images in terminal Emacs via Kitty graphics protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026
;;
;; Author: cashmere
;; Version: 0.5.0
;; URL: https://github.com/cashmeredev/kitty-graphics.el
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
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-link-display-format "ol" (s))
(declare-function org-current-level "org" ())
(defvar org-heading-regexp)
(defvar image-mode-map)
(declare-function markdown-overlays--resolve-image-url "markdown-overlays" (url))
(declare-function json-encode "json" (object))

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

(defcustom kitty-gfx-enable-video nil
  "When non-nil, enable inline video playback via mpv.
Requires mpv with --vo=kitty support (mpv 0.36.0+)."
  :type 'boolean
  :group 'kitty-graphics)

(defvar kitty-gfx--log-file "/tmp/kitty-gfx.log"
  "File path for debug log output.")

(defvar kitty-gfx--dry-run nil
  "When non-nil, log escape sequences instead of sending to terminal.
Useful for debugging and batch testing without a real terminal.")

(defun kitty-gfx--log (fmt &rest args)
  "Log to `kitty-gfx--log-file' and *kitty-gfx-debug* buffer when debug is on."
  (when kitty-gfx-debug
    (let ((msg (concat (format-time-string "%H:%M:%S.%3N ")
                       (apply #'format fmt args) "\n")))
      (ignore-errors (append-to-file msg nil kitty-gfx--log-file))
      (ignore-errors
        (let ((buf (get-buffer-create "*kitty-gfx-debug*")))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert msg)
            ;; Trim buffer at 2500 lines
            (when (> (line-number-at-pos (point-max)) 2500)
              (goto-char (point-min))
              (forward-line 500)
              (delete-region (point-min) (point)))))))))

(defun kitty-gfx--terminal-send (str)
  "Send STR to terminal, or log it in dry-run mode.
All terminal escape output should go through this function."
  (if kitty-gfx--dry-run
      (kitty-gfx--log "DRY-RUN-SEND: %S" str)
    (ignore-errors (send-string-to-terminal str))))

;;;; Constants — kept for reference if switching back to Unicode placeholders
;; (defconst kitty-gfx--placeholder-char #x10EEEE)
;; (defconst kitty-gfx--diacritics [...])

;;;; Internal state

;; Forward declaration — defined by `define-minor-mode' below.
(defvar kitty-graphics-mode)

(defvar kitty-gfx--active-backend nil
  "Symbol identifying the active graphics backend: `kitty' or `sixel'.
Set by `kitty-gfx--detect-protocol'.")

(defvar kitty-gfx--backends nil
  "Alist mapping backend symbols to operation alists.
Each backend alist maps operation symbols to functions:
  `detect'      — () -> bool: return non-nil if backend is supported
  `prepare'     — (file image-id) -> id-or-nil: prepare/transmit image
  `place'       — (ov id pid cols rows term-row term-col): place image
  `delete'      — (ov id pid): delete placement
  `cleanup'     — (file id): cleanup resources for file
  `cleanup-all' — (): cleanup all resources.")

(defvar kitty-gfx--next-id 1
  "Next image ID to assign (1-4294967295).
With direct placements, any uint32 ID works — no 256-color constraint.")

(defcustom kitty-gfx-cache-size 64
  "Maximum number of images to keep in the terminal-side cache.
When exceeded, the least recently used image is evicted and its
terminal data deleted via `a=d'."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-preferred-protocol 'auto
  "Preferred graphics protocol to use.
Choices: `auto' (try Kitty first, then Sixel), `kitty', or `sixel'.
Default is `auto'."
  :type '(choice (const :tag "Auto-detect (Kitty → Sixel)" auto)
                 (const :tag "Kitty graphics protocol" kitty)
                 (const :tag "Sixel protocol" sixel))
  :group 'kitty-graphics)

(defcustom kitty-gfx-sixel-encoder-program nil
  "Program used to encode raster images to Sixel.
When nil, auto-detect: prefer `img2sixel' (libsixel), then
`magick' (ImageMagick 7), then `convert' (ImageMagick 6, deprecated).
When set to a string, use that program and treat it as `img2sixel'-style
unless the basename is `magick' or `convert'."
  :type '(choice (const :tag "Auto-detect" nil) string)
  :group 'kitty-graphics)

(defcustom kitty-gfx-sixel-encoder-args nil
  "Extra arguments passed to `kitty-gfx-sixel-encoder-program'.
These come before the per-invocation size flags and the input file."
  :type '(repeat string)
  :group 'kitty-graphics)

(defcustom kitty-gfx-sixel-encoder-timeout 5.0
  "Maximum time in seconds to wait for a single Sixel encoder run.
When nil, wait indefinitely.  Encoders that hang on a malformed image
will otherwise block Emacs."
  :type '(choice (const :tag "No timeout" nil) number)
  :group 'kitty-graphics)

(defcustom kitty-gfx-tmux-allow-sixel t
  "When non-nil, allow the Sixel backend to engage inside tmux >= 3.4.
tmux 3.4 (released 2024-02-13) ships native Sixel rendering, so this
package no longer hard-disables Sixel under tmux.  Set to nil if your
tmux is built without `--enable-sixel' or if you prefer to avoid the
upstream scroll artifact: tmux's cell buffer is not pixel-aware, so
images may persist after scrolling until the affected cells are
overwritten."
  :type 'boolean
  :group 'kitty-graphics)

(defcustom kitty-gfx-heading-scales '((1 . 2.0) (2 . 1.5) (3 . 1.2))
  "Alist mapping org heading level to visual scale factor.
Headings at levels not listed use scale 1.0 (normal size).
Requires Kitty >= 0.40.0 (text sizing protocol, OSC 66).

Scale values are floats: 2.0 = double size, 1.5 = 50% larger.
Any scale > 1.0 occupies 2+ terminal rows (multicell block).
Maximum scale is 7.0 (limited by protocol)."
  :type '(alist :key-type (integer :tag "Heading level")
                :value-type (choice (const :tag "2.0x (double)" 2.0)
                                    (const :tag "1.5x" 1.5)
                                    (const :tag "1.2x" 1.2)
                                    (number :tag "Custom (1.0-7.0)")))
  :group 'kitty-graphics)

(defcustom kitty-gfx-heading-sizes-auto nil
  "When non-nil, automatically apply heading sizes in org buffers.
Heading sizes are applied when `org-mode' is activated and
`kitty-graphics-mode' is enabled.  Set to nil to require manual
activation via `kitty-gfx-org-heading-sizes'."
  :type 'boolean
  :group 'kitty-graphics)

(defvar kitty-gfx--image-cache (make-hash-table :test 'equal)
  "Maps file paths to image IDs (integers).
Only stores the terminal-side image ID — display dimensions are
computed fresh each time to avoid stale values from different
display contexts (window sizes, zoom levels, etc.).")

(defvar kitty-gfx--cache-lru nil
  "LRU list of file paths in `kitty-gfx--image-cache'.
Most recently used at the front.")

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

(defvar kitty-gfx--text-sizing-support nil
  "Cached text sizing protocol support level.
nil means not yet queried.  Possible values after query:
  `scale'  -- full support (s= and w= both work, Kitty >= 0.40.0)
  `width'  -- width-only support (w= works, s= does not)
  `none'   -- no support (terminal ignores OSC 66 entirely)")

(defvar-local kitty-gfx--heading-rescan-timer nil
  "Timer for debouncing heading re-scans after text edits.
Prevents queuing redundant `kitty-gfx--org-apply-heading-sizes'
calls when multiple characters are typed rapidly.")

(defvar-local kitty-gfx--mpv-process nil
  "The mpv process object for the current buffer's video.")

(defvar-local kitty-gfx--mpv-ipc-socket nil
  "Path to the mpv JSON IPC socket file.")

(defvar-local kitty-gfx--mpv-ipc-connection nil
  "Network process connected to mpv's IPC socket.")

(defvar-local kitty-gfx--mpv-overlay nil
  "The overlay reserving space for the video.")

(defvar-local kitty-gfx--mpv-last-row nil
  "Last known terminal row of the video overlay.")

(defvar-local kitty-gfx--mpv-last-col nil
  "Last known terminal column of the video overlay.")

;;;; Terminal detection

(defun kitty-gfx--backend-fn (op)
  "Return the backend function for operation OP.
Looks up OP in the active backend's operation alist.
Signals an error if no backend is active or OP is missing."
  (unless kitty-gfx--active-backend
    (error "No active graphics backend"))
  (let* ((backend-alist (alist-get kitty-gfx--active-backend kitty-gfx--backends))
         (fn (alist-get op backend-alist)))
    (unless fn
      (error "Backend %s does not implement operation %s"
             kitty-gfx--active-backend op))
    fn))

(defun kitty-gfx--detect-protocol ()
  "Detect and activate a graphics protocol backend.
Returns non-nil if a supported backend is found.
Sets `kitty-gfx--active-backend' to the detected backend symbol."
  (if (display-graphic-p)
      (progn
        (kitty-gfx--log "detect-protocol: GUI frame, no terminal graphics")
        (setq kitty-gfx--active-backend nil)
        nil)
      (let ((pref kitty-gfx-preferred-protocol)
            (detected nil))
        (kitty-gfx--log "detect-protocol: preference=%s" pref)
        (cond
         ;; Explicit backend preference
         ((eq pref 'kitty)
          (let ((fn (alist-get 'detect (alist-get 'kitty kitty-gfx--backends))))
            (when (and fn (funcall fn))
              (setq detected 'kitty))))
         ((eq pref 'sixel)
          (let ((fn (alist-get 'detect (alist-get 'sixel kitty-gfx--backends))))
            (when (and fn (funcall fn))
              (setq detected 'sixel))))
         ;; Auto: try Kitty first (fast env check), then Sixel
         (t
          (let ((kitty-fn (alist-get 'detect (alist-get 'kitty kitty-gfx--backends))))
            (if (and kitty-fn (funcall kitty-fn))
                (setq detected 'kitty)
              (let ((sixel-fn (alist-get 'detect (alist-get 'sixel kitty-gfx--backends))))
                (when (and sixel-fn (funcall sixel-fn))
                  (setq detected 'sixel)))))))
        (setq kitty-gfx--active-backend detected)
        (kitty-gfx--log "detect-protocol: result=%s" detected)
        detected)))

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

(defun kitty-gfx--query-text-sizing-support ()
  "Detect terminal text sizing protocol support via CPR probing.
Sends three cursor position queries interleaved with OSC 66 width
and scale tests, then compares cursor column advancement.
Sets `kitty-gfx--text-sizing-support' to `scale', `width', or `none'.

The detection sequence (per Kitty spec):
  CR → CPR1 → OSC66(w=2,\" \") → CPR2 → OSC66(s=2,\" \") → CPR3 → DSR

Compare column positions:
  x2 = x1+2 AND x3 = x2+2 → full scale support
  x2 = x1+2 only           → width-only support
  no advancement            → no support

Uses DSR (device status report) as a sentinel to avoid hanging."
  (if kitty-gfx--text-sizing-support
      ;; Already detected — return cached result
      (kitty-gfx--log "text-sizing: cached result=%s"
                       kitty-gfx--text-sizing-support)
    (condition-case err
        (let ((response "")
              (done nil)
              (deadline (+ (float-time) 1.0)))
          ;; Save cursor, CR to column 1, then interleaved CPR + OSC 66
          ;; tests, DSR sentinel, erase line, restore cursor.
          (send-string-to-terminal
           (concat "\e7\r\e[6n"                 ; save + CR + CPR1
                   "\e]66;w=2; \a\e[6n"         ; width test + CPR2
                   "\e]66;s=2; \a\e[6n"         ; scale test + CPR3
                   "\e[5n"                       ; DSR sentinel
                   "\e[2K\e8"))                  ; erase line + restore
          ;; Read until DSR response (ends with 'n') or timeout
          (while (and (not done) (< (float-time) deadline))
            (let ((ch (with-timeout (0.1 nil)
                        (read-event nil nil 0.1))))
              (if ch
                  (progn
                    (setq response (concat response (string ch)))
                    (when (and (string-suffix-p "n" response)
                               (>= (cl-count ?R response) 3))
                      (setq done t)))
                ;; No input — check if we have enough responses
                (when (>= (cl-count ?R response) 3)
                  (setq done t)))))
          ;; Parse three CPR responses: ESC [ row ; col R
          (let ((cols nil)
                (start 0))
            (while (string-match "\e\\[[0-9]+;\\([0-9]+\\)R" response start)
              (push (string-to-number (match-string 1 response)) cols)
              (setq start (match-end 0)))
            (setq cols (nreverse cols))
            (if (>= (length cols) 3)
                (let ((x1 (nth 0 cols))
                      (x2 (nth 1 cols))
                      (x3 (nth 2 cols)))
                  (kitty-gfx--log "text-sizing: CPR cols x1=%d x2=%d x3=%d"
                                   x1 x2 x3)
                  (cond
                   ((and (eql x2 (+ x1 2)) (eql x3 (+ x2 2)))
                    (setq kitty-gfx--text-sizing-support 'scale)
                    (kitty-gfx--log "text-sizing: full support (scale)"))
                   ((eql x2 (+ x1 2))
                    (setq kitty-gfx--text-sizing-support 'width)
                    (kitty-gfx--log "text-sizing: width-only support"))
                   (t
                    (setq kitty-gfx--text-sizing-support 'none)
                    (kitty-gfx--log "text-sizing: no support"))))
              (kitty-gfx--log "text-sizing: parse failed (got %d CPRs) raw=%S"
                               (length cols) response)
              (setq kitty-gfx--text-sizing-support 'none)))
          ;; Flush any remaining terminal responses
          (let ((flush-deadline (+ (float-time) 0.1)))
            (while (< (float-time) flush-deadline)
              (unless (read-event nil nil 0.02)
                (setq flush-deadline 0)))))
      (error
       (kitty-gfx--log "text-sizing: query error: %s"
                        (error-message-string err))
       (setq kitty-gfx--text-sizing-support 'none))))
  kitty-gfx--text-sizing-support)

;;;; Synchronized output

(defun kitty-gfx--sync-begin ()
  "Begin synchronized output (BSU).
The terminal buffers output until `kitty-gfx--sync-end' is called,
preventing partial rendering and flicker."
  (kitty-gfx--log "sync-begin")
  (kitty-gfx--terminal-send "\e[?2026h"))

(defun kitty-gfx--sync-end ()
  "End synchronized output (ESU).
Flushes buffered output to the terminal all at once."
  (kitty-gfx--log "sync-end")
  (kitty-gfx--terminal-send "\e[?2026l"))

;;;; Protocol layer

(defun kitty-gfx--transmit-image (id base64-data)
  "Transmit image data to terminal with `a=t' (store only, no display).
ID is the image ID to assign.  BASE64-DATA is the PNG data, base64-encoded.
After this call, the image is stored in the terminal and can be placed
with `kitty-gfx--place-image'."
  (let* ((chunk-size kitty-gfx-chunk-size)
         (len (length base64-data))
         (offset 0)
         (first t)
         (chunk-count 0))
    (kitty-gfx--log "transmit-begin: id=%d b64-len=%d chunk-size=%d chunks=%d"
                     id len chunk-size (ceiling (/ (float len) chunk-size)))
    (while (< offset len)
      (let* ((end (min (+ offset chunk-size) len))
             (chunk (substring base64-data offset end))
             (more (if (< end len) 1 0))
             (ctrl (if first
                       (format "a=t,q=2,f=100,i=%d,m=%d" id more)
                     (format "m=%d,q=2" more))))
        (kitty-gfx--terminal-send (format "\e_G%s;%s\e\\" ctrl chunk))
        (cl-incf chunk-count)
        (setq offset end
              first nil)))
    (kitty-gfx--log "transmit-done: id=%d chunks-sent=%d" id chunk-count)))

(defun kitty-gfx--delete-by-id (id)
  "Delete image with ID and free data."
  (kitty-gfx--log "delete-by-id: id=%d" id)
  (kitty-gfx--terminal-send (format "\e_Ga=d,d=I,i=%d,q=2\e\\" id)))

(defun kitty-gfx--delete-all-images ()
  "Delete all visible placements and free data."
  (kitty-gfx--log "delete-all-images")
  (kitty-gfx--terminal-send "\e_Ga=d,d=A,q=2\e\\"))

;;;; Direct placement (the core rendering mechanism)

(defun kitty-gfx--alloc-placement-id ()
  "Allocate a unique placement ID."
  (let ((pid kitty-gfx--next-placement-id))
    (setq kitty-gfx--next-placement-id (1+ kitty-gfx--next-placement-id))
    (when (> kitty-gfx--next-placement-id 4294967295)
      (setq kitty-gfx--next-placement-id 1))
    (kitty-gfx--log "alloc-pid: %d" pid)
    pid))

(defun kitty-gfx--place-image (image-id placement-id cols rows term-row term-col)
  "Place image IMAGE-ID at terminal position TERM-ROW, TERM-COL.
PLACEMENT-ID is the unique placement ID (p=PID) — reusing the same PID
replaces the previous placement, preventing accumulation.
COLS x ROWS is the size in terminal cells.
Uses direct placement: move cursor, then `a=p' with `c' and `r' params."
  (kitty-gfx--log "place: id=%d pid=%d cols=%d rows=%d row=%d col=%d"
                   image-id placement-id cols rows term-row term-col)
  (kitty-gfx--terminal-send
   (format "\e7\e[%d;%dH\e_Gq=2,a=p,i=%d,p=%d,c=%d,r=%d\e\\\e8"
           term-row term-col image-id placement-id cols rows)))

;;;; Kitty backend

(defun kitty-gfx--kitty-detect ()
  "Return non-nil if the terminal supports Kitty graphics protocol."
  (let ((supported (or (getenv "KITTY_PID")
                       (equal (getenv "TERM_PROGRAM") "kitty")
                       (equal (getenv "TERM_PROGRAM") "WezTerm")
                       (equal (getenv "TERM_PROGRAM") "ghostty"))))
    (kitty-gfx--log "kitty-detect: %s (KITTY_PID=%s TERM_PROGRAM=%s)"
                     supported (getenv "KITTY_PID") (getenv "TERM_PROGRAM"))
    supported))

(defun kitty-gfx--kitty-prepare (file image-id)
  "Prepare image FILE for Kitty display.
Converts to PNG if needed, encodes to base64, transmits to terminal.
Returns IMAGE-ID on success, nil on failure."
  (let* ((png (kitty-gfx--convert-to-png file))
         (temp-p (and png (not (string= png file)))))
    (unwind-protect
        (let ((b64 (when png (kitty-gfx--read-file-base64 png))))
          (if (not b64)
              (progn
                (kitty-gfx--log "kitty-prepare: skipped %s (conversion failed)" file)
                nil)
            (kitty-gfx--log "kitty-prepare: transmit id=%d b64-len=%d png=%s"
                             image-id (length b64) png)
            (kitty-gfx--transmit-image image-id b64)
            image-id))
      (when temp-p
        (ignore-errors (delete-file png))))))

(defun kitty-gfx--kitty-place (_ov image-id placement-id cols rows term-row term-col)
  "Place Kitty image at terminal position.
OV is the overlay (unused by Kitty backend but part of the interface)."
  (kitty-gfx--place-image image-id placement-id cols rows term-row term-col))

(defun kitty-gfx--kitty-delete (_ov image-id placement-id)
  "Delete Kitty placement PID of image ID."
  (kitty-gfx--delete-placement image-id placement-id))

(defun kitty-gfx--kitty-cleanup (_file image-id)
  "Cleanup Kitty image data for FILE (identified by IMAGE-ID)."
  (kitty-gfx--delete-by-id image-id))

(defun kitty-gfx--kitty-cleanup-all ()
  "Cleanup all Kitty images."
  (kitty-gfx--delete-all-images))

;;;; Sixel backend

(defvar kitty-gfx--sixel-temp-files nil
  "List of temporary Sixel files created for caching.")

(defvar kitty-gfx--sixel-cache (make-hash-table :test 'equal)
  "Maps (file . dims-string) to temp sixel file paths.")

(defvar kitty-gfx--tmux-version-cache 'unset
  "Cached `kitty-gfx--tmux-version' result.
Sentinel `unset' means the probe has not run yet; nil means tmux was
absent or its version could not be parsed; otherwise a list (MAJOR MINOR).")

(defun kitty-gfx--tmux-version ()
  "Return tmux version as (MAJOR MINOR) integers, or nil when unavailable.
Memoised in `kitty-gfx--tmux-version-cache'."
  (when (eq kitty-gfx--tmux-version-cache 'unset)
    (setq kitty-gfx--tmux-version-cache
          (when (executable-find "tmux")
            (with-temp-buffer
              (when (zerop (ignore-errors
                             (call-process "tmux" nil t nil "-V")))
                (goto-char (point-min))
                (when (re-search-forward
                       "tmux\\(?:[[:space:]]+next-\\)?[[:space:]]+\\([0-9]+\\)\\.\\([0-9]+\\)"
                       nil t)
                  (list (string-to-number (match-string 1))
                        (string-to-number (match-string 2)))))))))
  kitty-gfx--tmux-version-cache)

(defun kitty-gfx--tmux-sixel-supported-p ()
  "Return non-nil when running under tmux >= 3.4 with Sixel allowed.
Returns nil outside tmux, nil when `kitty-gfx-tmux-allow-sixel' is off,
nil when tmux's version cannot be determined, and nil for tmux < 3.4."
  (and (getenv "TMUX")
       kitty-gfx-tmux-allow-sixel
       (let ((ver (kitty-gfx--tmux-version)))
         (and ver
              (or (> (car ver) 3)
                  (and (= (car ver) 3) (>= (cadr ver) 4)))))))

(defun kitty-gfx--sixel-detect ()
  "Return non-nil if the terminal likely supports Sixel protocol.
Inside tmux, requires tmux >= 3.4 (native Sixel rendering, 2024-02-13)
and `kitty-gfx-tmux-allow-sixel'.  Older tmux versions still disable
Sixel because they drop the DCS payload."
  (let* ((term (getenv "TERM"))
         (term-prog (getenv "TERM_PROGRAM"))
         (in-tmux (getenv "TMUX"))
         (tmux-ver (and in-tmux (kitty-gfx--tmux-version)))
         (tmux-ok (kitty-gfx--tmux-sixel-supported-p))
         ;; Windows Terminal's TERM value is not stable enough to rely on
         ;; alone, so accept its session markers when present.
         (windows-terminal (or (getenv "WT_SESSION")
                               (getenv "WT_PROFILE_ID")
                               (getenv "WT_WINDOWID")))
         (supported (and term
                         (or (not in-tmux) tmux-ok)
                         (or (string-match-p "xterm\\|vt[0-9]\\|foot\\|contour" term)
                             (member term-prog '("foot" "Konsole" "mintty" "mlterm"
                                                 "contour" "WezTerm"))
                             windows-terminal)
                         t)))
    (kitty-gfx--log
     "sixel-detect: %s (TERM=%s TERM_PROGRAM=%s TMUX=%s tmux-ver=%s tmux-ok=%s WT=%s)"
     supported term term-prog (if in-tmux "yes" "no")
     (if tmux-ver (format "%d.%d" (car tmux-ver) (cadr tmux-ver)) "n/a")
     (if tmux-ok "yes" "no")
     (if windows-terminal "yes" "no"))
    supported))

(defun kitty-gfx--sixel-cache-path (file cols rows)
  "Return deterministic temp file path for FILE at COLS x ROWS."
  (let* ((key (format "%s:%dx%d" file cols rows))
         (hash (md5 key)))
    (expand-file-name (concat "kitty-gfx-sixel-" hash ".six") temporary-file-directory)))

(defun kitty-gfx--sixel-resolve-encoder ()
  "Resolve the Sixel encoder program.
Return a cons (KIND . ABS-PATH) where KIND is `img2sixel' or `imagemagick'
and ABS-PATH is the resolved executable path, or nil when no encoder
is available."
  (let* ((user kitty-gfx-sixel-encoder-program)
         (path (cond
                (user (executable-find user))
                (t (or (executable-find "img2sixel")
                       (executable-find "magick")
                       (executable-find "convert"))))))
    (when path
      (let ((base (downcase (file-name-nondirectory path))))
        (cons (cond
               ((string-prefix-p "img2sixel" base) 'img2sixel)
               ((or (string-prefix-p "magick" base)
                    (string-prefix-p "convert" base)) 'imagemagick)
               ;; User-specified non-standard binary: assume img2sixel-style
               (t 'img2sixel))
              path)))))

(defun kitty-gfx--sixel-run-encoder (program timeout dest-buffer args)
  "Run PROGRAM with ARGS, writing stdout into DEST-BUFFER.
TIMEOUT, when a positive number, terminates the process after that many
seconds and signals an error.  Errors include captured stderr.
Returns t on success, nil on failure (failures are logged, not signalled)."
  (let* ((stderr-buf (generate-new-buffer " *kitty-gfx-sixel-stderr*"))
         (process-connection-type nil)
         (proc (make-process :name "kitty-gfx-sixel-encoder"
                             :buffer dest-buffer
                             :command (cons program args)
                             :coding 'binary
                             :connection-type 'pipe
                             :stderr stderr-buf
                             :noquery t))
         (timer (and (numberp timeout)
                     (> timeout 0)
                     (run-at-time
                      timeout nil
                      (lambda (p)
                        (when (process-live-p p)
                          (process-put p 'kitty-gfx-timed-out t)
                          (delete-process p)))
                      proc))))
    (set-process-sentinel proc #'ignore)
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.1))
          (let* ((timed-out (process-get proc 'kitty-gfx-timed-out))
                 (exit (process-exit-status proc))
                 (stderr (string-trim
                          (with-current-buffer stderr-buf (buffer-string)))))
            (cond
             (timed-out
              (kitty-gfx--log
               "sixel-encode: TIMEOUT after %.1fs (%s killed)"
               (float timeout) program)
              nil)
             ((eq exit 0) t)
             (t
              (kitty-gfx--log "sixel-encode: %s exit=%s%s"
                              program exit
                              (if (string-empty-p stderr)
                                  ""
                                (concat ": " stderr)))
              nil))))
      (when timer (cancel-timer timer))
      (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf)))))

(defun kitty-gfx--sixel-encode (png-file cols rows)
  "Encode PNG-FILE as Sixel data for COLS x ROWS cells.
Returns Sixel data string or nil on failure.
Computes pixel dimensions from cell size.  The encoder is selected via
`kitty-gfx-sixel-encoder-program' (auto-detected when nil) and bounded
by `kitty-gfx-sixel-encoder-timeout'."
  (let* ((cw (or kitty-gfx--cell-pixel-width 8))
         (ch (or kitty-gfx--cell-pixel-height 16))
         (pixel-w (* cols cw))
         (pixel-h (* rows ch))
         (resolved (kitty-gfx--sixel-resolve-encoder)))
    (if (not resolved)
        (progn
          (kitty-gfx--log "sixel-encode: no encoder found (img2sixel/magick/convert)")
          (message "kitty-gfx: Sixel backend requires img2sixel or ImageMagick")
          nil)
      (let* ((kind (car resolved))
             (path (cdr resolved))
             (base (file-name-nondirectory path))
             (args (pcase kind
                     ('img2sixel
                      (append kitty-gfx-sixel-encoder-args
                              (list "-w" (number-to-string pixel-w)
                                    "-h" (number-to-string pixel-h))
                              (list png-file)))
                     ('imagemagick
                      (append (list png-file)
                              kitty-gfx-sixel-encoder-args
                              (list "-geometry"
                                    (format "%dx%d" pixel-w pixel-h))
                              (list "sixel:-"))))))
        (when (string-prefix-p "convert" (downcase base))
          (kitty-gfx--log "sixel-encode: WARNING deprecated `convert' resolved (%s); install `magick' or `img2sixel'" path))
        (kitty-gfx--log "sixel-encode: %s -> %dx%d pixels via %s (%s)"
                        png-file pixel-w pixel-h base kind)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (if (kitty-gfx--sixel-run-encoder
               path kitty-gfx-sixel-encoder-timeout
               (current-buffer) args)
              (let ((data (buffer-string)))
                (kitty-gfx--log "sixel-encode: success (%d bytes)" (length data))
                data)
            nil))))))

(defun kitty-gfx--sixel-prepare (file _image-id)
  "Prepare FILE for Sixel display.
For Sixel, preparation just validates the file exists and is convertible.
Actual encoding happens at place-time (needs dimensions).
Returns non-nil on success."
  (let ((png (kitty-gfx--convert-to-png file)))
    (when png
      (kitty-gfx--log "sixel-prepare: %s -> %s" file png)
      ;; Cache the PNG path for later encoding
      (puthash file png kitty-gfx--sixel-cache)
      t)))

(defun kitty-gfx--sixel-place (ov _image-id _placement-id cols rows term-row term-col)
  "Place Sixel image at terminal position.
Encodes on-demand if not cached, then emits DCS sequence."
  (let* ((file (overlay-get ov 'kitty-gfx-file))
         (png (gethash file kitty-gfx--sixel-cache))
         (cache-path (kitty-gfx--sixel-cache-path file cols rows))
         (sixel-data nil))
    (if (not png)
        (kitty-gfx--log "sixel-place: no PNG cached for %s" file)
    ;; Check if sixel encoding is cached
    (if (file-exists-p cache-path)
        (progn
          (kitty-gfx--log "sixel-place: using cached sixel %s" cache-path)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally cache-path)
            (setq sixel-data (buffer-string))))
      ;; Encode on-demand
      (kitty-gfx--log "sixel-place: encoding %s at %dx%d" png cols rows)
      (setq sixel-data (kitty-gfx--sixel-encode png cols rows))
      (when sixel-data
        ;; Cache the encoding
        (ignore-errors
          (with-temp-file cache-path
            (set-buffer-multibyte nil)
            (insert sixel-data)))
        (push cache-path kitty-gfx--sixel-temp-files)
        ;; LRU eviction: cap temp files at kitty-gfx-cache-size
        (when (> (length kitty-gfx--sixel-temp-files) kitty-gfx-cache-size)
          (let ((victim (car (last kitty-gfx--sixel-temp-files))))
            (kitty-gfx--log "sixel-cache-evict: %s (count=%d max=%d)"
                            victim (length kitty-gfx--sixel-temp-files)
                            kitty-gfx-cache-size)
            (ignore-errors (delete-file victim))
            (setq kitty-gfx--sixel-temp-files
                  (butlast kitty-gfx--sixel-temp-files))))))
      ;; Emit Sixel sequence if we have data
      (when sixel-data
        (let* ((cw (or kitty-gfx--cell-pixel-width 8))
               (ch (or kitty-gfx--cell-pixel-height 16)))
          (kitty-gfx--log "sixel-place: emitting at row=%d col=%d data-len=%d pixel-target=%dx%d"
                          term-row term-col (length sixel-data) (* cols cw) (* rows ch)))
        (kitty-gfx--terminal-send
         (format "\e7\e[%d;%dH%s\e8" term-row term-col sixel-data))))))

(defun kitty-gfx--sixel-delete (ov _image-id _placement-id)
  "Delete Sixel placement by overwriting with spaces.
Sixel has no placement IDs — erase by writing spaces over the region."
  (let ((last-row (overlay-get ov 'kitty-gfx-last-row))
        (last-col (overlay-get ov 'kitty-gfx-last-col))
        (rows (overlay-get ov 'kitty-gfx-rows))
        (cols (overlay-get ov 'kitty-gfx-cols)))
    (when (and last-row last-col rows cols)
      (kitty-gfx--log "sixel-delete: erase row=%d col=%d %dx%d"
                       last-row last-col cols rows)
      (kitty-gfx--terminal-send
       (format "\e7%s\e8"
               (mapconcat
                (lambda (r)
                  (format "\e[%d;%dH%s" (+ last-row r) last-col (make-string cols ?\s)))
                (number-sequence 0 (1- rows))
                ""))))))

(defun kitty-gfx--sixel-cleanup (file _image-id)
  "Cleanup Sixel resources for FILE."
  (when file
    (remhash file kitty-gfx--sixel-cache)
    ;; Remove cached sixel encodings for this file
    (dolist (temp-file kitty-gfx--sixel-temp-files)
      (when (string-match-p (regexp-quote (md5 file)) temp-file)
        (kitty-gfx--log "sixel-cleanup: deleting %s" temp-file)
        (ignore-errors (delete-file temp-file))
        (setq kitty-gfx--sixel-temp-files (delete temp-file kitty-gfx--sixel-temp-files))))))

(defun kitty-gfx--sixel-cleanup-all ()
  "Cleanup all Sixel resources.
Erases visible Sixel images from the terminal before cleaning
disk/memory state, preventing pixel artifacts on mode disable."
  (kitty-gfx--log "sixel-cleanup-all: deleting %d temp files"
                   (length kitty-gfx--sixel-temp-files))
  ;; Erase visible images from terminal (Sixel has no protocol-level
  ;; delete — must overwrite cells with spaces).
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (dolist (ov kitty-gfx--overlays)
        (when (and (overlay-buffer ov)
                   (not (overlay-get ov 'kitty-gfx-heading))
                   (overlay-get ov 'kitty-gfx-last-row))
          (funcall #'kitty-gfx--sixel-delete ov nil nil)))))
  ;; Clean disk cache
  (dolist (temp-file kitty-gfx--sixel-temp-files)
    (ignore-errors (delete-file temp-file)))
  (setq kitty-gfx--sixel-temp-files nil)
  (clrhash kitty-gfx--sixel-cache))

;; Register backends
(setq kitty-gfx--backends
      `((kitty . ((detect . ,#'kitty-gfx--kitty-detect)
                  (prepare . ,#'kitty-gfx--kitty-prepare)
                  (place . ,#'kitty-gfx--kitty-place)
                  (delete . ,#'kitty-gfx--kitty-delete)
                  (cleanup . ,#'kitty-gfx--kitty-cleanup)
                  (cleanup-all . ,#'kitty-gfx--kitty-cleanup-all)))
        (sixel . ((detect . ,#'kitty-gfx--sixel-detect)
                  (prepare . ,#'kitty-gfx--sixel-prepare)
                  (place . ,#'kitty-gfx--sixel-place)
                  (delete . ,#'kitty-gfx--sixel-delete)
                  (cleanup . ,#'kitty-gfx--sixel-cleanup)
                  (cleanup-all . ,#'kitty-gfx--sixel-cleanup-all)))))

;; Cleanup temp files on exit
(add-hook 'kill-emacs-hook #'kitty-gfx--sixel-cleanup-all)

;;;; Text sizing protocol (OSC 66)

(defun kitty-gfx--decompose-scale (scale)
  "Decompose SCALE (float) into OSC 66 parameters (s n d).
Returns (CELL-S FRAC-N FRAC-D) where:
  CELL-S is the integer cell scale (1-7, the s= parameter)
  FRAC-N is the fractional numerator (0-15, the n= parameter)
  FRAC-D is the fractional denominator (0-15, the d= parameter)

Examples:
  1.0 -> (1 0 0)  -- no scaling
  2.0 -> (2 0 0)  -- double size, 2-row block
  1.5 -> (2 3 4)  -- 2-row block, 3/4 fractional fill
  1.2 -> (2 3 5)  -- 2-row block, 3/5 fractional fill
  3.0 -> (3 0 0)  -- triple size, 3-row block"
  (let* ((clamped (max 1.0 (min 7.0 (float scale))))
         (s (max 1 (min 7 (ceiling clamped))))
         (ratio (/ clamped s)))
    (if (<= (abs (- ratio 1.0)) 0.01)
        ;; Close enough to 1.0 -- no fractional part needed
        (list s 0 0)
      (let ((best-n 0)
            (best-d 0)
            (best-err 1.0))
        (cl-loop for d from 2 to 15
                 for n = (round (* ratio d))
                 when (and (> n 0) (< n d) (<= n 15))
                 do (let ((err (abs (- (/ (float n) d) ratio))))
                      (when (< err best-err)
                        (setq best-n n best-d d best-err err))))
        (list s best-n best-d)))))

(defun kitty-gfx--validate-osc66 (s n d text)
  "Return non-nil if OSC 66 parameters are valid per protocol spec.
S is cell scale (1-7), N is fractional numerator (0-15),
D is fractional denominator (0-15, must be > N when non-zero),
TEXT is the string payload (max 4096 bytes UTF-8)."
  (and (<= 1 s 7)
       (<= 0 n 15)
       (<= 0 d 15)
       (or (zerop d) (> d n))
       (<= (length (encode-coding-string text 'utf-8)) 4096)))

(defun kitty-gfx--heading-sgr (level)
  "Return SGR escape string for org heading at LEVEL.
Applies bold + 24-bit foreground color from org-level-N face.
Falls back to bold-only when color is unavailable or face undefined."
  (let* ((face (intern (format "org-level-%d" (min level 8))))
         (fg (and (facep face)
                  (face-attribute face :foreground nil t)))
         (color (when (and (stringp fg)
                           (not (string-prefix-p "unspecified" fg)))
                  (color-values fg))))
    (if color
        (format "\e[1;38;2;%d;%d;%dm"
                (/ (nth 0 color) 256)
                (/ (nth 1 color) 256)
                (/ (nth 2 color) 256))
      "\e[1m")))

(defun kitty-gfx--place-heading (ov)
  "Emit OSC 66 to render heading overlay OV at its cached terminal position.
Pre-erases the target area using ECH before emitting, preventing
artifacts from partial overwrites (adapted from mdfried's pattern).
Sequence: save-cursor, erase-area, move-to-position, SGR-color,
OSC-66-payload, SGR-reset, restore-cursor."
  (let* ((raw-text (overlay-get ov 'kitty-gfx-heading-text))
         ;; Strip text properties — org-modern, font-lock, etc. can
         ;; attach display/face properties that corrupt OSC 66 payload.
         (text (substring-no-properties raw-text))
         (cell-s (overlay-get ov 'kitty-gfx-heading-cell-s))
         (frac-n (overlay-get ov 'kitty-gfx-heading-frac-n))
         (frac-d (overlay-get ov 'kitty-gfx-heading-frac-d))
         (level (overlay-get ov 'kitty-gfx-heading-level))
         (row (overlay-get ov 'kitty-gfx-last-row))
         (col (overlay-get ov 'kitty-gfx-last-col))
         (cols (overlay-get ov 'kitty-gfx-cols))
         (rows (overlay-get ov 'kitty-gfx-rows))
         (sgr (kitty-gfx--heading-sgr level))
         ;; Build the OSC 66 metadata: s=S, and optionally n=N:d=D
         (meta (if (and frac-n frac-d (> frac-d 0))
                   (format "s=%d:n=%d:d=%d" cell-s frac-n frac-d)
                 (format "s=%d" cell-s))))
    (kitty-gfx--log "place-heading: L%d row=%d col=%d s=%d n=%d d=%d text=%S"
                     level row col cell-s frac-n frac-d text)
    ;; Pre-erase: clean the target area before emitting OSC 66.
    ;; This prevents ghost artifacts from previous content or
    ;; partially-overwritten multicell blocks.
    (kitty-gfx--erase-heading-at row col (or cols 0) (or rows 1))
    ;; Emit OSC 66 at the target position
    (kitty-gfx--terminal-send
     (format "\e7\e[%d;%dH%s\e]66;%s;%s\a\e[0m\e8"
             row col sgr meta text))
    ;; After successful emission, switch display to spaces so Emacs
    ;; incremental redraws don't overwrite the multicell block.
    ;; Before first emission the overlay shows the plain heading text
    ;; as a visible fallback (set in kitty-gfx--make-heading-overlay).
    ;; Mark as emitted so subsequent refresh cycles skip re-emission.
    ;; Cleared when heading moves, is erased, or becomes hidden.
    (overlay-put ov 'kitty-gfx-heading-emitted t)
    (let ((beg (overlay-start ov))
          (end (overlay-end ov)))
      (when (and beg end)
        (overlay-put ov 'display (make-string (- end beg) ?\s))))))

(defun kitty-gfx--erase-heading-at (row col cols rows)
  "Erase a heading multicell block at ROW, COL spanning COLS x ROWS cells.
Uses the ECH (Erase Character) escape `\\e[NX' which erases N characters
at the cursor without moving it — more efficient than writing spaces.
Disables DECAWM (auto-wrap) during erase to prevent wrapping artifacts
when the erase area extends near the right edge.  Erases each row of
the multicell block to ensure complete cleanup.
Adapted from mdfried's erase-character dance."
  (when (and row col cols rows (> cols 0) (> rows 0))
    (kitty-gfx--terminal-send
     (format "\e7\e[?7l\e[%d;%dH\e[%dX%s\e[?7h\e8"
             row col cols
             ;; For multi-row blocks (s > 1), erase additional rows
             (if (> rows 1)
                 (mapconcat
                  (lambda (r)
                    (format "\e[%d;%dH\e[%dX" (+ row r) col cols))
                  (number-sequence 1 (1- rows)) "")
               "")))))

(defun kitty-gfx--erase-heading (ov)
  "Erase the multicell block of heading overlay OV at its cached position.
Also restores the display property to the plain heading text so the
heading is visible again (instead of spaces that hid it for OSC 66)."
  (let ((row (overlay-get ov 'kitty-gfx-last-row))
        (col (overlay-get ov 'kitty-gfx-last-col))
        (cols (overlay-get ov 'kitty-gfx-cols))
        (rows (overlay-get ov 'kitty-gfx-rows)))
    (when (and row col)
      (kitty-gfx--log "erase-heading: L%d row=%d col=%d cols=%d rows=%d"
                       (overlay-get ov 'kitty-gfx-heading-level)
                       row col (or cols 0) (or rows 0))
      (kitty-gfx--erase-heading-at row col (or cols 0) (or rows 1))
      ;; Restore display to plain text so the heading is readable
      ;; until the next OSC 66 emission switches it back to spaces.
      ;; Clear emitted flag so next refresh re-emits if heading
      ;; becomes visible again.
      (overlay-put ov 'kitty-gfx-heading-emitted nil)
      ;; Restore display to plain text so the heading is readable
      ;; until the next OSC 66 emission switches it back to spaces.
      (let ((text (overlay-get ov 'kitty-gfx-heading-text)))
        (when text
          (overlay-put ov 'display (substring-no-properties text)))))))

(defun kitty-gfx-run-self-tests ()
  "Run batch-safe self-tests for kitty-graphics.
Tests pure logic functions that don't require a terminal.
Signals error on failure, prints success message otherwise."
  (interactive)
  ;; decompose-scale: identity
  (cl-assert (equal (kitty-gfx--decompose-scale 1.0) '(1 0 0))
             nil "decompose 1.0 failed")
  ;; decompose-scale: integer scales
  (cl-assert (equal (kitty-gfx--decompose-scale 2.0) '(2 0 0))
             nil "decompose 2.0 failed")
  (cl-assert (equal (kitty-gfx--decompose-scale 3.0) '(3 0 0))
             nil "decompose 3.0 failed")
  ;; decompose-scale: fractional scales produce valid params
  (let ((r15 (kitty-gfx--decompose-scale 1.5)))
    (cl-assert (= (nth 0 r15) 2) nil "1.5 cell-s should be 2")
    (cl-assert (> (nth 1 r15) 0) nil "1.5 should have fractional n")
    (cl-assert (> (nth 2 r15) (nth 1 r15)) nil "1.5: d must be > n"))
  (let ((r12 (kitty-gfx--decompose-scale 1.2)))
    (cl-assert (= (nth 0 r12) 2) nil "1.2 cell-s should be 2")
    (cl-assert (> (nth 1 r12) 0) nil "1.2 should have fractional n")
    (cl-assert (> (nth 2 r12) (nth 1 r12)) nil "1.2: d must be > n"))
  ;; decompose-scale: clamping
  (cl-assert (= (nth 0 (kitty-gfx--decompose-scale 0.5)) 1)
             nil "scale < 1.0 should clamp cell-s to 1")
  (cl-assert (= (nth 0 (kitty-gfx--decompose-scale 10.0)) 7)
             nil "scale > 7.0 should clamp cell-s to 7")
  ;; validate-osc66: valid params
  (cl-assert (kitty-gfx--validate-osc66 2 3 4 "hello")
             nil "valid params should pass")
  (cl-assert (kitty-gfx--validate-osc66 1 0 0 "test")
             nil "no-fraction params should pass")
  ;; validate-osc66: invalid params
  (cl-assert (not (kitty-gfx--validate-osc66 0 0 0 "x"))
             nil "s=0 should fail")
  (cl-assert (not (kitty-gfx--validate-osc66 8 0 0 "x"))
             nil "s=8 should fail")
  (cl-assert (not (kitty-gfx--validate-osc66 2 5 3 "x"))
             nil "n > d should fail")
  (cl-assert (not (kitty-gfx--validate-osc66 2 5 5 "x"))
             nil "n = d should fail")
  ;; validate-osc66: text length
  (cl-assert (kitty-gfx--validate-osc66 1 0 0 (make-string 4096 ?a))
             nil "4096 bytes should pass")
  (cl-assert (not (kitty-gfx--validate-osc66 1 0 0 (make-string 4097 ?a)))
             nil "4097 bytes should fail")
  ;; All decomposed scales should validate
  (dolist (scale '(1.0 1.2 1.5 2.0 2.5 3.0 4.0 5.0 6.0 7.0))
    (let ((params (kitty-gfx--decompose-scale scale)))
      (cl-assert (kitty-gfx--validate-osc66
                  (nth 0 params) (nth 1 params) (nth 2 params) "test")
                 nil (format "decomposed scale %.1f should validate" scale))))
  ;; heading-sgr: should return a string (falls back to bold in batch)
  (let ((sgr (kitty-gfx--heading-sgr 1)))
    (cl-assert (stringp sgr) nil "heading-sgr should return string")
    (cl-assert (string-prefix-p "\e[" sgr) nil "heading-sgr should be SGR escape"))
  ;; make-heading-overlay: creates overlay with correct properties
  (with-temp-buffer
    (insert "* Test Heading\nBody text\n")
    (let* ((kitty-gfx--dry-run t)
           (ov (kitty-gfx--make-heading-overlay 1 15 "Test Heading" 2.0 1)))
      (cl-assert (overlay-get ov 'kitty-gfx) nil "overlay should have kitty-gfx")
      (cl-assert (overlay-get ov 'kitty-gfx-heading) nil "should be heading type")
      (cl-assert (equal (overlay-get ov 'kitty-gfx-heading-text) "Test Heading")
                 nil "heading text mismatch")
      (cl-assert (= (overlay-get ov 'kitty-gfx-heading-scale) 2.0)
                 nil "heading scale mismatch")
      (cl-assert (= (overlay-get ov 'kitty-gfx-heading-level) 1)
                 nil "heading level mismatch")
      (cl-assert (= (overlay-get ov 'kitty-gfx-heading-cell-s) 2)
                 nil "cell-s should be 2 for scale 2.0")
      (cl-assert (= (overlay-get ov 'kitty-gfx-rows) 2)
                 nil "rows should match cell-s")
      (cl-assert (stringp (overlay-get ov 'display))
                 nil "should have display property")
      (cl-assert (stringp (overlay-get ov 'after-string))
                 nil "should have after-string for cell-s > 1")
      (delete-overlay ov)))
  ;; place-heading: verify escape sequence format in dry-run
  (with-temp-buffer
    (insert "* Hello World\nBody\n")
    (let* ((kitty-gfx--dry-run t)
           (kitty-gfx-debug t)
           (ov (kitty-gfx--make-heading-overlay 1 14 "Hello World" 2.0 1)))
      ;; Simulate cached position (normally set by refresh phase 1)
      (overlay-put ov 'kitty-gfx-last-row 5)
      (overlay-put ov 'kitty-gfx-last-col 1)
      (kitty-gfx--place-heading ov)
      ;; In dry-run, the escape was logged, not sent — verify overlay
      ;; properties are intact (the function reads but doesn't modify them)
      (cl-assert (= (overlay-get ov 'kitty-gfx-last-row) 5)
                 nil "place-heading should not modify cached position")
      (delete-overlay ov)))
  ;; erase-heading: verify it runs without error in dry-run
  (with-temp-buffer
    (insert "* Erase Test\nBody\n")
    (let* ((kitty-gfx--dry-run t)
           (ov (kitty-gfx--make-heading-overlay 1 13 "Erase Test" 2.0 1)))
      (overlay-put ov 'kitty-gfx-last-row 3)
      (overlay-put ov 'kitty-gfx-last-col 1)
      (kitty-gfx--erase-heading ov)
      ;; After erase, cached position is still set (caller clears it)
      (cl-assert (= (overlay-get ov 'kitty-gfx-last-row) 3)
                 nil "erase-heading should not modify cached position")
      (delete-overlay ov)))
  ;; erase-heading: no-op when no cached position
  (with-temp-buffer
    (insert "* No Pos\nBody\n")
    (let* ((kitty-gfx--dry-run t)
           (ov (kitty-gfx--make-heading-overlay 1 9 "No Pos" 1.5 2)))
      ;; No cached position — erase should be a no-op
      (kitty-gfx--erase-heading ov)
      (cl-assert (null (overlay-get ov 'kitty-gfx-last-row))
                 nil "erase with no pos should be a no-op")
      (delete-overlay ov)))
  (message "kitty-gfx: all self-tests passed"))

;;;; Heading overlay management

(defun kitty-gfx--make-heading-overlay (beg end text scale level)
  "Create overlay from BEG to END for heading TEXT at SCALE.
LEVEL is the org heading level (1-based).
SCALE is the visual scale factor (float, e.g., 1.5 for 1.5x).
Decomposed into OSC 66 parameters (s, n, d).  The cell scale s
determines the multicell block height (rows).  Vertical space is
reserved via an `after-string' of (s - 1) newlines.

Does NOT emit any OSC 66 -- that happens during refresh."
  (let* ((decomposed (kitty-gfx--decompose-scale scale))
         (cell-s (nth 0 decomposed))
         (frac-n (nth 1 decomposed))
         (frac-d (nth 2 decomposed))
         (rows cell-s)
         (cols (* (length text) cell-s))
         (ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'kitty-gfx t)
    (overlay-put ov 'kitty-gfx-heading t)
    (overlay-put ov 'kitty-gfx-heading-text text)
    (overlay-put ov 'kitty-gfx-heading-scale (float scale))
    (overlay-put ov 'kitty-gfx-heading-cell-s cell-s)
    (overlay-put ov 'kitty-gfx-heading-frac-n frac-n)
    (overlay-put ov 'kitty-gfx-heading-frac-d frac-d)
    (overlay-put ov 'kitty-gfx-heading-level level)
    (overlay-put ov 'kitty-gfx-cols cols)
    (overlay-put ov 'kitty-gfx-rows rows)
    ;; Show the plain heading text initially — no spaces yet.
    ;; The `display' property strips org markup (stars, links) so
    ;; the heading is readable even before OSC 66 renders.
    ;; After the first successful OSC 66 emission,
    ;; `kitty-gfx--place-heading' switches this to spaces so that
    ;; Emacs incremental redraws don't destroy the multicell block
    ;; (overwrite Rule 3).  This deferred approach prevents the
    ;; "invisible heading" failure mode where OSC 66 never fires.
    (overlay-put ov 'display text)
    ;; Reserve vertical space: the cell block is `cell-s' rows tall,
    ;; so we add (cell-s - 1) lines after the heading line.
    ;; Each line is filled with spaces so Emacs actively draws them
    ;; during incremental redisplay, naturally clearing ghost
    ;; multicell fragments via overwrite Rule 3.
    (when (> cell-s 1)
      (let ((spaceline (concat (make-string 200 ?\s) "\n")))
        (overlay-put ov 'after-string
                     (apply #'concat
                            (make-list (1- cell-s) spaceline)))))
    ;; High priority so kitty-gfx overlays win over org-modern etc.
    (overlay-put ov 'priority 100)
    ;; Remove overlay when heading text is edited; rescan will
    ;; re-create it with updated text.
    (overlay-put ov 'modification-hooks
                 (list #'kitty-gfx--heading-modified))
    (overlay-put ov 'insert-in-front-hooks
                 (list #'kitty-gfx--heading-modified))
    (push ov kitty-gfx--overlays)
    (kitty-gfx--log "make-heading-ov: L%d scale=%.2f s=%d n=%d d=%d text=%S beg=%d end=%d"
                     level (float scale) cell-s frac-n frac-d text beg end)
    ov))

(defun kitty-gfx--heading-modified (ov after &rest _args)
  "Modification hook for heading overlays.
When the heading text is edited (AFTER is non-nil), remove the
stale overlay and schedule a rescan to re-create it."
  (when (and after (overlay-buffer ov))
    (kitty-gfx--log "heading-modified: removing stale overlay at %d"
                     (overlay-start ov))
    (kitty-gfx--remove-overlay ov)
    ;; Debounced rescan — don't re-scan on every keystroke
    (when kitty-gfx--heading-rescan-timer
      (cancel-timer kitty-gfx--heading-rescan-timer))
    (setq kitty-gfx--heading-rescan-timer
          (run-at-time 0.2 nil
                       (lambda ()
                         (setq kitty-gfx--heading-rescan-timer nil)
                         (when (and kitty-graphics-mode
                                    (derived-mode-p 'org-mode))
                           (kitty-gfx--org-apply-heading-sizes)))))))

(defun kitty-gfx--org-apply-heading-sizes (&optional beg end)
  "Scan org headings in region BEG..END and create scaled overlays.
Only creates overlays for headings with a scale > 1.0 in
`kitty-gfx-heading-scales'.  Skips headings that already have
a kitty-gfx heading overlay."
  (when (derived-mode-p 'org-mode)
    (let ((start (or beg (point-min)))
          (stop (or end (point-max)))
          (count 0))
      (kitty-gfx--log "apply-heading-sizes: scanning %d..%d in %s"
                       start stop (buffer-name))
      (save-excursion
        (goto-char start)
        (while (re-search-forward org-heading-regexp stop t)
          (let* ((level (org-current-level))
                 (scale (alist-get level kitty-gfx-heading-scales))
                 (line-beg (line-beginning-position))
                 (line-end (line-end-position)))
            (when (and scale (> scale 1.0))
              ;; Skip if already has a heading overlay
              (unless (cl-some (lambda (ov)
                                 (overlay-get ov 'kitty-gfx-heading))
                               (overlays-in line-beg line-end))
                (let* ((raw (org-get-heading t t t t))
                       (text (if (fboundp 'org-link-display-format)
                                 (org-link-display-format raw)
                               raw)))
                  (kitty-gfx--make-heading-overlay
                   line-beg line-end text scale level)
                  (cl-incf count)))))))
      (kitty-gfx--log "apply-heading-sizes: created %d overlays" count)
      (when (> count 0)
        (kitty-gfx--schedule-refresh)))))

(defun kitty-gfx--org-remove-heading-sizes ()
  "Remove all heading size overlays from the current buffer."
  (let ((count 0))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'kitty-gfx-heading)
        (kitty-gfx--remove-overlay ov)
        (cl-incf count)))
    (kitty-gfx--log "remove-heading-sizes: removed %d" count)))

(defvar-local kitty-gfx--heading-saved-modes nil
  "Alist of (MODE . WAS-ACTIVE) saved when heading sizes are enabled.
Used to restore conflicting minor modes when heading sizes are disabled.")

(defun kitty-gfx--heading-disable-conflicting ()
  "Disable minor modes that conflict with OSC 66 heading rendering.
Saves their state for restoration by `kitty-gfx--heading-restore-modes'.
Conflicts: org-modern (overlay display props), org-appear (emphasis toggling),
org-indent (virtual indentation), visual-line-mode (line wrapping),
olivetti-mode (window margins shift position calculations)."
  (setq kitty-gfx--heading-saved-modes nil)
  (dolist (mode '(org-modern-mode org-appear-mode org-indent-mode visual-line-mode olivetti-mode))
    (when (and (boundp mode) (symbol-value mode))
      (push (cons mode t) kitty-gfx--heading-saved-modes)
      (funcall mode -1)
      (kitty-gfx--log "heading-preview: disabled %s" mode)))
  ;; Unfold all headings so positions are stable
  (when (fboundp 'org-fold-show-all)
    (org-fold-show-all))
  (when kitty-gfx--heading-saved-modes
    (kitty-gfx--log "heading-preview: saved modes=%S" kitty-gfx--heading-saved-modes)))

(defun kitty-gfx--heading-restore-modes ()
  "Restore minor modes that were disabled for heading rendering."
  (dolist (entry kitty-gfx--heading-saved-modes)
    (when (cdr entry)
      (funcall (car entry) 1)
      (kitty-gfx--log "heading-preview: restored %s" (car entry))))
  (setq kitty-gfx--heading-saved-modes nil))

;;;###autoload
(defun kitty-gfx-org-heading-sizes (&optional arg)
  "Toggle scaled heading sizes in the current org buffer.
Enters a clean preview mode: conflicting minor modes (org-modern,
org-appear, org-indent, visual-line-mode) are temporarily disabled
and headings are unfolded.  Toggling off restores previous state.
With prefix ARG, force remove heading sizes."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org-mode buffer"))
  (unless (eq kitty-gfx--text-sizing-support 'scale)
    (user-error "Terminal does not support text sizing (needs Kitty >= 0.40.0)"))
  (if (or arg (cl-some (lambda (ov) (overlay-get ov 'kitty-gfx-heading))
                        (overlays-in (point-min) (point-max))))
      (progn
        (kitty-gfx--org-remove-heading-sizes)
        (kitty-gfx--heading-restore-modes)
        (message "Heading sizes removed, modes restored"))
    (kitty-gfx--heading-disable-conflicting)
    (kitty-gfx--org-apply-heading-sizes)
    (message "Heading sizes applied (preview mode — conflicting modes disabled)")))

;;;; Position mapping

(defun kitty-gfx--in-folded-region-p (pos)
  "Non-nil if POS is inside a folded region (collapsed heading, block, etc.).
Checks org-fold (org 9.6+, text-property based) first, then falls
back to overlay-based invisibility for legacy org and outline-mode.
Ignores cosmetic invisibility like hidden link brackets (`org-link')."
  (let ((folded
         (or
          ;; org-fold (org 9.6+): text-property based folding.
          (and (fboundp 'org-fold-folded-p)
               (condition-case nil
                   (org-fold-folded-p pos)
                 (error nil)))
          ;; Legacy / non-org overlay-based folding (outline-mode, etc.)
          (let ((inv (get-char-property pos 'invisible)))
            (and inv (not (eq inv 'org-link)))))))
    (when folded
      (kitty-gfx--log "in-folded-region: pos=%d folded=%s" pos folded))
    folded))

(defun kitty-gfx--overlay-screen-pos (ov &optional win)
  "Return (TERM-ROW . TERM-COL) for overlay OV in WIN, or nil if hidden.
Coordinates are 1-indexed terminal positions.  WIN defaults to a window
showing OV's buffer, for interactive debug helpers.
Returns nil when the overlay position is outside the visible window
range, inside a folded region, or not visible on screen."
  (let* ((buf (overlay-buffer ov))
         (pos (overlay-start ov))
         (win (and buf
                   (or (and (window-live-p win)
                            (eq (window-buffer win) buf)
                            win)
                       (get-buffer-window buf)))))
    ;; Fast path: skip entirely if no window, no position, or
    ;; buffer position is outside the visible window range.
    ;; This avoids expensive posn-at-point and fold checks.
    (when (and win pos
               (<= (window-start win) pos)
               (<= pos (window-end win t))
               (pos-visible-in-window-p pos win)
               ;; Check structural folding (outline, org-fold).
               ;; Single check — result used for both log and gate.
               (not (kitty-gfx--in-folded-region-p pos)))
      ;; posn-col-row returns coordinates relative to the window BODY
      ;; (text area).  Use window-body-edges to convert to frame coords.
      ;; body-left accounts for margins/fringes; body-top accounts for
      ;; header-line.  +1 converts 0-based frame coords to 1-based terminal.
      (let* ((body (window-body-edges win))
             (body-left (nth 0 body))
             (body-top (nth 1 body))
             (win-pos (posn-at-point pos win)))
        (when win-pos
          (let* ((col-row (posn-col-row win-pos))
                 (row (cdr col-row))
                 (posn-col (car col-row))
                 (posn-xy (posn-x-y win-pos))
                 ;; `posn-col-row' is derived from pixel coordinates and can
                 ;; report the position after an overlay's `display' string
                 ;; rather than the overlay's logical start.  That is exactly
                 ;; the wrong edge for Sixel placement: the terminal graphic
                 ;; must be emitted at the top-left of the reserved cells.
                 ;; In terminal Emacs text cells are fixed-width, so the
                 ;; buffer column at POS is the reliable horizontal anchor.
                 (buffer-col (save-excursion
                               (goto-char pos)
                               (current-column)))
                 (visual-col (max 0 (- buffer-col (window-hscroll win)))))
            (kitty-gfx--log "screen-pos-detail: pid=%s posn-col=%d buffer-col=%d visual-col=%d posn-row=%d posn-xy=%S body-left=%d body-top=%d"
                            (overlay-get ov 'kitty-gfx-pid) posn-col buffer-col
                            visual-col row posn-xy body-left body-top)
            (when col-row
              (let ((result (cons (+ body-top row 1) (+ body-left visual-col 1))))
                (kitty-gfx--log "screen-pos: pid=%s pos=%d win=%s -> row=%d col=%d"
                                (overlay-get ov 'kitty-gfx-pid) pos win
                                (car result) (cdr result))
                result))))))))

;;;; Refresh cycle

(defun kitty-gfx--emit-heading-overlays ()
  "Phase 2: emit OSC 66 for visible heading overlays that need it.
Skips headings already emitted at their current position and
detects row collisions — if two headings would occupy overlapping
terminal rows, the later one is skipped to prevent multicell
block corruption."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((occupied (make-hash-table :test 'eql)))
          ;; First pass: mark rows occupied by already-emitted headings
          (dolist (ov kitty-gfx--overlays)
            (when (and (overlay-get ov 'kitty-gfx-heading)
                       (overlay-get ov 'kitty-gfx-heading-emitted)
                       (overlay-get ov 'kitty-gfx-last-row))
              (let ((row (overlay-get ov 'kitty-gfx-last-row))
                    (rows (or (overlay-get ov 'kitty-gfx-rows) 1)))
                (dotimes (r rows)
                  (puthash (+ row r) t occupied)))))
          ;; Second pass: emit new headings, checking for row conflicts
          (dolist (ov kitty-gfx--overlays)
            (when (and (overlay-get ov 'kitty-gfx-heading)
                       (overlay-get ov 'kitty-gfx-last-row)
                       (not (overlay-get ov 'kitty-gfx-heading-emitted)))
              (let* ((row (overlay-get ov 'kitty-gfx-last-row))
                     (rows (or (overlay-get ov 'kitty-gfx-rows) 1))
                     (conflict nil))
                ;; Check if any target row is already occupied
                (dotimes (r rows)
                  (when (gethash (+ row r) occupied)
                    (setq conflict t)))
                (if conflict
                    (kitty-gfx--log "emit-heading: SKIP L%d row=%d (row conflict)"
                                     (overlay-get ov 'kitty-gfx-heading-level) row)
                  ;; No conflict — place and mark rows
                  (dotimes (r rows)
                    (puthash (+ row r) t occupied))
                  (kitty-gfx--place-heading ov))))))))))

(defun kitty-gfx--refresh ()
  "Re-place all visible images after redisplay using direct placements.
Relies on placement IDs (p=PID) — re-placing with the same PID
replaces the previous placement without needing to delete first.
Caches last position per overlay to skip redundant re-placements.
Deletes placements for overlays that scrolled out of view.
All terminal output is wrapped in synchronized output (BSU/ESU)
to prevent flicker."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    ;; Force redisplay so posn-at-point sees up-to-date pixel positions
    ;; after display property changes (e.g., org-toggle-inline-images
    ;; creating multi-line blank overlays).
    (redisplay t)
    ;; Re-query cell size if invalidated (e.g., after terminal resize)
    (unless (and kitty-gfx--cell-pixel-width kitty-gfx--cell-pixel-height)
      (kitty-gfx--query-cell-size))
    (let ((total-overlays 0)
          (placed 0)
          (hidden 0)
          (pruned 0))
      (kitty-gfx--log "refresh: begin")
      (kitty-gfx--sync-begin)
      (unwind-protect
          (walk-windows
           (lambda (win)
             (with-current-buffer (window-buffer win)
               (when kitty-gfx--overlays
                 ;; A single overlay can be visible in multiple windows showing
                 ;; the same buffer.  Its legacy last-row/last-col properties
                 ;; mirror the placement for the window currently being
                 ;; refreshed; per-window placement tracking below keeps the
                 ;; individual terminal regions deletable when one window later
                 ;; disappears.
                 (dolist (ov kitty-gfx--overlays)
                   (let ((placement (kitty-gfx--image-placement ov win)))
                     (unless (overlay-get ov 'kitty-gfx-heading)
                       (overlay-put ov 'kitty-gfx-last-row
                                    (plist-get (cdr placement) :row))
                       (overlay-put ov 'kitty-gfx-last-col
                                    (plist-get (cdr placement) :col)))))
                 ;; Prune dead overlays (overlay-buffer returns nil)
                 (let ((before (length kitty-gfx--overlays)))
                   (setq kitty-gfx--overlays
                         (cl-delete-if-not #'overlay-buffer kitty-gfx--overlays))
                   (let ((removed (- before (length kitty-gfx--overlays))))
                     (when (> removed 0)
                       (cl-incf pruned removed)
                       (kitty-gfx--log "refresh: pruned %d dead overlays from %s"
                                       removed (buffer-name)))))
                 (let* ((edges (window-edges win))
                        (win-bottom (nth 3 edges)))
                   (kitty-gfx--log "refresh: win=%s buf=%s overlays=%d bottom=%d"
                                   win (buffer-name) (length kitty-gfx--overlays) win-bottom)
                   (dolist (ov kitty-gfx--overlays)
                     (cl-incf total-overlays)
                     (kitty-gfx--refresh-overlay ov win win-bottom)
                     (if (overlay-get ov 'kitty-gfx-last-row)
                         (cl-incf placed)
                       (cl-incf hidden)))))
               ;; Refresh mpv video overlay position
               (kitty-gfx--refresh-mpv-overlay)))
           nil 'visible)
        ;; Phase 2: emit OSC 66 for all visible heading overlays.
        ;; This runs AFTER all posn-at-point queries (phase 1) to
        ;; prevent Emacs mini-redraws from destroying freshly-placed
        ;; multicell blocks.  Headings are stateless — always re-emit.
        (kitty-gfx--emit-heading-overlays)
        (kitty-gfx--sync-end))
      (kitty-gfx--log "refresh: done total=%d placed=%d hidden=%d pruned=%d"
                       total-overlays placed hidden pruned))))

(defun kitty-gfx--refresh-overlay (ov win win-bottom)
  "Refresh a single overlay OV in WIN.
WIN-BOTTOM is WIN's bottom edge.  Dispatches to heading or image
refresh based on overlay type."
  (if (overlay-get ov 'kitty-gfx-heading)
      ;; Heading overlay — phase 1: compute position + erase if moved.
      ;; OSC 66 emission happens in phase 2 (kitty-gfx--emit-heading-overlays).
      (kitty-gfx--refresh-heading-overlay ov win win-bottom)
  ;; Image overlay refresh
  (let* ((pos (kitty-gfx--overlay-screen-pos ov win))
         (rows (overlay-get ov 'kitty-gfx-rows))
         (cols (overlay-get ov 'kitty-gfx-cols))
         (placement (kitty-gfx--image-placement ov win))
         (placement-data (cdr placement))
         (last-row (plist-get placement-data :row))
         (last-col (plist-get placement-data :col)))
    (let ((pid (overlay-get ov 'kitty-gfx-pid))
          (id (overlay-get ov 'kitty-gfx-id)))
      (if (and pos
               ;; Start row is on screen
               (<= (car pos) win-bottom)
               ;; Image must fit: start + rows must not exceed win-bottom.
               ;; This prevents placing images that overflow the terminal
               ;; and cause visual corruption.
               (<= (+ (car pos) rows -1) win-bottom))
          ;; Visible and fits — place if position changed
          (let ((new-row (car pos))
                (new-col (cdr pos)))
            (if (and (eql new-row last-row)
                     (eql new-col last-col))
                (kitty-gfx--log "refresh-ov: pid=%d unchanged at row=%d col=%d"
                                pid new-row new-col)
              (kitty-gfx--log "refresh-ov: pid=%d moved %s -> row=%d col=%d"
                              pid
                              (if last-row (format "row=%d,col=%d" last-row last-col) "nil")
                              new-row new-col)
              (overlay-put ov 'kitty-gfx-last-row new-row)
              (overlay-put ov 'kitty-gfx-last-col new-col)
              (kitty-gfx--record-image-placement ov win new-row new-col cols rows pid)
              (setq placement (kitty-gfx--image-placement ov win)
                    pid (plist-get (cdr placement) :pid))
              (funcall (kitty-gfx--backend-fn 'place)
                       ov id pid cols rows new-row new-col)))
        ;; Not visible or overflows — delete if was placed in this window
        (when placement
          (kitty-gfx--log "refresh-ov: pid=%d hiding in win=%s (was row=%d col=%d)"
                          pid win last-row last-col)
          (kitty-gfx--delete-image-placement ov placement)
          (kitty-gfx--forget-image-placement ov win)
          (overlay-put ov 'kitty-gfx-last-row nil)
          (overlay-put ov 'kitty-gfx-last-col nil)))))))

(defun kitty-gfx--refresh-heading-overlay (ov win win-bottom)
  "Refresh heading overlay OV in WIN.
WIN-BOTTOM is WIN's bottom edge.  Phase 1 of two-phase heading
refresh: computes screen position, erases old multicell block if
heading moved or became hidden, and caches the new position.  Does
NOT emit OSC 66 — that happens in phase 2
(`kitty-gfx--emit-heading-overlays') to avoid posn-at-point redraws
destroying freshly-placed blocks."
  (let ((pos (kitty-gfx--overlay-screen-pos ov win))
        (rows (overlay-get ov 'kitty-gfx-rows))
        (last-row (overlay-get ov 'kitty-gfx-last-row))
        (last-col (overlay-get ov 'kitty-gfx-last-col)))
    (if (and pos
             (<= (car pos) win-bottom)
             (<= (+ (car pos) rows -1) win-bottom))
        ;; Visible — erase old position if moved, cache new
        (let ((new-row (car pos))
              (new-col (cdr pos)))
          (when (and last-row
                     (not (and (eql new-row last-row)
                               (eql new-col last-col))))
            ;; Heading moved — erase at old position
            (kitty-gfx--erase-heading ov))
          (overlay-put ov 'kitty-gfx-last-row new-row)
          (overlay-put ov 'kitty-gfx-last-col new-col)
          (kitty-gfx--log "refresh-heading: L%d visible at row=%d col=%d"
                           (overlay-get ov 'kitty-gfx-heading-level)
                           new-row new-col))
      ;; Not visible — erase if was placed, clear cache
      (when last-row
        (kitty-gfx--erase-heading ov))
      (overlay-put ov 'kitty-gfx-last-row nil)
      (overlay-put ov 'kitty-gfx-last-col nil))))

(defvar kitty-gfx--refresh-pending nil
  "Non-nil if a refresh was requested during the cooldown period.")

(defun kitty-gfx--schedule-refresh ()
  "Schedule an image refresh using leading-edge debounce.
On the first call, refresh is scheduled via `run-at-time' 0 (fires
after the current redisplay completes) and a cooldown timer starts
\(duration `kitty-gfx-render-delay').  Calls during cooldown are
suppressed but flagged; when the cooldown expires a single trailing
refresh fires to capture the final state."
  (if kitty-gfx--render-timer
      ;; Cooldown active — flag that another refresh is wanted.
      (setq kitty-gfx--refresh-pending t)
    ;; No cooldown — schedule refresh after redisplay + start cooldown.
    ;; run-at-time 0 ensures posn-at-point sees up-to-date positions.
    (setq kitty-gfx--refresh-pending nil)
    (run-at-time 0 nil #'kitty-gfx--refresh)
    (setq kitty-gfx--render-timer
          (run-at-time kitty-gfx-render-delay nil
                       (lambda ()
                         (setq kitty-gfx--render-timer nil)
                         (when kitty-gfx--refresh-pending
                           (setq kitty-gfx--refresh-pending nil)
                           (kitty-gfx--refresh)))))))

(defun kitty-gfx--on-window-scroll (win _new-start)
  "Handle window scroll for image refresh."
  (when (buffer-local-value 'kitty-gfx--overlays (window-buffer win))
    (kitty-gfx--log "on-scroll: win=%s buf=%s" win (buffer-name (window-buffer win)))
    (kitty-gfx--schedule-refresh)))

(defun kitty-gfx--on-buffer-change (_frame-or-window)
  "Handle buffer change for image refresh.
Deletes placements for buffers no longer visible in any window,
then invalidates position caches and schedules a refresh."
  (kitty-gfx--log "on-buffer-change: cleaning up non-visible placements")
  ;; Find which buffers are currently visible
  (let ((visible-bufs nil))
    (walk-windows (lambda (w) (push (window-buffer w) visible-bufs))
                  nil 'visible)
    (kitty-gfx--log "on-buffer-change: visible-bufs=(%s)"
                    (mapconcat #'buffer-name visible-bufs ", "))
    ;; Delete placements for buffers that are no longer in any window
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and kitty-gfx--overlays
                   (not (memq buf visible-bufs)))
          (kitty-gfx--log "on-buffer-change: deleting placements for hidden buf=%s"
                          (buffer-name))
          (dolist (ov kitty-gfx--overlays)
            (when (overlay-buffer ov)
              (if (overlay-get ov 'kitty-gfx-heading)
                  ;; Heading overlay — erase multicell block to prevent
                  ;; ghost artifacts if the new buffer doesn't fully
                  ;; overwrite the heading's terminal cells.
                  (when (overlay-get ov 'kitty-gfx-last-row)
                    (kitty-gfx--erase-heading ov)
                    (overlay-put ov 'kitty-gfx-last-row nil)
                    (overlay-put ov 'kitty-gfx-last-col nil))
                ;; Image overlay — delete all terminal placements, including
                ;; multiple windows that were showing this buffer.
                (kitty-gfx--delete-image-placements ov))))))))
  ;; Reset cache for visible buffers so they re-place correctly.
  ;; Heading overlays preserve cache (same rationale as on-window-change).
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (dolist (ov kitty-gfx--overlays)
        (when (and (overlay-buffer ov)
                   (not (overlay-get ov 'kitty-gfx-heading)))
          (overlay-put ov 'kitty-gfx-placements nil)
          (overlay-put ov 'kitty-gfx-last-row nil)
          (overlay-put ov 'kitty-gfx-last-col nil)))))
  ;; Longer debounce: cancel any fast leading-edge cooldown and
  ;; schedule a 0.1s delayed refresh to let buffer switch settle.
  (when kitty-gfx--render-timer
    (cancel-timer kitty-gfx--render-timer))
  (setq kitty-gfx--refresh-pending nil
        kitty-gfx--render-timer
        (run-at-time 0.1 nil
                     (lambda ()
                       (setq kitty-gfx--render-timer nil)
                       (kitty-gfx--refresh)))))

(defun kitty-gfx--on-window-change (_frame)
  "Handle window configuration change for image refresh.
Invalidates cell pixel size, deletes stale image placements, then
clears image position caches so the refresh cycle re-places images
at their new positions.  Uses a longer debounce than normal refresh
to let Emacs finish window layout transitions (e.g., when closing a
split, Emacs briefly shows two windows for the same buffer before
settling to one)."
  (kitty-gfx--log "on-window-change: deleting stale placements and invalidating cell size")
  (setq kitty-gfx--cell-pixel-width nil
        kitty-gfx--cell-pixel-height nil)
  ;; Delete image placements before clearing their cached positions.
  ;; Window splits/resizes can move an image from the middle of the old
  ;; window to the center of the new pane(s).  A buffer can also be shown
  ;; in multiple windows, and closing one of those windows leaves terminal
  ;; pixels that no remaining window can discover from `posn-at-point'.
  ;; Therefore image placements are tracked and deleted per window before
  ;; the cache is reset.  Some terminals do not reliably erase an old
  ;; direct placement when it is re-placed at a different geometry, and
  ;; Sixel is stateless and must be explicitly overwritten.
  ;;
  ;; Heading overlays PRESERVE their cache — the refresh cycle needs
  ;; old→new position comparison to erase multicell blocks properly.
  (kitty-gfx--sync-begin)
  (unwind-protect
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (dolist (ov kitty-gfx--overlays)
            (when (and (overlay-buffer ov)
                       (not (overlay-get ov 'kitty-gfx-heading)))
              (kitty-gfx--delete-image-placements ov)))))
    (kitty-gfx--sync-end))
  ;; Longer debounce: cancel any fast leading-edge cooldown and
  ;; schedule a 0.1s delayed refresh to let window layout settle.
  (when kitty-gfx--render-timer
    (cancel-timer kitty-gfx--render-timer))
  (setq kitty-gfx--refresh-pending nil
        kitty-gfx--render-timer
        (run-at-time 0.1 nil
                     (lambda ()
                       (setq kitty-gfx--render-timer nil)
                       (kitty-gfx--refresh)))))

(defun kitty-gfx--on-redisplay ()
  "Post-command hook to schedule image refresh."
  (kitty-gfx--schedule-refresh))

;;;; Image processing

(defun kitty-gfx--read-file-base64 (file)
  "Read FILE and return base64-encoded string."
  (kitty-gfx--log "read-file-base64: %s size=%s"
                   file (ignore-errors (file-attribute-size (file-attributes file))))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (base64-encode-region (point-min) (point-max) t)
    (let ((result (buffer-string)))
      (kitty-gfx--log "read-file-base64: done b64-len=%d" (length result))
      result)))

(defun kitty-gfx--image-pixel-size (file)
  "Return (WIDTH . HEIGHT) in pixels for image FILE, or nil."
  (let ((identify (or (executable-find "magick")
                      (executable-find "identify"))))
    (when identify
      (when (string-suffix-p "identify" identify)
        (kitty-gfx--log "image-pixel-size: WARNING deprecated `identify' binary resolved: %s (use `magick' instead)" identify))
      (with-temp-buffer
        (let ((args (if (string-suffix-p "magick" identify)
                        (list identify nil '(t nil) nil "identify" "-format" "%w %h"
                              (concat file "[0]"))  ; first frame only
                      (list identify nil '(t nil) nil "-format" "%w %h"
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
Returns FILE unchanged if it is already PNG.
Returns nil if FILE is not PNG and ImageMagick is unavailable or
conversion fails — callers must handle nil gracefully."
  (if (string-suffix-p ".png" file t)
      (progn
        (kitty-gfx--log "convert-to-png: %s already PNG" file)
        file)
    (let ((convert (or (executable-find "magick")
                       (executable-find "convert"))))
      (if (not convert)
          (progn
            (kitty-gfx--log "convert-to-png: no ImageMagick, cannot convert %s" file)
            (message "kitty-gfx: %s requires ImageMagick for display"
                     (file-name-nondirectory file))
            nil)
        (let ((out (make-temp-file "kitty-gfx-" nil ".png")))
          (kitty-gfx--log "convert-to-png: %s -> %s via %s" file out convert)
          (let ((exit-code
                 (call-process convert nil nil nil file out)))
            (kitty-gfx--log "convert-to-png: exit-code=%s" exit-code)
            ;; Check that conversion produced a non-empty file
            (if (and (file-exists-p out)
                     (> (file-attribute-size (file-attributes out)) 0))
                (progn
                  (kitty-gfx--log "convert-to-png: success out-size=%d"
                                   (file-attribute-size (file-attributes out)))
                  out)
              (kitty-gfx--log "convert-to-png: FAILED (empty or missing output)")
              (ignore-errors (delete-file out))
              nil)))))))

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
      (kitty-gfx--log "alloc-id: WRAP next-id reset to 1")
      (setq kitty-gfx--next-id 1))
    (kitty-gfx--log "alloc-id: %d" id)
    id))

(defun kitty-gfx--cache-touch (file)
  "Move FILE to the front of the LRU list (most recently used)."
  (setq kitty-gfx--cache-lru
        (cons file (delete file kitty-gfx--cache-lru)))
  (kitty-gfx--log "cache-touch: %s (lru-len=%d)" (file-name-nondirectory file)
                   (length kitty-gfx--cache-lru)))

(defun kitty-gfx--cache-put (file image-id)
  "Store IMAGE-ID for FILE in cache, evicting LRU entries if needed."
  (kitty-gfx--log "cache-put: %s id=%d (cache-count=%d max=%d)"
                   (file-name-nondirectory file) image-id
                   (hash-table-count kitty-gfx--image-cache) kitty-gfx-cache-size)
  ;; Evict oldest entries if cache is full
  (while (and (> (hash-table-count kitty-gfx--image-cache)
                 (max 1 kitty-gfx-cache-size))
              kitty-gfx--cache-lru)
    (let* ((victim (car (last kitty-gfx--cache-lru)))
           (victim-id (gethash victim kitty-gfx--image-cache)))
      (when (and victim-id kitty-gfx--active-backend)
        (funcall (kitty-gfx--backend-fn 'cleanup) victim victim-id))
      (remhash victim kitty-gfx--image-cache)
      (setq kitty-gfx--cache-lru (butlast kitty-gfx--cache-lru))
      (kitty-gfx--log "cache-evict: %s id=%s (remaining=%d)"
                       (file-name-nondirectory victim) victim-id
                       (hash-table-count kitty-gfx--image-cache))))
  (puthash file image-id kitty-gfx--image-cache)
  (kitty-gfx--cache-touch file))

(defun kitty-gfx--cache-get (file)
  "Return cached image ID for FILE, or nil.  Moves FILE to front of LRU."
  (let ((id (gethash file kitty-gfx--image-cache)))
    (kitty-gfx--log "cache-get: %s -> %s" (file-name-nondirectory file)
                     (if id (format "id=%d (hit)" id) "nil (miss)"))
    (when id
      (kitty-gfx--cache-touch file))
    id))

(defun kitty-gfx--cache-remove (file)
  "Remove FILE from the cache and LRU list."
  (kitty-gfx--log "cache-remove: %s" (file-name-nondirectory file))
  (remhash file kitty-gfx--image-cache)
  (setq kitty-gfx--cache-lru (delete file kitty-gfx--cache-lru)))

(defun kitty-gfx--make-blank-display (cols rows)
  "Create a blank display string of COLS terminal columns x ROWS lines.
Each line is propertized with face `default' to prevent org-link
underline/color from bleeding through the overlay."
  (mapconcat (lambda (_) (propertize (make-string cols ?\s) 'face 'default))
             (number-sequence 1 rows) "\n"))

(defun kitty-gfx--make-overlay (beg end image-id cols rows file &optional reuse-pid)
  "Create overlay from BEG to END for image IMAGE-ID (COLS x ROWS).
FILE is the source file path (needed by some backends for re-encoding).
The overlay's display property shows blank space that the terminal
fills with the image via direct placement.
When REUSE-PID is non-nil, reuse that placement ID instead of
allocating a new one.  This lets the terminal atomically replace
the old placement (same PID, new dimensions/position) without a
delete step, avoiding visual glitches in some terminals."
  (let ((ov (make-overlay beg end nil t nil))
        (pid (or reuse-pid (kitty-gfx--alloc-placement-id))))
    (overlay-put ov 'display
                 (concat (kitty-gfx--make-blank-display cols rows) "\n"))
    (overlay-put ov 'face 'default)  ; override inherited faces (org-link underline etc.)
    (overlay-put ov 'kitty-gfx t)
    (overlay-put ov 'kitty-gfx-id image-id)
    (overlay-put ov 'kitty-gfx-pid pid)
    (overlay-put ov 'kitty-gfx-cols cols)
    (overlay-put ov 'kitty-gfx-rows rows)
    (overlay-put ov 'kitty-gfx-file file)
    ;; Don't set evaporate — zero-width overlays (beg==end) would be
    ;; deleted immediately if evaporate is set.
    (push ov kitty-gfx--overlays)
    (kitty-gfx--log "make-overlay: id=%d pid=%d cols=%d rows=%d beg=%d end=%d buf=%s (total=%d)"
                     image-id pid cols rows beg end (buffer-name) (length kitty-gfx--overlays))
    ov))

(defun kitty-gfx--image-placement (ov win)
  "Return OV's recorded image placement for WIN, or nil."
  (assq win (overlay-get ov 'kitty-gfx-placements)))

(defun kitty-gfx--record-image-placement (ov win row col cols rows pid)
  "Record that OV is placed in WIN at ROW COL with COLS ROWS and PID."
  (unless (kitty-gfx--image-placement ov win)
    (setq pid (kitty-gfx--alloc-placement-id)))
  (let ((placements (assq-delete-all win (copy-sequence
                                          (overlay-get ov 'kitty-gfx-placements)))))
    (overlay-put ov 'kitty-gfx-placements
                 (cons (cons win (list :row row :col col
                                       :cols cols :rows rows
                                       :pid pid))
                       placements))))

(defun kitty-gfx--forget-image-placement (ov win)
  "Forget OV's recorded image placement for WIN."
  (overlay-put ov 'kitty-gfx-placements
               (assq-delete-all win (copy-sequence
                                     (overlay-get ov 'kitty-gfx-placements)))))

(defun kitty-gfx--delete-image-placement (ov placement)
  "Delete one recorded image PLACEMENT for OV."
  (let* ((data (cdr placement))
         (id (overlay-get ov 'kitty-gfx-id))
         (pid (plist-get data :pid))
         (row (plist-get data :row))
         (col (plist-get data :col))
         (cols (plist-get data :cols))
         (rows (plist-get data :rows))
         (old-row (overlay-get ov 'kitty-gfx-last-row))
         (old-col (overlay-get ov 'kitty-gfx-last-col))
         (old-cols (overlay-get ov 'kitty-gfx-cols))
         (old-rows (overlay-get ov 'kitty-gfx-rows)))
    (when (and id pid row col cols rows kitty-gfx--active-backend)
      ;; Sixel deletion is position-based and reads these properties from OV;
      ;; Kitty deletion ignores them and deletes by PID.  Temporarily bind the
      ;; recorded geometry so both backends can share the same helper.
      (unwind-protect
          (progn
            (overlay-put ov 'kitty-gfx-last-row row)
            (overlay-put ov 'kitty-gfx-last-col col)
            (overlay-put ov 'kitty-gfx-cols cols)
            (overlay-put ov 'kitty-gfx-rows rows)
            (funcall (kitty-gfx--backend-fn 'delete) ov id pid))
        (overlay-put ov 'kitty-gfx-last-row old-row)
        (overlay-put ov 'kitty-gfx-last-col old-col)
        (overlay-put ov 'kitty-gfx-cols old-cols)
        (overlay-put ov 'kitty-gfx-rows old-rows)))))

(defun kitty-gfx--delete-image-placements (ov)
  "Delete all recorded terminal placements for image overlay OV."
  (let ((placements (overlay-get ov 'kitty-gfx-placements)))
    (if placements
        (dolist (placement placements)
          (condition-case err
              (kitty-gfx--delete-image-placement ov placement)
            (error
             (kitty-gfx--log "delete-image-placements: error: %s"
                              (error-message-string err)))))
      ;; Backward-compatible fallback for overlays created before per-window
      ;; placement tracking or for callers that only populated last-row/col.
      (let ((id (overlay-get ov 'kitty-gfx-id))
            (pid (overlay-get ov 'kitty-gfx-pid)))
        (when (and id pid kitty-gfx--active-backend
                   (overlay-get ov 'kitty-gfx-last-row))
          (condition-case err
              (funcall (kitty-gfx--backend-fn 'delete) ov id pid)
            (error
             (kitty-gfx--log "delete-image-placements: fallback error: %s"
                              (error-message-string err))))))))
  (overlay-put ov 'kitty-gfx-placements nil)
  (overlay-put ov 'kitty-gfx-last-row nil)
  (overlay-put ov 'kitty-gfx-last-col nil))

(defun kitty-gfx--delete-placement (id pid)
  "Delete a specific placement PID of image ID from terminal.
Uses d=i (lowercase) to remove the placement but keep stored image
data so the image can be re-placed without retransmitting."
  (kitty-gfx--log "delete-placement: id=%d pid=%d" id pid)
  (kitty-gfx--terminal-send
   (format "\e_Ga=d,d=i,i=%d,p=%d,q=2\e\\" id pid)))

(defun kitty-gfx--remove-overlay (ov &optional keep-placement)
  "Remove overlay OV and delete its placement from terminal.
When KEEP-PLACEMENT is non-nil, skip the terminal-side delete so
the placement ID can be reused by a subsequent overlay (avoids
visual glitches from delete+re-place sequences in some terminals)."
  (let ((id (overlay-get ov 'kitty-gfx-id))
        (pid (overlay-get ov 'kitty-gfx-pid)))
    (when keep-placement
      (overlay-put ov 'kitty-gfx-placements nil))
    (kitty-gfx--log "remove-overlay: id=%s pid=%s keep=%s buf=%s"
                     id pid keep-placement
                     (when (overlay-buffer ov) (buffer-name (overlay-buffer ov))))
    (when (overlay-buffer ov)
      (unless keep-placement
        (kitty-gfx--delete-image-placements ov))
      (delete-overlay ov))
    (setq kitty-gfx--overlays (delq ov kitty-gfx--overlays))
    (kitty-gfx--log "remove-overlay: done (remaining=%d)" (length kitty-gfx--overlays))))

;;;; Public API

;;;###autoload
(defun kitty-gfx-display-image (file &optional beg end max-cols max-rows)
  "Display image FILE in the current buffer.
BEG/END span the overlay region.  MAX-COLS/MAX-ROWS limit size."
  (interactive "fImage file: ")
  (unless kitty-gfx--active-backend
    (user-error "Terminal does not support graphics"))
  (let* ((max-c (or max-cols kitty-gfx-max-width))
         (max-r (or max-rows kitty-gfx-max-height))
         (abs-file (expand-file-name file))
         (cached-id (kitty-gfx--cache-get abs-file))
         (image-id (or cached-id (kitty-gfx--alloc-id)))
         ;; Always compute dimensions fresh — they depend on max-cols/rows
         ;; which vary by display context (org inline vs image-mode vs dired).
         (dims (let ((px (kitty-gfx--image-pixel-size abs-file)))
                 (if px
                     (kitty-gfx--compute-cell-dims
                      (car px) (cdr px) max-c max-r)
                   (cons (min 40 max-c) (min 15 max-r)))))
         (cols (car dims))
         (rows (cdr dims))
         (start (or beg (point)))
         (stop (or end (point))))
    (kitty-gfx--log "display-image: file=%s id=%d cols=%d rows=%d beg=%s end=%s cached=%s"
                    abs-file image-id cols rows start stop (if cached-id "yes" "no"))
    ;; Prepare image if not cached (backend-specific: transmit or validate)
    (unless cached-id
      (when (funcall (kitty-gfx--backend-fn 'prepare) abs-file image-id)
        (kitty-gfx--cache-put abs-file image-id)))
    ;; Create overlay with blank space (even for cached images, dims are fresh)
    (when (or cached-id (gethash abs-file kitty-gfx--image-cache))
      (kitty-gfx--make-overlay start stop image-id cols rows abs-file)
      ;; Schedule initial render
      (kitty-gfx--schedule-refresh))))

(defun kitty-gfx--display-image-centered (file max-cols max-rows
                                                &optional win-cols win-rows
                                                scale reuse-pid)
  "Display FILE centered in the current buffer.
MAX-COLS and MAX-ROWS are the maximum image dimensions at scale 1.0.
WIN-COLS and WIN-ROWS are the available window dimensions for centering;
they default to MAX-COLS and MAX-ROWS if not provided.
SCALE (default 1.0) multiplies the computed cell dims for zoom.
REUSE-PID, when non-nil, is passed to `kitty-gfx--make-overlay' so the
new placement atomically replaces the old one (same PID, new dims).
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
    (kitty-gfx--log "centered: file=%s px=%S base=%S scale=%.2f img=%dx%d win=%dx%d pad=h%d,v%d"
                     (file-name-nondirectory abs-file) px base-dims s
                     img-cols img-rows wc wr h-pad v-pad)
    ;; Vertical centering: newlines before the image
    (dotimes (_ v-pad) (insert "\n"))
    ;; Horizontal centering: spaces to shift the overlay start column
    (insert (make-string h-pad ?\s))
    (let* ((img-start (point))
           (_ (insert "\n"))
           ;; Ensure image is transmitted (cache stores only the ID)
           (cached-id (kitty-gfx--cache-get abs-file))
           (image-id (or cached-id (kitty-gfx--alloc-id))))
      (unless cached-id
        (when (funcall (kitty-gfx--backend-fn 'prepare) abs-file image-id)
          (kitty-gfx--cache-put abs-file image-id)))
      ;; Create overlay at the scaled dimensions.
      (when (or cached-id (gethash abs-file kitty-gfx--image-cache))
        (kitty-gfx--make-overlay img-start (point) image-id
                                  img-cols img-rows abs-file reuse-pid)
        (kitty-gfx--schedule-refresh)))))

(defun kitty-gfx-remove-images (&optional beg end)
  "Remove all kitty-gfx overlays in region BEG..END (defaults to whole buffer)."
  (interactive)
  (let ((count 0))
    (dolist (ov (overlays-in (or beg (point-min)) (or end (point-max))))
      (when (overlay-get ov 'kitty-gfx)
        (cl-incf count)
        (kitty-gfx--remove-overlay ov)))
    (kitty-gfx--log "remove-images: removed %d overlays from %s" count (buffer-name))))

(defun kitty-gfx-clear-all ()
  "Remove all images from all buffers and the terminal."
  (interactive)
  (kitty-gfx--log "clear-all: begin (cache=%d lru=%d)"
                   (hash-table-count kitty-gfx--image-cache) (length kitty-gfx--cache-lru))
  ;; Walk all buffers, not just current
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when kitty-gfx--overlays
        (kitty-gfx-remove-images))))
  (when kitty-gfx--active-backend
    (funcall (kitty-gfx--backend-fn 'cleanup-all)))
  (clrhash kitty-gfx--image-cache)
  (setq kitty-gfx--cache-lru nil)
  (setq kitty-gfx--next-id 1)
  (setq kitty-gfx--next-placement-id 1)
  (kitty-gfx--log "clear-all: done (reset IDs to 1)"))

;;;; Debug commands

(defun kitty-gfx-debug-state ()
  "Dump all critical kitty-gfx state to *kitty-gfx-debug-state* buffer."
  (interactive)
  (let ((buf (get-buffer-create "*kitty-gfx-debug-state*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "=== kitty-gfx debug state ===\n")
      (insert (format "Timestamp: %s\n" (format-time-string "%Y-%m-%d %H:%M:%S.%3N")))
      (insert (format "Backend: %s\n" kitty-gfx--active-backend))
      (insert (format "Cell pixel size: %sx%s\n"
                      kitty-gfx--cell-pixel-width kitty-gfx--cell-pixel-height))
      (insert (format "Text sizing: %s\n" kitty-gfx--text-sizing-support))
      (insert (format "ImageMagick: magick=%s convert=%s identify=%s\n"
                      (executable-find "magick")
                      (executable-find "convert")
                      (executable-find "identify")))
      (insert (format "Next ID: %d  Next PID: %d\n"
                      kitty-gfx--next-id kitty-gfx--next-placement-id))
      (insert "\n--- Windows ---\n")
      (walk-windows
       (lambda (win)
         (let ((edges (window-edges win))
               (body (window-body-edges win)))
           (insert (format "  win=%s buf=%s edges=%S body=%S size=%dx%d\n"
                           win (buffer-name (window-buffer win))
                           edges body
                           (window-body-width win) (window-body-height win)))))
       nil 'visible)
      (insert "\n--- Overlays ---\n")
      (let ((count 0))
        (dolist (b (buffer-list))
          (let ((ovs (buffer-local-value 'kitty-gfx--overlays b)))
            (when ovs
              (dolist (ov ovs)
                (cl-incf count)
                (let ((alive (not (null (overlay-buffer ov))))
                      (heading-p (overlay-get ov 'kitty-gfx-heading)))
                  (insert (format "  [%d] buf=%s alive=%s type=%s cols=%s rows=%s\n"
                                  count (buffer-name b) alive
                                  (if heading-p "heading" "image")
                                  (overlay-get ov 'kitty-gfx-cols)
                                  (overlay-get ov 'kitty-gfx-rows)))
                  (if heading-p
                      (insert (format "       text=%S scale=%.2f level=%s s=%s\n"
                                      (overlay-get ov 'kitty-gfx-heading-text)
                                      (or (overlay-get ov 'kitty-gfx-heading-scale) 0)
                                      (overlay-get ov 'kitty-gfx-heading-level)
                                      (overlay-get ov 'kitty-gfx-heading-cell-s)))
                    (insert (format "       id=%s pid=%s file=%s\n"
                                    (overlay-get ov 'kitty-gfx-id)
                                    (overlay-get ov 'kitty-gfx-pid)
                                    (overlay-get ov 'kitty-gfx-file))))
                  (insert (format "       buf-pos=%s-%s last-row=%s last-col=%s\n"
                                  (and alive (overlay-start ov))
                                  (and alive (overlay-end ov))
                                  (overlay-get ov 'kitty-gfx-last-row)
                                  (overlay-get ov 'kitty-gfx-last-col)))
                  (when alive
                    (let ((screen-pos (kitty-gfx--overlay-screen-pos ov)))
                      (insert (format "       computed-screen-pos=%S\n" screen-pos)))))))))
        (insert (format "\nTotal overlays: %d\n" count)))
      (insert "\n--- Image cache ---\n")
      (insert (format "  entries=%d lru-len=%d\n"
                      (hash-table-count kitty-gfx--image-cache)
                      (length kitty-gfx--cache-lru)))
      (maphash (lambda (k v) (insert (format "  %s -> %s\n" k v)))
               kitty-gfx--image-cache)
      (insert "\n--- Sixel cache ---\n")
      (insert (format "  entries=%d\n" (hash-table-count kitty-gfx--sixel-cache)))
      (maphash (lambda (k v) (insert (format "  %s -> %s\n" k v)))
               kitty-gfx--sixel-cache))
    (display-buffer buf)
    (message "kitty-gfx: debug state dumped to *kitty-gfx-debug-state*")))

(defun kitty-gfx-debug-overlay-at-point ()
  "Show deep debug info for the kitty-gfx overlay at point."
  (interactive)
  (let ((found nil))
    (dolist (ov (overlays-at (point)))
      (when (overlay-get ov 'kitty-gfx-id)
        (setq found ov)))
    (if (not found)
        (message "kitty-gfx: no overlay at point")
      (let* ((id (overlay-get found 'kitty-gfx-id))
             (pid (overlay-get found 'kitty-gfx-pid))
             (cols (overlay-get found 'kitty-gfx-cols))
             (rows (overlay-get found 'kitty-gfx-rows))
             (file (overlay-get found 'kitty-gfx-file))
             (cw (or kitty-gfx--cell-pixel-width 8))
             (ch (or kitty-gfx--cell-pixel-height 16))
             (pixel-w (* (or cols 0) cw))
             (pixel-h (* (or rows 0) ch))
             (last-row (overlay-get found 'kitty-gfx-last-row))
             (last-col (overlay-get found 'kitty-gfx-last-col))
             (pos (overlay-start found))
             (win (selected-window))
             (win-pos (and pos (posn-at-point pos win)))
             (col-row (and win-pos (posn-col-row win-pos)))
             (edges (window-edges win))
             (body-edges (window-body-edges win))
             (buf-col (save-excursion
                        (goto-char pos)
                        (current-column)))
             (screen-pos (kitty-gfx--overlay-screen-pos found))
             (disp-prop (overlay-get found 'display))
             (disp-len (if (stringp disp-prop) (length disp-prop) nil)))
        (message (concat
                  "kitty-gfx overlay: id=%s pid=%s file=%s\n"
                  "  cols=%s rows=%s cell=%dx%d pixel=%dx%d\n"
                  "  posn-col-row=%S win-edges=%S body-edges=%S buf-col=%d\n"
                  "  computed-screen-pos=%S last-row=%s last-col=%s\n"
                  "  display-prop-len=%s")
                 id pid file
                 cols rows cw ch pixel-w pixel-h
                 col-row edges body-edges buf-col
                 screen-pos last-row last-col
                 disp-len)))))

;;;; Minor mode

;;;###autoload
(define-minor-mode kitty-graphics-mode
  "Display images in terminal Emacs via graphics protocol (Kitty or Sixel)."
  :global t
  :lighter (:eval (concat " KittyGfx["
                          (pcase kitty-gfx--active-backend
                            ('kitty "K")
                            ('sixel "S")
                            (_ "?"))
                          (if (eq kitty-gfx--text-sizing-support 'scale)
                              "+T" "")
                          "]"))
  (if kitty-graphics-mode
      (if (kitty-gfx--detect-protocol)
          (progn
            (kitty-gfx--log "mode: enabling (backend=%s)" kitty-gfx--active-backend)
            (when kitty-gfx--active-backend
              (funcall (kitty-gfx--backend-fn 'cleanup-all)))  ; clear stale state
            (kitty-gfx--query-cell-size)
            ;; Probe text sizing support (OSC 66) when on Kitty backend
            (when (eq kitty-gfx--active-backend 'kitty)
              (kitty-gfx--query-text-sizing-support))
            (kitty-gfx--install-hooks)
            (kitty-gfx--install-integrations)
            ;; Sixel backend silently drops images when no encoder is on
            ;; PATH.  Warn loudly so users notice before they wonder why
            ;; nothing renders.
            (when (and (eq kitty-gfx--active-backend 'sixel)
                       (not (kitty-gfx--sixel-resolve-encoder)))
              (kitty-gfx--log "mode: WARNING no Sixel encoder on PATH")
              (display-warning
               'kitty-graphics
               "Sixel backend active but no encoder on PATH.
Install `img2sixel' (libsixel; strongly recommended) or
ImageMagick (`magick'/`convert').  Without an encoder, no images
will render even though detection reports Sixel as supported."
               :warning))
            (kitty-gfx--log "mode: enabled (backend=%s cell=%dx%d text-sizing=%s)"
                             kitty-gfx--active-backend
                             kitty-gfx--cell-pixel-width kitty-gfx--cell-pixel-height
                             kitty-gfx--text-sizing-support)
            (message "Kitty graphics mode enabled (%s backend%s)"
                     kitty-gfx--active-backend
                     (if (eq kitty-gfx--text-sizing-support 'scale)
                         ", text sizing" "")))
        (kitty-gfx--log "mode: terminal not supported, aborting enable")
        (setq kitty-graphics-mode nil)
        (message "Kitty graphics: terminal not supported"))
    (kitty-gfx--log "mode: disabling")
    (kitty-gfx-stop-video)
    (kitty-gfx--uninstall-hooks)
    (kitty-gfx--uninstall-integrations)
    (when kitty-gfx--active-backend
      (funcall (kitty-gfx--backend-fn 'cleanup-all)))
    (when kitty-gfx--render-timer
      (cancel-timer kitty-gfx--render-timer))
    (setq kitty-gfx--render-timer nil
          kitty-gfx--refresh-pending nil
          kitty-gfx--active-backend nil
          kitty-gfx--text-sizing-support nil)
    (kitty-gfx--log "mode: disabled")))

(defun kitty-gfx--install-hooks ()
  "Install redisplay hooks for image refresh."
  (add-hook 'window-scroll-functions #'kitty-gfx--on-window-scroll)
  (add-hook 'window-size-change-functions #'kitty-gfx--on-window-change)
  (add-hook 'window-buffer-change-functions #'kitty-gfx--on-buffer-change)
  (add-hook 'post-command-hook #'kitty-gfx--on-redisplay)
  (add-hook 'kill-buffer-hook #'kitty-gfx--kill-buffer-hook))

(defun kitty-gfx--uninstall-hooks ()
  "Remove redisplay hooks."
  (remove-hook 'window-scroll-functions #'kitty-gfx--on-window-scroll)
  (remove-hook 'window-size-change-functions #'kitty-gfx--on-window-change)
  (remove-hook 'window-buffer-change-functions #'kitty-gfx--on-buffer-change)
  (remove-hook 'post-command-hook #'kitty-gfx--on-redisplay)
  (remove-hook 'kill-buffer-hook #'kitty-gfx--kill-buffer-hook))

;;;; Org-mode integration

(defun kitty-gfx--org-mode-heading-hook ()
  "Org-mode hook to auto-apply heading sizes.
Only activates when `kitty-gfx-heading-sizes-auto' is set and
the terminal supports text sizing.  Enters preview mode by
disabling conflicting minor modes."
  (when (and kitty-graphics-mode
             (eq kitty-gfx--text-sizing-support 'scale)
             (not (display-graphic-p)))
    ;; Use run-at-time 0 so conflicting modes have finished
    ;; their own org-mode-hook setup before we disable them.
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p (current-buffer))
                     (with-current-buffer (current-buffer)
                       (kitty-gfx--heading-disable-conflicting)
                       (kitty-gfx--org-apply-heading-sizes)))))))

(defun kitty-gfx--nuke-headings ()
  "Erase all heading multicell blocks in the current buffer.
The `nuke' phase of nuke-and-repaint: erases every heading overlay's
multicell block at its cached terminal position, then clears the
cache.  The subsequent refresh cycle handles the `repaint' phase,
re-emitting OSC 66 only for headings that are still visible
\(not inside a fold)."
  (let ((count 0))
    (dolist (ov kitty-gfx--overlays)
      (when (and (overlay-get ov 'kitty-gfx-heading)
                 (overlay-buffer ov)
                 (overlay-get ov 'kitty-gfx-last-row))
        (kitty-gfx--erase-heading ov)
        (overlay-put ov 'kitty-gfx-last-row nil)
        (overlay-put ov 'kitty-gfx-last-col nil)
        (cl-incf count)))
    (when (> count 0)
      (kitty-gfx--log "nuke-headings: erased %d heading blocks" count))
    count))

(defun kitty-gfx--on-org-cycle (&rest _args)
  "Handle org visibility cycling.
Deletes image placements and erases heading multicell blocks from
the terminal, clears position caches, then schedules a refresh
that re-places only the overlays that are still visible (not
inside a fold).  Heading overlays use nuke-and-repaint: erase all,
then let the refresh cycle re-emit the visible ones."
  (kitty-gfx--log "on-org-cycle: overlays=%d" (length kitty-gfx--overlays))
  (when (and kitty-graphics-mode kitty-gfx--overlays)
    (kitty-gfx--sync-begin)
    (unwind-protect
        (dolist (ov kitty-gfx--overlays)
          (when (overlay-buffer ov)
            (if (overlay-get ov 'kitty-gfx-heading)
                ;; Heading overlay — erase multicell block (nuke phase)
                (when (overlay-get ov 'kitty-gfx-last-row)
                  (kitty-gfx--erase-heading ov)
                  (overlay-put ov 'kitty-gfx-last-row nil)
                  (overlay-put ov 'kitty-gfx-last-col nil))
              ;; Image overlay — delete terminal placement
              (let ((id (overlay-get ov 'kitty-gfx-id))
                    (pid (overlay-get ov 'kitty-gfx-pid)))
                (when (and id pid kitty-gfx--active-backend)
                  (funcall (kitty-gfx--backend-fn 'delete) ov id pid)))
              (overlay-put ov 'kitty-gfx-last-row nil)
              (overlay-put ov 'kitty-gfx-last-col nil))))
      (kitty-gfx--sync-end))
    (kitty-gfx--schedule-refresh)))

(defun kitty-gfx--image-file-p (file)
  "Return non-nil if FILE has an image extension.
GIF files are detected so they get routed through the image pipeline,
but only the first frame is rendered (no animation in terminal)."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext)
                     '("png" "jpg" "jpeg" "bmp" "svg"
                       "webp" "tiff" "tif" "gif")))))

(defun kitty-gfx--org-display-inline-images-tty (&optional _include-linked beg end)
  "Display inline images in org buffer via Kitty graphics.
Scans for file:, attachment:, and relative path links."
  (when (derived-mode-p 'org-mode)
    (let ((start (or beg (point-min)))
          (stop (or end (point-max))))
      (kitty-gfx--log "org-display: scanning region %d..%d in %s" start stop (buffer-name))
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
                                 (when-let* ((dir (org-attach-dir)))
                                   (expand-file-name path dir))))
                              (t path))))
                  (when (and file
                             (file-exists-p (expand-file-name file))
                             (kitty-gfx--image-file-p file)
                             (not (cl-some (lambda (ov)
                                             (overlay-get ov 'kitty-gfx))
                                           (overlays-in link-beg link-end))))
                    (kitty-gfx--log "org-display: found link %s at %d..%d"
                                     file link-beg link-end)
                    (condition-case err
                        (kitty-gfx-display-image
                         (expand-file-name file) link-beg link-end
                         kitty-gfx-max-width kitty-gfx-max-height)
                      (error
                       (kitty-gfx--log "org-display: ERROR %s: %s"
                                        file (error-message-string err))
                       (message "kitty-gfx: %s: %s"
                                 file (error-message-string err))))))))))))))


(defun kitty-gfx--org-display-advice (orig-fn &rest args)
  "Around advice for `org-display-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (kitty-gfx--log "advice: org-display-inline-images (terminal path)")
        (apply #'kitty-gfx--org-display-inline-images-tty args))
    (apply orig-fn args)))

(defun kitty-gfx--org-remove-advice (orig-fn &rest args)
  "Around advice for `org-remove-inline-images'."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    (kitty-gfx--log "advice: org-remove-inline-images")
    (kitty-gfx-remove-images))
  (apply orig-fn args))

(defun kitty-gfx--org-toggle-advice (orig-fn &rest args)
  "Around advice for `org-toggle-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (let ((has-images (cl-some (lambda (ov) (overlay-get ov 'kitty-gfx))
                                 (overlays-in (point-min) (point-max)))))
        (kitty-gfx--log "advice: org-toggle has-images=%s" has-images)
        (if has-images
            (kitty-gfx-remove-images)
          (kitty-gfx--org-display-inline-images-tty)))
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
rendered to images via dvipng/dvisvgm and displayed via
kitty-graphics (works with both Kitty and Sixel backends).
The image generation pipeline does not require a GUI."
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
          (when-let* ((ov (car kitty-gfx--overlays)))
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

;;;; Typst inline equation preview

(defcustom kitty-gfx-typst-command "typst"
  "Path to the typst executable used for inline math previews."
  :type 'string
  :group 'kitty-graphics)

(defcustom kitty-gfx-typst-ppi 300
  "Pixels-per-inch passed to `typst compile' for math previews.
Higher values give crisper images at the cost of compile time."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-typst-text-size 11
  "Text size in points used when rendering typst math fragments."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-typst-preamble nil
  "Extra typst code prepended to each math fragment before compilation.
When nil, a default preamble is used that auto-sizes the page,
disables the page fill, and applies `kitty-gfx-typst-text-size' with
the current Emacs foreground color."
  :type '(choice (const :tag "Default" nil) string)
  :group 'kitty-graphics)

(defvar kitty-gfx--typst-cache-dir nil
  "Directory holding cached typst-rendered PNGs.")

(defun kitty-gfx--typst-cache-dir ()
  "Return the cache directory for typst PNGs, creating it if needed."
  (unless (and kitty-gfx--typst-cache-dir
               (file-directory-p kitty-gfx--typst-cache-dir))
    (setq kitty-gfx--typst-cache-dir
          (expand-file-name "kitty-gfx-typst" temporary-file-directory))
    (make-directory kitty-gfx--typst-cache-dir t))
  kitty-gfx--typst-cache-dir)

(defun kitty-gfx--typst-color-hex (color)
  "Convert COLOR (name or `#rrggbb') to a `#RRGGBB' string for typst.
Returns `#000000' on failure."
  (or (when (stringp color)
        (let ((rgb (ignore-errors (color-name-to-rgb color))))
          (when (and rgb (= (length rgb) 3))
            (format "#%02x%02x%02x"
                    (round (* 255 (nth 0 rgb)))
                    (round (* 255 (nth 1 rgb)))
                    (round (* 255 (nth 2 rgb)))))))
      "#000000"))

(defun kitty-gfx--typst-default-preamble ()
  "Build the default typst preamble using current Emacs foreground color."
  (let* ((raw (face-attribute 'default :foreground nil))
         (fg (kitty-gfx--typst-color-hex
              (and (stringp raw)
                   (not (string-prefix-p "unspecified" raw))
                   raw))))
    (format "#set page(width: auto, height: auto, margin: 2pt, fill: none)
#set text(size: %dpt, fill: rgb(\"%s\"))
"
            kitty-gfx-typst-text-size fg)))

(defconst kitty-gfx--typst-math-regexp
  "\\$\\(?:[^$\n\\\\]\\|\\\\.\\)+\\$"
  "Regexp matching a single `$...$' typst math fragment on one line.
Backslash-escaped characters within the fragment are allowed; newlines
end the match.")

(defun kitty-gfx--typst-render (fragment)
  "Compile FRAGMENT (typst source including the surrounding `$') to PNG.
Return the absolute path to the generated PNG, or nil on failure.
Results are cached under `kitty-gfx--typst-cache-dir', keyed by SHA-1
of the full preamble + fragment + ppi."
  (unless (executable-find kitty-gfx-typst-command)
    (user-error "typst executable not found: %s" kitty-gfx-typst-command))
  (let* ((preamble (or kitty-gfx-typst-preamble
                       (kitty-gfx--typst-default-preamble)))
         (body (concat preamble fragment "\n"))
         (key (sha1 (format "%s|%d" body kitty-gfx-typst-ppi)))
         (dir (kitty-gfx--typst-cache-dir))
         (typ (expand-file-name (concat key ".typ") dir))
         (png (expand-file-name (concat key ".png") dir)))
    (unless (file-exists-p png)
      (with-temp-file typ (insert body))
      (let* ((log-buf (get-buffer-create "*kitty-gfx-typst*"))
             (ret (condition-case err
                      (call-process kitty-gfx-typst-command nil log-buf nil
                                    "compile"
                                    "--format" "png"
                                    "--ppi" (number-to-string kitty-gfx-typst-ppi)
                                    typ png)
                    (error
                     (kitty-gfx--log "typst-render: call-process error: %S" err)
                     -1))))
        (unless (eq ret 0)
          (kitty-gfx--log "typst-render: compile failed (exit=%s) for %s"
                          ret typ)
          (setq png nil))))
    (and png (file-exists-p png) png)))

;;;###autoload
(defun kitty-gfx-typst-preview (&optional beg end)
  "Render typst `$...$' math fragments as inline PNG images.
With an active region, restrict to it; otherwise scan the whole buffer.
Existing typst preview overlays in the range are replaced.
Requires `kitty-graphics-mode' and a working `typst' executable."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (unless kitty-graphics-mode
    (user-error "kitty-graphics-mode is not active"))
  (unless kitty-gfx--active-backend
    (user-error "Terminal does not support graphics"))
  (let ((start (or beg (point-min)))
        (stop (or end (point-max)))
        (count 0))
    (kitty-gfx-typst-clear-preview start stop)
    (save-excursion
      (goto-char start)
      (while (re-search-forward kitty-gfx--typst-math-regexp stop t)
        (let* ((m-beg (match-beginning 0))
               (m-end (match-end 0))
               (frag (match-string-no-properties 0))
               (png (kitty-gfx--typst-render frag)))
          (when png
            (kitty-gfx-display-image png m-beg m-end)
            (when-let* ((ov (car kitty-gfx--overlays)))
              (overlay-put ov 'kitty-gfx-typst t)
              (overlay-put ov 'modification-hooks
                           (list (lambda (o after &rest _)
                                   (when after
                                     (kitty-gfx--remove-overlay o))))))
            (cl-incf count)))))
    (when (called-interactively-p 'any)
      (message "kitty-gfx: rendered %d typst fragment%s"
               count (if (= count 1) "" "s")))
    count))

;;;###autoload
(defun kitty-gfx-typst-clear-preview (&optional beg end)
  "Remove kitty-graphics typst preview overlays between BEG and END.
With an active region, restrict to it; otherwise clear the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let ((start (or beg (point-min)))
        (stop (or end (point-max))))
    (dolist (ov (overlays-in start stop))
      (when (overlay-get ov 'kitty-gfx-typst)
        (kitty-gfx--remove-overlay ov)))))

;;;; image-mode integration

(defvar-local kitty-gfx--image-scale 1.0
  "Zoom scale factor for image-mode display.
Values > 1.0 zoom in, < 1.0 zoom out.")

(defun kitty-gfx--image-mode-render (&optional reuse-placement)
  "Render the current image file centered at current scale.
When REUSE-PLACEMENT is non-nil, reuse the old terminal placement
ID instead of deleting it first.  This is useful for zoom commands
where the new placement immediately replaces the old one, but it is
intentionally not used for window size changes because stale pixels
can otherwise remain over newly-created window separators."
  (when-let* ((file (buffer-file-name)))
    (when (kitty-gfx--image-file-p file)
      (let* ((inhibit-read-only t)
             (win-w (- (window-body-width) 2))
             (win-h (- (window-body-height) 2))
             (max-cols (min win-w kitty-gfx-max-width))
             (max-rows (min win-h kitty-gfx-max-height))
             ;; Save the old placement ID only when the caller explicitly
             ;; wants to reuse it.  Reusing avoids delete+re-place glitches
             ;; for zoom commands (WezTerm #5892), but window splits/resizes
             ;; must delete first so stale terminal pixels are cleared.
             (old-pid (when (and reuse-placement (car kitty-gfx--overlays))
                        (overlay-get (car kitty-gfx--overlays) 'kitty-gfx-pid))))
        (kitty-gfx--log "image-mode-render: file=%s scale=%.2f win=%dx%d max=%dx%d reuse-pid=%s"
                         (file-name-nondirectory file) kitty-gfx--image-scale
                         win-w win-h max-cols max-rows old-pid)
        ;; Remove overlays.  When OLD-PID is non-nil, skip terminal-side
        ;; delete so the new placement atomically replaces it; otherwise
        ;; delete/erase the old placement before changing the buffer text.
        (dolist (ov (overlays-in (point-min) (point-max)))
          (when (overlay-get ov 'kitty-gfx)
            (kitty-gfx--remove-overlay ov old-pid)))
        (erase-buffer)
        (kitty-gfx--display-image-centered
         file max-cols max-rows win-w win-h
         kitty-gfx--image-scale old-pid)
        (goto-char (point-min))
        (set-buffer-modified-p nil)))))

(defun kitty-gfx-image-increase-size ()
  "Zoom in on the image in image-mode."
  (interactive)
  (setq kitty-gfx--image-scale (* kitty-gfx--image-scale 1.25))
  (kitty-gfx--image-mode-render t))

(defun kitty-gfx-image-decrease-size ()
  "Zoom out on the image in image-mode."
  (interactive)
  (setq kitty-gfx--image-scale (max 0.1 (* kitty-gfx--image-scale 0.8)))
  (kitty-gfx--image-mode-render t))

(defun kitty-gfx-image-reset-size ()
  "Reset image zoom to default in image-mode."
  (interactive)
  (setq kitty-gfx--image-scale 1.0)
  (kitty-gfx--image-mode-render t))

(defun kitty-gfx--image-mode-advice (orig-fn &rest args)
  "Around advice for `image-mode'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (major-mode-suspend)
        ;; Use our own major-mode symbol so evil-collection's
        ;; image-mode bindings (which call native image functions
        ;; that fail in terminal) don't override our keymap.
        (setq major-mode 'kitty-gfx-image-mode
              mode-name (format "Image[%s]"
                                (pcase kitty-gfx--active-backend
                                  ('kitty "Kitty") ('sixel "Sixel") (_ "GFX"))))
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map special-mode-map)
          (define-key map (kbd "q") #'kill-current-buffer)
          (define-key map (kbd "+") #'kitty-gfx-image-increase-size)
          (define-key map (kbd "=") #'kitty-gfx-image-increase-size)
          (define-key map (kbd "-") #'kitty-gfx-image-decrease-size)
          (define-key map (kbd "0") #'kitty-gfx-image-reset-size)
          (use-local-map map))
        ;; If evil is loaded, bind zoom keys in normal state so they
        ;; aren't shadowed by evil's default normal-state bindings.
        (when (fboundp 'evil-local-set-key)
          (evil-local-set-key 'normal (kbd "+") #'kitty-gfx-image-increase-size)
          (evil-local-set-key 'normal (kbd "=") #'kitty-gfx-image-increase-size)
          (evil-local-set-key 'normal (kbd "-") #'kitty-gfx-image-decrease-size)
          (evil-local-set-key 'normal (kbd "0") #'kitty-gfx-image-reset-size)
          (evil-local-set-key 'normal (kbd "q") #'kill-current-buffer))
        (setq-local buffer-read-only t)
        ;; Re-render when window size changes (e.g., split/unsplit)
        ;; so centering and overflow checks use correct dimensions.
        (add-hook 'window-size-change-functions
                  (lambda (_frame)
                    (when (eq major-mode 'kitty-gfx-image-mode)
                      (kitty-gfx--image-mode-render)))
                  nil t)
        (kitty-gfx--image-mode-render)
        (set-buffer-modified-p nil))
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
        (kitty-gfx--log "shr-put-image: type=%s url=%s data-len=%s alt=%s"
                         type url (when data (length data)) alt)
        (insert (or alt "[image]"))
        (let ((end (point)))
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
            (unwind-protect
                (condition-case err
                    (when file
                      (kitty-gfx-display-image file start end))
                  (error
                   (kitty-gfx--log "shr-put-image error: %s" (error-message-string err))))
              (when temp-p
                (ignore-errors (delete-file file)))))))
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

(defun kitty-gfx--doc-view-terminal-p ()
  "Non-nil when Kitty graphics is handling a doc-view buffer in a terminal."
  (and kitty-graphics-mode
       (not (display-graphic-p))
       (eq major-mode 'doc-view-mode)))

(defun kitty-gfx--doc-view-image-cell-size ()
  "Return the current doc-view Kitty image size as (COLS . ROWS), or nil."
  (when (overlayp kitty-gfx--doc-view-overlay)
    (let ((cols (overlay-get kitty-gfx--doc-view-overlay 'kitty-gfx-cols))
          (rows (overlay-get kitty-gfx--doc-view-overlay 'kitty-gfx-rows)))
      (when (and cols rows)
        (cons cols rows)))))

(defun kitty-gfx--doc-view-max-hscroll ()
  "Return the maximum horizontal scroll for the current Kitty doc-view page."
  (let ((size (kitty-gfx--doc-view-image-cell-size)))
    (max 0 (- (or (car size) 0) (window-body-width)))))

(defun kitty-gfx--doc-view-max-vscroll ()
  "Return the maximum vertical pixel scroll for the current Kitty doc-view page."
  (let ((size (kitty-gfx--doc-view-image-cell-size)))
    (max 0 (- (* (or (cdr size) 0) (frame-char-height))
              (window-body-height nil t)))))

(defun kitty-gfx--doc-view-set-hscroll (ncols)
  "Set horizontal scroll to NCOLS for Kitty doc-view and refresh the page."
  (let ((new (max 0 (min ncols (kitty-gfx--doc-view-max-hscroll)))))
    (set-window-hscroll (selected-window) new)
    (kitty-gfx--schedule-refresh)
    new))

(defun kitty-gfx--doc-view-set-vscroll (pixels)
  "Set vertical pixel scroll to PIXELS for Kitty doc-view and refresh the page."
  (let ((new (max 0 (min pixels (kitty-gfx--doc-view-max-vscroll)))))
    (set-window-vscroll (selected-window) new t)
    (kitty-gfx--schedule-refresh)
    new))

(defun kitty-gfx--doc-view-forward-hscroll (&optional n)
  "Scroll the current Kitty doc-view page left by N columns."
  (kitty-gfx--doc-view-set-hscroll (+ (window-hscroll) (or n 1))))

(defun kitty-gfx--doc-view-next-line (&optional n)
  "Scroll the current Kitty doc-view page upward by N terminal rows."
  (kitty-gfx--doc-view-set-vscroll
   (+ (window-vscroll nil t) (* (or n 1) (frame-char-height)))))

(defun kitty-gfx--doc-view-scroll-left (&optional n)
  "Scroll the current Kitty doc-view page leftward by N columns."
  (kitty-gfx--doc-view-forward-hscroll
   (cond
    ((null n) (max 0 (- (window-body-width) 2)))
    ((eq n '-) (min 0 (- 2 (window-body-width))))
    (t (prefix-numeric-value n)))))

(defun kitty-gfx--doc-view-scroll-up (&optional n)
  "Scroll the current Kitty doc-view page upward by N rows."
  (kitty-gfx--doc-view-next-line
   (cond
    ((null n) (max 0 (- (window-body-height) next-screen-context-lines)))
    ((eq n '-) (min 0 (- next-screen-context-lines (window-body-height))))
    (t (prefix-numeric-value n)))))

(defun kitty-gfx--doc-view-image-forward-hscroll-advice (orig-fn &optional n)
  "Around advice for `image-forward-hscroll' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-forward-hscroll n)
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-backward-hscroll-advice (orig-fn &optional n)
  "Around advice for `image-backward-hscroll' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-forward-hscroll (- (or n 1)))
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-next-line-advice (orig-fn &optional n)
  "Around advice for `image-next-line' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-next-line n)
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-previous-line-advice (orig-fn &optional n)
  "Around advice for `image-previous-line' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-next-line (- (or n 1)))
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-scroll-left-advice (orig-fn &optional n)
  "Around advice for `image-scroll-left' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-scroll-left n)
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-scroll-right-advice (orig-fn &optional n)
  "Around advice for `image-scroll-right' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-scroll-left
       (cond
        ((null n) (min 0 (- 2 (window-body-width))))
        ((eq n '-) (max 0 (- (window-body-width) 2)))
        (t (- (prefix-numeric-value n)))))
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-scroll-up-advice (orig-fn &optional n)
  "Around advice for `image-scroll-up' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-scroll-up n)
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-scroll-down-advice (orig-fn &optional n)
  "Around advice for `image-scroll-down' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (kitty-gfx--doc-view-scroll-up
       (cond
        ((null n) (min 0 (- next-screen-context-lines (window-body-height))))
        ((eq n '-) (max 0 (- (window-body-height) next-screen-context-lines)))
        (t (- (prefix-numeric-value n)))))
    (funcall orig-fn n)))

(defun kitty-gfx--doc-view-image-bol-advice (orig-fn &optional arg)
  "Around advice for `image-bol' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (progn
        (when (and arg (/= (prefix-numeric-value arg) 1))
          (kitty-gfx--doc-view-next-line (- (prefix-numeric-value arg) 1)))
        (kitty-gfx--doc-view-set-hscroll 0))
    (funcall orig-fn arg)))

(defun kitty-gfx--doc-view-image-eol-advice (orig-fn &optional arg)
  "Around advice for `image-eol' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (progn
        (when (and arg (/= (prefix-numeric-value arg) 1))
          (kitty-gfx--doc-view-next-line (- (prefix-numeric-value arg) 1)))
        (kitty-gfx--doc-view-set-hscroll (kitty-gfx--doc-view-max-hscroll)))
    (funcall orig-fn arg)))

(defun kitty-gfx--doc-view-image-bob-advice (orig-fn)
  "Around advice for `image-bob' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (progn
        (kitty-gfx--doc-view-set-hscroll 0)
        (kitty-gfx--doc-view-set-vscroll 0))
    (funcall orig-fn)))

(defun kitty-gfx--doc-view-image-eob-advice (orig-fn)
  "Around advice for `image-eob' in Kitty doc-view buffers."
  (if (kitty-gfx--doc-view-terminal-p)
      (progn
        (kitty-gfx--doc-view-set-hscroll (kitty-gfx--doc-view-max-hscroll))
        (kitty-gfx--doc-view-set-vscroll (kitty-gfx--doc-view-max-vscroll)))
    (funcall orig-fn)))

(defun kitty-gfx--doc-view-insert-image-advice (orig-fn file &rest args)
  "Around advice for `doc-view-insert-image'.
Displays the page image via Kitty graphics instead of an Emacs
image spec.  FILE is the path to the page PNG."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when (and file (file-exists-p file))
        (kitty-gfx--log "doc-view-insert: file=%s scale=%.2f" file kitty-gfx--doc-view-scale)
        ;; Remember current file for zoom commands
        (setq kitty-gfx--doc-view-current-file file)
        ;; Save old PID and remove overlay without terminal-side delete
        ;; so the new placement atomically replaces it (WezTerm #5892).
        (let ((old-pid (when kitty-gfx--doc-view-overlay
                         (overlay-get kitty-gfx--doc-view-overlay 'kitty-gfx-pid))))
          (when kitty-gfx--doc-view-overlay
            (kitty-gfx--remove-overlay kitty-gfx--doc-view-overlay old-pid)
            (setq kitty-gfx--doc-view-overlay nil))
          ;; Display the rendered page using only an overlay.  Do not erase
          ;; or insert text here: doc-view buffers visit the original PDF, so
          ;; mutating buffer text can corrupt the document if it is saved.
          (let* ((win-w (- (window-body-width) 1))
                 (win-h (- (window-body-height) 1))
                 (abs-file (expand-file-name file))
                 (px (kitty-gfx--image-pixel-size abs-file))
                 (base-dims (if px
                                (kitty-gfx--compute-cell-dims
                                 (car px) (cdr px) win-w win-h)
                              (cons (min 40 win-w) (min 15 win-h))))
                 (img-cols (max 1 (round (* kitty-gfx--doc-view-scale
                                             (car base-dims)))))
                 (img-rows (max 1 (round (* kitty-gfx--doc-view-scale
                                             (cdr base-dims)))))
                 (cached-id (kitty-gfx--cache-get abs-file))
                 (image-id (or cached-id (kitty-gfx--alloc-id))))
            (set-window-hscroll (selected-window) 0)
            (set-window-vscroll (selected-window) 0 t)
            (unless cached-id
              (when (funcall (kitty-gfx--backend-fn 'prepare) abs-file image-id)
                (kitty-gfx--cache-put abs-file image-id)))
            (when (or cached-id (gethash abs-file kitty-gfx--image-cache))
              (setq kitty-gfx--doc-view-overlay
                    (kitty-gfx--make-overlay (point-min) (point-max)
                                             image-id img-cols img-rows
                                             abs-file old-pid))
              (kitty-gfx--schedule-refresh))))
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
    (kitty-gfx--log "dired-preview: %s" file)
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
             kitty-gfx--active-backend)
    (kitty-gfx--log "dirvish-preview: %s" file)
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

;;;; markdown-overlays integration (agent-shell)

(defun kitty-gfx--markdown-overlays-fontify-image-advice (orig-fn start end url-start url-end)
  "Around advice for `markdown-overlays--fontify-image'.
Displays markdown images ![alt](url) via Kitty graphics in terminal.
Falls back to ORIG-FN in GUI."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when-let* ((url (buffer-substring-no-properties url-start url-end))
                  (path (markdown-overlays--resolve-image-url url))
                  ((file-exists-p path))
                  ((kitty-gfx--image-file-p path)))
        (kitty-gfx--log "markdown-overlays-image: %s" path)
        (condition-case err
            (kitty-gfx-display-image
             path start end
             kitty-gfx-max-width kitty-gfx-max-height)
          (error
           (kitty-gfx--log "markdown-overlays-image error: %s" (error-message-string err)))))
    (funcall orig-fn start end url-start url-end)))

(defun kitty-gfx--markdown-overlays-fontify-image-file-path-advice (orig-fn start end path-start path-end)
  "Around advice for `markdown-overlays--fontify-image-file-path'.
Displays bare image file paths via Kitty graphics in terminal.
Falls back to ORIG-FN in GUI."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when-let* ((raw (buffer-substring-no-properties path-start path-end))
                  (path (markdown-overlays--resolve-image-url raw))
                  ((file-exists-p path))
                  ((kitty-gfx--image-file-p path)))
        (kitty-gfx--log "markdown-overlays-path: %s" path)
        (condition-case err
            (kitty-gfx-display-image
             path start end
             kitty-gfx-max-width kitty-gfx-max-height)
          (error
           (kitty-gfx--log "markdown-overlays-path error: %s" (error-message-string err)))))
    (funcall orig-fn start end path-start path-end)))

;;;; mpv video integration

(defun kitty-gfx--mpv-available-p ()
  "Return non-nil if mpv video playback is available."
  (and kitty-gfx-enable-video
       kitty-graphics-mode
       (not (display-graphic-p))
       (eq kitty-gfx--active-backend 'kitty)
       (executable-find "mpv")))

(defun kitty-gfx--mpv-ipc-send (command)
  "Send COMMAND (a list) to mpv via JSON IPC.
COMMAND is encoded as {\"command\": COMMAND}."
  (when (and kitty-gfx--mpv-ipc-connection
             (process-live-p kitty-gfx--mpv-ipc-connection))
    (let ((json (concat (json-encode `(("command" . ,command))) "\n")))
      (condition-case err
          (process-send-string kitty-gfx--mpv-ipc-connection json)
        (error
         (kitty-gfx--log "mpv-ipc-send error: %s" (error-message-string err)))))))

(defun kitty-gfx--mpv-ipc-connect (socket-path callback)
  "Poll for SOCKET-PATH existence, then connect and call CALLBACK.
Polls every 50ms, times out after 2 seconds."
  (let ((attempts 0)
        (max-attempts 40))
    (cl-labels
        ((try-connect ()
           (cond
            ((file-exists-p socket-path)
             (condition-case err
                 (let ((proc (make-network-process
                              :name "kitty-gfx-mpv-ipc"
                              :family 'local
                              :service socket-path
                              :buffer nil
                              :noquery t
                              :filter (lambda (_proc output)
                                        (kitty-gfx--log "mpv-ipc: %s" output)))))
                   (setq kitty-gfx--mpv-ipc-connection proc)
                   (kitty-gfx--log "mpv: IPC connected to %s" socket-path)
                   (when callback (funcall callback)))
               (error
                (kitty-gfx--log "mpv: IPC connect failed: %s" (error-message-string err))
                (cl-incf attempts)
                (when (< attempts max-attempts)
                  (run-at-time 0.05 nil #'try-connect)))))
            ((< attempts max-attempts)
             (cl-incf attempts)
             (run-at-time 0.05 nil #'try-connect))
            (t
             (kitty-gfx--log "mpv: IPC socket timeout after 2s")
             (message "kitty-gfx: mpv IPC connection timed out")))))
      (try-connect))))

(defun kitty-gfx--mpv-compute-geometry ()
  "Compute video geometry as (COL ROW WIDTH-PX HEIGHT-PX COLS ROWS).
Uses the selected window dimensions and cell pixel size."
  (kitty-gfx--query-cell-size)
  (let* ((cw (or kitty-gfx--cell-pixel-width 8))
         (ch (or kitty-gfx--cell-pixel-height 16))
         (max-cols (min (- (window-body-width) 2) kitty-gfx-max-width))
         (max-rows (min (- (window-body-height) 4) kitty-gfx-max-height))
         ;; 16:9 aspect ratio, fit within max bounds
         (video-cols max-cols)
         (video-rows (min max-rows (max 10 (/ (* video-cols 9) 16))))
         (width-px (* video-cols cw))
         (height-px (* video-rows ch)))
    (list 1 1 width-px height-px video-cols video-rows)))

(defun kitty-gfx--mpv-overlay-position ()
  "Return (ROW . COL) terminal position of the mpv overlay, or nil if hidden.
ROW and COL are 1-based terminal cell coordinates."
  (when (and kitty-gfx--mpv-overlay
             (overlay-buffer kitty-gfx--mpv-overlay))
    (let* ((ov kitty-gfx--mpv-overlay)
           (start (overlay-start ov))
           (win (get-buffer-window (overlay-buffer ov))))
      (when (and win
                 (pos-visible-in-window-p start win))
        (let* ((win-edges (window-edges win nil nil t))
               (win-top (nth 1 win-edges))
               (win-left (nth 0 win-edges))
               (coords (posn-col-row (posn-at-point start win)))
               (col (+ win-left (car coords) 1))
               (row (+ (/ win-top (or kitty-gfx--cell-pixel-height 16))
                       (cdr coords) 1)))
          (cons row col))))))

(defun kitty-gfx--refresh-mpv-overlay ()
  "Update mpv position if the overlay has moved.  Called from the refresh cycle."
  (when (and kitty-gfx--mpv-process
             (process-live-p kitty-gfx--mpv-process)
             kitty-gfx--mpv-overlay)
    (let ((pos (kitty-gfx--mpv-overlay-position)))
      (if pos
          (let ((row (car pos))
                (col (cdr pos)))
            (unless (and (eql row kitty-gfx--mpv-last-row)
                         (eql col kitty-gfx--mpv-last-col))
              (kitty-gfx--log "mpv: reposition to row=%d col=%d" row col)
              (kitty-gfx--mpv-ipc-send (list "set_property" "vo-kitty-top" row))
              (kitty-gfx--mpv-ipc-send (list "set_property" "vo-kitty-left" col))
              (setq kitty-gfx--mpv-last-row row
                    kitty-gfx--mpv-last-col col)))
        ;; Overlay not visible — keep audio, hide video
        (when kitty-gfx--mpv-last-row
          (kitty-gfx--log "mpv: overlay hidden, keeping audio")
          (setq kitty-gfx--mpv-last-row nil
                kitty-gfx--mpv-last-col nil))))))

(defun kitty-gfx--mpv-process-sentinel (proc event)
  "Handle mpv process state changes.
PROC is the mpv process, EVENT describes the state change."
  (kitty-gfx--log "mpv: process event: %s" (string-trim event))
  (when (memq (process-status proc) '(exit signal))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (eq kitty-gfx--mpv-process proc)
          (kitty-gfx--mpv-cleanup))))))

(defun kitty-gfx--mpv-cleanup ()
  "Clean up mpv state in the current buffer."
  (when kitty-gfx--mpv-ipc-connection
    (ignore-errors (delete-process kitty-gfx--mpv-ipc-connection))
    (setq kitty-gfx--mpv-ipc-connection nil))
  (when kitty-gfx--mpv-process
    (when (process-live-p kitty-gfx--mpv-process)
      (ignore-errors (kill-process kitty-gfx--mpv-process)))
    (setq kitty-gfx--mpv-process nil))
  (when kitty-gfx--mpv-ipc-socket
    (ignore-errors (delete-file kitty-gfx--mpv-ipc-socket))
    (setq kitty-gfx--mpv-ipc-socket nil))
  (when kitty-gfx--mpv-overlay
    (ignore-errors (delete-overlay kitty-gfx--mpv-overlay))
    (setq kitty-gfx--mpv-overlay nil))
  (setq kitty-gfx--mpv-last-row nil
        kitty-gfx--mpv-last-col nil))

;;;###autoload
(defun kitty-gfx-play-video (file)
  "Play video FILE inline in the current buffer via mpv.
Requires `kitty-gfx-enable-video' to be non-nil and mpv installed."
  (interactive "fVideo file: ")
  (unless kitty-gfx-enable-video
    (user-error "Video playback disabled; set kitty-gfx-enable-video to t"))
  (unless (kitty-gfx--mpv-available-p)
    (user-error "mpv video requires Kitty backend and mpv installed"))
  ;; Stop any existing video in this buffer
  (when kitty-gfx--mpv-process
    (kitty-gfx--mpv-cleanup))
  (let* ((file (expand-file-name file))
         (geom (kitty-gfx--mpv-compute-geometry))
         (col (nth 0 geom))
         (row (nth 1 geom))
         (width-px (nth 2 geom))
         (height-px (nth 3 geom))
         (video-cols (nth 4 geom))
         (video-rows (nth 5 geom))
         (socket (make-temp-name "/tmp/kitty-gfx-mpv-"))
         (socket-path (concat socket ".sock")))
    ;; Create overlay to reserve space
    (let* ((start (point))
           (inhibit-read-only t))
      ;; Insert blank lines for the overlay to cover
      (insert (make-string video-rows ?\n))
      (let ((end (point)))
        (setq kitty-gfx--mpv-overlay
              (make-overlay start end nil t nil))
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx t)
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx-mpv t)
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx-cols video-cols)
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx-rows video-rows)
        (overlay-put kitty-gfx--mpv-overlay 'evaporate t)
        (goto-char start)))
    ;; Compute initial terminal position
    (let ((pos (kitty-gfx--mpv-overlay-position)))
      (when pos
        (setq row (car pos) col (cdr pos))))
    ;; Store socket path
    (setq kitty-gfx--mpv-ipc-socket socket-path)
    ;; Spawn mpv
    (let ((proc (start-process
                 "kitty-gfx-mpv" nil "mpv"
                 "--vo=kitty"
                 "--vo-kitty-use-shm=yes"
                 (format "--vo-kitty-left=%d" col)
                 (format "--vo-kitty-top=%d" row)
                 (format "--vo-kitty-width=%d" width-px)
                 (format "--vo-kitty-height=%d" height-px)
                 "--vo-kitty-config-clear=no"
                 "--vo-kitty-alt-screen=no"
                 "--really-quiet"
                 "--no-terminal"
                 (format "--input-ipc-server=%s" socket-path)
                 file)))
      (setq kitty-gfx--mpv-process proc)
      (set-process-sentinel proc #'kitty-gfx--mpv-process-sentinel)
      (set-process-query-on-exit-flag proc nil)
      (kitty-gfx--log "mpv: started pid=%s file=%s" (process-id proc) file)
      ;; Connect IPC after mpv creates the socket
      (kitty-gfx--mpv-ipc-connect socket-path nil))))

(defun kitty-gfx-stop-video ()
  "Stop the current buffer's inline video playback."
  (interactive)
  (if kitty-gfx--mpv-process
      (progn
        (kitty-gfx--mpv-cleanup)
        (message "kitty-gfx: video stopped"))
    (message "kitty-gfx: no video playing")))

(defun kitty-gfx-toggle-video ()
  "Toggle pause/resume of the current buffer's inline video."
  (interactive)
  (if (and kitty-gfx--mpv-process (process-live-p kitty-gfx--mpv-process))
      (kitty-gfx--mpv-ipc-send '("cycle" "pause"))
    (message "kitty-gfx: no video playing")))

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
    ;; Auto-apply heading sizes when entering org buffers
    (when kitty-gfx-heading-sizes-auto
      (add-hook 'org-mode-hook #'kitty-gfx--org-mode-heading-hook))
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
                #'kitty-gfx--doc-view-scale-reset-advice)
    (advice-add 'image-forward-hscroll :around
                #'kitty-gfx--doc-view-image-forward-hscroll-advice)
    (advice-add 'image-backward-hscroll :around
                #'kitty-gfx--doc-view-image-backward-hscroll-advice)
    (advice-add 'image-next-line :around
                #'kitty-gfx--doc-view-image-next-line-advice)
    (advice-add 'image-previous-line :around
                #'kitty-gfx--doc-view-image-previous-line-advice)
    (advice-add 'image-scroll-left :around
                #'kitty-gfx--doc-view-image-scroll-left-advice)
    (advice-add 'image-scroll-right :around
                #'kitty-gfx--doc-view-image-scroll-right-advice)
    (advice-add 'image-scroll-up :around
                #'kitty-gfx--doc-view-image-scroll-up-advice)
    (advice-add 'image-scroll-down :around
                #'kitty-gfx--doc-view-image-scroll-down-advice)
    (advice-add 'image-bol :around
                #'kitty-gfx--doc-view-image-bol-advice)
    (advice-add 'image-eol :around
                #'kitty-gfx--doc-view-image-eol-advice)
    (advice-add 'image-bob :around
                #'kitty-gfx--doc-view-image-bob-advice)
    (advice-add 'image-eob :around
                #'kitty-gfx--doc-view-image-eob-advice))
  (with-eval-after-load 'markdown-overlays
    (advice-add 'markdown-overlays--fontify-image :around
                #'kitty-gfx--markdown-overlays-fontify-image-advice)
    (advice-add 'markdown-overlays--fontify-image-file-path :around
                #'kitty-gfx--markdown-overlays-fontify-image-file-path-advice))
  (kitty-gfx--install-dirvish))

(defun kitty-gfx--uninstall-integrations ()
  "Remove all advice."
  (remove-hook 'org-mode-hook #'kitty-gfx--org-mode-heading-hook)
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
  (advice-remove 'image-forward-hscroll #'kitty-gfx--doc-view-image-forward-hscroll-advice)
  (advice-remove 'image-backward-hscroll #'kitty-gfx--doc-view-image-backward-hscroll-advice)
  (advice-remove 'image-next-line #'kitty-gfx--doc-view-image-next-line-advice)
  (advice-remove 'image-previous-line #'kitty-gfx--doc-view-image-previous-line-advice)
  (advice-remove 'image-scroll-left #'kitty-gfx--doc-view-image-scroll-left-advice)
  (advice-remove 'image-scroll-right #'kitty-gfx--doc-view-image-scroll-right-advice)
  (advice-remove 'image-scroll-up #'kitty-gfx--doc-view-image-scroll-up-advice)
  (advice-remove 'image-scroll-down #'kitty-gfx--doc-view-image-scroll-down-advice)
  (advice-remove 'image-bol #'kitty-gfx--doc-view-image-bol-advice)
  (advice-remove 'image-eol #'kitty-gfx--doc-view-image-eol-advice)
  (advice-remove 'image-bob #'kitty-gfx--doc-view-image-bob-advice)
  (advice-remove 'image-eob #'kitty-gfx--doc-view-image-eob-advice)
  (advice-remove 'image-mode #'kitty-gfx--image-mode-advice)
  (advice-remove 'shr-put-image #'kitty-gfx--shr-put-image-advice)
  (advice-remove 'markdown-overlays--fontify-image #'kitty-gfx--markdown-overlays-fontify-image-advice)
  (advice-remove 'markdown-overlays--fontify-image-file-path #'kitty-gfx--markdown-overlays-fontify-image-file-path-advice)
  (kitty-gfx--uninstall-dirvish))

;;;; Buffer cleanup

(defun kitty-gfx--image-id-in-other-buffers-p (id &optional exclude-buf)
  "Non-nil if image ID is used by overlays in buffers other than EXCLUDE-BUF.
EXCLUDE-BUF defaults to the current buffer."
  (let ((skip (or exclude-buf (current-buffer)))
        (found nil))
    (dolist (buf (buffer-list))
      (unless (or found (eq buf skip))
        (with-current-buffer buf
          (dolist (ov kitty-gfx--overlays)
            (when (and (not found)
                       (overlay-buffer ov)
                       (eql (overlay-get ov 'kitty-gfx-id) id))
              (setq found t))))))
    found))

(defun kitty-gfx--kill-buffer-hook ()
  "Clean up images when buffer is killed.
Deletes terminal-side placements for this buffer's overlays.
Only deletes terminal-side image data (and cache entries) if no
other buffer has overlays referencing the same image ID — this
prevents breaking shared images (e.g., same file open in org-mode
and image-mode simultaneously)."
  (when kitty-gfx--mpv-process
    (kitty-gfx--mpv-cleanup))
  (when (and kitty-graphics-mode kitty-gfx--overlays)
    (kitty-gfx--log "kill-buffer-hook: buf=%s overlays=%d" (buffer-name) (length kitty-gfx--overlays))
    (let ((deleted-ids nil))
      (dolist (ov kitty-gfx--overlays)
        (condition-case nil
            (let ((id (overlay-get ov 'kitty-gfx-id))
                  (pid (overlay-get ov 'kitty-gfx-pid)))
              (when (and id pid kitty-gfx--active-backend)
                ;; Always delete the placement (it's buffer-specific)
                (funcall (kitty-gfx--backend-fn 'delete) ov id pid))
              ;; Only delete the image data if no other buffer uses it
              (when (and id (not (memq id deleted-ids)))
                (if (kitty-gfx--image-id-in-other-buffers-p id)
                    (kitty-gfx--log "kill-buffer-hook: id=%d still used in other buffers, keeping" id)
                  (push id deleted-ids))))
          (error nil)))
      ;; Remove cache entries only for IDs we actually deleted
      (when deleted-ids
        (kitty-gfx--log "kill-buffer-hook: cleaning cache for ids=%S" deleted-ids)
        (when kitty-gfx--active-backend
          (dolist (id deleted-ids)
            (funcall (kitty-gfx--backend-fn 'cleanup) nil id)))
        (maphash (lambda (file id)
                   (when (memq id deleted-ids)
                     (kitty-gfx--cache-remove file)))
                 (copy-hash-table kitty-gfx--image-cache)))
      (setq kitty-gfx--overlays nil)
      (kitty-gfx--log "kill-buffer-hook: done (cache-count=%d)"
                       (hash-table-count kitty-gfx--image-cache)))))

(provide 'kitty-graphics)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; kitty-graphics.el ends here
