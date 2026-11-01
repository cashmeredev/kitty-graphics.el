;;; kitty-graphics.el --- Display images in the terminal via the Kitty graphics protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 cashmere <cashmere@autistici.org>
;;
;; Author: cashmere <cashmere@autistici.org>
;; Assisted-by: Claude:claude-opus-4-8
;; Maintainer: cashmere <cashmere@autistici.org>
;; Version: 1.4.0
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
;; Architecture: image data is transmitted once per terminal via `a=t'
;; (stored in the terminal without display).  Overlays reserve blank space
;; in Emacs buffers.  After each redisplay, direct placements (`a=p' with
;; cursor positioning) are emitted via `send-string-to-terminal' at the
;; correct screen positions.  Each placement uses a unique placement ID
;; (`p=PID') so repeated placements replace rather than accumulate.
;;
;; Multiple terminals (emacs --daemon + several `emacsclient -t'): output
;; is routed per window to that window's own terminal, and per-client state
;; (backend, cell size, text-sizing level, and which image ids have been
;; transmitted) lives in terminal parameters, so clients on different
;; terminals - even mixed Kitty and Sixel - render correctly at once.
;; Capability probes run lazily, once per terminal, while it is selected.
;; Inline video (mpv) and the casty browser stream a single byte stream to
;; one fd and are therefore bound to the terminal they were launched on;
;; the same buffer shown on a second client renders only its reserved
;; blank area there.
;;
;; Requires: Kitty >= 0.20.0 (direct placement support).
;; Important: Launch Emacs with TERM=xterm-256color for proper color support.
;;
;; Usage:
;;   (require 'kitty-graphics)
;;   (kitty-graphics-setup)
;;   ;; Then org-mode C-c C-x C-v, markdown-mode `markdown-toggle-inline-images',
;;   ;; image-mode, eww images all work.
;;
;; `kitty-graphics-setup' enables the mode the right way for both plain
;; `emacs -nw' and `emacs --daemon': under a daemon there is no terminal
;; at startup, so it defers enabling to the first `emacsclient -t' frame.
;; For a one-off interactive terminal you can also just call
;; `kitty-graphics-mode' directly.

;;; Code:

(require 'cl-lib)

;; Forward declarations for optional dependencies
(declare-function org-element-context "org-element" ())
(declare-function org-element-link-parser "org-element" ())
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
(declare-function doc-view-reconvert-doc "doc-view" ())
(declare-function doc-view-set-up-single-converter "doc-view" ())
(defvar doc-view--current-cache-dir)
(defvar doc-view--image-file-pattern)
(defvar doc-view-resolution)
(defvar doc-view-mupdf-use-svg)
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
(declare-function org-get-todo-state "org" ())
(declare-function org-get-tags "org" (&optional pos local))
(declare-function org-get-todo-face "org" (kwd))
(defvar org-heading-regexp)
(defvar org-comment-regexp)
(defvar image-mode-map)
(declare-function markdown-overlays--resolve-image-url "markdown-overlays" (url))
(declare-function markdown-display-inline-images "markdown-mode" (&optional begin end))
(declare-function markdown-remove-inline-images "markdown-mode" ())
(declare-function markdown-toggle-inline-images "markdown-mode" ())
(declare-function json-encode "json" (object))

;;;; Customization

(defgroup kitty-graphics nil
  "Display images in terminal Emacs via Kitty graphics."
  :group 'multimedia
  :prefix "kitty-graphics-")

(define-obsolete-variable-alias 'kitty-gfx-max-width 'kitty-graphics-max-width "1.3.0")

(defcustom kitty-graphics-max-width 120
  "Maximum image width in terminal columns for inline images.
For full-window modes like doc-view, the window size is used instead."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-max-height 'kitty-graphics-max-height "1.3.0")

(defcustom kitty-graphics-max-height 40
  "Maximum image height in terminal rows for inline images.
For full-window modes like doc-view, the window size is used instead."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-graphics-doc-view-resolution-scale 2.0
  "Render-resolution multiplier for doc-view pages in the terminal.
doc-view renders pages to PNG at a fixed DPI (`doc-view-resolution',
default 100).  When that PNG has fewer pixels than the terminal area
it is drawn into (cols x cell-pixel-width by rows x cell-pixel-height),
the terminal upscales it and text looks blurry.  When the rendered
page is too small, kitty-graphics raises the buffer-local
`doc-view-resolution' so the document is re-rendered with at least
this many times the pixels of the exact-fit display area.
Values above 1.0 also provide zoom headroom: zooming crops source
pixels, so pages stay sharp up to roughly this factor before
upscaling kicks in.  Higher values cost conversion time and memory.
Set to 1.0 for exact-fit rendering, or nil to disable and always use
doc-view's resolution as-is."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-shr-scale 'kitty-graphics-shr-scale "1.3.0")

(defcustom kitty-graphics-shr-scale nil
  "Image sizing for the shr backends (eww, elfeed, mu4e, gnus).
nil renders images at natural size, shrinking only to fit
`kitty-graphics-max-width' and `kitty-graphics-max-height'.
A float (e.g. 0.25) renders every image at that fraction of its
natural size, still capped at the max dimensions.
The symbol `fit' dynamically scales each image into a box derived
from the live window: `kitty-graphics-shr-fit-width' of the window width
and `kitty-graphics-shr-fit-height' rows tall, preserving aspect ratio and
never enlarging images that already fit."
  :type '(choice (const :tag "Natural size (shrink to fit max)" nil)
                 (number :tag "Fraction of natural size")
                 (const :tag "Dynamic window-relative fit" fit))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-shr-fit-width 'kitty-graphics-shr-fit-width "1.3.0")

(defcustom kitty-graphics-shr-fit-width 0.6
  "Fraction of the window width an image may occupy under `fit' sizing.
Only consulted when `kitty-graphics-shr-scale' is `fit'."
  :type 'number
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-shr-fit-height 'kitty-graphics-shr-fit-height "1.3.0")

(defcustom kitty-graphics-shr-fit-height 20
  "Maximum image height in rows under `fit' sizing.
Only consulted when `kitty-graphics-shr-scale' is `fit'."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-org-image-scale 'kitty-graphics-org-image-scale "1.3.0")

(defcustom kitty-graphics-org-image-scale 'fit
  "Sizing for org-mode inline images in the terminal.
nil renders at natural size, shrinking only to fit `kitty-graphics-max-width'
and `kitty-graphics-max-height'.  A float (e.g. 0.25) renders at that fraction
of natural size, still capped at the max dimensions.  The symbol `fit'
scales each image into a box derived from the live window:
`kitty-graphics-org-image-fit-width' of the window width and
`kitty-graphics-org-image-fit-height' rows tall, preserving aspect ratio and
never enlarging images that already fit.  Mirrors `kitty-graphics-shr-scale'
for the eww/mu4e backends.  Defaults to `fit' so large images do not
overflow the window."
  :type '(choice (const :tag "Natural size (shrink to fit max)" nil)
                 (number :tag "Fraction of natural size")
                 (const :tag "Dynamic window-relative fit" fit))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-org-image-fit-width 'kitty-graphics-org-image-fit-width "1.3.0")

(defcustom kitty-graphics-org-image-fit-width 0.8
  "Fraction of the window width an org inline image may occupy under `fit'.
Only consulted when `kitty-graphics-org-image-scale' is `fit'."
  :type 'number
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-org-image-fit-height 'kitty-graphics-org-image-fit-height "1.3.0")

(defcustom kitty-graphics-org-image-fit-height 25
  "Maximum org inline image height in rows under `fit' sizing.
Only consulted when `kitty-graphics-org-image-scale' is `fit'."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-markdown-image-scale 'kitty-graphics-markdown-image-scale "1.3.0")

(defcustom kitty-graphics-markdown-image-scale 'fit
  "Sizing for markdown-mode inline images in the terminal.
nil renders at natural size, shrinking only to fit
`kitty-graphics-max-width' and `kitty-graphics-max-height'.  A float (e.g. 0.25)
renders at that fraction of natural size, still capped at the max
dimensions.  The symbol `fit' scales each image into a box derived from
the live window: `kitty-graphics-markdown-image-fit-width' of the window
width and `kitty-graphics-markdown-image-fit-height' rows tall, preserving
aspect ratio and never enlarging images that already fit.  Defaults to
`fit' so large images do not overflow the window."
  :type '(choice (const :tag "Natural size (shrink to fit max)" nil)
                 (number :tag "Fraction of natural size")
                 (const :tag "Dynamic window-relative fit" fit))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-markdown-image-fit-width 'kitty-graphics-markdown-image-fit-width "1.3.0")

(defcustom kitty-graphics-markdown-image-fit-width 0.8
  "Fraction of the window width a markdown inline image may occupy under `fit'.
Only consulted when `kitty-graphics-markdown-image-scale' is `fit'."
  :type 'number
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-markdown-image-fit-height 'kitty-graphics-markdown-image-fit-height "1.3.0")

(defcustom kitty-graphics-markdown-image-fit-height 25
  "Maximum markdown inline image height in rows under `fit' sizing.
Only consulted when `kitty-graphics-markdown-image-scale' is `fit'."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-chunk-size 'kitty-graphics-chunk-size "1.3.0")

(defcustom kitty-graphics-chunk-size 4096
  "Maximum base64 chunk size for image transfer."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-render-delay 'kitty-graphics-render-delay "1.3.0")

(defcustom kitty-graphics-render-delay 0.016
  "Delay in seconds before re-rendering images after redisplay.
This debounces rapid redisplay events.  Default is ~1 frame at 60fps."
  :type 'number
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-skip-clean-refresh 'kitty-graphics-skip-clean-refresh "1.3.0")

(defcustom kitty-graphics-skip-clean-refresh t
  "When non-nil, skip scheduling a refresh when no window content changed.
`kitty-graphics--on-redisplay' compares each visible overlay window against
the signature stored after the last successful refresh (see
`kitty-graphics--window-signature') and schedules nothing when they all
match.  Set to nil to restore the old refresh-on-every-command
behaviour as an escape hatch."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-async-conversion 'kitty-graphics-async-conversion "1.3.0")

(defcustom kitty-graphics-async-conversion t
  "When non-nil, convert non-PNG images to PNG asynchronously.
The overlay reserves its blank screen area immediately and the image
appears via a forced refresh once the background conversion finishes.
When nil, conversion blocks Emacs as before."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-process-timeout 'kitty-graphics-process-timeout "1.3.0")

(defcustom kitty-graphics-process-timeout 15.0
  "Seconds a blocking external command may run before kitty-graphics kills it.
Applies to the ImageMagick/identify pixel-size probe, PNG conversion,
ffmpeg thumbnail extraction, and typst compilation, so a hung or
pathological external process cannot freeze Emacs.  Sixel encoding has
its own bound, `kitty-graphics-sixel-encoder-timeout'.  Set to nil or 0 to
disable the watchdog."
  :type '(choice (const :tag "No timeout" nil) number)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-debug 'kitty-graphics-debug "1.3.0")

(defcustom kitty-graphics-debug (and (getenv "KITTY_GFX_DEBUG") t)
  "When non-nil, log debug info to *kitty-graphics-debug* buffer.
Defaults to t when the KITTY_GFX_DEBUG environment variable is set."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-enable-video 'kitty-graphics-enable-video "1.3.0")

(defcustom kitty-graphics-enable-video nil
  "When non-nil, enable inline video playback via mpv.
Requires mpv with --vo=kitty support (mpv 0.36.0+) on the Kitty
backend; on the Sixel backend it needs an mpv built with libsixel
(--vo=sixel, experimental)."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-enable-browser 'kitty-graphics-enable-browser "1.3.0")

(defcustom kitty-graphics-enable-browser nil
  "When non-nil, enable the inline casty web browser.
Requires the casty program (see `kitty-graphics-casty-program') built
with embed-mode support, and the Kitty backend."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-casty-program 'kitty-graphics-casty-program "1.3.0")

(defcustom kitty-graphics-casty-program "casty"
  "Program name or path used to launch the casty browser in embed mode."
  :type 'string
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-casty-chrome 'kitty-graphics-casty-chrome "1.3.0")

(defcustom kitty-graphics-casty-chrome nil
  "Path to a Chromium-based browser for casty to drive, or nil.
When set, it is passed to casty as the CASTY_CHROME environment
variable so casty reuses an already-installed browser (Chromium,
Helium, Brave, …) instead of downloading Chrome Headless Shell."
  :type '(choice (const :tag "casty default" nil) (file :tag "Browser binary"))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-browser-max-width 'kitty-graphics-browser-max-width "1.3.0")

(defcustom kitty-graphics-browser-max-width 200
  "Maximum width in columns for the inline browser frame."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-browser-max-height 'kitty-graphics-browser-max-height "1.3.0")

(defcustom kitty-graphics-browser-max-height 60
  "Maximum height in rows for the inline browser frame."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-browser-scroll-step 'kitty-graphics-browser-scroll-step "1.3.0")

(defcustom kitty-graphics-browser-scroll-step 300
  "Pixels scrolled per `j'/`k' keypress in the inline browser."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-browser-evil-bindings 'kitty-graphics-browser-evil-bindings "1.3.0")

(defcustom kitty-graphics-browser-evil-bindings t
  "When non-nil, mirror the browser keymap into evil normal/motion state."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-video-file-extensions 'kitty-graphics-video-file-extensions "1.3.0")

(defcustom kitty-graphics-video-file-extensions
  '("mp4" "mkv" "webm" "mov" "m4v" "avi")
  "File extensions handled by inline mpv preview in dired / dirvish.
Compared lowercase against `file-name-extension'."
  :type '(repeat string)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-play-gifs-with-mpv 'kitty-graphics-play-gifs-with-mpv "1.3.0")

(defcustom kitty-graphics-play-gifs-with-mpv t
  "When non-nil, opening a GIF plays it animated through mpv.
GIF still previews as a static first-frame thumbnail while browsing
dired / dirvish (it stays an image for `kitty-graphics--image-file-p'); this
only affects what happens when the file is opened for playback, where
mpv loops the animation.  Has no effect when mpv is unavailable."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-video-thumbnail-seek 'kitty-graphics-video-thumbnail-seek "1.3.0")

(defcustom kitty-graphics-video-thumbnail-seek "0.5"
  "Seconds offset into a video at which thumbnails are extracted.
Passed verbatim as `-ss' to ffmpeg.  A small positive offset
avoids the all-black title frame some encoders produce at t=0."
  :type 'string
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-dired-preview-debounce 'kitty-graphics-dired-preview-debounce "1.3.0")

(defcustom kitty-graphics-dired-preview-debounce 0.3
  "Idle seconds before `kitty-graphics-dired-auto-preview-mode' previews
the file at point after the cursor moves."
  :type 'number
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-dirvish-video-inline-preview 'kitty-graphics-dirvish-video-inline-preview "1.3.0")

(defcustom kitty-graphics-dirvish-video-inline-preview nil
  "Where to play a video opened with RET inside a dirvish session.
When nil (the default), tear down the dirvish layout and play the
video full-frame, matching dirvish's behaviour for regular files
and images.  When non-nil, keep the dirvish layout and play the
video inside the existing preview side window."
  :type 'boolean
  :group 'kitty-graphics)

(defvar kitty-graphics--log-file (expand-file-name "kitty-graphics.log" temporary-file-directory)
  "File path for debug log output.")

(defvar kitty-graphics--dry-run nil
  "When non-nil, log escape sequences instead of sending to terminal.
Useful for debugging and batch testing without a real terminal.")

(defun kitty-graphics--log (fmt &rest args)
  "Log to `kitty-graphics--log-file' and the debug buffer when debug is on.
Log lines also go to the *kitty-graphics-debug* buffer."
  (when kitty-graphics-debug
    (let ((msg (concat (format-time-string "%H:%M:%S.%3N ")
                       (apply #'format fmt args) "\n")))
      ;; Write silently: `append-to-file' echoes "Added to <file>" to the echo
      ;; area, which would set `current-message' and make
      ;; `kitty-graphics--refresh-inhibited-p' treat every debug-log write as user
      ;; feedback — permanently inhibiting the refresh that paints images.
      (ignore-errors
        (let ((inhibit-message t)
              (message-log-max nil))
          (write-region msg nil kitty-graphics--log-file 'append 'silent)))
      (ignore-errors
        (let ((buf (get-buffer-create "*kitty-graphics-debug*")))
          (with-current-buffer buf
            (goto-char (point-max))
            (insert msg)
            ;; Trim buffer at 2500 lines
            (when (> (line-number-at-pos (point-max)) 2500)
              (goto-char (point-min))
              (forward-line 500)
              (delete-region (point-min) (point)))))))))

(defvar kitty-graphics--messaged-once (make-hash-table :test 'equal)
  "Keys of one-time user messages already shown this session.
Used by `kitty-graphics--message-once' so recurring conditions (encode
failures, tmux misconfiguration) surface exactly one echo-area
message instead of spamming on every refresh.")

(defun kitty-graphics--message-once (key msg)
  "Show MSG in the echo area at most once per session for KEY.
Repeat calls with the same KEY only log MSG.  Returns MSG."
  (if (gethash key kitty-graphics--messaged-once)
      (kitty-graphics--log "message-once: suppressed %s" key)
    (puthash key t kitty-graphics--messaged-once)
    (message "%s" msg))
  msg)

(define-obsolete-variable-alias 'kitty-gfx-tmux-passthrough 'kitty-graphics-tmux-passthrough "1.3.0")

(defcustom kitty-graphics-tmux-passthrough t
  "When non-nil, wrap Kitty graphics APC sequences with the tmux DCS
passthrough envelope inside tmux.  Required for the Kitty protocol to
traverse tmux when `allow-passthrough' is on.  Plain CSI sequences and
text bytes are never wrapped — tmux handles those natively and needs to
see them to keep its own grid in sync.  Sixel DCS is also left unwrapped
because tmux 3.4+ renders Sixel itself.  Set to nil to disable entirely."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-kitty-placement-mode 'kitty-graphics-kitty-placement-mode "1.3.0")

(defcustom kitty-graphics-kitty-placement-mode 'auto
  "Placement strategy for the Kitty graphics backend.

- `direct' — emit an `a=p,c,r' APC at the image's terminal-screen
  coordinates.  Simple and broadly supported, but inside a terminal
  multiplexer the image lives in the outer terminal's pixel layer
  where the multiplexer cannot evict it, so the image ghosts on pane
  / window switches.

- `placeholder' — use the Kitty graphics protocol's Unicode
  placeholder mode.  Transmit the image with `a=t' (store only),
  register a virtual placement with `a=p,U=1', and write `U+10EEEE'
  cells with row/column diacritics plus an image-id-encoded SGR
  foreground into the area the overlay covers.  Those cells live in
  the multiplexer's character grid as regular text, so window
  switches and buffer scrolling are handled by the multiplexer
  naturally; no ghost survives.  Requires the outer terminal to
  implement the placeholder protocol — verified on kitty.app and
  Ghostty 1.3+; other terminals may need additional work.

- `auto' (default) — `placeholder' when running inside tmux (where
  the ghost problem is worst), `direct' otherwise."
  :type '(choice (const :tag "Auto (placeholder inside tmux, direct otherwise)" auto)
                 (const :tag "Direct screen placement (a=p,c,r)" direct)
                 (const :tag "Unicode placeholder (U=1)" placeholder))
  :group 'kitty-graphics)

(defvar kitty-graphics--target-terminal nil
  "Terminal object `kitty-graphics--terminal-send' should write to.
nil means the selected frame's terminal — the historical default and
the only behaviour outside a multi-client daemon.  `kitty-graphics--refresh'
binds this per window so each client's escapes reach its own tty, and
the mpv/casty filters bind it to the terminal playback started on.")

(defun kitty-graphics--target-frame ()
  "Return a live frame for `kitty-graphics--target-terminal'.
Falls back to the selected frame when there is no target terminal.
Resolves per-client environment (e.g. TMUX) for the terminal that
`kitty-graphics--terminal-send' is currently writing to."
  (or (and kitty-graphics--target-terminal
           (terminal-live-p kitty-graphics--target-terminal)
           (car (frames-on-display-list kitty-graphics--target-terminal)))
      (selected-frame)))

(defun kitty-graphics--tparam (key)
  "Read terminal-parameter KEY for `kitty-graphics--target-terminal'.
nil target means the selected frame's terminal."
  (terminal-parameter kitty-graphics--target-terminal key))

(defun kitty-graphics--set-tparam (key value)
  "Set terminal-parameter KEY to VALUE for `kitty-graphics--target-terminal'.
nil target means the selected frame's terminal.  Returns VALUE."
  (set-terminal-parameter kitty-graphics--target-terminal key value)
  value)

(defun kitty-graphics--clear-terminal-state (term)
  "Drop all kitty-graphics per-client state stored on terminal TERM.
Clears the detected backend, queried cell size, text-sizing level,
tmux probe results, and the query/transmission bookkeeping so the
terminal is treated as fresh."
  (when (terminal-live-p term)
    (set-terminal-parameter term 'kitty-graphics-backend nil)
    (set-terminal-parameter term 'kitty-graphics-cell-w nil)
    (set-terminal-parameter term 'kitty-graphics-cell-h nil)
    (set-terminal-parameter term 'kitty-graphics-text-sizing nil)
    (set-terminal-parameter term 'kitty-graphics-tmux-version nil)
    (set-terminal-parameter term 'kitty-graphics-tmux-passthrough nil)
    (set-terminal-parameter term 'kitty-graphics-transmitted nil)
    (set-terminal-parameter term 'kitty-graphics-virtual-dims nil)))

;; Kitty stores transmitted image data per terminal: an `a=t' transmit to
;; client A's tty does not exist on client B's tty.  The global file->id
;; cache assigns one id per file for all clients, but whether that id's
;; bytes have actually reached a given terminal is tracked here, per
;; terminal, so each new client re-transmits on first use.
(defun kitty-graphics--transmitted-p (id)
  "Non-nil if image ID was transmitted to `kitty-graphics--target-terminal'."
  (let ((h (kitty-graphics--tparam 'kitty-graphics-transmitted)))
    (and h (gethash id h))))

(defun kitty-graphics--mark-transmitted (id)
  "Record that image ID has been transmitted to `kitty-graphics--target-terminal'."
  (let ((h (or (kitty-graphics--tparam 'kitty-graphics-transmitted)
               (kitty-graphics--set-tparam 'kitty-graphics-transmitted
                                      (make-hash-table)))))
    (puthash id t h)))

(defun kitty-graphics--terminal-transmitted-p (term id)
  "Non-nil if image ID was transmitted to terminal TERM."
  (let ((h (terminal-parameter term 'kitty-graphics-transmitted)))
    (and h (gethash id h))))

(defun kitty-graphics--terminal-unmark-transmitted (term id)
  "Forget that image ID was transmitted to terminal TERM."
  (let ((h (terminal-parameter term 'kitty-graphics-transmitted)))
    (when h (remhash id h))))

(defmacro kitty-graphics--with-terminal (term &rest body)
  "Evaluate BODY with output routed to TERM and per-terminal state bound.
Shadows the backend, cell-size, and text-sizing globals with TERM's
stored terminal parameters (falling back to the current global default),
so the render-path read sites observe per-terminal values without each
needing terminal awareness.  The globals are special variables, so these
`let*' bindings are dynamic and visible throughout BODY's call tree."
  (declare (indent 1) (debug (form body)))
  (let ((tv (make-symbol "term")))
    `(let* ((,tv ,term)
            (kitty-graphics--target-terminal ,tv)
            (kitty-graphics--active-backend
             (or (terminal-parameter ,tv 'kitty-graphics-backend)
                 kitty-graphics--active-backend))
            (kitty-graphics--cell-pixel-width
             (or (terminal-parameter ,tv 'kitty-graphics-cell-w)
                 kitty-graphics--cell-pixel-width))
            (kitty-graphics--cell-pixel-height
             (or (terminal-parameter ,tv 'kitty-graphics-cell-h)
                 kitty-graphics--cell-pixel-height))
            (kitty-graphics--text-sizing-support
             (or (terminal-parameter ,tv 'kitty-graphics-text-sizing)
                 kitty-graphics--text-sizing-support)))
       ,@body)))

(defun kitty-graphics--wrap-tmux-passthrough (str)
  "Wrap STR with tmux DCS passthrough envelope.
Doubles every ESC in STR and surrounds with `\\ePtmux;' ... `\\e\\\\'.
Requires `allow-passthrough on' in tmux for the outer terminal to
actually see the unwrapped payload."
  (concat "\ePtmux;"
          (replace-regexp-in-string "\e" "\e\e" str t t)
          "\e\\"))

(defun kitty-graphics--needs-tmux-wrap-p (str)
  "Return non-nil if STR contains a Kitty graphics APC that tmux would eat.
Only APC sequences starting with `\\e_G' (the Kitty graphics indicator)
need the passthrough wrapper; plain CSI movement, SGR, OSC, and raw
text all pass through tmux untouched and must NOT be wrapped (tmux
needs them to update its own grid for tmux-window-switch correctness)."
  (and kitty-graphics-tmux-passthrough
       (kitty-graphics--frame-getenv "TMUX" (kitty-graphics--target-frame))
       (string-match-p "\e_G" str)))

(defun kitty-graphics--terminal-send (str)
  "Send STR to terminal, or log it in dry-run mode.
All terminal escape output should go through this function.

Inside tmux, Kitty graphics APC sequences are wrapped with the tmux DCS
passthrough envelope so they reach the outer terminal.  Everything else
is emitted raw."
  (let ((payload (if (kitty-graphics--needs-tmux-wrap-p str)
                     (kitty-graphics--wrap-tmux-passthrough str)
                   str)))
    (if kitty-graphics--dry-run
        (kitty-graphics--log "DRY-RUN-SEND: %S" payload)
      (ignore-errors
        (send-string-to-terminal payload kitty-graphics--target-terminal)))))

;;;; Unicode placeholder protocol constants

(defconst kitty-graphics--placeholder-char ?\x10EEEE
  "Base code point of a Kitty graphics Unicode placeholder cell.
Each rendered cell consists of this character followed by two
combining marks from `kitty-graphics--diacritics' encoding the (row,
col) into the image, with the cell's truecolor SGR foreground
encoding the image identifier.  See the Kitty graphics protocol's
Unicode-placeholder section for the exact rules.")

;; The placeholder code point lives in the Supplementary Private Use
;; Area-B.  Emacs' default Unicode width tables classify it as 2-wide,
;; but the protocol mandates one cell per placeholder.  Pinning the
;; width to 1 at load time keeps every (PH + row-dia + col-dia) triple
;; on a single terminal cell — without this, the overlay's reserved
;; blank area and the placeholder cells we paint over it disagree on
;; cell count, stretching or wrapping the image.
(set-char-table-range char-width-table kitty-graphics--placeholder-char 1)

(defconst kitty-graphics--diacritics
  [#x0305  #x030D  #x030E  #x0310  #x0312  #x033D  #x033E  #x033F
   #x0346  #x034A  #x034B  #x034C  #x0350  #x0351  #x0352  #x0357
   #x035B  #x0363  #x0364  #x0365  #x0366  #x0367  #x0368  #x0369
   #x036A  #x036B  #x036C  #x036D  #x036E  #x036F  #x0483  #x0484
   #x0485  #x0486  #x0487  #x0592  #x0593  #x0594  #x0595  #x0597
   #x0598  #x0599  #x059C  #x059D  #x059E  #x059F  #x05A0  #x05A1
   #x05A8  #x05A9  #x05AB  #x05AC  #x05AF  #x05C4  #x0610  #x0611
   #x0612  #x0613  #x0614  #x0615  #x0616  #x0617  #x0657  #x0658
   #x0659  #x065A  #x065B  #x065D  #x065E  #x06D6  #x06D7  #x06D8
   #x06D9  #x06DA  #x06DB  #x06DC  #x06DF  #x06E0  #x06E1  #x06E2
   #x06E4  #x06E7  #x06E8  #x06EB  #x06EC  #x0730  #x0732  #x0733
   #x0735  #x0736  #x073A  #x073D  #x073F  #x0740  #x0741  #x0743
   #x0745  #x0747  #x0749  #x074A  #x07EB  #x07EC  #x07ED  #x07EE
   #x07EF  #x07F0  #x07F1  #x07F3  #x0816  #x0817  #x0818  #x0819
   #x081B  #x081C  #x081D  #x081E  #x081F  #x0820  #x0821  #x0822
   #x0823  #x0825  #x0826  #x0827  #x0829  #x082A  #x082B  #x082C
   #x082D  #x0951  #x0953  #x0954  #x0F82  #x0F83  #x0F86  #x0F87
   #x135D  #x135E  #x135F  #x17DD  #x193A  #x1A17  #x1A75  #x1A76
   #x1A77  #x1A78  #x1A79  #x1A7A  #x1A7B  #x1A7C  #x1B6B  #x1B6D
   #x1B6E  #x1B6F  #x1B70  #x1B71  #x1B72  #x1B73  #x1CD0  #x1CD1
   #x1CD2  #x1CDA  #x1CDB  #x1CE0  #x1DC0  #x1DC1  #x1DC3  #x1DC4
   #x1DC5  #x1DC6  #x1DC7  #x1DC8  #x1DC9  #x1DCB  #x1DCC  #x1DD1
   #x1DD2  #x1DD3  #x1DD4  #x1DD5  #x1DD6  #x1DD7  #x1DD8  #x1DD9
   #x1DDA  #x1DDB  #x1DDC  #x1DDD  #x1DDE  #x1DDF  #x1DE0  #x1DE1
   #x1DE2  #x1DE3  #x1DE4  #x1DE5  #x1DE6  #x1DFE  #x20D0  #x20D1
   #x20D4  #x20D5  #x20D6  #x20D7  #x20DB  #x20DC  #x20E1  #x20E7
   #x20E9  #x20F0  #x2CEF  #x2CF0  #x2CF1  #x2DE0  #x2DE1  #x2DE2
   #x2DE3  #x2DE4  #x2DE5  #x2DE6  #x2DE7  #x2DE8  #x2DE9  #x2DEA
   #x2DEB  #x2DEC  #x2DED  #x2DEE  #x2DEF  #x2DF0  #x2DF1  #x2DF2
   #x2DF3  #x2DF4  #x2DF5  #x2DF6  #x2DF7  #x2DF8  #x2DF9  #x2DFA
   #x2DFB  #x2DFC  #x2DFD  #x2DFE  #x2DFF  #xA66F  #xA67C  #xA67D
   #xA6F0  #xA6F1  #xA8E0  #xA8E1  #xA8E2  #xA8E3  #xA8E4  #xA8E5
   #xA8E6  #xA8E7  #xA8E8  #xA8E9  #xA8EA  #xA8EB  #xA8EC  #xA8ED
   #xA8EE  #xA8EF  #xA8F0  #xA8F1  #xAAB0  #xAAB2  #xAAB3  #xAAB7
   #xAAB8  #xAABE  #xAABF  #xAAC1  #xFE20  #xFE21  #xFE22  #xFE23
   #xFE24  #xFE25  #xFE26  #x10A0F #x10A38 #x1D185 #x1D186 #x1D187
   #x1D188 #x1D189 #x1D1AA #x1D1AB #x1D1AC #x1D1AD #x1D242 #x1D243
   #x1D244]
  "297 combining-mark code points used by the Kitty graphics Unicode
placeholder protocol to encode row/column indices.  Cell (Y, X) of an
image is referenced by appending `(aref kitty-graphics--diacritics Y)' then
`(aref kitty-graphics--diacritics X)' after `kitty-graphics--placeholder-char'.
Hard limit: images > 297 cells in either dimension cannot use this
mode.  Order is significant — do not sort.")

(defun kitty-graphics--effective-placement-mode ()
  "Resolve `kitty-graphics-kitty-placement-mode' to `direct' or `placeholder'.
The `auto' value chooses `placeholder' inside tmux (where direct
placement leaks images across pane switches) and `direct' outside
\(where direct is simpler and the ghost problem does not apply).
TMUX is read from the target frame's environment, matching the frame
`kitty-graphics--needs-tmux-wrap-p' wraps for, so a multi-tty daemon does
not resolve a tmux client's mode from whichever frame is selected."
  (pcase kitty-graphics-kitty-placement-mode
    ('direct 'direct)
    ('placeholder 'placeholder)
    (_ (if (kitty-graphics--frame-getenv "TMUX" (kitty-graphics--target-frame))
           'placeholder
         'direct))))

(defun kitty-graphics--emit-placeholder-cells (image-id cols rows term-row term-col)
  "Emit a COLS x ROWS block of Kitty Unicode placeholder cells.

Bytes are written via `kitty-graphics--terminal-send' rather than going
through Emacs's display engine: Emacs strips combining diacritics
attached to private-use base characters such as U+10EEEE, which
would silently break the protocol.  Calling this from a TTY display
context is therefore correct only when something else (an overlay
display string, in our case) has already reserved the screen cells.

Each cell encodes the image identifier via the truecolor SGR
foreground and the cell's image-relative (row, col) via two
combining diacritics from `kitty-graphics--diacritics'.  IMAGE-ID must
fit in 24 bits; the protocol's optional fourth combining character
for an extra MSB byte is not produced here.

TERM-ROW and TERM-COL are 1-based terminal coordinates of the
image area's top-left.  COLS and ROWS beyond the diacritic table's
297 entries are clamped — the protocol cannot address further cells,
and signaling here would abort the whole refresh cycle.  The emission
is bracketed by DECSC/DECRC \(`\\e7' / `\\e8') so the caller's cursor
and SGR state are preserved."
  (let ((max (length kitty-graphics--diacritics)))
    (when (> image-id #xffffff)
      (error "kitty-graphics: image id %d exceeds 24 bits — \
placeholder mode cannot encode it" image-id))
    (when (or (> rows max) (> cols max))
      (kitty-graphics--log "emit-placeholder-cells: clamping %dx%d to grid max %d"
                      cols rows max)
      (setq cols (min cols max)
            rows (min rows max))))
  (let* ((sgr (format "\e[38;2;%d;%d;%dm"
                      (logand (ash image-id -16) #xff)
                      (logand (ash image-id -8)  #xff)
                      (logand image-id           #xff)))
         (ph (string kitty-graphics--placeholder-char))
         (parts (list "\e7" sgr)))
    (dotimes (y rows)
      (push (format "\e[%d;%dH" (+ term-row y) term-col) parts)
      (let ((row-dia (string (aref kitty-graphics--diacritics y))))
        (dotimes (x cols)
          (push ph parts)
          (push row-dia parts)
          (push (string (aref kitty-graphics--diacritics x)) parts))))
    (push "\e[0m\e8" parts)
    (kitty-graphics--terminal-send (mapconcat #'identity (nreverse parts) ""))))

;;;; Internal state

;; Forward declaration — defined by `define-minor-mode' below.
(defvar kitty-graphics-mode)

(defvar kitty-graphics--active-backend nil
  "Symbol identifying the active graphics backend: `kitty' or `sixel'.
Set by `kitty-graphics--detect-protocol'.")

(defvar kitty-graphics--backends nil
  "Alist mapping backend symbols to operation alists.
Each backend alist maps operation symbols to functions:
  `detect'      — () -> bool: return non-nil if backend is supported
  `prepare'     — (file image-id) -> id-or-nil: prepare/transmit image
  `place'       — (ov id pid cols rows term-row term-col): place image
  `delete'      — (ov id pid): delete placement
  `cleanup'     — (file id): cleanup resources for file
  `cleanup-all' — (): cleanup all resources.")

(defvar kitty-graphics--next-id 1
  "Next image ID to assign (1-4294967295).
With direct placements, any uint32 ID works — no 256-color constraint.")

(define-obsolete-variable-alias 'kitty-gfx-cache-size 'kitty-graphics-cache-size "1.3.0")

(defcustom kitty-graphics-cache-size 64
  "Maximum number of images to keep in the terminal-side cache.
When exceeded, the least recently used image is evicted and its
terminal data deleted via `a=d'."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-base64-cache-bytes 'kitty-graphics-base64-cache-bytes "1.3.0")

(defcustom kitty-graphics-base64-cache-bytes 67108864
  "Maximum total bytes of base64-encoded image data to cache in memory.
`kitty-graphics--read-file-base64' keeps encoded payloads keyed by file and
modification time so re-transmits to additional terminals skip the
read+encode cost.  Least-recently-used entries are evicted when the
total exceeds this cap; a single payload larger than the cap is never
cached."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-preferred-protocol 'kitty-graphics-preferred-protocol "1.3.0")

(defcustom kitty-graphics-preferred-protocol 'auto
  "Preferred graphics protocol to use.
Choices: `auto' (try Kitty first, then Sixel), `kitty', or `sixel'.
Default is `auto'."
  :type '(choice (const :tag "Auto-detect (Kitty → Sixel)" auto)
                 (const :tag "Kitty graphics protocol" kitty)
                 (const :tag "Sixel protocol" sixel))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-sixel-encoder-program 'kitty-graphics-sixel-encoder-program "1.3.0")

(defcustom kitty-graphics-sixel-encoder-program nil
  "Program used to encode raster images to Sixel.
When nil, auto-detect: prefer `img2sixel' (libsixel), then
`magick' (ImageMagick 7), then `convert' (ImageMagick 6, deprecated).
When set to a string, use that program and treat it as `img2sixel'-style
unless the basename is `magick' or `convert'."
  :type '(choice (const :tag "Auto-detect" nil) string)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-sixel-encoder-args 'kitty-graphics-sixel-encoder-args "1.3.0")

(defcustom kitty-graphics-sixel-encoder-args nil
  "Extra arguments passed to `kitty-graphics-sixel-encoder-program'.
The raw escape hatch: appended after the dither/palette arguments
derived from `kitty-graphics-sixel-dither' and `kitty-graphics-sixel-colors'.
For img2sixel these come before the per-invocation size flags and the
input file; for ImageMagick they come after the `-geometry' resize and
before the `sixel:-' output."
  :type '(repeat string)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-sixel-dither 'kitty-graphics-sixel-dither "1.3.0")

(defcustom kitty-graphics-sixel-dither nil
  "Dithering algorithm for Sixel encoding, or nil for the encoder default.
\"none\" disables dithering, \"fs\" selects Floyd-Steinberg, and
\"atkinson\" selects Atkinson.  img2sixel supports all three via
`-d'; ImageMagick maps \"none\" to `+dither' and both \"fs\" and
\"atkinson\" to `-dither FloydSteinberg' (Atkinson is img2sixel-only)."
  :type '(choice (const :tag "Encoder default" nil)
                 (const :tag "No dithering" "none")
                 (const :tag "Floyd-Steinberg" "fs")
                 (const :tag "Atkinson (img2sixel only)" "atkinson"))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-sixel-colors 'kitty-graphics-sixel-colors "1.3.0")

(defcustom kitty-graphics-sixel-colors 256
  "Number of palette colors for Sixel encoding.
Passed as `-p N' to img2sixel and `-colors N' to ImageMagick.
Lower values shrink the Sixel payload at the cost of color fidelity;
nil leaves the palette size to the encoder."
  :type '(choice (const :tag "Encoder default" nil) integer)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-sixel-encoder-timeout 'kitty-graphics-sixel-encoder-timeout "1.3.0")

(defcustom kitty-graphics-sixel-encoder-timeout 5.0
  "Maximum time in seconds to wait for a single Sixel encoder run.
When nil, wait indefinitely.  Encoders that hang on a malformed image
will otherwise block Emacs."
  :type '(choice (const :tag "No timeout" nil) number)
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-tmux-allow-sixel 'kitty-graphics-tmux-allow-sixel "1.3.0")

(defcustom kitty-graphics-tmux-allow-sixel t
  "When non-nil, allow the Sixel backend to engage inside tmux >= 3.4.
tmux 3.4 (released 2024-02-13) ships native Sixel rendering, so this
package no longer hard-disables Sixel under tmux.  Set to nil if your
tmux is built without `--enable-sixel' or if you prefer to avoid the
upstream scroll artifact: tmux's cell buffer is not pixel-aware, so
images may persist after scrolling until the affected cells are
overwritten."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-heading-scales 'kitty-graphics-heading-scales "1.3.0")

(defcustom kitty-graphics-heading-scales '((1 . 2.0) (2 . 1.5) (3 . 1.2))
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

(define-obsolete-variable-alias 'kitty-gfx-heading-min-scale 'kitty-graphics-heading-min-scale "1.3.0")

(defcustom kitty-graphics-heading-min-scale 1.2
  "Smallest scale worth rendering as a multicell heading.
Any scale > 1.0 needs at least two terminal rows (a glyph that tall
cannot fit in one cell), so a barely-larger heading doubles its line
height for little visual gain.  Configured scales above 1.0 but below
this threshold are left at normal one-row size.  Set to 1.0 to scale
every heading whose scale exceeds 1.0."
  :type 'number
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-heading-valign 'kitty-graphics-heading-valign "1.3.0")

(defcustom kitty-graphics-heading-valign 2
  "Vertical alignment of scaled heading text within its multicell block.
One of 0 (top), 1 (bottom), or 2 (centered).  Emitted as the OSC 66
`v=' parameter, which Kitty honors only for fractionally-scaled text
\(scales like 1.5 or 1.2 that render shorter than the rows they
reserve).  Integer scales such as 2.0 fill their block exactly, so this
has no effect on them.  Centering removes the gap a fractional heading
would otherwise leave below itself."
  :type '(choice (const :tag "Top" 0)
                 (const :tag "Bottom" 1)
                 (const :tag "Centered" 2))
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-heading-fontify-keywords 'kitty-graphics-heading-fontify-keywords "1.3.0")

(defcustom kitty-graphics-heading-fontify-keywords t
  "When non-nil, render a scaled org heading's parts in their own colors.
The TODO/DONE keyword, priority cookie, title, and tags are emitted as
separate OSC 66 segments, each with the SGR of the face Emacs would
fontify it with (`org-todo'/`org-done', `org-priority', `org-level-N',
`org-tag').  When nil, only the plain title is shown, rendered in the
heading-level color (the pre-1.1 behavior)."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-heading-sizes-auto 'kitty-graphics-heading-sizes-auto "1.3.0")

(defcustom kitty-graphics-heading-sizes-auto nil
  "When non-nil, automatically apply heading sizes in org buffers.
Heading sizes are applied when `org-mode' is activated and
`kitty-graphics-mode' is enabled.  Set to nil to require manual
activation via `kitty-graphics-org-heading-sizes'."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-heading-scan-visible-only 'kitty-graphics-heading-scan-visible-only "1.3.0")

(defcustom kitty-graphics-heading-scan-visible-only t
  "When non-nil, instrument org headings only around the visible region.
Heading overlays are created lazily for the displayed window region
plus a margin of two screenfuls in each direction, driven by scroll
and window-change hooks.  Keeps activation cheap in buffers with
thousands of headings.  Set to nil to scan the whole buffer up front
\(the pre-0.7 behavior)."
  :type 'boolean
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-heading-conflicting-modes 'kitty-graphics-heading-conflicting-modes "1.3.0")

(defcustom kitty-graphics-heading-conflicting-modes
  '(org-modern-mode org-appear-mode org-indent-mode visual-line-mode olivetti-mode)
  "Minor modes temporarily disabled while OSC 66 heading sizes are active.
These modes attach display properties, virtual indentation, soft
wrapping, or window margins that corrupt the heading position math or
the OSC 66 payload.  Their prior state is saved and restored when
heading sizes are turned off."
  :type '(repeat symbol)
  :group 'kitty-graphics)

(defvar kitty-graphics--image-cache (make-hash-table :test 'equal)
  "Maps file paths to image IDs (integers).
Only stores the terminal-side image ID — display dimensions are
computed fresh each time to avoid stale values from different
display contexts (window sizes, zoom levels, etc.).")

(defvar kitty-graphics--cache-lru nil
  "LRU list of file paths in `kitty-graphics--image-cache'.
Most recently used at the front.")

(defvar kitty-graphics--png-cache (make-hash-table :test 'equal)
  "Maps source file paths to (MTIME . PNG-PATH) conversion results.
Consulted by `kitty-graphics--convert-to-png' before shelling out and
populated after every successful conversion (sync or async).  Stale
entries (source mtime changed) are reconverted and their old temp PNG
deleted.")

(defvar kitty-graphics--converting (make-hash-table :test 'equal)
  "Maps file paths to the list of callbacks awaiting an async conversion.
A key's presence means a conversion process for that file is in
flight; further requests append their callback instead of spawning a
second process.")

(defvar kitty-graphics--transmit-queue nil
  "Pending image transmits as a list of (TERMINAL FILE IMAGE-ID).
Filled by `kitty-graphics--ensure-transmitted' when a terminal lacks an
image's data; drained one entry per tick by
`kitty-graphics--transmit-drain' so a newly attached client does not block
Emacs transmitting its whole backlog inside one refresh.")

(defvar kitty-graphics--transmit-drain-timer nil
  "Repeating timer that drains `kitty-graphics--transmit-queue'.")

(defvar kitty-graphics--transmit-drain-succeeded nil
  "Non-nil when the current drain cycle transmitted at least one image.
Gates the trailing forced refresh in `kitty-graphics--transmit-drain': a
cycle of pure failures must not force a refresh, because that refresh
would re-queue the same failing transmit and spin forever.")

(defvar kitty-graphics--base64-cache (make-hash-table :test 'equal)
  "Maps file paths to (MTIME . BASE64-STRING) for transmitted images.
Bounded by `kitty-graphics-base64-cache-bytes'; see
`kitty-graphics--base64-cache-lru' for eviction order.")

(defvar kitty-graphics--base64-cache-lru nil
  "LRU list of file paths in `kitty-graphics--base64-cache'.
Most recently used at the front.")

(defvar kitty-graphics--base64-cache-total 0
  "Total bytes of base64 payloads currently in `kitty-graphics--base64-cache'.")

(defvar-local kitty-graphics--overlays nil
  "Image overlays in this buffer.")

(defvar kitty-graphics--render-timer nil
  "Timer for deferred re-rendering.")

(defvar kitty-graphics--force-redisplay nil
  "Non-nil when the next refresh must call `(redisplay t)' first.
See full docstring near `kitty-graphics--schedule-refresh'.")

(defvar kitty-graphics--cell-pixel-width nil
  "Terminal cell width in pixels (queried on startup).")

(defvar kitty-graphics--cell-pixel-height nil
  "Terminal cell height in pixels (queried on startup).")

;; kitty-graphics--placeholder-width removed — direct placements don't use placeholders

(defvar kitty-graphics--next-placement-id 1
  "Next placement ID (p=PID) for direct placements.
Each overlay gets a unique PID so repeated placements replace
rather than accumulate.")

(defvar kitty-graphics--text-sizing-support nil
  "Cached text sizing protocol support level.
nil means not yet queried.  Possible values after query:
  `scale'  -- full support (s= and w= both work, Kitty >= 0.40.0)
  `width'  -- width-only support (w= works, s= does not)
  `none'   -- no support (terminal ignores OSC 66 entirely)")

(defvar-local kitty-graphics--heading-rescan-timer nil
  "Timer for debouncing heading re-scans after text edits.
Prevents queuing redundant stale-heading updates when multiple
characters are typed rapidly.")

(defvar-local kitty-graphics--heading-sizes-enabled nil
  "Non-nil while scaled heading sizes are active in this org buffer.
Set by `kitty-graphics-org-heading-sizes' and the auto-enable hook;
consulted by the scroll/window-change hooks that drive
visible-region heading scans.")

(defvar kitty-graphics--heading-flush-needed nil
  "Non-nil when a heading reservation changed during refresh phase 1.
Set by `kitty-graphics--heading-sync-reservation' whenever an overlay's
space-reservation display strings were just mutated.  Consumed by
`kitty-graphics--refresh', which must flush those strings to the terminal
with `redisplay' BEFORE phase 2 emits OSC 66 — otherwise the next
redisplay would draw the spaces on top of the freshly painted
multicell block and clip its leading glyphs.")

(defvar-local kitty-graphics--mpv-process nil
  "The mpv process object for the current buffer's video.")

(defvar-local kitty-graphics--mpv-ipc-socket nil
  "Path to the mpv JSON IPC socket file.")

(defvar-local kitty-graphics--mpv-ipc-connection nil
  "Network process connected to mpv's IPC socket.")

(defvar-local kitty-graphics--mpv-ipc-timer nil
  "Pending socket-poll timer of `kitty-graphics--mpv-ipc-connect'.
Stored so `kitty-graphics--mpv-cleanup' can cancel an in-flight poll.")

(defvar-local kitty-graphics--mpv-overlay nil
  "The overlay reserving space for the video.")

(defvar-local kitty-graphics--mpv-terminal nil
  "Terminal object the mpv playback was launched on.
mpv writes one Kitty VO byte stream to a single fd, so it cannot fan out
to several daemon clients; its frames are bound to the terminal that
started playback.  The process filter routes output here and the
canonical-window search is restricted to this terminal's windows.")

(defvar-local kitty-graphics--mpv-vo nil
  "The mpv video output the current playback was spawned with.
\"kitty\" or \"sixel\", chosen from the launching terminal's backend by
`kitty-graphics--mpv-backend-vo' at spawn time, so reposition IPC and
cleanup address the right vo without re-deriving the backend.")

(defvar kitty-graphics--mpv-vo-sixel-cache 'unknown
  "Cached result of the `mpv --vo=help' sixel probe.
The symbol `unknown' until `kitty-graphics--mpv-vo-sixel-p' runs the
probe, then t or nil for the rest of the session.")

(defvar-local kitty-graphics--mpv-last-row nil
  "Last known terminal row of the video overlay.")

(defvar-local kitty-graphics--mpv-last-col nil
  "Last known terminal column of the video overlay.")

(defvar-local kitty-graphics--mpv-paused nil
  "Local pause state mirror for the current buffer's mpv process.
Flipped by `kitty-graphics-toggle-video' so the user gets immediate
echo-area feedback without round-tripping through mpv IPC.")

(defvar-local kitty-graphics--mpv-auto-paused nil
  "Non-nil when the refresh cycle auto-paused mpv because the buffer
was no longer shown in any window.  Distinct from
`kitty-graphics--mpv-paused' so the user-driven pause state is preserved
across window hide/show.")

(defvar-local kitty-graphics--browser-process nil
  "The casty process object for the current browser buffer.")

(defvar-local kitty-graphics--browser-ipc-socket nil
  "Path to the casty JSON IPC socket file.")

(defvar-local kitty-graphics--browser-ipc-connection nil
  "Network process connected to casty's IPC socket.")

(defvar-local kitty-graphics--browser-ipc-timer nil
  "Pending socket-poll timer of `kitty-graphics--browser-ipc-connect'.
Stored so `kitty-graphics--browser-cleanup' can cancel an in-flight poll.")

(defvar-local kitty-graphics--browser-overlay nil
  "The overlay reserving space for the browser frame.")

(defvar-local kitty-graphics--browser-terminal nil
  "Terminal object the casty browser was launched on.
Like `kitty-graphics--mpv-terminal', casty emits a single byte stream and is
bound to its launching terminal; output is routed here.")

(defvar-local kitty-graphics--browser-image-id nil
  "Kitty image id allocated for this buffer's casty frames.")

(defvar-local kitty-graphics--browser-cols nil
  "Current browser frame width in columns.")

(defvar-local kitty-graphics--browser-rows nil
  "Current browser frame height in rows.")

(defvar-local kitty-graphics--browser-last-row nil
  "Last known terminal row of the browser overlay.")

(defvar-local kitty-graphics--browser-last-col nil
  "Last known terminal column of the browser overlay.")

(defvar-local kitty-graphics--browser-xterm-mouse-was-off nil
  "Non-nil if `kitty-graphics-browser-mode' turned on `xterm-mouse-mode'.
Terminal Emacs only delivers mouse events (wheel scroll, click-to-follow)
while `xterm-mouse-mode' is enabled; we enable it for the browser and
restore the prior state on cleanup.")

(defvar-local kitty-graphics--browser-hint-active nil
  "Non-nil while casty link-hint mode is active in this buffer.
Set by `kitty-graphics-browser-hints' and cleared when casty replies
`{\"hintActive\":false}' (a label was chosen or hints were cancelled);
used as the keep-predicate of the hint transient keymap.")

(define-obsolete-variable-alias 'kitty-gfx-video-overlay-map 'kitty-graphics-video-overlay-map "1.3.0")

(defvar kitty-graphics-video-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'kitty-graphics-toggle-video)
    (define-key map (kbd "q")   #'kitty-graphics-stop-video-and-back)
    (define-key map (kbd "?")   #'kitty-graphics-video-help)
    map)
  "Keymap active when point is inside the inline mpv video region.
Attached as the `keymap' property of the mpv overlay so the
bindings only shadow normal editing while the cursor is on the
blank lines covered by the video frame.")

;;;; Terminal detection

(defun kitty-graphics--backend-fn (op)
  "Return the backend function for operation OP.
Looks up OP in the active backend's operation alist.
Signals an error if no backend is active or OP is missing."
  (unless kitty-graphics--active-backend
    (error "No active graphics backend"))
  (let* ((backend-alist (alist-get kitty-graphics--active-backend kitty-graphics--backends))
         (fn (alist-get op backend-alist)))
    (unless fn
      (error "Backend %s does not implement operation %s"
             kitty-graphics--active-backend op))
    fn))

(defun kitty-graphics--detect-protocol ()
  "Detect and activate a graphics protocol backend.
Returns non-nil if a supported backend is found.
Sets `kitty-graphics--active-backend' to the detected backend symbol."
  (if (display-graphic-p)
      (progn
        (kitty-graphics--log "detect-protocol: GUI frame, no terminal graphics")
        (setq kitty-graphics--active-backend nil)
        (kitty-graphics--set-tparam 'kitty-graphics-backend nil)
        nil)
      (let ((pref kitty-graphics-preferred-protocol)
            (detected nil))
        (kitty-graphics--log "detect-protocol: preference=%s" pref)
        (cond
         ;; Explicit backend preference
         ((eq pref 'kitty)
          (let ((fn (alist-get 'detect (alist-get 'kitty kitty-graphics--backends))))
            (when (and fn (funcall fn))
              (setq detected 'kitty))))
         ((eq pref 'sixel)
          (let ((fn (alist-get 'detect (alist-get 'sixel kitty-graphics--backends))))
            (when (and fn (funcall fn))
              (setq detected 'sixel))))
         ;; Auto: try Kitty first (fast env check), then Sixel
         (t
          (let ((kitty-fn (alist-get 'detect (alist-get 'kitty kitty-graphics--backends))))
            (if (and kitty-fn (funcall kitty-fn))
                (setq detected 'kitty)
              (let ((sixel-fn (alist-get 'detect (alist-get 'sixel kitty-graphics--backends))))
                (when (and sixel-fn (funcall sixel-fn))
                  (setq detected 'sixel)))))))
        (setq kitty-graphics--active-backend detected)
        (kitty-graphics--set-tparam 'kitty-graphics-backend detected)
        (kitty-graphics--log "detect-protocol: result=%s" detected)
        detected)))

(defun kitty-graphics--unsupported-reason (&optional frame)
  "Return a human-readable string explaining why no backend is active.
Re-examines FRAME's environment the way the detect functions do and
reports the most likely cause: a graphical frame, tmux with
passthrough off, a tmux too old for Sixel, or an unrecognized
terminal.  Used by the mode-enable failure message and
`kitty-graphics-doctor'."
  (let* ((frame (or frame (selected-frame)))
         (in-tmux (kitty-graphics--frame-getenv "TMUX" frame))
         (term (or (frame-parameter frame 'tty-type)
                   (kitty-graphics--frame-getenv "TERM" frame)))
         (term-prog (kitty-graphics--frame-getenv "TERM_PROGRAM" frame)))
    (cond
     ((display-graphic-p frame)
      "graphical frame; terminal graphics need a text terminal (emacs -nw)")
     ((and in-tmux (not (kitty-graphics--tmux-passthrough-p frame)))
      "inside tmux with allow-passthrough off; run: tmux set -g allow-passthrough on")
     ((and in-tmux (not (kitty-graphics--tmux-sixel-supported-p frame)))
      (let ((ver (kitty-graphics--tmux-version frame)))
        (if ver
            (format "tmux %d.%d is too old for Sixel (needs >= 3.4)"
                    (car ver) (cadr ver))
          "tmux version unknown; Sixel inside tmux needs tmux >= 3.4")))
     (t
      (format "no Kitty or Sixel terminal detected (TERM=%s, TERM_PROGRAM=%s); set `kitty-graphics-preferred-protocol' to force one"
              (or term "?") (or term-prog "?"))))))

(defun kitty-graphics--unread-non-reply (response patterns events)
  "Push back input consumed while reading a terminal reply.
Strips every match of PATTERNS (and any trailing partial escape
sequence) from RESPONSE; whatever characters remain are user
keystrokes that arrived interleaved with the reply, so they are
prepended to `unread-command-events' together with the non-character
EVENTS, instead of leaking into the reader or being dropped."
  (let ((leftover response))
    (dolist (re patterns)
      (setq leftover (replace-regexp-in-string re "" leftover)))
    (setq leftover (replace-regexp-in-string "\e\\[?[0-9;]*\\'" "" leftover))
    (let ((pending (append events (append leftover nil))))
      (when pending
        (kitty-graphics--log "unread-non-reply: pushing back %d events"
                        (length pending))
        (setq unread-command-events
              (append pending unread-command-events))))))

(defun kitty-graphics--cpr-columns (response)
  "Return the cursor column of every full CPR reply in RESPONSE, in order."
  (let ((cols nil)
        (start 0))
    (while (string-match "\e\\[[0-9]+;\\([0-9]+\\)R" response start)
      (push (string-to-number (match-string 1 response)) cols)
      (setq start (match-end 0)))
    (nreverse cols)))

(defun kitty-graphics--query-cell-size ()
  "Query terminal for cell size in pixels using CSI 16 t (XTWINOPS).
The terminal responds with CSI 6 ; HEIGHT ; WIDTH t.
Falls back to reasonable defaults if query fails or times out.
The read completes only on a full match of that reply, never on a
bare suffix check, so user keystrokes cannot terminate it early;
keystrokes consumed while waiting are pushed back onto
`unread-command-events'."
  ;; Guard on the per-terminal parameter, not the global, so every client
  ;; terminal queries its own cell size exactly once even when another
  ;; terminal already populated the global default.
  (unless (terminal-parameter nil 'kitty-graphics-cell-w)
    (let ((w nil) (h nil)
          (reply-re "\e\\[6;\\([0-9]+\\);\\([0-9]+\\)t"))
      (condition-case nil
          (let ((response "")
                (extra nil)
                (done nil)
                (deadline (+ (float-time) 0.5)))  ; 500ms timeout
            ;; Send CSI 16 t — request cell size in pixels
            (send-string-to-terminal "\e[16t")
            ;; Read response characters until we get the full sequence
            ;; Expected: ESC [ 6 ; HEIGHT ; WIDTH t
            (while (and (not done) (< (float-time) deadline))
              (let ((ch (read-event nil nil 0.1)))
                (when ch
                  (if (characterp ch)
                      (setq response (concat response (string ch)))
                    (push ch extra))
                  (when (string-match-p reply-re response)
                    (setq done t)))))
            ;; Parse the response: ESC [ 6 ; HEIGHT ; WIDTH t
            (when (string-match reply-re response)
              (let ((rh (string-to-number (match-string 1 response)))
                    (rw (string-to-number (match-string 2 response))))
                (when (and (> rw 0) (> rh 0))
                  (setq w rw h rh)
                  (kitty-graphics--log "cell-size query: %dx%d pixels" w h))))
            (kitty-graphics--unread-non-reply response (list reply-re)
                                         (nreverse extra)))
        (error nil))
      ;; Fallback if query failed, then publish to both the global default
      ;; and this terminal's parameter.
      (setq w (or w 8) h (or h 16))
      (setq kitty-graphics--cell-pixel-width w
            kitty-graphics--cell-pixel-height h)
      (set-terminal-parameter nil 'kitty-graphics-cell-w w)
      (set-terminal-parameter nil 'kitty-graphics-cell-h h)
      (kitty-graphics--log "cell-size final: %dx%d" w h))))

(defun kitty-graphics--query-text-sizing-support ()
  "Detect terminal text sizing protocol support via CPR probing.
Sends three cursor position queries interleaved with OSC 66 width
and scale tests, then compares cursor column advancement.
Sets `kitty-graphics--text-sizing-support' to `scale', `width', or `none'.

The detection sequence (per Kitty spec):
  CR → CPR1 → OSC66(w=2,\" \") → CPR2 → OSC66(s=2,\" \") → CPR3 → DSR

Compare column positions:
  x2 = x1+2 AND x3 = x2+2 → full scale support
  x2 = x1+2 only           → width-only support
  no advancement            → no support

Uses DSR (device status report) as a sentinel to avoid hanging.
The read completes only on a full match of the DSR reply, so user
keystrokes cannot end it early; keystrokes consumed while waiting
are pushed back onto `unread-command-events'."
  (if (terminal-parameter nil 'kitty-graphics-text-sizing)
      ;; Already detected for this terminal — reuse the cached result
      (progn
        (setq kitty-graphics--text-sizing-support
              (terminal-parameter nil 'kitty-graphics-text-sizing))
        (kitty-graphics--log "text-sizing: cached result=%s"
                        kitty-graphics--text-sizing-support))
    (condition-case err
        (let ((response "")
              (extra nil)
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
          ;; Read until the full DSR reply (ESC [ 0 n) or timeout
          (while (and (not done) (< (float-time) deadline))
            (let ((ch (read-event nil nil 0.1)))
              (if ch
                  (progn
                    (if (characterp ch)
                        (setq response (concat response (string ch)))
                      (push ch extra))
                    (when (string-match-p "\e\\[0n" response)
                      (setq done t)))
                ;; No input — check if we have enough responses
                (when (>= (length (kitty-graphics--cpr-columns response)) 3)
                  (setq done t)))))
          ;; Parse three CPR responses: ESC [ row ; col R
          (let ((cols (kitty-graphics--cpr-columns response)))
            (if (>= (length cols) 3)
                (let ((x1 (nth 0 cols))
                      (x2 (nth 1 cols))
                      (x3 (nth 2 cols)))
                  (kitty-graphics--log "text-sizing: CPR cols x1=%d x2=%d x3=%d"
                                   x1 x2 x3)
                  (cond
                   ((and (eql x2 (+ x1 2)) (eql x3 (+ x2 2)))
                    (setq kitty-graphics--text-sizing-support 'scale)
                    (kitty-graphics--log "text-sizing: full support (scale)"))
                   ((eql x2 (+ x1 2))
                    (setq kitty-graphics--text-sizing-support 'width)
                    (kitty-graphics--log "text-sizing: width-only support"))
                   (t
                    (setq kitty-graphics--text-sizing-support 'none)
                    (kitty-graphics--log "text-sizing: no support"))))
              (kitty-graphics--log "text-sizing: parse failed (got %d CPRs) raw=%S"
                               (length cols) response)
              (setq kitty-graphics--text-sizing-support 'none)))
          ;; Flush any remaining terminal responses
          (let ((flush-deadline (+ (float-time) 0.1)))
            (while (< (float-time) flush-deadline)
              (let ((ch (read-event nil nil 0.02)))
                (if ch
                    (if (characterp ch)
                        (setq response (concat response (string ch)))
                      (push ch extra))
                  (setq flush-deadline 0)))))
          (kitty-graphics--unread-non-reply
           response '("\e\\[[0-9]+;[0-9]+R" "\e\\[0n") (nreverse extra)))
      (error
       (kitty-graphics--log "text-sizing: query error: %s"
                        (error-message-string err))
       (setq kitty-graphics--text-sizing-support 'none))))
  (set-terminal-parameter nil 'kitty-graphics-text-sizing kitty-graphics--text-sizing-support)
  kitty-graphics--text-sizing-support)

;;;; Synchronized output

(defun kitty-graphics--sync-begin ()
  "Begin synchronized output (BSU).
The terminal buffers output until `kitty-graphics--sync-end' is called,
preventing partial rendering and flicker."
  (kitty-graphics--log "sync-begin")
  (kitty-graphics--terminal-send "\e[?2026h"))

(defun kitty-graphics--sync-end ()
  "End synchronized output (ESU).
Flushes buffered output to the terminal all at once."
  (kitty-graphics--log "sync-end")
  (kitty-graphics--terminal-send "\e[?2026l"))

;;;; Protocol layer

(defun kitty-graphics--transmit-image (id base64-data)
  "Transmit image data with `a=t' (store-only) under image id ID.
BASE64-DATA is the PNG bytes, base64-encoded.  Chunked into
`kitty-graphics-chunk-size'-byte pieces using `m=1/0' continuation
markers per the Kitty graphics protocol.

This call only stores the image; how it is later rendered depends
on the active placement mode:

- `direct': `kitty-graphics--place-image' later emits an `a=p,c,r' APC
  at screen coordinates.
- `placeholder': `kitty-graphics--place-placeholder' later registers a
  `U=1' virtual placement sized to the rendered cell grid and paints
  placeholder cells that reference it."
  (let* ((mode (kitty-graphics--effective-placement-mode))
         (chunk-size kitty-graphics-chunk-size)
         (len (length base64-data))
         (offset 0)
         (first t)
         (chunk-count 0))
    (kitty-graphics--log "transmit-begin: id=%d b64-len=%d chunk-size=%d chunks=%d mode=%s"
                     id len chunk-size (ceiling (/ (float len) chunk-size)) mode)
    (while (< offset len)
      (let* ((end (min (+ offset chunk-size) len))
             (chunk (substring base64-data offset end))
             (more (if (< end len) 1 0))
             (ctrl (if first
                       (format "a=t,q=2,f=100,i=%d,m=%d" id more)
                     (format "m=%d,q=2" more))))
        (kitty-graphics--terminal-send (format "\e_G%s;%s\e\\" ctrl chunk))
        (cl-incf chunk-count)
        (setq offset end
              first nil)))
    (kitty-graphics--log "transmit-done: id=%d chunks-sent=%d" id chunk-count)))

(defun kitty-graphics--register-virtual-placement (id cols rows)
  "Register a COLS x ROWS virtual placement (`a=p,U=1,p=1') for image ID.
This is the placement-step counterpart to a plain `a=t' transmit
when operating in `placeholder' mode.  The placement has no screen
coordinates; instead, any subsequent cell containing the Unicode
placeholder character with a foreground color encoding ID renders
the corresponding fragment of the stored image.  Sending `c'/`r' is
required for the placeholder grid to address the whole image: without
them a downscaled image shows only its top-left crop.  The registered
dimensions are cached per terminal, and a registration with the same
`i' and `p' replaces the previous one (per the protocol), so this is
re-issued only when the cell dimensions actually change.

We deliberately split this from `a=T,U=1' (transmit-and-display)
because the combined form causes some terminals (e.g. Ghostty
1.3.x) to also draw one copy of the image at the cursor position
at transmit time, producing an unwanted ghost copy."
  (let ((dims-by-id (or (kitty-graphics--tparam 'kitty-graphics-virtual-dims)
                        (kitty-graphics--set-tparam 'kitty-graphics-virtual-dims
                                               (make-hash-table))))
        (dims (cons cols rows)))
    (unless (equal (gethash id dims-by-id) dims)
      (kitty-graphics--log "register-virtual-placement: id=%d cols=%d rows=%d"
                      id cols rows)
      (kitty-graphics--terminal-send
       (format "\e_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\e\\" id cols rows))
      (puthash id dims dims-by-id))))

(defun kitty-graphics--delete-by-id (id)
  "Delete image with ID and free data."
  (kitty-graphics--log "delete-by-id: id=%d" id)
  (kitty-graphics--terminal-send (format "\e_Ga=d,d=I,i=%d,q=2\e\\" id)))

(defun kitty-graphics--delete-all-images ()
  "Delete all visible placements and free data."
  (kitty-graphics--log "delete-all-images")
  (kitty-graphics--terminal-send "\e_Ga=d,d=A,q=2\e\\"))

;;;; Direct placement (the core rendering mechanism)

(defun kitty-graphics--alloc-placement-id ()
  "Allocate a unique placement ID."
  (let ((pid kitty-graphics--next-placement-id))
    (setq kitty-graphics--next-placement-id (1+ kitty-graphics--next-placement-id))
    (when (> kitty-graphics--next-placement-id 4294967295)
      (setq kitty-graphics--next-placement-id 1))
    (kitty-graphics--log "alloc-pid: %d" pid)
    pid))

(defun kitty-graphics--place-image (image-id placement-id cols rows term-row term-col
                                        &optional src-x src-y src-w src-h)
  "Place image IMAGE-ID at terminal position TERM-ROW, TERM-COL.
PLACEMENT-ID is the unique placement ID (p=PID) — reusing the same PID
replaces the previous placement, preventing accumulation.
COLS x ROWS is the size in terminal cells.
When SRC-X/SRC-Y/SRC-W/SRC-H are all non-nil, only that source pixel
rectangle of the stored image is shown (Kitty `x'/`y'/`w'/`h' params),
scaled into COLS x ROWS cells — used for zoomed, clipped doc-view pages.
Uses direct placement: move cursor, then `a=p' with `c' and `r' params.
The cursor movement and the APC are sent separately: inside tmux only
the APC may travel through the passthrough envelope — wrapping the
cursor moves with it would make them execute on the outer terminal
with pane-relative coordinates."
  (kitty-graphics--log "place: id=%d pid=%d cols=%d rows=%d row=%d col=%d crop=%s"
                   image-id placement-id cols rows term-row term-col
                   (if src-x (format "%d,%d,%d,%d" src-x src-y src-w src-h) "none"))
  (kitty-graphics--terminal-send (format "\e7\e[%d;%dH" term-row term-col))
  (kitty-graphics--terminal-send
   (concat (format "\e_Gq=2,a=p,i=%d,p=%d,c=%d,r=%d"
                   image-id placement-id cols rows)
           (when (and src-x src-y src-w src-h)
             (format ",x=%d,y=%d,w=%d,h=%d" src-x src-y src-w src-h))
           "\e\\"))
  (kitty-graphics--terminal-send "\e8"))

;;;; Kitty backend

(defun kitty-graphics--frame-getenv (var &optional frame)
  "Return env VAR for FRAME, preferring frame env over process env.
Daemon Emacs (`emacs --daemon' / `emacsclient -t') sets the attached
client's TERM, TERM_PROGRAM, TMUX, etc. on the frame's `environment'
parameter, while the daemon process inherits whatever shell launched
it (often `TERM=dumb' from a non-tty service unit).  Plain
`getenv VAR FRAME' looks ONLY at the frame env, so it returns nil
for vars the client did not forward; plain `getenv VAR' looks at
process env first and never sees the client's value.  This helper
returns the frame env when present and falls back to the process
env otherwise."
  (let ((f (or frame (selected-frame))))
    (or (getenv var f) (getenv var))))

(defun kitty-graphics--kitty-detect ()
  "Return non-nil if the terminal supports Kitty graphics protocol.
Reads env vars via `kitty-graphics--frame-getenv' so emacs --daemon
clients see the attached terminal's environment.

Inside tmux `TERM_PROGRAM' is masked to \"tmux\", and over `kitten ssh'
KITTY_PID is unset on the remote (it is the *local* kitty's pid), so we
also accept terminal-specific env markers — KITTY_WINDOW_ID /
KITTY_PUBLIC_KEY for kitty, `GHOSTTY_RESOURCES_DIR' for Ghostty, etc. —
as evidence that the outer terminal speaks the Kitty protocol.

When inside tmux with `allow-passthrough' off, the Kitty APC escapes
would be swallowed by tmux, so the backend reports unsupported (with
a one-time message naming the fix) and detection falls through to
Sixel when available."
  (let* ((frame (selected-frame))
         (kitty-pid (kitty-graphics--frame-getenv "KITTY_PID" frame))
         ;; KITTY_WINDOW_ID / KITTY_PUBLIC_KEY are exported by kitty's shell
         ;; integration and survive both `kitten ssh' (where KITTY_PID is
         ;; absent) and tmux (where TERM_PROGRAM is masked to "tmux").
         (kitty-window-id (kitty-graphics--frame-getenv "KITTY_WINDOW_ID" frame))
         (kitty-public-key (kitty-graphics--frame-getenv "KITTY_PUBLIC_KEY" frame))
         (term-prog (kitty-graphics--frame-getenv "TERM_PROGRAM" frame))
         (ghostty (or (kitty-graphics--frame-getenv "GHOSTTY_RESOURCES_DIR" frame)
                      (kitty-graphics--frame-getenv "GHOSTTY_BIN_DIR" frame)))
         (wezterm (kitty-graphics--frame-getenv "WEZTERM_EXECUTABLE" frame))
         (in-tmux (kitty-graphics--frame-getenv "TMUX" frame))
         (supported (or kitty-pid
                        kitty-window-id
                        kitty-public-key
                        ghostty
                        wezterm
                        (member term-prog '("kitty" "WezTerm" "ghostty")))))
    (when (and supported in-tmux (not (kitty-graphics--tmux-passthrough-p frame)))
      (kitty-graphics--log "kitty-detect: disabled, tmux allow-passthrough is off")
      (kitty-graphics--message-once
       "tmux-passthrough-off"
       "kitty-graphics: tmux blocks Kitty graphics (allow-passthrough is off); run: tmux set -g allow-passthrough on, then toggle kitty-graphics-mode to re-detect")
      (setq supported nil))
    (kitty-graphics--log "kitty-detect: %s (KITTY_PID=%s KITTY_WINDOW_ID=%s TERM_PROGRAM=%s GHOSTTY=%s WEZTERM=%s)"
                     supported kitty-pid kitty-window-id term-prog
                     (if ghostty "set" "no") (if wezterm "set" "no"))
    supported))

(defun kitty-graphics--kitty-prepare (file image-id)
  "Prepare image FILE for Kitty display.
Converts to PNG if needed, encodes to base64, transmits to terminal.
Converted PNGs are owned by `kitty-graphics--png-cache' and kept for reuse.
Returns IMAGE-ID on success, nil on failure."
  (let* ((png (kitty-graphics--convert-to-png file))
         (b64 (when png (kitty-graphics--read-file-base64 png))))
    (if (not b64)
        (progn
          (kitty-graphics--log "kitty-prepare: skipped %s (conversion failed)" file)
          nil)
      (kitty-graphics--log "kitty-prepare: transmit id=%d b64-len=%d png=%s"
                       image-id (length b64) png)
      (kitty-graphics--transmit-image image-id b64)
      ;; The bytes now live on the terminal output was routed to;
      ;; record it so this client is not re-transmitted needlessly and
      ;; other clients still re-transmit on their own first use.
      (kitty-graphics--mark-transmitted image-id)
      image-id)))

(defun kitty-graphics--transmit-queue-reset ()
  "Cancel the drain timer and drop all queued transmits."
  (when kitty-graphics--transmit-drain-timer
    (cancel-timer kitty-graphics--transmit-drain-timer))
  (setq kitty-graphics--transmit-drain-timer nil
        kitty-graphics--transmit-queue nil
        kitty-graphics--transmit-drain-succeeded nil))

(defun kitty-graphics--transmit-drain ()
  "Transmit one queued image, then stop and force a refresh when done.
Each tick pops a single (TERMINAL FILE IMAGE-ID) entry and runs the
Kitty prepare with output routed to that entry's terminal.  When the
queue empties the timer cancels itself, and a forced refresh is
scheduled so the freshly transmitted images get placed — but only when
at least one transmit in the cycle succeeded; a failing transmit stays
untransmitted and would be re-queued by the forced refresh, looping
forever."
  (let ((entry (pop kitty-graphics--transmit-queue)))
    (when entry
      (let ((term (nth 0 entry))
            (file (nth 1 entry))
            (id (nth 2 entry)))
        (if (not (terminal-live-p term))
            (kitty-graphics--log "transmit-drain: dropped id=%d (dead terminal)" id)
          (kitty-graphics--log "transmit-drain: id=%d term=%s (queued=%d)"
                          id term (length kitty-graphics--transmit-queue))
          (when (kitty-graphics--with-terminal term
                  (kitty-graphics--kitty-prepare file id))
            (setq kitty-graphics--transmit-drain-succeeded t))))))
  (unless kitty-graphics--transmit-queue
    (when kitty-graphics--transmit-drain-timer
      (cancel-timer kitty-graphics--transmit-drain-timer)
      (setq kitty-graphics--transmit-drain-timer nil))
    (when kitty-graphics--transmit-drain-succeeded
      (setq kitty-graphics--transmit-drain-succeeded nil)
      (kitty-graphics--schedule-refresh t))))

(defun kitty-graphics--transmit-enqueue (term file image-id)
  "Queue IMAGE-ID/FILE for transmission to TERM and ensure the drain runs.
Duplicate (TERM, IMAGE-ID) pairs are not queued twice."
  (unless (cl-find-if (lambda (entry)
                        (and (eq (nth 0 entry) term)
                             (eql (nth 2 entry) image-id)))
                      kitty-graphics--transmit-queue)
    (kitty-graphics--log "transmit-enqueue: id=%d term=%s (queued=%d)"
                    image-id term (1+ (length kitty-graphics--transmit-queue)))
    (setq kitty-graphics--transmit-queue
          (append kitty-graphics--transmit-queue (list (list term file image-id)))))
  (unless kitty-graphics--transmit-drain-timer
    (setq kitty-graphics--transmit-drain-timer
          (run-at-time 0.01 0.01 #'kitty-graphics--transmit-drain))))

(defun kitty-graphics--ensure-transmitted (file image-id)
  "Return non-nil when IMAGE-ID is ready to place on the target terminal.
Called from the refresh path, where the target terminal is bound.  When
the terminal already holds the image (or the backend is Sixel, which
re-emits pixels on every placement) this returns t and the caller
places immediately.  When the image's data is missing, the transmit is
queued on `kitty-graphics--transmit-queue' instead of blocking the refresh
loop, and nil is returned so the caller skips this overlay; the drain
timer's trailing forced refresh places it once transmitted.  Also
returns nil while FILE's async PNG conversion is still in flight."
  (cond
   ((and file (gethash file kitty-graphics--converting))
    (kitty-graphics--log "ensure-transmitted: %s still converting, deferring" file)
    nil)
   ((not (and (eq kitty-graphics--active-backend 'kitty) file image-id)) t)
   ((kitty-graphics--transmitted-p image-id) t)
   (t
    (kitty-graphics--transmit-enqueue
     (or kitty-graphics--target-terminal (frame-terminal))
     file image-id)
    nil)))

(defun kitty-graphics--kitty-place (ov image-id placement-id cols rows term-row term-col)
  "Place Kitty image at (TERM-ROW, TERM-COL) using the active placement mode.
Dispatches to either `kitty-graphics--place-placeholder' (when
`kitty-graphics-kitty-placement-mode' resolves to `placeholder') or the
existing direct-placement `kitty-graphics--place-image' otherwise.

PLACEMENT-ID is window-specific (allocated per (overlay, window) by
`kitty-graphics--record-image-placement') and is reused by the
placeholder path as the per-window key for tracking previously-
emitted areas, so the same overlay shown in two windows does not
have its second window's cells erased by the first window's
re-placement."
  (pcase (kitty-graphics--effective-placement-mode)
    ('placeholder
     (kitty-graphics--place-placeholder ov placement-id image-id cols rows
                                   term-row term-col))
    (_
     (kitty-graphics--place-image image-id placement-id cols rows term-row term-col))))

(defun kitty-graphics--place-placeholder (ov pid image-id cols rows term-row term-col)
  "Render IMAGE-ID at (TERM-ROW, TERM-COL) via Unicode placeholder cells.
Registers (or re-registers, when the dimensions changed) the image's
virtual placement sized COLS x ROWS first, so the placeholder grid maps
onto the whole image rather than a top-left crop.  Dimensions beyond
the 297-entry diacritic table are clamped.  Per-window tracking is
keyed by PID — the placement id allocated to the (overlay, window)
pair by the caller.  Before emitting at the new position, erase the
area this PID previously occupied (if any) so the image does not ghost
where it used to be.  After emission, remember the new area for the
next erase."
  (let ((max (length kitty-graphics--diacritics)))
    (when (or (> cols max) (> rows max))
      (kitty-graphics--log "place-placeholder: clamping %dx%d to grid max %d"
                      cols rows max)
      (setq cols (min cols max)
            rows (min rows max))))
  (kitty-graphics--register-virtual-placement image-id cols rows)
  (when (overlayp ov)
    (kitty-graphics--erase-placeholder-area ov pid))
  (kitty-graphics--emit-placeholder-cells image-id cols rows term-row term-col)
  (when (overlayp ov)
    (kitty-graphics--record-placeholder-area ov pid term-row term-col cols rows)))

(defun kitty-graphics--record-placeholder-area (ov pid row col cols rows)
  "Remember on OV that PID was emitted at (ROW, COL) sized COLS x ROWS.
Replaces any prior entry for PID in OV's `kitty-graphics-placeholder-areas'
alist."
  (let* ((areas (overlay-get ov 'kitty-graphics-placeholder-areas))
         (rest (assq-delete-all pid (copy-sequence areas))))
    (overlay-put ov 'kitty-graphics-placeholder-areas
                 (cons (cons pid (list row col cols rows)) rest))))

(defun kitty-graphics--erase-placeholder-area (ov pid)
  "Overwrite OV's PID-keyed placeholder cells with spaces.
Reads the saved (row col cols rows) tuple from OV's
`kitty-graphics-placeholder-areas' alist for PID and writes a rectangle
of spaces over those terminal cells, so the multiplexer no longer
holds placeholder bytes the outer terminal would expand back into
the image.  No-op when no prior area is recorded for PID.  Removes
PID's entry from the alist after erasing."
  (when-let* ((areas (overlay-get ov 'kitty-graphics-placeholder-areas))
              (entry (assq pid areas)))
    (pcase-let ((`(,row ,col ,cs ,rs) (cdr entry)))
      (kitty-graphics--log "erase-placeholder-area: pid=%d row=%d col=%d %dx%d"
                       pid row col cs rs)
      (let ((parts (list "\e7"))
            (blank (make-string cs ?\s)))
        (dotimes (y rs)
          (push (format "\e[%d;%dH%s" (+ row y) col blank) parts))
        (push "\e8" parts)
        (kitty-graphics--terminal-send (mapconcat #'identity (nreverse parts) ""))))
    (overlay-put ov 'kitty-graphics-placeholder-areas
                 (assq-delete-all pid (copy-sequence areas)))))

(defun kitty-graphics--kitty-delete (ov image-id placement-id)
  "Delete Kitty placement PLACEMENT-ID of IMAGE-ID for overlay OV.
In `direct' mode emit a per-placement delete APC.  In `placeholder'
mode overwrite OV's PID-keyed placeholder cells with spaces; the
stored image data is preserved either way so a subsequent re-place
is cheap."
  (pcase (kitty-graphics--effective-placement-mode)
    ('placeholder
     (when (overlayp ov)
       (kitty-graphics--erase-placeholder-area ov placement-id)))
    (_
     (kitty-graphics--delete-placement image-id placement-id))))

(defun kitty-graphics--kitty-cleanup (_file image-id)
  "Cleanup Kitty image data for FILE (identified by IMAGE-ID)."
  (kitty-graphics--delete-by-id image-id))

(defun kitty-graphics--kitty-cleanup-all ()
  "Cleanup all Kitty images."
  (kitty-graphics--delete-all-images))

;;;; Sixel backend

(defvar kitty-graphics--sixel-temp-files nil
  "List of temporary Sixel files created for caching.")

(defvar kitty-graphics--sixel-cache (make-hash-table :test 'equal)
  "Maps (file . dims-string) to temp sixel file paths.")

(defun kitty-graphics--tmux-socket (&optional frame)
  "Return the tmux server socket path for FRAME, or nil outside tmux.
Parsed from FRAME's TMUX env var, whose format is
\"SOCKET-PATH,SERVER-PID,SESSION-ID\".  Read via
`kitty-graphics--frame-getenv' so each daemon client resolves the tmux
server it is actually attached to."
  (let ((tmux (kitty-graphics--frame-getenv "TMUX" frame)))
    (when (and tmux (not (string-empty-p tmux)))
      (let ((sock (car (split-string tmux ","))))
        (and sock (not (string-empty-p sock)) sock)))))

(defun kitty-graphics--tmux-display-message (format-spec &optional frame)
  "Run tmux `display-message -p FORMAT-SPEC' against FRAME's server.
Targets the socket derived from FRAME's TMUX env var via `tmux -S',
so daemon clients sitting in different tmux servers each query their
own.  Returns the trimmed output string, or nil on failure."
  (when (executable-find "tmux")
    (let ((sock (kitty-graphics--tmux-socket frame)))
      (with-temp-buffer
        (let* ((args (append (when sock (list "-S" sock))
                             (list "display-message" "-p" format-spec)))
               (exit (ignore-errors
                       (apply #'call-process "tmux" nil '(t nil) nil args))))
          (when (eq exit 0)
            (string-trim (buffer-string))))))))

(defun kitty-graphics--tmux-version (&optional frame)
  "Return tmux version as (MAJOR MINOR) integers, or nil when unavailable.
Asks FRAME's tmux server for `#{version}' (falling back to the local
`tmux -V' client binary when the server query fails), since daemon
clients can sit in different tmux servers running different versions.
Cached per terminal under the `kitty-graphics-tmux-version' parameter;
sentinel `none' records a failed probe so it is not retried."
  (let* ((term (frame-terminal (or frame (selected-frame))))
         (cached (terminal-parameter term 'kitty-graphics-tmux-version)))
    (if cached
        (and (consp cached) cached)
      (let* ((raw (or (kitty-graphics--tmux-display-message "#{version}" frame)
                      (kitty-graphics--tmux-client-version)))
             (ver (when (and raw
                             (string-match
                              "\\(?:next-\\)?\\([0-9]+\\)\\.\\([0-9]+\\)" raw))
                    (list (string-to-number (match-string 1 raw))
                          (string-to-number (match-string 2 raw))))))
        (kitty-graphics--log "tmux-version: %S (raw=%S term=%s)" ver raw term)
        (set-terminal-parameter term 'kitty-graphics-tmux-version (or ver 'none))
        ver))))

(defun kitty-graphics--tmux-client-version ()
  "Return the raw output of `tmux -V', or nil when tmux is unavailable."
  (when (executable-find "tmux")
    (with-temp-buffer
      (when (eq (ignore-errors
                  (call-process "tmux" nil '(t nil) nil "-V"))
                0)
        (string-trim (buffer-string))))))

(defun kitty-graphics--tmux-passthrough-state (&optional frame)
  "Return FRAME's tmux `allow-passthrough' state: `on', `off', or `unknown'.
Queries `#{allow-passthrough}' on the socket from FRAME's TMUX env
var; \"on\" and \"all\" count as `on'.  An empty or failed reply maps
to `unknown' (tmux < 3.3 has no such option and always passes DCS
through).  Cached per terminal under `kitty-graphics-tmux-passthrough'."
  (let* ((term (frame-terminal (or frame (selected-frame))))
         (cached (terminal-parameter term 'kitty-graphics-tmux-passthrough)))
    (or cached
        (let* ((raw (kitty-graphics--tmux-display-message "#{allow-passthrough}" frame))
               (state (cond ((member raw '("on" "all")) 'on)
                            ((member raw '(nil "")) 'unknown)
                            (t 'off))))
          (kitty-graphics--log "tmux-passthrough: %s (raw=%S term=%s)" state raw term)
          (set-terminal-parameter term 'kitty-graphics-tmux-passthrough state)
          state))))

(defun kitty-graphics--tmux-passthrough-p (&optional frame)
  "Return non-nil when FRAME runs inside tmux with `allow-passthrough' enabled.
Returns nil outside tmux and nil when tmux reports the option as off;
an unknown state (old tmux, failed query) counts as enabled because
those servers pass DCS through unconditionally."
  (and (kitty-graphics--frame-getenv "TMUX" frame)
       (memq (kitty-graphics--tmux-passthrough-state frame) '(on unknown))
       t))

(defun kitty-graphics--tmux-sixel-supported-p (&optional frame)
  "Return non-nil when running under tmux >= 3.4 with Sixel allowed.
Returns nil outside tmux, nil when `kitty-graphics-tmux-allow-sixel' is off,
nil when tmux's version cannot be determined, and nil for tmux < 3.4.
TMUX is read via `kitty-graphics--frame-getenv' so this works under
emacs --daemon clients; FRAME defaults to the selected frame."
  (and (kitty-graphics--frame-getenv "TMUX" frame)
       kitty-graphics-tmux-allow-sixel
       (let ((ver (kitty-graphics--tmux-version frame)))
         (and ver
              (or (> (car ver) 3)
                  (and (= (car ver) 3) (>= (cadr ver) 4)))))))

(defun kitty-graphics--outer-terminal-no-sixel-p (&optional frame)
  "Return non-nil when the terminal hosting tmux cannot render Sixel.
Kitty and Ghostty speak the Kitty graphics protocol but have no Sixel
support, so a Sixel emitted inside tmux is stored and then drawn by tmux
as its own \"SIXEL IMAGE\" placeholder instead of an image.  Detected via
the same env markers as `kitty-graphics--kitty-detect' (KITTY_*, GHOSTTY_*),
which survive the tmux TERM_PROGRAM masking."
  (let ((frame (or frame (selected-frame))))
    (or (kitty-graphics--frame-getenv "KITTY_PID" frame)
        (kitty-graphics--frame-getenv "KITTY_WINDOW_ID" frame)
        (kitty-graphics--frame-getenv "KITTY_PUBLIC_KEY" frame)
        (kitty-graphics--frame-getenv "GHOSTTY_RESOURCES_DIR" frame)
        (kitty-graphics--frame-getenv "GHOSTTY_BIN_DIR" frame)
        (member (kitty-graphics--frame-getenv "TERM_PROGRAM" frame)
                '("kitty" "ghostty"))
        nil)))

(defun kitty-graphics--sixel-detect ()
  "Return non-nil if the terminal likely supports Sixel protocol.
Inside tmux, requires tmux >= 3.4 (native Sixel rendering, 2024-02-13)
and `kitty-graphics-tmux-allow-sixel'.  Older tmux versions still drop the
DCS payload, and a kitty/ghostty outer terminal cannot render Sixel at
all (tmux would only draw its placeholder), so both disable Sixel.

Reads env vars via `kitty-graphics--frame-getenv' so emacs --daemon
clients see the attached terminal's environment.  Falls back to the
frame's `tty-type' parameter when TERM is missing or `dumb', which
is typical for daemons launched from a non-tty service unit."
  (let* ((frame (selected-frame))
         (frame-term (frame-parameter frame 'tty-type))
         (env-term (kitty-graphics--frame-getenv "TERM" frame))
         (term (cond ((and frame-term (not (equal frame-term "dumb"))) frame-term)
                     ((and env-term (not (equal env-term "dumb"))) env-term)
                     (t (or frame-term env-term))))
         (term-prog (kitty-graphics--frame-getenv "TERM_PROGRAM" frame))
         (in-tmux (kitty-graphics--frame-getenv "TMUX" frame))
         (tmux-ver (and in-tmux (kitty-graphics--tmux-version frame)))
         (tmux-ok (kitty-graphics--tmux-sixel-supported-p frame))
         ;; Windows Terminal's TERM value is not stable enough to rely on
         ;; alone, so accept its session markers when present.
         (windows-terminal (or (kitty-graphics--frame-getenv "WT_SESSION" frame)
                               (kitty-graphics--frame-getenv "WT_PROFILE_ID" frame)
                               (kitty-graphics--frame-getenv "WT_WINDOWID" frame)))
         (supported (and term
                         (or (not in-tmux) tmux-ok)
                         (or (string-match-p "xterm\\|vt[0-9]\\|foot\\|contour" term)
                             ;; Once `tmux-ok' is true, tmux >= 3.4 itself
                             ;; renders Sixel, so the outer TERM regex is
                             ;; irrelevant -- accept the canonical
                             ;; tmux-* / screen-* TERMs that tmux assigns.
                             (and tmux-ok
                                  (string-match-p "\\`\\(tmux\\|screen\\)\\b" term))
                             (member term-prog '("foot" "Konsole" "mintty" "mlterm"
                                                 "contour" "WezTerm"))
                             windows-terminal)
                         t)))
    (when (and supported in-tmux (kitty-graphics--outer-terminal-no-sixel-p frame))
      (kitty-graphics--log "sixel-detect: disabled, outer terminal has no Sixel; tmux would only draw its placeholder")
      (kitty-graphics--message-once
       "sixel-outer-no-sixel"
       "kitty-graphics: this terminal has no Sixel support, so tmux only shows a placeholder; run: tmux set -g allow-passthrough on to use the Kitty protocol instead")
      (setq supported nil))
    (kitty-graphics--log
     "sixel-detect: %s (TERM=%s TERM_PROGRAM=%s TMUX=%s tmux-ver=%s tmux-ok=%s WT=%s)"
     supported term term-prog (if in-tmux "yes" "no")
     (if tmux-ver (format "%d.%d" (car tmux-ver) (cadr tmux-ver)) "n/a")
     (if tmux-ok "yes" "no")
     (if windows-terminal "yes" "no"))
    (when (and in-tmux (not tmux-ok) kitty-graphics-tmux-allow-sixel)
      (kitty-graphics--message-once
       "sixel-tmux-version"
       (if tmux-ver
           (format "kitty-graphics: tmux %d.%d cannot render Sixel; tmux >= 3.4 is required"
                   (car tmux-ver) (cadr tmux-ver))
         "kitty-graphics: tmux version unknown; Sixel inside tmux requires tmux >= 3.4")))
    supported))

(defun kitty-graphics--sixel-cache-path (file cols rows)
  "Return deterministic temp file path for FILE at COLS x ROWS."
  (let* ((key (format "%s:%dx%d" file cols rows))
         (hash (md5 key)))
    (expand-file-name (concat "kitty-graphics-sixel-" hash ".six") temporary-file-directory)))

(defun kitty-graphics--sixel-resolve-encoder ()
  "Resolve the Sixel encoder program.
Return a cons (KIND . ABS-PATH) where KIND is `img2sixel' or `imagemagick'
and ABS-PATH is the resolved executable path, or nil when no encoder
is available."
  (let* ((user kitty-graphics-sixel-encoder-program)
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

(defvar kitty-graphics--sixel-encode-timed-out nil
  "Non-nil when the most recent `kitty-graphics--sixel-run-encoder' timed out.
Reset at the start of every run; consulted by the failure-feedback
path so the user message can distinguish a hung encoder (watchdog
fired) from a plain non-zero exit.")

(defun kitty-graphics--run-process (program args timeout dest-buffer)
  "Run PROGRAM with ARGS, writing stdout into DEST-BUFFER.
When TIMEOUT is a positive number, a watchdog kills PROGRAM after that
many seconds so a hung command cannot freeze Emacs.  Stderr is captured
and logged.  Returns the integer exit status, the symbol `timeout' when
the watchdog killed it, or nil when the process could not be started.
DEST-BUFFER nil discards stdout."
  (let* ((stderr-buf (generate-new-buffer " *kitty-graphics-process-stderr*"))
         (process-connection-type nil)
         (proc (condition-case err
                   (make-process :name (concat "kitty-graphics-"
                                               (file-name-nondirectory program))
                                 :buffer dest-buffer
                                 :command (cons program args)
                                 :coding 'binary
                                 :connection-type 'pipe
                                 :stderr stderr-buf
                                 :noquery t)
                 (error
                  (kitty-graphics--log "run-process: %s failed to start: %S" program err)
                  nil)))
         (timer (and proc (numberp timeout) (> timeout 0)
                     (run-at-time
                      timeout nil
                      (lambda (p)
                        (when (process-live-p p)
                          (process-put p 'kitty-graphics-timed-out t)
                          (delete-process p)))
                      proc))))
    (if (not proc)
        (progn
          (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf))
          nil)
      (set-process-sentinel proc #'ignore)
      (unwind-protect
          (progn
            (while (process-live-p proc)
              (accept-process-output proc 0.1))
            (let ((stderr (string-trim
                           (with-current-buffer stderr-buf (buffer-string)))))
              (unless (string-empty-p stderr)
                (kitty-graphics--log "run-process: %s stderr: %s" program stderr)))
            (if (process-get proc 'kitty-graphics-timed-out)
                (progn
                  (kitty-graphics--log "run-process: TIMEOUT after %ss (%s killed)"
                                  timeout program)
                  'timeout)
              (process-exit-status proc)))
        (when (process-live-p proc) (delete-process proc))
        (when timer (cancel-timer timer))
        (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf))))))

(defun kitty-graphics--sixel-run-encoder (program timeout dest-buffer args)
  "Run PROGRAM with ARGS, writing stdout into DEST-BUFFER.
TIMEOUT, when a positive number, terminates the process after that many
seconds.  Returns t on success, nil on failure (timeout or non-zero
exit); a timeout also sets `kitty-graphics--sixel-encode-timed-out'."
  (setq kitty-graphics--sixel-encode-timed-out nil)
  (let ((status (kitty-graphics--run-process program args timeout dest-buffer)))
    (cond
     ((eq status 'timeout)
      (setq kitty-graphics--sixel-encode-timed-out t)
      nil)
     ((eql status 0) t)
     (t nil))))

(defun kitty-graphics--sixel-img2sixel-tuning-args ()
  "Return img2sixel arguments for the dither and palette defcustoms."
  (append (when kitty-graphics-sixel-dither
            (list "-d" kitty-graphics-sixel-dither))
          (when kitty-graphics-sixel-colors
            (list "-p" (number-to-string kitty-graphics-sixel-colors)))))

(defun kitty-graphics--sixel-imagemagick-tuning-args ()
  "Return ImageMagick arguments for the dither and palette defcustoms.
\"atkinson\" falls back to Floyd-Steinberg since ImageMagick has no
Atkinson dither."
  (append (pcase kitty-graphics-sixel-dither
            ("none" (list "+dither"))
            ((or "fs" "atkinson") (list "-dither" "FloydSteinberg"))
            (_ nil))
          (when kitty-graphics-sixel-colors
            (list "-colors" (number-to-string kitty-graphics-sixel-colors)))))

(defun kitty-graphics--sixel-prescale (png-file pixel-w pixel-h)
  "Resize PNG-FILE to fit PIXEL-W x PIXEL-H, returning a temp PNG path.
Returns nil when the source already fits, when no ImageMagick binary
is available, or when the resize fails — callers then encode the
original file.  The resize is bounded by the same watchdog as the
encoder runs (`kitty-graphics--sixel-run-encoder').  The caller owns and
must delete the returned file."
  (let ((magick (or (executable-find "magick")
                    (executable-find "convert")))
        (px (kitty-graphics--image-pixel-size png-file)))
    (when (and magick px
               (or (> (car px) pixel-w) (> (cdr px) pixel-h)))
      (let ((out (make-temp-file "kitty-graphics-prescale-" nil ".png"))
            (ok nil))
        (unwind-protect
            (setq ok (with-temp-buffer
                       (kitty-graphics--sixel-run-encoder
                        magick kitty-graphics-sixel-encoder-timeout (current-buffer)
                        (list png-file "-resize"
                              (format "%dx%d" pixel-w pixel-h) out))))
          (unless ok (ignore-errors (delete-file out))))
        (when ok
          (kitty-graphics--log "sixel-prescale: %s %dx%d -> %s (fit %dx%d)"
                          png-file (car px) (cdr px) out pixel-w pixel-h)
          out)))))

(defun kitty-graphics--sixel-encode (png-file cols rows)
  "Encode PNG-FILE as Sixel data for COLS x ROWS cells.
Returns Sixel data string or nil on failure.
Computes pixel dimensions from cell size.  The encoder is selected via
`kitty-graphics-sixel-encoder-program' (auto-detected when nil) and bounded
by `kitty-graphics-sixel-encoder-timeout'.  Dither and palette size come
from `kitty-graphics-sixel-dither' and `kitty-graphics-sixel-colors', with
`kitty-graphics-sixel-encoder-args' appended as the raw escape hatch.
When img2sixel encodes a source larger than the target pixel box and
ImageMagick is available, the image is pre-scaled to a temp PNG first
so img2sixel quantizes the small image instead of the full-size one."
  (let* ((cw (or kitty-graphics--cell-pixel-width 8))
         (ch (or kitty-graphics--cell-pixel-height 16))
         (pixel-w (* cols cw))
         (pixel-h (* rows ch))
         (resolved (kitty-graphics--sixel-resolve-encoder)))
    (if (not resolved)
        (progn
          (kitty-graphics--log "sixel-encode: no encoder found (img2sixel/magick/convert)")
          (message "kitty-graphics: Sixel backend requires img2sixel or ImageMagick")
          nil)
      (let ((kind (car resolved))
            (path (cdr resolved))
            (prescaled nil))
        (unwind-protect
            (progn
              (when (eq kind 'img2sixel)
                (setq prescaled
                      (kitty-graphics--sixel-prescale png-file pixel-w pixel-h)))
              (let* ((base (file-name-nondirectory path))
                     (input (or prescaled png-file))
                     (args (pcase kind
                             ('img2sixel
                              (append (kitty-graphics--sixel-img2sixel-tuning-args)
                                      kitty-graphics-sixel-encoder-args
                                      (unless prescaled
                                        (list "-w" (number-to-string pixel-w)
                                              "-h" (number-to-string pixel-h)))
                                      (list input)))
                             ('imagemagick
                              (append (list input)
                                      (list "-geometry"
                                            (format "%dx%d" pixel-w pixel-h))
                                      (kitty-graphics--sixel-imagemagick-tuning-args)
                                      kitty-graphics-sixel-encoder-args
                                      (list "sixel:-"))))))
                (when (string-prefix-p "convert" (downcase base))
                  (kitty-graphics--log "sixel-encode: WARNING deprecated `convert' resolved (%s); install `magick' or `img2sixel'" path))
                (kitty-graphics--log "sixel-encode: %s -> %dx%d pixels via %s (%s%s)"
                                input pixel-w pixel-h base kind
                                (if prescaled ", pre-scaled" ""))
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (if (kitty-graphics--sixel-run-encoder
                       path kitty-graphics-sixel-encoder-timeout
                       (current-buffer) args)
                      (let ((data (buffer-string)))
                        (kitty-graphics--log "sixel-encode: success (%d bytes)" (length data))
                        data)
                    nil))))
          (when prescaled
            (ignore-errors (delete-file prescaled))))))))

(defun kitty-graphics--sixel-prepare (file _image-id)
  "Prepare FILE for Sixel display.
For Sixel, preparation just validates the file exists and is convertible.
Actual encoding happens at place-time (needs dimensions).
Returns non-nil on success."
  (let ((png (kitty-graphics--convert-to-png file)))
    (when png
      (kitty-graphics--log "sixel-prepare: %s -> %s" file png)
      ;; Cache the PNG path for later encoding
      (puthash file png kitty-graphics--sixel-cache)
      t)))

(defun kitty-graphics--sixel-file-stamp (file)
  "Return FILE's modification time, or t when FILE is unreadable.
Stored in the `kitty-graphics-sixel-failed' overlay property so a failed
encode is retried once the file changes on disk."
  (or (file-attribute-modification-time (file-attributes file)) t))

(defun kitty-graphics--sixel-failure-current-p (ov file)
  "Return non-nil when OV's recorded Sixel encode failure still applies.
The failure marker stores FILE's mtime at failure time; when FILE has
changed on disk since, the marker is cleared, OV's blank display cells
are restored, and nil is returned so the caller re-runs the encoder.
Returns nil when OV carries no failure marker."
  (let ((failed (overlay-get ov 'kitty-graphics-sixel-failed)))
    (cond
     ((null failed) nil)
     ((equal failed (kitty-graphics--sixel-file-stamp file)) t)
     (t
      (overlay-put ov 'kitty-graphics-sixel-failed nil)
      (overlay-put ov 'display
                   (concat (kitty-graphics--make-blank-display
                            (overlay-get ov 'kitty-graphics-cols)
                            (overlay-get ov 'kitty-graphics-rows))
                           "\n"))
      (kitty-graphics--log "sixel-place: %s changed on disk, retrying failed overlay"
                      file)
      nil))))

(defun kitty-graphics--sixel-report-encode-failure (ov file)
  "Surface a Sixel encode failure for FILE on overlay OV.
Replaces OV's blank display cells with a visible failure marker and
marks OV so subsequent refreshes stop retrying the encoder.  The
marker records FILE's current mtime; a change on disk clears it (see
`kitty-graphics--sixel-failure-current-p'), as does removing or
re-displaying the image.  Shows a one-time echo-area message (per
file, per session) naming the encoder and whether the timeout
watchdog killed it."
  (overlay-put ov 'kitty-graphics-sixel-failed (kitty-graphics--sixel-file-stamp file))
  (overlay-put ov 'display "[sixel: encode failed]\n")
  (let ((encoder (kitty-graphics--sixel-resolve-encoder)))
    (kitty-graphics--message-once
     (concat "sixel-encode-failed:" file)
     (format "kitty-graphics: Sixel encode %s for %s (encoder: %s)"
             (if kitty-graphics--sixel-encode-timed-out
                 (format "timed out after %gs" kitty-graphics-sixel-encoder-timeout)
               "failed")
             (file-name-nondirectory file)
             (if encoder (cdr encoder) "none found")))))

(defun kitty-graphics--sixel-place (ov _image-id _placement-id cols rows term-row term-col)
  "Place Sixel image at terminal position.
Encodes on-demand if not cached, then emits DCS sequence.  An overlay
whose encode already failed shows a text marker and is skipped, so a
broken or hanging encoder is not re-run on every refresh; the failure
sticks until the file changes on disk or the image is re-displayed."
  (let* ((file (overlay-get ov 'kitty-graphics-file))
         (png (gethash file kitty-graphics--sixel-cache))
         (cache-path (kitty-graphics--sixel-cache-path file cols rows))
         (dims (cons cols rows))
         (mem (and (equal (overlay-get ov 'kitty-graphics-sixel-dims) dims)
                   (overlay-get ov 'kitty-graphics-sixel-data)))
         (sixel-data nil))
    (cond
     ((kitty-graphics--sixel-failure-current-p ov file)
      (kitty-graphics--log "sixel-place: skipping failed overlay for %s" file))
     ((not png)
      (kitty-graphics--log "sixel-place: no PNG cached for %s" file))
     (t
      ;; In-memory hit (re-emit at unchanged size) skips both the disk
      ;; read and the encoder; the on-screen refresh loop leans on this
      ;; so a Sixel image survives redisplay without re-encoding.
      (cond
       (mem
        (kitty-graphics--log "sixel-place: reusing in-memory sixel for %s" file)
        (setq sixel-data mem))
       ((file-exists-p cache-path)
        (kitty-graphics--log "sixel-place: using cached sixel %s" cache-path)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally cache-path)
          (setq sixel-data (buffer-string))))
       (t
        ;; Encode on-demand
        (kitty-graphics--log "sixel-place: encoding %s at %dx%d" png cols rows)
        (setq sixel-data (kitty-graphics--sixel-encode png cols rows))
        (if (not sixel-data)
            (kitty-graphics--sixel-report-encode-failure ov file)
          ;; Cache the encoding
          (ignore-errors
            (with-temp-file cache-path
              (set-buffer-multibyte nil)
              (insert sixel-data)))
          (push cache-path kitty-graphics--sixel-temp-files)
          ;; LRU eviction: cap temp files at kitty-graphics-cache-size
          (when (> (length kitty-graphics--sixel-temp-files) kitty-graphics-cache-size)
            (let ((victim (car (last kitty-graphics--sixel-temp-files))))
              (kitty-graphics--log "sixel-cache-evict: %s (count=%d max=%d)"
                              victim (length kitty-graphics--sixel-temp-files)
                              kitty-graphics-cache-size)
              (ignore-errors (delete-file victim))
              (setq kitty-graphics--sixel-temp-files
                    (butlast kitty-graphics--sixel-temp-files)))))))
      ;; Emit Sixel sequence if we have data
      (when sixel-data
        (overlay-put ov 'kitty-graphics-sixel-data sixel-data)
        (overlay-put ov 'kitty-graphics-sixel-dims dims)
        (let* ((cw (or kitty-graphics--cell-pixel-width 8))
               (ch (or kitty-graphics--cell-pixel-height 16)))
          (kitty-graphics--log "sixel-place: emitting at row=%d col=%d data-len=%d pixel-target=%dx%d"
                          term-row term-col (length sixel-data) (* cols cw) (* rows ch)))
        (kitty-graphics--terminal-send
         (format "\e7\e[%d;%dH%s\e8" term-row term-col sixel-data)))))))

(defun kitty-graphics--blank-rect-string (row col cols rows)
  "Return an escape string overwriting a COLS x ROWS cell rectangle with spaces.
ROW and COL are 1-based terminal coordinates of the top-left corner.
The cursor position is saved and restored around the writes."
  (format "\e7%s\e8"
          (mapconcat
           (lambda (r)
             (format "\e[%d;%dH%s" (+ row r) col (make-string cols ?\s)))
           (number-sequence 0 (1- rows))
           "")))

(defun kitty-graphics--sixel-delete (ov _image-id _placement-id)
  "Delete Sixel placement by overwriting with spaces.
Sixel has no placement IDs — erase by writing spaces over the region."
  (let ((last-row (overlay-get ov 'kitty-graphics-last-row))
        (last-col (overlay-get ov 'kitty-graphics-last-col))
        (rows (overlay-get ov 'kitty-graphics-rows))
        (cols (overlay-get ov 'kitty-graphics-cols)))
    (when (and last-row last-col rows cols)
      (kitty-graphics--log "sixel-delete: erase row=%d col=%d %dx%d"
                       last-row last-col cols rows)
      (kitty-graphics--terminal-send
       (kitty-graphics--blank-rect-string last-row last-col cols rows)))))

(defun kitty-graphics--sixel-cleanup (file _image-id)
  "Cleanup Sixel resources for FILE."
  (when file
    (remhash file kitty-graphics--sixel-cache)
    ;; Remove cached sixel encodings for this file
    (dolist (temp-file kitty-graphics--sixel-temp-files)
      (when (string-match-p (regexp-quote (md5 file)) temp-file)
        (kitty-graphics--log "sixel-cleanup: deleting %s" temp-file)
        (ignore-errors (delete-file temp-file))
        (setq kitty-graphics--sixel-temp-files (delete temp-file kitty-graphics--sixel-temp-files))))))

(defun kitty-graphics--sixel-cleanup-all ()
  "Cleanup all Sixel resources.
Erases visible Sixel images from the terminal before cleaning
disk/memory state, preventing pixel artifacts on mode disable."
  (kitty-graphics--log "sixel-cleanup-all: deleting %d temp files"
                   (length kitty-graphics--sixel-temp-files))
  ;; Erase visible images from terminal (Sixel has no protocol-level
  ;; delete — must overwrite cells with spaces).
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (dolist (ov kitty-graphics--overlays)
        (when (and (overlay-buffer ov)
                   (not (overlay-get ov 'kitty-graphics-heading))
                   (overlay-get ov 'kitty-graphics-last-row))
          (funcall #'kitty-graphics--sixel-delete ov nil nil)))))
  ;; Clean disk cache
  (dolist (temp-file kitty-graphics--sixel-temp-files)
    (ignore-errors (delete-file temp-file)))
  (setq kitty-graphics--sixel-temp-files nil)
  (clrhash kitty-graphics--sixel-cache))

;; Register backends
(setq kitty-graphics--backends
      `((kitty . ((detect . ,#'kitty-graphics--kitty-detect)
                  (prepare . ,#'kitty-graphics--kitty-prepare)
                  (place . ,#'kitty-graphics--kitty-place)
                  (delete . ,#'kitty-graphics--kitty-delete)
                  (cleanup . ,#'kitty-graphics--kitty-cleanup)
                  (cleanup-all . ,#'kitty-graphics--kitty-cleanup-all)))
        (sixel . ((detect . ,#'kitty-graphics--sixel-detect)
                  (prepare . ,#'kitty-graphics--sixel-prepare)
                  (place . ,#'kitty-graphics--sixel-place)
                  (delete . ,#'kitty-graphics--sixel-delete)
                  (cleanup . ,#'kitty-graphics--sixel-cleanup)
                  (cleanup-all . ,#'kitty-graphics--sixel-cleanup-all)))))

;; Cleanup temp files on exit
(add-hook 'kill-emacs-hook #'kitty-graphics--sixel-cleanup-all)

;;;; Text sizing protocol (OSC 66)

(defun kitty-graphics--decompose-scale (scale)
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

(defun kitty-graphics--heading-scaled-p (scale)
  "Return non-nil when SCALE warrants a multicell heading overlay.
A scale above 1.0 but below `kitty-graphics-heading-min-scale' is treated as
not worth the extra terminal row and stays at normal size."
  (and scale (> scale 1.0) (>= scale kitty-graphics-heading-min-scale)))

(defun kitty-graphics--validate-osc66 (s n d text)
  "Return non-nil if OSC 66 parameters are valid per protocol spec.
S is cell scale (1-7), N is fractional numerator (0-15),
D is fractional denominator (0-15, must be > N when non-zero),
TEXT is the string payload (max 4096 bytes UTF-8)."
  (and (<= 1 s 7)
       (<= 0 n 15)
       (<= 0 d 15)
       (or (zerop d) (> d n))
       (<= (length (encode-coding-string text 'utf-8)) 4096)))

(defun kitty-graphics--truncate-utf8 (text max-bytes)
  "Return TEXT truncated so its UTF-8 encoding is at most MAX-BYTES.
Truncation happens on character boundaries, so the result is always
valid UTF-8."
  (while (> (length (encode-coding-string text 'utf-8)) max-bytes)
    (setq text (substring text 0 -1)))
  text)

(defun kitty-graphics--color-sgr (selector color)
  "Return an SGR color parameter \"SELECTOR;2;R;G;B\" for COLOR, or nil.
SELECTOR is 38 for foreground or 48 for background.  COLOR is an Emacs
color name or hex string; unspecified or unresolvable colors yield nil.
\"#RRGGBB\" hex is parsed directly so the emitted truecolor is exact
regardless of the frame's display color model; named colors go through
`color-values'."
  (let ((rgb (cond
              ((not (stringp color)) nil)
              ((string-prefix-p "unspecified" color) nil)
              ((string-match
                "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\'"
                color)
               (list (string-to-number (match-string 1 color) 16)
                     (string-to-number (match-string 2 color) 16)
                     (string-to-number (match-string 3 color) 16)))
              (t (let ((v (color-values color)))
                   (and v (mapcar (lambda (x) (/ x 256)) v)))))))
    (when rgb
      (format "%d;2;%d;%d;%d" selector (nth 0 rgb) (nth 1 rgb) (nth 2 rgb)))))

(defun kitty-graphics--spec-attribute (spec attr)
  "Resolve face attribute ATTR from SPEC, following `:inherit'.
SPEC may be a named face symbol, an attribute plist, a color string
\(taken as the foreground), or a list of any of those — the shapes
`org-get-todo-face' returns for custom TODO keywords.  Returns the
attribute value, or nil when unspecified."
  (cond
   ((null spec) nil)
   ((and (symbolp spec) (facep spec))
    (let ((v (face-attribute spec attr nil t)))
      (unless (eq v 'unspecified) v)))
   ((stringp spec)
    (when (eq attr :foreground) spec))
   ((keywordp (car-safe spec))
    (let ((v (plist-get spec attr)))
      (if (and v (not (eq v 'unspecified)))
          v
        (kitty-graphics--spec-attribute (plist-get spec :inherit) attr))))
   ((consp spec)
    (cl-some (lambda (s) (kitty-graphics--spec-attribute s attr)) spec))))

(defun kitty-graphics--face-sgr (face)
  "Return an SGR escape string rendering FACE's visual attributes.
FACE may be a named face, an attribute plist, a color string, or a
list of those — the shapes `org-get-todo-face' yields for custom TODO
keywords.  Honors weight, slant, underline, and 24-bit foreground and
background, following `:inherit'.  Stays bold by default (matching the
prior behavior) unless the face is explicitly light, so scaled text
always stands out."
  (let ((weight (kitty-graphics--spec-attribute face :weight))
        (slant (kitty-graphics--spec-attribute face :slant))
        (underline (kitty-graphics--spec-attribute face :underline))
        (fg (kitty-graphics--color-sgr 38 (kitty-graphics--spec-attribute face :foreground)))
        (bg (kitty-graphics--color-sgr 48 (kitty-graphics--spec-attribute face :background)))
        (params nil))
    (if (memq weight '(light semi-light semilight ultra-light extra-light thin))
        (push "2" params)
      (push "1" params))
    (when (memq slant '(italic oblique))
      (push "3" params))
    (when (and underline (not (eq underline 'unspecified)))
      (push "4" params))
    (when fg (push fg params))
    (when bg (push bg params))
    (format "\e[%sm" (mapconcat #'identity (nreverse params) ";"))))

(defun kitty-graphics--heading-sgr (level)
  "Return SGR escape string for an org heading at LEVEL.
Renders the `org-level-N' face (capped at level 8) via
`kitty-graphics--face-sgr', falling back to bold when undefined."
  (kitty-graphics--face-sgr (intern (format "org-level-%d" (min level 8)))))

(defun kitty-graphics--emit-heading-segments (segments limit row col cell-s meta)
  "Emit SEGMENTS as consecutive OSC 66 blocks starting at ROW, COL.
Each (TEXT . FACE) run is rendered with its own SGR via
`kitty-graphics--face-sgr', sharing the OSC 66 sizing META.  The combined
text is truncated to LIMIT characters so a heading fitted to the window
width does not overflow.  Returns the next free column."
  (let ((remaining limit)
        (cur-col col))
    (dolist (seg segments)
      (when (> remaining 0)
        (let* ((full (substring-no-properties (car seg)))
               (text (if (<= (length full) remaining)
                         full
                       (substring full 0 remaining))))
          (setq remaining (- remaining (length text)))
          (when (> (length text) 0)
            (kitty-graphics--terminal-send
             (format "\e7\e[%d;%dH%s\e]66;%s;%s\a\e[0m\e8"
                     row cur-col (kitty-graphics--face-sgr (cdr seg)) meta text))
            (setq cur-col (+ cur-col (* (string-width text) cell-s)))))))
    cur-col))

(defun kitty-graphics--place-heading (ov)
  "Emit OSC 66 to render heading overlay OV at its cached terminal position.
Pre-erases the target area using ECH before emitting, preventing
artifacts from partial overwrites (adapted from mdfried's pattern).
With `kitty-graphics-heading-fontify-keywords', the heading is emitted as
per-part colored segments (TODO keyword, priority, title, tags);
otherwise as one block in the heading-level color.
Sequence: save-cursor, erase-area, move-to-position, SGR-color,
OSC-66-payload, SGR-reset, restore-cursor."
  (let* ((raw-text (or (overlay-get ov 'kitty-graphics-render-text)
                       (overlay-get ov 'kitty-graphics-heading-text)))
         ;; Strip text properties — org-modern, font-lock, etc. can
         ;; attach display/face properties that corrupt OSC 66 payload.
         (text (kitty-graphics--truncate-utf8
                (substring-no-properties raw-text) 4096))
         (cell-s (overlay-get ov 'kitty-graphics-heading-cell-s))
         (frac-n (overlay-get ov 'kitty-graphics-heading-frac-n))
         (frac-d (overlay-get ov 'kitty-graphics-heading-frac-d))
         (level (overlay-get ov 'kitty-graphics-heading-level))
         (row (overlay-get ov 'kitty-graphics-last-row))
         (col (overlay-get ov 'kitty-graphics-last-col))
         (cols (overlay-get ov 'kitty-graphics-cols))
         (rows (overlay-get ov 'kitty-graphics-rows))
         (sgr (kitty-graphics--heading-sgr level))
         ;; Build the OSC 66 metadata: s=S, and optionally n=N:d=D:v=V.
         ;; v= (vertical alignment) only applies to fractional scaling,
         ;; so it rides along only on the n/d branch.
         (meta (if (and frac-n frac-d (> frac-d 0))
                   (format "s=%d:n=%d:d=%d:v=%d"
                           cell-s frac-n frac-d kitty-graphics-heading-valign)
                 (format "s=%d" cell-s))))
    (kitty-graphics--log "place-heading: L%d row=%d col=%d s=%d n=%d d=%d text=%S"
                     level row col cell-s frac-n frac-d text)
    ;; Pre-erase: clean the target area before emitting OSC 66.
    ;; This prevents ghost artifacts from previous content or
    ;; partially-overwritten multicell blocks.
    (kitty-graphics--erase-heading-at row col (or cols 0) (or rows 1))
    (let ((segments (overlay-get ov 'kitty-graphics-heading-segments)))
      (if segments
          (kitty-graphics--emit-heading-segments
           segments (length text) row col cell-s meta)
        (kitty-graphics--terminal-send
         (format "\e7\e[%d;%dH%s\e]66;%s;%s\a\e[0m\e8"
                 row col sgr meta text))))
    (overlay-put ov 'kitty-graphics-heading-emitted t)))

(defun kitty-graphics--erase-heading-at (row col cols rows)
  "Erase a heading multicell block at ROW, COL spanning COLS x ROWS cells.
Uses the ECH (Erase Character) escape `\\e[NX' which erases N characters
at the cursor without moving it — more efficient than writing spaces.
Disables DECAWM (auto-wrap) during erase to prevent wrapping artifacts
when the erase area extends near the right edge.  Erases each row of
the multicell block to ensure complete cleanup.
Adapted from mdfried's erase-character dance."
  (when (and row col cols rows (> cols 0) (> rows 0))
    (kitty-graphics--terminal-send
     (format "\e7\e[?7l\e[%d;%dH\e[%dX%s\e[?7h\e8"
             row col cols
             ;; For multi-row blocks (s > 1), erase additional rows
             (if (> rows 1)
                 (mapconcat
                  (lambda (r)
                    (format "\e[%d;%dH\e[%dX" (+ row r) col cols))
                  (number-sequence 1 (1- rows)) "")
               "")))))

(defun kitty-graphics--heading-reset (ov)
  "Drop heading overlay OV's cached position and show its plain text.
Used whenever OV stops being rendered as a multicell block (scrolled
out, folded away, collapsed, buffer hidden).  Deliberately sends NO
erase sequence: the terminal scrolls or redraws those cells together
with the buffer text Emacs knows about, so erasing at a cached
position would wipe whatever content now lives there (issue seen as
blanked body lines after fold/scroll)."
  (overlay-put ov 'kitty-graphics-last-row nil)
  (overlay-put ov 'kitty-graphics-last-col nil)
  (overlay-put ov 'kitty-graphics-heading-emitted nil)
  (let ((text (overlay-get ov 'kitty-graphics-heading-text)))
    (when (and text (not (equal (overlay-get ov 'display) text)))
      (overlay-put ov 'display text))))

(defun kitty-graphics--heading-erase-all ()
  "Erase every emitted heading multicell block at its cached position.
Unlike `kitty-graphics--heading-reset', which trusts Emacs to repaint the
heading line, this writes an explicit ECH erase first.  Used on
window-layout changes (a popup, which-key, or the minibuffer opening a
window over the buffer): the new window owns those terminal cells, so
Emacs never repaints them and the stale glyphs would otherwise bleed
into the popup.  Clears each block's cached position so the debounced
refresh re-places the still-visible ones afterwards."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (dolist (ov kitty-graphics--overlays)
          (when (and (overlay-buffer ov)
                     (overlay-get ov 'kitty-graphics-heading)
                     (overlay-get ov 'kitty-graphics-heading-emitted))
            (kitty-graphics--erase-heading-at
             (overlay-get ov 'kitty-graphics-last-row)
             (overlay-get ov 'kitty-graphics-last-col)
             (or (overlay-get ov 'kitty-graphics-cols) 0)
             (or (overlay-get ov 'kitty-graphics-rows) 1))
            (kitty-graphics--heading-reset ov)))))))

(defun kitty-graphics--heading-fit-text (text cell-s max-cols)
  "Return the longest prefix of TEXT whose scaled width fits MAX-COLS.
Each character of TEXT occupies (`char-width' * CELL-S) terminal
columns when rendered as an OSC 66 multicell block."
  (let ((i 0)
        (width 0)
        (len (length text)))
    (while (and (< i len)
                (<= (* (+ width (char-width (aref text i))) cell-s)
                    max-cols))
      (setq width (+ width (char-width (aref text i))))
      (setq i (1+ i)))
    (substring text 0 i)))

(defun kitty-graphics--heading-sync-reservation (ov cols cell-s)
  "Make OV reserve exactly COLS x CELL-S terminal cells with spaces.
Sets the `display' property to COLS spaces and the `after-string' to
\(CELL-S - 1) lines of COLS spaces, so Emacs's redisplay matrix tracks
the precise rectangle the multicell block will occupy.  Flags
`kitty-graphics--heading-flush-needed' when anything changed so the refresh
cycle flushes the spaces to the terminal before emitting OSC 66."
  (let ((spaces (make-string cols ?\s)))
    (unless (equal (overlay-get ov 'display) spaces)
      (overlay-put ov 'display spaces)
      (setq kitty-graphics--heading-flush-needed t))
    (when (> cell-s 1)
      (let ((after (apply #'concat
                          (make-list (1- cell-s) (concat spaces "\n")))))
        (unless (equal (overlay-get ov 'after-string) after)
          (overlay-put ov 'after-string after)
          (setq kitty-graphics--heading-flush-needed t))))))

(defun kitty-graphics-run-self-tests ()
  "Run batch-safe self-tests for kitty-graphics.
Tests pure logic functions that don't require a terminal.
Signals error on failure, prints success message otherwise."
  (interactive)
  ;; heading-scaled-p: honors the min-scale threshold
  (let ((kitty-graphics-heading-min-scale 1.2))
    (cl-assert (not (kitty-graphics--heading-scaled-p 1.0)) nil "1.0 should not scale")
    (cl-assert (not (kitty-graphics--heading-scaled-p 1.1)) nil "1.1 below min should not scale")
    (cl-assert (kitty-graphics--heading-scaled-p 1.2) nil "1.2 at min should scale")
    (cl-assert (kitty-graphics--heading-scaled-p 2.0) nil "2.0 should scale")
    (cl-assert (not (kitty-graphics--heading-scaled-p nil)) nil "nil should not scale"))
  ;; decompose-scale: identity
  (cl-assert (equal (kitty-graphics--decompose-scale 1.0) '(1 0 0))
             nil "decompose 1.0 failed")
  ;; decompose-scale: integer scales
  (cl-assert (equal (kitty-graphics--decompose-scale 2.0) '(2 0 0))
             nil "decompose 2.0 failed")
  (cl-assert (equal (kitty-graphics--decompose-scale 3.0) '(3 0 0))
             nil "decompose 3.0 failed")
  ;; decompose-scale: fractional scales produce valid params
  (let ((r15 (kitty-graphics--decompose-scale 1.5)))
    (cl-assert (= (nth 0 r15) 2) nil "1.5 cell-s should be 2")
    (cl-assert (> (nth 1 r15) 0) nil "1.5 should have fractional n")
    (cl-assert (> (nth 2 r15) (nth 1 r15)) nil "1.5: d must be > n"))
  (let ((r12 (kitty-graphics--decompose-scale 1.2)))
    (cl-assert (= (nth 0 r12) 2) nil "1.2 cell-s should be 2")
    (cl-assert (> (nth 1 r12) 0) nil "1.2 should have fractional n")
    (cl-assert (> (nth 2 r12) (nth 1 r12)) nil "1.2: d must be > n"))
  ;; decompose-scale: clamping
  (cl-assert (= (nth 0 (kitty-graphics--decompose-scale 0.5)) 1)
             nil "scale < 1.0 should clamp cell-s to 1")
  (cl-assert (= (nth 0 (kitty-graphics--decompose-scale 10.0)) 7)
             nil "scale > 7.0 should clamp cell-s to 7")
  ;; validate-osc66: valid params
  (cl-assert (kitty-graphics--validate-osc66 2 3 4 "hello")
             nil "valid params should pass")
  (cl-assert (kitty-graphics--validate-osc66 1 0 0 "test")
             nil "no-fraction params should pass")
  ;; validate-osc66: invalid params
  (cl-assert (not (kitty-graphics--validate-osc66 0 0 0 "x"))
             nil "s=0 should fail")
  (cl-assert (not (kitty-graphics--validate-osc66 8 0 0 "x"))
             nil "s=8 should fail")
  (cl-assert (not (kitty-graphics--validate-osc66 2 5 3 "x"))
             nil "n > d should fail")
  (cl-assert (not (kitty-graphics--validate-osc66 2 5 5 "x"))
             nil "n = d should fail")
  ;; validate-osc66: text length
  (cl-assert (kitty-graphics--validate-osc66 1 0 0 (make-string 4096 ?a))
             nil "4096 bytes should pass")
  (cl-assert (not (kitty-graphics--validate-osc66 1 0 0 (make-string 4097 ?a)))
             nil "4097 bytes should fail")
  ;; All decomposed scales should validate
  (dolist (scale '(1.0 1.2 1.5 2.0 2.5 3.0 4.0 5.0 6.0 7.0))
    (let ((params (kitty-graphics--decompose-scale scale)))
      (cl-assert (kitty-graphics--validate-osc66
                  (nth 0 params) (nth 1 params) (nth 2 params) "test")
                 nil (format "decomposed scale %.1f should validate" scale))))
  ;; heading-sgr: should return a string (falls back to bold in batch)
  (let ((sgr (kitty-graphics--heading-sgr 1)))
    (cl-assert (stringp sgr) nil "heading-sgr should return string")
    (cl-assert (string-prefix-p "\e[" sgr) nil "heading-sgr should be SGR escape"))
  ;; face-sgr: undefined face falls back to bold
  (cl-assert (equal (kitty-graphics--face-sgr 'no-such-face-xyz) "\e[1m")
             nil "face-sgr should fall back to bold for undefined face")
  ;; face-sgr: a real face yields a well-formed SGR escape
  (let ((sgr (kitty-graphics--face-sgr 'bold)))
    (cl-assert (and (string-prefix-p "\e[" sgr) (string-suffix-p "m" sgr))
               nil "face-sgr should be a complete SGR escape"))
  ;; face-sgr: italic face emits the slant parameter
  (cl-assert (string-match-p ";?3;?\\|\\[3m" (kitty-graphics--face-sgr 'italic))
             nil "face-sgr should emit slant for an italic face")
  ;; color-sgr: foreground vs background selector, unusable color -> nil
  (cl-assert (string-prefix-p "38;2;" (kitty-graphics--color-sgr 38 "#ffffff"))
             nil "color-sgr should build a 38;2 foreground param")
  (cl-assert (string-prefix-p "48;2;" (kitty-graphics--color-sgr 48 "#000000"))
             nil "color-sgr should build a 48;2 background param")
  (cl-assert (null (kitty-graphics--color-sgr 38 "unspecified-fg"))
             nil "color-sgr should reject unspecified colors")
  ;; spec-attribute: resolves plists, color strings, and :inherit
  (cl-assert (equal (kitty-graphics--spec-attribute '(:foreground "#ff0000") :foreground)
                    "#ff0000")
             nil "spec-attribute should read a plist foreground")
  (cl-assert (equal (kitty-graphics--spec-attribute "#00ff00" :foreground) "#00ff00")
             nil "spec-attribute should treat a color string as foreground")
  (cl-assert (null (kitty-graphics--spec-attribute "#00ff00" :background))
             nil "spec-attribute color string has no background")
  ;; face-sgr: a custom TODO-style color plist yields the right RGB
  (cl-assert (string-match-p "38;2;255;0;0"
                             (kitty-graphics--face-sgr '(:foreground "#ff0000")))
             nil "face-sgr should render a custom keyword color")
  ;; make-heading-overlay: creates overlay with correct properties
  (with-temp-buffer
    (insert "* Test Heading\nBody text\n")
    (let* ((kitty-graphics--dry-run t)
           (ov (kitty-graphics--make-heading-overlay 1 15 "Test Heading" 2.0 1)))
      (cl-assert (overlay-get ov 'kitty-graphics) nil "overlay should have kitty-graphics")
      (cl-assert (overlay-get ov 'kitty-graphics-heading) nil "should be heading type")
      (cl-assert (equal (overlay-get ov 'kitty-graphics-heading-text) "Test Heading")
                 nil "heading text mismatch")
      (cl-assert (= (overlay-get ov 'kitty-graphics-heading-scale) 2.0)
                 nil "heading scale mismatch")
      (cl-assert (= (overlay-get ov 'kitty-graphics-heading-level) 1)
                 nil "heading level mismatch")
      (cl-assert (= (overlay-get ov 'kitty-graphics-heading-cell-s) 2)
                 nil "cell-s should be 2 for scale 2.0")
      (cl-assert (= (overlay-get ov 'kitty-graphics-rows) 2)
                 nil "rows should match cell-s")
      (cl-assert (stringp (overlay-get ov 'display))
                 nil "should have display property")
      (cl-assert (stringp (overlay-get ov 'after-string))
                 nil "should have after-string for cell-s > 1")
      (delete-overlay ov)))
  ;; place-heading: verify escape sequence format in dry-run
  (with-temp-buffer
    (insert "* Hello World\nBody\n")
    (let* ((kitty-graphics--dry-run t)
           (kitty-graphics-debug t)
           (ov (kitty-graphics--make-heading-overlay 1 14 "Hello World" 2.0 1)))
      ;; Simulate cached position (normally set by refresh phase 1)
      (overlay-put ov 'kitty-graphics-last-row 5)
      (overlay-put ov 'kitty-graphics-last-col 1)
      (kitty-graphics--place-heading ov)
      ;; In dry-run, the escape was logged, not sent — verify overlay
      ;; properties are intact (the function reads but doesn't modify them)
      (cl-assert (= (overlay-get ov 'kitty-graphics-last-row) 5)
                 nil "place-heading should not modify cached position")
      (delete-overlay ov)))
  ;; heading-fit-text: full fit, truncation, and wide chars
  (cl-assert (equal (kitty-graphics--heading-fit-text "Hello World" 2 79)
                    "Hello World")
             nil "fit-text should keep text that fits")
  (cl-assert (equal (kitty-graphics--heading-fit-text "Hello World" 2 10)
                    "Hello")
             nil "fit-text should truncate to max-cols")
  (cl-assert (equal (kitty-graphics--heading-fit-text "日本語" 2 8) "日本")
             nil "fit-text should count double-width chars")
  (cl-assert (equal (kitty-graphics--heading-fit-text "abc" 2 1) "")
             nil "fit-text should return empty when nothing fits")
  ;; heading-sync-reservation: display + after-string sized to the block
  (with-temp-buffer
    (insert "* Reserve Me\nBody\n")
    (let* ((kitty-graphics--heading-flush-needed nil)
           (ov (kitty-graphics--make-heading-overlay 1 13 "Reserve Me" 2.0 1)))
      (kitty-graphics--heading-sync-reservation ov 20 2)
      (cl-assert kitty-graphics--heading-flush-needed
                 nil "reservation change should flag a flush")
      (cl-assert (equal (overlay-get ov 'display) (make-string 20 ?\s))
                 nil "display should be block-width spaces")
      (cl-assert (equal (overlay-get ov 'after-string)
                        (concat (make-string 20 ?\s) "\n"))
                 nil "after-string should be one block-width space line")
      (setq kitty-graphics--heading-flush-needed nil)
      (kitty-graphics--heading-sync-reservation ov 20 2)
      (cl-assert (not kitty-graphics--heading-flush-needed)
                 nil "unchanged reservation should not flag a flush")
      (kitty-graphics--heading-reset ov)
      (cl-assert (null (overlay-get ov 'kitty-graphics-last-row))
                 nil "reset should clear cached row")
      (cl-assert (equal (overlay-get ov 'display) "Reserve Me")
                 nil "reset should restore plain text display")
      (delete-overlay ov)))
  (with-current-buffer (window-buffer (selected-window))
    (cl-assert (= 0 (kitty-graphics--window-line-number-width (selected-window)))
               nil "line-number width must be 0 when display-line-numbers is off")
    (setq-local display-line-numbers t)
    (unwind-protect
        (let ((width (kitty-graphics--window-line-number-width (selected-window))))
          (cl-assert (and (integerp width) (>= width 0))
                     nil "line-number width must be a non-negative integer"))
      (kill-local-variable 'display-line-numbers)))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/bin/mpv"))
            ((symbol-function 'call-process)
             (lambda (&rest _)
               (insert "Available video outputs:\n"
                       "  gpu : Shader-based GPU Renderer\n"
                       "  sixel : terminal graphics using sixels\n"
                       "  kitty : Kitty terminal graphics protocol\n")
               0)))
    (let ((kitty-graphics--mpv-vo-sixel-cache 'unknown))
      (cl-assert (kitty-graphics--mpv-vo-sixel-p)
                 nil "probe should find a listed sixel vo")))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/bin/mpv"))
            ((symbol-function 'call-process)
             (lambda (&rest _)
               (insert "Available video outputs:\n"
                       "  gpu : Shader-based GPU Renderer\n"
                       "  kitty : Kitty terminal graphics protocol\n"
                       "  tct : true-color terminals\n")
               0)))
    (let ((kitty-graphics--mpv-vo-sixel-cache 'unknown))
      (cl-assert (not (kitty-graphics--mpv-vo-sixel-p))
                 nil "probe should miss when no sixel vo is listed")))
  (let ((kitty-graphics-sixel-dither "fs")
        (kitty-graphics-sixel-colors 16))
    (let ((args (kitty-graphics--mpv-vo-args "sixel" 3 5 640 320 80 20)))
      (dolist (expected '("--vo=sixel"
                          "--vo-sixel-cols=80"
                          "--vo-sixel-rows=20"
                          "--vo-sixel-width=640"
                          "--vo-sixel-height=320"
                          "--vo-sixel-left=3"
                          "--vo-sixel-top=5"
                          "--vo-sixel-config-clear=no"
                          "--vo-sixel-dither=fs"
                          "--vo-sixel-fixedpalette=no"
                          "--vo-sixel-reqcolors=16"))
        (cl-assert (member expected args)
                   nil (format "sixel vo args should contain %s" expected)))))
  (let ((kitty-graphics-sixel-dither nil)
        (kitty-graphics-sixel-colors 256))
    (let ((args (kitty-graphics--mpv-vo-args "sixel" 1 1 100 100 10 10)))
      (cl-assert (not (seq-find (lambda (a) (string-prefix-p "--vo-sixel-dither" a)) args))
                 nil "default dither should not be passed to mpv")
      (cl-assert (not (seq-find (lambda (a) (string-prefix-p "--vo-sixel-reqcolors" a)) args))
                 nil "default 256 colors should not be passed to mpv")))
  (let ((args (kitty-graphics--mpv-vo-args "kitty" 3 5 640 320 80 20)))
    (dolist (expected '("--vo=kitty"
                        "--vo-kitty-cols=80"
                        "--vo-kitty-rows=20"
                        "--vo-kitty-left=3"
                        "--vo-kitty-top=5"))
      (cl-assert (member expected args)
                 nil (format "kitty vo args should contain %s" expected))))
  ;; org inline images: commented-out links (`# [[...]]') must not render,
  ;; matching native org which skips them via the parse tree (issue from #37).
  (require 'org)
  (let* ((img (make-temp-file "kitty-graphics-selftest" nil ".png"))
         (rendered nil)
         (record (lambda (file &rest _) (push (file-name-nondirectory file) rendered))))
    (unwind-protect
        (cl-letf (((symbol-function 'kitty-graphics--org-display-image) record)
                  ((symbol-function 'kitty-graphics--image-file-p) (lambda (_) t)))
          (with-temp-buffer
            (org-mode)
            (setq buffer-file-name (expand-file-name "selftest.org"))
            (insert (format "# [[%s]]\n\n[[%s]]\n" img img))
            (kitty-graphics--org-display-inline-images-tty))
          (cl-assert (= (length rendered) 1)
                     nil "org-display should skip commented-out image links")
          ;; A link the user just commented out must drop its leftover
          ;; preview overlay, else the orphan drives a refresh feedback loop.
          (let ((kitty-graphics--dry-run t))
            (with-temp-buffer
              (org-mode)
              (setq buffer-file-name (expand-file-name "selftest.org"))
              (insert (format "# [[%s]]\n" img))
              (overlay-put (make-overlay (point-min) (line-end-position 0))
                           'kitty-graphics t)
              (kitty-graphics--org-display-inline-images-tty)
              (cl-assert (null (cl-find-if (lambda (o) (overlay-get o 'kitty-graphics))
                                           (overlays-in (point-min) (point-max))))
                         nil "commenting a link should remove its preview overlay"))))
      (delete-file img)))
  (message "kitty-graphics: all self-tests passed"))

(define-obsolete-function-alias 'kitty-gfx-run-self-tests 'kitty-graphics-run-self-tests "1.3.0")

;;;; Heading overlay management

(defun kitty-graphics--make-heading-overlay (beg end text scale level)
  "Create overlay from BEG to END for heading TEXT at SCALE.
LEVEL is the org heading level (1-based).
SCALE is the visual scale factor (float, e.g., 1.5 for 1.5x).
Decomposed into OSC 66 parameters (s, n, d).  The cell scale s
determines the multicell block height (rows).  Vertical space is
reserved via an `after-string' of (s - 1) newlines.

Does NOT emit any OSC 66 -- that happens during refresh."
  (let* ((decomposed (kitty-graphics--decompose-scale scale))
         (cell-s (nth 0 decomposed))
         (frac-n (nth 1 decomposed))
         (frac-d (nth 2 decomposed))
         (rows cell-s)
         (cols (* (string-width text) cell-s))
         (ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'kitty-graphics t)
    (overlay-put ov 'kitty-graphics-heading t)
    (overlay-put ov 'kitty-graphics-heading-text text)
    (overlay-put ov 'kitty-graphics-heading-scale (float scale))
    (overlay-put ov 'kitty-graphics-heading-cell-s cell-s)
    (overlay-put ov 'kitty-graphics-heading-frac-n frac-n)
    (overlay-put ov 'kitty-graphics-heading-frac-d frac-d)
    (overlay-put ov 'kitty-graphics-heading-level level)
    (overlay-put ov 'kitty-graphics-cols cols)
    (overlay-put ov 'kitty-graphics-rows rows)
    ;; Show the plain heading text initially — no spaces yet.
    ;; The `display' property strips org markup (stars, links) so
    ;; the heading is readable even before OSC 66 renders.
    ;; After the first successful OSC 66 emission,
    ;; `kitty-graphics--place-heading' switches this to spaces so that
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
      (let ((spaceline (concat (make-string
                                (min cols (max 1 (1- (frame-width))))
                                ?\s)
                               "\n")))
        (overlay-put ov 'after-string
                     (apply #'concat
                            (make-list (1- cell-s) spaceline)))))
    ;; High priority so kitty-graphics overlays win over org-modern etc.
    (overlay-put ov 'priority 100)
    (overlay-put ov 'modification-hooks
                 (list #'kitty-graphics--heading-modified))
    (overlay-put ov 'insert-in-front-hooks
                 (list #'kitty-graphics--heading-modified))
    (overlay-put ov 'insert-behind-hooks
                 (list #'kitty-graphics--heading-modified))
    (add-hook 'change-major-mode-hook #'kitty-graphics--remove-buffer-graphics nil t)
    (push ov kitty-graphics--overlays)
    (kitty-graphics--log "make-heading-ov: L%d scale=%.2f s=%d n=%d d=%d text=%S beg=%d end=%d"
                     level (float scale) cell-s frac-n frac-d text beg end)
    ov))

(defun kitty-graphics--heading-modified (ov after &rest _args)
  "Modification hook for heading overlays.
When the heading text is edited (AFTER is non-nil), the overlay stays
in place: it is marked stale and its display property is dropped so
the live buffer text shows at normal size while typing — Emacs
redrawing the line over the multicell block erases it (kitty's
overwrite rule), so no manual erase is sent.  A debounced rescan then
updates the overlay in place (or removes it when the line is no
longer a heading)."
  (when (and after (overlay-buffer ov))
    (unless (overlay-get ov 'kitty-graphics-heading-stale)
      (kitty-graphics--log "heading-modified: marking overlay stale at %d"
                       (overlay-start ov))
      (overlay-put ov 'kitty-graphics-heading-stale t)
      (overlay-put ov 'kitty-graphics-heading-emitted nil)
      (overlay-put ov 'display nil)
      (overlay-put ov 'kitty-graphics-last-row nil)
      (overlay-put ov 'kitty-graphics-last-col nil))
    (when kitty-graphics--heading-rescan-timer
      (cancel-timer kitty-graphics--heading-rescan-timer))
    (setq kitty-graphics--heading-rescan-timer
          (let ((buf (current-buffer)))
            (run-at-time 0.2 nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq kitty-graphics--heading-rescan-timer nil)
                               (kitty-graphics--heading-rescan-stale)))))))))

(defun kitty-graphics--heading-rescan-stale ()
  "Update every stale heading overlay in the current buffer in place.
Overlays whose line still matches `org-heading-regexp' are re-anchored
and refreshed via `kitty-graphics--heading-update-overlay'; the rest are
removed and their line is re-scanned so a heading whose level (and thus
scale) changed gets a fresh overlay."
  (when (and kitty-graphics-mode (derived-mode-p 'org-mode))
    (let ((changed 0))
      (dolist (ov (copy-sequence kitty-graphics--overlays))
        (when (and (overlay-get ov 'kitty-graphics-heading)
                   (overlay-get ov 'kitty-graphics-heading-stale)
                   (overlay-buffer ov))
          (cl-incf changed)
          (unless (kitty-graphics--heading-update-overlay ov)
            (let ((line-beg (save-excursion
                              (goto-char (overlay-start ov))
                              (line-beginning-position)))
                  (line-end (save-excursion
                              (goto-char (overlay-start ov))
                              (line-end-position))))
              (kitty-graphics--remove-overlay ov)
              (kitty-graphics--org-apply-heading-sizes line-beg line-end)))))
      (when (> changed 0)
        (kitty-graphics--log "heading-rescan-stale: refreshed %d overlays" changed)
        (kitty-graphics--schedule-refresh t)))))

(defun kitty-graphics--heading-update-overlay (ov)
  "Re-anchor stale heading overlay OV to its line and refresh its text.
Returns non-nil when OV still covers a heading of unchanged scale and
was updated in place; nil when the caller should remove it (line is no
longer a heading, the level's scale changed, or another heading overlay
already owns the line)."
  (save-excursion
    (goto-char (overlay-start ov))
    (let ((line-beg (line-beginning-position))
          (line-end (line-end-position)))
      (goto-char line-beg)
      (when (and (< line-beg line-end)
                 (looking-at org-heading-regexp)
                 (not (cl-some (lambda (other)
                                 (and (not (eq other ov))
                                      (overlay-get other 'kitty-graphics-heading)
                                      (not (overlay-get other 'kitty-graphics-heading-stale))))
                               (overlays-in line-beg line-end))))
        (let* ((level (org-current-level))
               (scale (and level (alist-get level kitty-graphics-heading-scales)))
               (cell-s (overlay-get ov 'kitty-graphics-heading-cell-s))
               (decomposed (and scale (kitty-graphics--decompose-scale scale))))
          (when (and (kitty-graphics--heading-scaled-p scale)
                     (= cell-s (nth 0 decomposed)))
            (let* ((segments (and kitty-graphics-heading-fontify-keywords
                                  (kitty-graphics--org-heading-segments level)))
                   (text (if segments
                             (mapconcat #'car segments "")
                           (kitty-graphics--org-heading-title level))))
              (move-overlay ov line-beg line-end)
              (overlay-put ov 'kitty-graphics-heading-text text)
              (overlay-put ov 'kitty-graphics-heading-segments segments)
              (overlay-put ov 'kitty-graphics-heading-scale (float scale))
              (overlay-put ov 'kitty-graphics-heading-frac-n (nth 1 decomposed))
              (overlay-put ov 'kitty-graphics-heading-frac-d (nth 2 decomposed))
              (overlay-put ov 'kitty-graphics-heading-level level)
              (overlay-put ov 'kitty-graphics-cols (* (string-width text) cell-s))
              (overlay-put ov 'display text)
              (overlay-put ov 'kitty-graphics-heading-stale nil)
              (overlay-put ov 'kitty-graphics-heading-emitted nil)
              (kitty-graphics--log "heading-update: L%d re-anchored text=%S" level text)
              t)))))))

(defun kitty-graphics--org-heading-title (level)
  "Return the plain, link-formatted title of the org heading at point.
LEVEL is unused but kept for symmetry with
`kitty-graphics--org-heading-segments'."
  (ignore level)
  (let ((raw (org-get-heading t t t t)))
    (substring-no-properties
     (if (fboundp 'org-link-display-format)
         (org-link-display-format raw)
       raw))))

(defun kitty-graphics--org-heading-segments (level)
  "Return styled (TEXT . FACE) runs for the org heading at point.
Splits the heading into its TODO/DONE keyword, priority cookie, title,
and tags, each paired with the face Emacs fontifies it with.  Point
must be at the heading line.  The concatenation of the run texts is the
full string the heading should display."
  (let ((title-face (intern (format "org-level-%d" (min level 8))))
        (todo (org-get-todo-state))
        (tags (org-get-tags nil t))
        (title (kitty-graphics--org-heading-title level))
        (priority (save-excursion
                    (beginning-of-line)
                    (when (re-search-forward
                           "^\\*+ +\\(?:[A-Z0-9]+ +\\)?\\(\\[#[A-Z0-9]\\]\\)"
                           (line-end-position) t)
                      (match-string-no-properties 1))))
        (segments nil))
    (when todo
      (push (cons (concat todo " ") (org-get-todo-face todo)) segments))
    (when priority
      (push (cons (concat priority " ") 'org-priority) segments))
    (push (cons title title-face) segments)
    (when tags
      (push (cons (concat " :" (mapconcat #'identity tags ":") ":") 'org-tag)
            segments))
    (nreverse segments)))

(defun kitty-graphics--org-apply-heading-sizes (&optional beg end)
  "Scan org headings in region BEG..END and create scaled overlays.
Only creates overlays for headings with a scale > 1.0 in
`kitty-graphics-heading-scales'.  Skips headings that already have
a kitty-graphics heading overlay."
  (when (derived-mode-p 'org-mode)
    (let ((start (or beg (point-min)))
          (stop (or end (point-max)))
          (count 0))
      (kitty-graphics--log "apply-heading-sizes: scanning %d..%d in %s"
                       start stop (buffer-name))
      (save-excursion
        (goto-char start)
        (while (re-search-forward org-heading-regexp stop t)
          (let* ((level (org-current-level))
                 (scale (alist-get level kitty-graphics-heading-scales))
                 (line-beg (line-beginning-position))
                 (line-end (line-end-position)))
            (when (kitty-graphics--heading-scaled-p scale)
              ;; Skip if already has a heading overlay
              (unless (cl-some (lambda (ov)
                                 (overlay-get ov 'kitty-graphics-heading))
                               (overlays-in line-beg line-end))
                (let* ((segments (and kitty-graphics-heading-fontify-keywords
                                      (kitty-graphics--org-heading-segments level)))
                       (text (if segments
                                 (mapconcat #'car segments "")
                               (kitty-graphics--org-heading-title level)))
                       (ov (kitty-graphics--make-heading-overlay
                            line-beg line-end text scale level)))
                  (overlay-put ov 'kitty-graphics-heading-segments segments)
                  (cl-incf count)))))))
      (kitty-graphics--log "apply-heading-sizes: created %d overlays" count)
      (when (> count 0)
        (kitty-graphics--schedule-refresh t)))))

(defun kitty-graphics--heading-scan-window (win)
  "Apply heading sizes around WIN's displayed region.
Scans from two screenfuls above `window-start' to two screenfuls
below `window-end'.  Idempotent: already-instrumented headings are
skipped by `kitty-graphics--org-apply-heading-sizes'.  No-op unless WIN's
buffer has heading sizes enabled."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (when (and kitty-graphics--heading-sizes-enabled
                 (derived-mode-p 'org-mode))
        (let ((margin (* 2 (max 1 (window-body-height win)))))
          (save-excursion
            (goto-char (window-start win))
            (forward-line (- margin))
            (let ((beg (point)))
              (goto-char (or (window-end win t) (point-max)))
              (forward-line margin)
              (kitty-graphics--org-apply-heading-sizes beg (point)))))))))

(defun kitty-graphics--heading-scan-visible ()
  "Run a visible-region heading scan for every relevant window.
Covers windows whose buffer has heading sizes enabled when
`kitty-graphics-heading-scan-visible-only' is active."
  (when kitty-graphics-heading-scan-visible-only
    (walk-windows
     (lambda (w)
       (when (buffer-local-value 'kitty-graphics--heading-sizes-enabled
                                 (window-buffer w))
         (kitty-graphics--heading-scan-window w)))
     nil 'visible)))

(defun kitty-graphics--heading-apply-initial ()
  "Instrument headings after enabling sizes in the current buffer.
Scans only the displayed viewport when
`kitty-graphics-heading-scan-visible-only' is non-nil (later regions are
picked up by the scroll and window-change hooks); otherwise scans the
whole buffer."
  (if kitty-graphics-heading-scan-visible-only
      (let ((win (get-buffer-window nil 'visible)))
        (when win
          (kitty-graphics--heading-scan-window win)))
    (kitty-graphics--org-apply-heading-sizes)))

(defun kitty-graphics--org-remove-heading-sizes ()
  "Remove all heading size overlays from the current buffer.
Removing the overlays drops their space reservations, so the next
redisplay redraws the heading lines as plain text over the multicell
blocks, which erases them (kitty's overwrite rule)."
  (setq kitty-graphics--heading-sizes-enabled nil)
  (let ((count 0))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'kitty-graphics-heading)
        (kitty-graphics--remove-overlay ov)
        (cl-incf count)))
    (kitty-graphics--log "remove-heading-sizes: removed %d" count)
    (when (> count 0)
      (kitty-graphics--schedule-refresh t))))

(defvar-local kitty-graphics--heading-saved-modes nil
  "Alist of (MODE . WAS-ACTIVE) saved when heading sizes are enabled.
Used to restore conflicting minor modes when heading sizes are disabled.")

(defun kitty-graphics--heading-disable-conflicting ()
  "Disable minor modes that conflict with OSC 66 heading rendering.
The modes come from `kitty-graphics-heading-conflicting-modes'; their state
is saved for restoration by `kitty-graphics--heading-restore-modes'.
Folded headings are left alone — they are skipped during rendering via
`kitty-graphics--in-folded-region-p'."
  (setq kitty-graphics--heading-saved-modes nil)
  (dolist (mode kitty-graphics-heading-conflicting-modes)
    (when (and (boundp mode) (symbol-value mode) (fboundp mode))
      (push (cons mode t) kitty-graphics--heading-saved-modes)
      (funcall mode -1)
      (kitty-graphics--log "heading-preview: disabled %s" mode)))
  (when kitty-graphics--heading-saved-modes
    (kitty-graphics--log "heading-preview: saved modes=%S" kitty-graphics--heading-saved-modes)))

(defun kitty-graphics--heading-restore-modes ()
  "Restore minor modes that were disabled for heading rendering."
  (dolist (entry kitty-graphics--heading-saved-modes)
    (when (cdr entry)
      (funcall (car entry) 1)
      (kitty-graphics--log "heading-preview: restored %s" (car entry))))
  (setq kitty-graphics--heading-saved-modes nil))

;;;###autoload
(defun kitty-graphics-org-heading-sizes (&optional arg)
  "Toggle scaled heading sizes in the current org buffer.
Enters a clean preview mode: the minor modes listed in
`kitty-graphics-heading-conflicting-modes' are temporarily disabled.
Folding is preserved; folded headings render as plain text until
revealed.  Toggling off restores previous state.
With prefix ARG, force remove heading sizes."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org-mode buffer"))
  (unless (eq kitty-graphics--text-sizing-support 'scale)
    (user-error "Terminal does not support text sizing (needs Kitty >= 0.40.0)"))
  (if (or arg (cl-some (lambda (ov) (overlay-get ov 'kitty-graphics-heading))
                        (overlays-in (point-min) (point-max))))
      (progn
        (kitty-graphics--org-remove-heading-sizes)
        (kitty-graphics--heading-restore-modes)
        (message "Heading sizes removed, modes restored"))
    (setq kitty-graphics--heading-sizes-enabled t)
    (kitty-graphics--heading-disable-conflicting)
    (kitty-graphics--heading-apply-initial)
    (message "Heading sizes applied (preview mode — conflicting modes disabled)")))

(define-obsolete-function-alias 'kitty-gfx-org-heading-sizes 'kitty-graphics-org-heading-sizes "1.3.0")

;;;; Position mapping

(defun kitty-graphics--in-folded-region-p (pos)
  "Non-nil if POS is inside a folded region (collapsed heading, block, etc.).
Checks org-fold (org 9.6+, text-property based) first, then falls
back to overlay-based invisibility for legacy org and outline-mode.
Ignores cosmetic invisibility like hidden link brackets (`org-link')
or markdown markup (`markdown-markup') — markdown-mode puts that
property on link/image markup whenever it fontifies, regardless of
whether hiding is active in `buffer-invisibility-spec'."
  (let ((folded
         (or
          ;; org-fold (org 9.6+): text-property based folding.
          (and (fboundp 'org-fold-folded-p)
               (condition-case nil
                   (org-fold-folded-p pos)
                 (error nil)))
          ;; Legacy / non-org overlay-based folding (outline-mode, etc.)
          (let ((inv (get-char-property pos 'invisible)))
            (and inv (not (memq inv '(org-link markdown-markup))))))))
    (when folded
      (kitty-graphics--log "in-folded-region: pos=%d folded=%s" pos folded))
    folded))

(defun kitty-graphics--window-line-number-width (win)
  "Return the columns WIN's line-number display occupies, 0 when disabled.
Uses `line-number-display-width' with WIN selected so the answer
reflects that window's `display-line-numbers' state, including padding.
Vanilla sessions without line numbers always get 0."
  (if (and (fboundp 'line-number-display-width)
           (window-live-p win)
           (buffer-local-value 'display-line-numbers (window-buffer win)))
      (with-selected-window win
        (round (line-number-display-width 'columns)))
    0))

(defun kitty-graphics--image-top-row (ov win row lnum-width visual-col)
  "Return the body row of image overlay OV's top edge in WIN.
ROW is what `posn-at-point' reported for OV's start.  Emacs reports a
row inside the reservation instead of its top when the multi-line
`display' string starts a line right after a truncated one (#47).
The overlay END is still reported correctly, and the blank
reservation's trailing newline puts END exactly ROWS below the top,
so derive the top from there.  The correction only applies to the
blank reservation made by `kitty-graphics--make-overlay', only when it
fits the window without wrapping and END is visible, and it only ever
moves ROW up within the reserved block, so correct positions are
returned unchanged."
  (let ((rows (overlay-get ov 'kitty-graphics-rows))
        (cols (overlay-get ov 'kitty-graphics-cols))
        (display (overlay-get ov 'display))
        (end (overlay-end ov)))
    (or (and (integerp rows) (integerp cols) (> rows 1)
             (not (overlay-get ov 'kitty-graphics-heading))
             (stringp display)
             (= (length display) (* rows (1+ cols)))
             (string-suffix-p "\n" display)
             (< (overlay-start ov) end)
             (< (+ lnum-width visual-col cols) (window-body-width win))
             (let* ((end-pos (posn-at-point end win))
                    (end-row (and end-pos (cdr (posn-col-row end-pos))))
                    (top-row (and end-row (- end-row rows))))
               (when (and top-row (>= top-row 0)
                          (< top-row row) (< row (+ top-row rows)))
                 (kitty-graphics--log "screen-pos: pid=%s row %d -> %d (end-row=%d rows=%d)"
                                      (overlay-get ov 'kitty-graphics-pid)
                                      row top-row end-row rows)
                 top-row)))
        row)))

(defun kitty-graphics--overlay-screen-pos (ov &optional win)
  "Return (TERM-ROW . TERM-COL) for overlay OV in WIN, or nil if hidden.
Coordinates are 1-indexed terminal positions.  WIN defaults to a window
showing OV's buffer, for interactive debug helpers.
The column accounts for window margins/fringes, the line-number display
width, and horizontal scroll.
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
               (not (kitty-graphics--in-folded-region-p pos)))
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
                 (visual-col (max 0 (- buffer-col (window-hscroll win))))
                 (lnum-width (kitty-graphics--window-line-number-width win)))
            (when row
              (setq row (kitty-graphics--image-top-row
                         ov win row lnum-width visual-col)))
            (kitty-graphics--log "screen-pos-detail: pid=%s posn-col=%d buffer-col=%d visual-col=%d lnum-width=%d posn-row=%d posn-xy=%S body-left=%d body-top=%d"
                            (overlay-get ov 'kitty-graphics-pid) posn-col buffer-col
                            visual-col lnum-width row posn-xy body-left body-top)
            (when col-row
              (let ((result (cons (+ body-top row 1)
                                  (+ body-left lnum-width visual-col 1))))
                (kitty-graphics--log "screen-pos: pid=%s pos=%d win=%s -> row=%d col=%d"
                                (overlay-get ov 'kitty-graphics-pid) pos win
                                (car result) (cdr result))
                result))))))))

;;;; Refresh cycle

(defun kitty-graphics--terminal-image-rows (term)
  "Return the list of terminal rows covered by image placements on TERM.
Reads the per-window placements recorded by
`kitty-graphics--record-image-placement' across all buffers, keeping only
windows that live on TERM.  Used to keep scaled headings from
overwriting image pixels."
  (let ((rows nil))
    (dolist (buf (buffer-list))
      (dolist (ov (buffer-local-value 'kitty-graphics--overlays buf))
        (unless (overlay-get ov 'kitty-graphics-heading)
          (dolist (placement (overlay-get ov 'kitty-graphics-placements))
            (let ((win (car placement))
                  (data (cdr placement)))
              (when (and (window-live-p win)
                         (eq (frame-terminal (window-frame win)) term))
                (let ((row (plist-get data :row))
                      (span (plist-get data :rows)))
                  (when (and row span)
                    (dotimes (r span)
                      (push (+ row r) rows))))))))))
    rows))

(defvar kitty-graphics--heading-pending-erases nil
  "Per-refresh list of (ROW COL COLS ROWS) heading blocks to erase.
Filled in phase 1 by `kitty-graphics--refresh-heading-overlay' when an
emitted heading moved while its window's start stayed put (a pure
redraw, so the cached absolute coordinates still point at the stale
block) and consumed at the start of phase 2
\(`kitty-graphics--emit-heading-overlays') inside the same synchronized
output block, before any placement.  Cleared at the start of every
`kitty-graphics--refresh' pass so an aborted pass cannot leak stale
coordinates into the next one.")

(defun kitty-graphics--emit-heading-overlays (term)
  "Phase 2: emit OSC 66 for visible heading overlays on terminal TERM.
Runs inside the caller's `kitty-graphics--with-terminal' + synchronized-output
block, so phase-1 placement and phase-2 emission stay in one terminal
frame (interleaved Emacs redisplay would otherwise corrupt freshly-placed
multicell blocks).  Only buffers whose canonical heading window lives on
TERM are processed — the cached row/col positions were computed for that
window, so emitting them on any other terminal would paint blocks at
coordinates belonging to a different client's screen.
Skips headings already emitted at their current position and
detects row collisions — if a heading would occupy terminal rows already
taken by another heading or by an image placement, it is skipped to
prevent multicell block / pixel corruption.
Before any placement, erases the queued stale blocks of headings that
moved during phase 1 (`kitty-graphics--heading-pending-erases'), so ghost
multicell fragments do not survive at the old coordinates."
  (dolist (entry kitty-graphics--heading-pending-erases)
    (kitty-graphics--log "emit-heading: erase moved block %S" entry)
    (apply #'kitty-graphics--erase-heading-at entry))
  (setq kitty-graphics--heading-pending-erases nil)
  (let ((image-rows (kitty-graphics--terminal-image-rows term)))
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((canonical (and kitty-graphics--overlays
                                (kitty-graphics--heading-canonical-window buf))))
            (when (and canonical
                       (eq (frame-terminal (window-frame canonical)) term))
              (let ((occupied (make-hash-table :test 'eql)))
                (dolist (r image-rows)
                  (puthash r t occupied))
                ;; First pass: mark rows occupied by already-emitted headings
                (dolist (ov kitty-graphics--overlays)
                  (when (and (overlay-get ov 'kitty-graphics-heading)
                             (overlay-get ov 'kitty-graphics-heading-emitted)
                             (overlay-get ov 'kitty-graphics-last-row))
                    (let ((row (overlay-get ov 'kitty-graphics-last-row))
                          (rows (or (overlay-get ov 'kitty-graphics-rows) 1)))
                      (dotimes (r rows)
                        (puthash (+ row r) t occupied)))))
                ;; Second pass: emit new headings, checking for row conflicts
                (dolist (ov kitty-graphics--overlays)
                  (when (and (overlay-get ov 'kitty-graphics-heading)
                             (overlay-get ov 'kitty-graphics-last-row)
                             (not (overlay-get ov 'kitty-graphics-heading-stale))
                             (not (overlay-get ov 'kitty-graphics-heading-emitted)))
                    (let* ((row (overlay-get ov 'kitty-graphics-last-row))
                           (rows (or (overlay-get ov 'kitty-graphics-rows) 1))
                           (conflict nil))
                      ;; Check if any target row is already occupied
                      (dotimes (r rows)
                        (when (gethash (+ row r) occupied)
                          (setq conflict t)))
                      (if conflict
                          (kitty-graphics--log "emit-heading: SKIP L%d row=%d (row conflict)"
                                          (overlay-get ov 'kitty-graphics-heading-level) row)
                        ;; No conflict — place and mark rows
                        (dotimes (r rows)
                          (puthash (+ row r) t occupied))
                        (kitty-graphics--place-heading ov)))))))))))))

(defun kitty-graphics--refresh-inhibited-p ()
  "Return non-nil if painting now would disturb user feedback.
Only an active minibuffer inhibits the actual paint: placing images
writes cursor-saved/restored escape sequences to the tty and never
touches the echo area, so a lingering `current-message' (e.g. doc-view's
\"Type ... to toggle\" or a mode-enable notice) must NOT block an
explicitly scheduled refresh — in an idle daemon client that message
never clears and the image would never appear.  The high-frequency
`post-command-hook' scheduler still backs off on `current-message' (see
`kitty-graphics--on-redisplay') to avoid flicker over transient feedback."
  (active-minibuffer-window))

(defun kitty-graphics--refresh ()
  "Re-place all visible images after redisplay using direct placements.
Relies on placement IDs (p=PID) — re-placing with the same PID
replaces the previous placement without needing to delete first.
Caches last position per overlay to skip redundant re-placements.
Deletes placements for overlays that scrolled out of view.
Output is routed per window to that window's terminal and wrapped in a
per-terminal synchronized-output pair (BSU/ESU) to prevent flicker, so
several daemon clients on different ttys render correctly at once."
  (when (and kitty-graphics-mode
             (kitty-graphics--any-visible-overlays-p)
             (not (kitty-graphics--refresh-inhibited-p)))
    ;; Force redisplay only when a caller flagged that display properties
    ;; were just mutated (overlay creation, window/buffer-change handlers)
    ;; so `posn-at-point' would otherwise see stale pixel positions.
    ;; Routine `post-command-hook' refreshes skip this — issue #19.
    (when kitty-graphics--force-redisplay
      (setq kitty-graphics--force-redisplay nil)
      (redisplay t))
    (let ((total-overlays 0)
          (placed 0)
          (hidden 0)
          (pruned 0)
          (by-term nil))
      (kitty-graphics--log "refresh: begin")
      (setq kitty-graphics--heading-pending-erases nil)
      ;; Group visible windows by their tty terminal in one pass, so each
      ;; terminal gets exactly ONE synchronized-output block spanning both
      ;; phase 1 (image placement + heading erase) and phase 2 (heading
      ;; emit).  Splitting those phases into separate sync blocks lets Emacs
      ;; redisplay interleave and leaves image/heading artifacts on screen.
      ;; GUI and dead frames are skipped — `send-string-to-terminal' errors
      ;; on a graphical display.
      (walk-windows
       (lambda (win)
         (let* ((frame (window-frame win))
                (term (and (frame-live-p frame)
                           (not (display-graphic-p frame))
                           (frame-terminal frame))))
           (when (and term (terminal-live-p term))
             (let ((cell (assq term by-term)))
               (if cell
                   (setcdr cell (cons win (cdr cell)))
                 (push (list term win) by-term))))))
       nil 'visible)
      (unwind-protect
          (dolist (entry by-term)
            (let ((term (car entry))
                  (wins (cdr entry)))
              ;; Lazily detect + probe this client's capabilities the first
              ;; time it is the selected frame.  `read-event' (used by the
              ;; queries) can only safely read the selected terminal, so
              ;; other clients keep fallback values until focused.  Both
              ;; query functions self-guard on their stored terminal
              ;; parameter, so this is cheap on later refreshes.
              (when (eq (frame-terminal (selected-frame)) term)
                (unless (terminal-parameter term 'kitty-graphics-backend)
                  (kitty-graphics--detect-protocol))
                (kitty-graphics--query-cell-size)
                (when (eq (terminal-parameter term 'kitty-graphics-backend) 'kitty)
                  (kitty-graphics--query-text-sizing-support)))
              (kitty-graphics--with-terminal term
                (kitty-graphics--sync-begin)
                (unwind-protect
                    (progn
                      ;; Phase 1: image placement + heading position/erase
                      ;; for every window on this terminal.
                      (dolist (win wins)
                        (with-current-buffer (window-buffer win)
                          (when kitty-graphics--overlays
                            ;; A single overlay can be visible in multiple
                            ;; windows showing the same buffer.  Its legacy
                            ;; last-row/last-col mirror the placement for the
                            ;; window currently refreshed; per-window tracking
                            ;; keeps individual terminal regions deletable
                            ;; when one window later disappears.
                            (dolist (ov kitty-graphics--overlays)
                              (let ((placement (kitty-graphics--image-placement ov win)))
                                (unless (overlay-get ov 'kitty-graphics-heading)
                                  (overlay-put ov 'kitty-graphics-last-row
                                               (plist-get (cdr placement) :row))
                                  (overlay-put ov 'kitty-graphics-last-col
                                               (plist-get (cdr placement) :col)))))
                            ;; Prune dead overlays (overlay-buffer returns nil)
                            (let ((before (length kitty-graphics--overlays)))
                              (setq kitty-graphics--overlays
                                    (cl-delete-if-not #'overlay-buffer kitty-graphics--overlays))
                              (let ((removed (- before (length kitty-graphics--overlays))))
                                (when (> removed 0)
                                  (cl-incf pruned removed)
                                  (kitty-graphics--log "refresh: pruned %d dead overlays from %s"
                                                  removed (buffer-name)))))
                            (let* ((edges (window-edges win))
                                   (win-bottom (nth 3 edges)))
                              (kitty-graphics--log "refresh: win=%s buf=%s overlays=%d bottom=%d term=%s"
                                              win (buffer-name) (length kitty-graphics--overlays)
                                              win-bottom term)
                              (dolist (ov kitty-graphics--overlays)
                                (cl-incf total-overlays)
                                (kitty-graphics--refresh-overlay ov win win-bottom)
                                (if (overlay-get ov 'kitty-graphics-last-row)
                                    (cl-incf placed)
                                  (cl-incf hidden)))))))
                      ;; Phase 2: emit OSC 66 for heading overlays whose
                      ;; buffer is shown on this terminal, inside the SAME
                      ;; sync block as phase 1 so mini-redraws cannot corrupt
                      ;; the freshly-placed multicell blocks.
                      (if (and kitty-graphics--heading-flush-needed
                               (progn
                                 (setq kitty-graphics--heading-flush-needed nil)
                                 (not (redisplay))))
                          (kitty-graphics--schedule-refresh t)
                        (kitty-graphics--emit-heading-overlays term)))
                  (kitty-graphics--sync-end)))))
        ;; mpv/casty repositioning runs once, after all terminals.  These
        ;; send no direct terminal escapes (frames arrive via the routed
        ;; process filter), so they need not sit inside a sync block.  Each
        ;; picks its own canonical window, constrained to its launch
        ;; terminal, and fires at most once per refresh regardless of how
        ;; many windows show the buffer.
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when kitty-graphics--mpv-overlay
              (kitty-graphics--refresh-mpv-overlay))))
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when kitty-graphics--browser-overlay
              (kitty-graphics--refresh-browser-overlay)))))
      (kitty-graphics--log "refresh: done total=%d placed=%d hidden=%d pruned=%d"
                       total-overlays placed hidden pruned)
      (kitty-graphics--update-window-signatures))))

(defun kitty-graphics--refresh-overlay (ov win win-bottom)
  "Refresh a single overlay OV in WIN.
WIN-BOTTOM is WIN's bottom edge.  Dispatches to heading or image
refresh based on overlay type."
  (if (overlay-get ov 'kitty-graphics-heading)
      ;; Heading overlay — phase 1: compute position + erase if moved.
      ;; OSC 66 emission happens in phase 2 (kitty-graphics--emit-heading-overlays).
      (kitty-graphics--refresh-heading-overlay ov win win-bottom)
  (if (overlay-get ov 'kitty-graphics-doc-view)
      ;; doc-view page — own zoom/scroll/crop path (centering + clipping).
      (kitty-graphics--doc-view-refresh-overlay ov win)
  ;; Image overlay refresh
  (let* ((pos (kitty-graphics--overlay-screen-pos ov win))
         (rows (overlay-get ov 'kitty-graphics-rows))
         (cols (overlay-get ov 'kitty-graphics-cols))
         (placement (kitty-graphics--image-placement ov win))
         (placement-data (cdr placement))
         (last-row (plist-get placement-data :row))
         (last-col (plist-get placement-data :col)))
    (let ((pid (overlay-get ov 'kitty-graphics-pid))
          (id (overlay-get ov 'kitty-graphics-id)))
      (if (and pos
               ;; Start row is on screen
               (<= (car pos) win-bottom)
               ;; In `direct' mode the entire image must fit, since
               ;; `a=p,c,r' places an image at an absolute screen
               ;; position and some terminals corrupt or scroll when
               ;; that region overflows the window.  In `placeholder'
               ;; mode the cells are normal text that Emacs naturally
               ;; clips to the visible buffer area, so partial
               ;; visibility is fine.
               (or (eq (kitty-graphics--effective-placement-mode) 'placeholder)
                   (<= (+ (car pos) rows -1) win-bottom)))
          ;; Visible and fits — place if position changed
          (let ((new-row (car pos))
                (new-col (cdr pos)))
            (cond
             ((and (eql new-row last-row)
                   (eql new-col last-col))
              ;; Kitty keeps the image as a persistent placement, so an
              ;; unchanged position is a no-op.  Sixel pixels live in the
              ;; text grid and any redisplay of those cells (blank-display
              ;; repaint, neighbouring edit) wipes them, leaving the image
              ;; gone since no later refresh re-emits at the same spot.  So
              ;; on Sixel re-emit from the cached encoding (cheap: no
              ;; re-encode, inside the refresh sync block, image-id/pid
              ;; ignored by `kitty-graphics--sixel-place').
              (cond
               ((not (eq kitty-graphics--active-backend 'sixel))
                (kitty-graphics--log "refresh-ov: pid=%d unchanged at row=%d col=%d"
                                pid new-row new-col))
               ;; Re-emit only once the encoding is in hand; while the
               ;; first encode is still running a re-emit would kick off
               ;; a redundant second encode of the same image (the disk
               ;; cache isn't written yet), so skip until it lands.
               ((and (equal (overlay-get ov 'kitty-graphics-sixel-dims)
                            (cons cols rows))
                     (overlay-get ov 'kitty-graphics-sixel-data))
                (kitty-graphics--log "refresh-ov: pid=%d sixel re-emit at row=%d col=%d"
                                pid new-row new-col)
                (funcall (kitty-graphics--backend-fn 'place)
                         ov id pid cols rows new-row new-col))
               (t
                (kitty-graphics--log "refresh-ov: pid=%d sixel re-emit deferred (no cached encoding)"
                                pid))))
             ((not (kitty-graphics--ensure-transmitted
                    (overlay-get ov 'kitty-graphics-file) id))
              (kitty-graphics--log "refresh-ov: pid=%d deferred (transmit queued or converting)"
                              pid))
             (t
              (kitty-graphics--log "refresh-ov: pid=%d moved %s -> row=%d col=%d"
                              pid
                              (if last-row (format "row=%d,col=%d" last-row last-col) "nil")
                              new-row new-col)
              ;; Sixel has no placement IDs — re-placing at a new position
              ;; or size leaves the old pixel block on screen unless we
              ;; explicitly erase it first.  `sixel-delete' reads OLD
              ;; last-row/last-col/cols/rows from the overlay, so erase
              ;; BEFORE updating the cache below (issue #13).
              ;;
              ;; Kitty direct mode: same-PID re-placement is supposed to
              ;; atomically replace the old placement, but when the new
              ;; geometry is smaller than the old one, several terminals
              ;; (Ghostty, WezTerm) leave the cells outside the new
              ;; rectangle painted with the old image's pixels.  Detect
              ;; the shrink case from the per-window placement's recorded
              ;; :cols/:rows and emit an explicit delete first so the old
              ;; rectangle is fully cleared before the new placement
              ;; appears.  Placeholder mode already erases inside
              ;; `kitty-graphics--place-placeholder', so it is not covered here.
              (when last-row
                (let* ((old-cols (plist-get placement-data :cols))
                       (old-rows (plist-get placement-data :rows))
                       (shrunk (or (and old-cols (< cols old-cols))
                                   (and old-rows (< rows old-rows)))))
                  (cond
                   ((eq kitty-graphics--active-backend 'sixel)
                    (funcall (kitty-graphics--backend-fn 'delete) ov id pid))
                   ((and (eq kitty-graphics--active-backend 'kitty)
                         (eq (kitty-graphics--effective-placement-mode) 'direct)
                         shrunk)
                    ;; The terminal placement was emitted with the
                    ;; per-window PID recorded on the overlay's
                    ;; placement, NOT the overlay-level PID, so the
                    ;; delete APC must address that PID.  Fall back to
                    ;; the overlay-level PID only when no per-window
                    ;; entry exists.
                    (let ((win-pid (or (plist-get placement-data :pid)
                                       pid)))
                      (kitty-graphics--log
                       "refresh-ov: pid=%d (win-pid=%d) shrink %dx%d -> %dx%d, delete first"
                       pid win-pid old-cols old-rows cols rows)
                      (funcall (kitty-graphics--backend-fn 'delete)
                               ov id win-pid))))))
              (overlay-put ov 'kitty-graphics-last-row new-row)
              (overlay-put ov 'kitty-graphics-last-col new-col)
              ;; Pass nil so a brand-new (overlay, window) placement gets its
              ;; own unique id instead of the shared overlay base pid; reuse
              ;; the recorded id on a move.  Use the returned effective id for
              ;; the terminal placement so record and emit never diverge.
              (setq pid (kitty-graphics--record-image-placement
                         ov win new-row new-col cols rows nil))
              (funcall (kitty-graphics--backend-fn 'place)
                       ov id pid cols rows new-row new-col))))
        ;; Not visible or overflows — delete if was placed in this window
        (when placement
          (kitty-graphics--log "refresh-ov: pid=%d hiding in win=%s (was row=%d col=%d)"
                          pid win last-row last-col)
          (kitty-graphics--delete-image-placement ov placement)
          (kitty-graphics--forget-image-placement ov win)
          (overlay-put ov 'kitty-graphics-last-row nil)
          (overlay-put ov 'kitty-graphics-last-col nil))))))))

(defun kitty-graphics--heading-canonical-window (buf)
  "Return the single window that renders BUF's scaled headings.
Mirrors `kitty-graphics--browser-canonical-window': prefers the selected
window when it shows BUF on a text terminal, else the first visible
text-terminal window showing BUF.  Heading overlays cache one terminal
position (`kitty-graphics-last-row'/`kitty-graphics-last-col') and one `window'
pin, so exactly one window — and therefore one terminal — can show the
OSC 66 rendering; all other windows keep plain text.  Picking per
buffer rather than per terminal keeps the pin stable when the buffer
is visible on several terminals at once."
  (let ((sel (selected-window)))
    (if (and (window-live-p sel)
             (eq (window-buffer sel) buf)
             (not (display-graphic-p (window-frame sel))))
        sel
      (cl-find-if (lambda (w)
                    (not (display-graphic-p (window-frame w))))
                  (get-buffer-window-list buf nil 'visible)))))

(defun kitty-graphics--refresh-heading-overlay (ov win win-bottom)
  "Refresh heading overlay OV in WIN.
WIN-BOTTOM is WIN's bottom edge.  Phase 1 of two-phase heading
refresh: computes the screen position, fits the heading text to the
window width, syncs the space reservation, and caches the new
position.  Does NOT emit OSC 66 — that happens in phase 2
\(`kitty-graphics--emit-heading-overlays') after the reservation spaces
were flushed to the terminal.  When an emitted heading moved while
the window start stayed put, the screen did not scroll, so the old
block still sits at the cached coordinates: that block is queued on
`kitty-graphics--heading-pending-erases' for phase 2 to erase.  When the
window start changed, the terminal scrolled the old block together
with the surrounding text, so nothing is queued — the pre-place
erase at the new position covers it.  Collapsed headings (their own
fold ellipsis at end of line) and hidden ones fall back to plain text
via `kitty-graphics--heading-reset' — Emacs redrawing the line then clears
the block.  Stale overlays (mid-edit) are left untouched, and only
the buffer's canonical window is processed; the overlay's `window'
property is pinned to it so other windows showing the buffer display
plain heading text."
  (when (and (not (overlay-get ov 'kitty-graphics-heading-stale))
             (eq win (kitty-graphics--heading-canonical-window (overlay-buffer ov))))
    (unless (eq (overlay-get ov 'window) win)
      (overlay-put ov 'window win)
      (overlay-put ov 'kitty-graphics-last-row nil)
      (overlay-put ov 'kitty-graphics-last-col nil)
      (overlay-put ov 'kitty-graphics-heading-emitted nil)
      (kitty-graphics--schedule-refresh t))
    (let ((pos (kitty-graphics--overlay-screen-pos ov win))
          (rows (overlay-get ov 'kitty-graphics-rows))
          (last-row (overlay-get ov 'kitty-graphics-last-row))
          (last-col (overlay-get ov 'kitty-graphics-last-col))
          (last-cols (overlay-get ov 'kitty-graphics-cols))
          (last-wstart (overlay-get ov 'kitty-graphics-last-wstart)))
      (if (and pos
               (<= (car pos) win-bottom)
               (<= (+ (car pos) rows -1) win-bottom)
               (not (kitty-graphics--in-folded-region-p (overlay-end ov))))
          (let* ((new-row (car pos))
                 (new-col (cdr pos))
                 (cell-s (overlay-get ov 'kitty-graphics-heading-cell-s))
                 (max-cols (max 0 (- (nth 2 (window-body-edges win))
                                     new-col)))
                 (fit (kitty-graphics--heading-fit-text
                       (overlay-get ov 'kitty-graphics-heading-text)
                       cell-s max-cols))
                 (cols (* (string-width fit) cell-s)))
            (if (zerop cols)
                (kitty-graphics--heading-reset ov)
              (overlay-put ov 'kitty-graphics-render-text fit)
              (overlay-put ov 'kitty-graphics-cols cols)
              (unless (and (eql new-row last-row)
                           (eql new-col last-col))
                (when (and last-row last-col
                           (overlay-get ov 'kitty-graphics-heading-emitted)
                           (eql (window-start win) last-wstart))
                  (kitty-graphics--log "refresh-heading: queue erase of moved block row=%d col=%d cols=%d"
                                  last-row last-col (or last-cols 0))
                  (push (list last-row last-col (or last-cols 0) (or rows 1))
                        kitty-graphics--heading-pending-erases))
                (overlay-put ov 'kitty-graphics-heading-emitted nil))
              (overlay-put ov 'kitty-graphics-last-row new-row)
              (overlay-put ov 'kitty-graphics-last-col new-col)
              (overlay-put ov 'kitty-graphics-last-wstart (window-start win))
              (kitty-graphics--heading-sync-reservation ov cols cell-s)
              (kitty-graphics--log "refresh-heading: L%d visible at row=%d col=%d cols=%d"
                              (overlay-get ov 'kitty-graphics-heading-level)
                              new-row new-col cols)))
        (kitty-graphics--heading-reset ov)))))

(defvar kitty-graphics--refresh-pending nil
  "Non-nil if a refresh was requested during the cooldown period.")

;; `kitty-graphics--force-redisplay' is declared near top of file alongside
;; `kitty-graphics--render-timer'.  It is set by paths that just mutated
;; display properties (overlay creation, window/buffer-change handlers)
;; and consumed/cleared by `kitty-graphics--refresh'.  Routine
;; `post-command-hook' refreshes leave it nil so we don't pay the
;; forced-redisplay cost every keystroke — issue #19.

(defun kitty-graphics--schedule-refresh (&optional force-redisplay)
  "Schedule an image refresh using leading-edge debounce.
On the first call, refresh is scheduled via `run-at-time' 0 (fires
after the current redisplay completes) and a cooldown timer starts
\(duration `kitty-graphics-render-delay').  Calls during cooldown are
suppressed but flagged; when the cooldown expires a single trailing
refresh fires to capture the final state.

When FORCE-REDISPLAY is non-nil, the next refresh will call
`(redisplay t)' before measuring positions — needed when the caller
just mutated display properties and `posn-at-point' would otherwise
return stale coordinates."
  (when force-redisplay
    (setq kitty-graphics--force-redisplay t)
    (kitty-graphics--invalidate-window-signatures))
  (if kitty-graphics--render-timer
      ;; Cooldown active — flag that another refresh is wanted.
      (setq kitty-graphics--refresh-pending t)
    ;; No cooldown — schedule refresh after redisplay + start cooldown.
    ;; run-at-time 0 ensures posn-at-point sees up-to-date positions.
    (setq kitty-graphics--refresh-pending nil)
    (run-at-time 0 nil #'kitty-graphics--refresh)
    (setq kitty-graphics--render-timer
          (run-at-time kitty-graphics-render-delay nil
                       (lambda ()
                         (setq kitty-graphics--render-timer nil)
                         (when kitty-graphics--refresh-pending
                           (setq kitty-graphics--refresh-pending nil)
                           (kitty-graphics--refresh)))))))

(defun kitty-graphics--heading-erase-window-blocks (win)
  "Erase WIN's emitted heading blocks at their cached coordinates.
Must run before WIN is redrawn (`window-scroll-functions' time), while
the cached positions still match the glass: Emacs's tty redisplay may
redraw lines instead of scrolling, which leaves the old multicell
block painted at its absolute rows where new text only partially
overwrites it.  Clears the emitted state and position cache but keeps
the space reservation, so the window does not reflow mid-scroll and
the scheduled refresh re-places each heading at its new coordinates."
  (let ((blocks nil))
    (dolist (ov (buffer-local-value 'kitty-graphics--overlays (window-buffer win)))
      (when (and (overlay-buffer ov)
                 (overlay-get ov 'kitty-graphics-heading)
                 (overlay-get ov 'kitty-graphics-heading-emitted)
                 (overlay-get ov 'kitty-graphics-last-row)
                 (overlay-get ov 'kitty-graphics-last-col)
                 (memq (overlay-get ov 'window) (list nil win)))
        (push ov blocks)))
    (when blocks
      (kitty-graphics--with-terminal (frame-terminal (window-frame win))
        (kitty-graphics--sync-begin)
        (unwind-protect
            (dolist (ov blocks)
              (kitty-graphics--erase-heading-at
               (overlay-get ov 'kitty-graphics-last-row)
               (overlay-get ov 'kitty-graphics-last-col)
               (or (overlay-get ov 'kitty-graphics-cols) 0)
               (or (overlay-get ov 'kitty-graphics-rows) 1))
              (overlay-put ov 'kitty-graphics-heading-emitted nil)
              (overlay-put ov 'kitty-graphics-last-row nil)
              (overlay-put ov 'kitty-graphics-last-col nil))
          (kitty-graphics--sync-end))))))

(defun kitty-graphics--on-window-scroll (win _new-start)
  "Handle window scroll for image refresh.
Also extends heading instrumentation around WIN's new region when
visible-only heading scanning is active, and erases WIN's emitted
heading blocks while their cached coordinates are still valid."
  (when (and kitty-graphics-heading-scan-visible-only
             (buffer-local-value 'kitty-graphics--heading-sizes-enabled
                                 (window-buffer win)))
    (kitty-graphics--heading-scan-window win))
  (when (buffer-local-value 'kitty-graphics--overlays (window-buffer win))
    (kitty-graphics--log "on-scroll: win=%s buf=%s" win (buffer-name (window-buffer win)))
    (kitty-graphics--heading-erase-window-blocks win)
    (set-window-parameter win 'kitty-graphics-sig nil)
    (kitty-graphics--schedule-refresh)))

(defun kitty-graphics--on-buffer-change (_frame-or-window)
  "Handle buffer change for image refresh.
Deletes placements for buffers no longer visible in any window,
then invalidates position caches and schedules a refresh.
Newly displayed org buffers with heading sizes enabled get their
viewport instrumented via `kitty-graphics--heading-scan-visible'."
  (kitty-graphics--log "on-buffer-change: cleaning up non-visible placements")
  (kitty-graphics--heading-scan-visible)
  (kitty-graphics--invalidate-window-signatures)
  ;; Find which buffers are currently visible
  (let ((visible-bufs nil))
    (walk-windows (lambda (w) (push (window-buffer w) visible-bufs))
                  nil 'visible)
    (kitty-graphics--log "on-buffer-change: visible-bufs=(%s)"
                    (mapconcat #'buffer-name visible-bufs ", "))
    ;; Drop per-window records on any mpv overlay whose buffer is no
    ;; longer visible OR whose recorded window now shows a different
    ;; buffer.  Prevents stale window entries from confusing
    ;; `kitty-graphics--mpv-canonical-window'.
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and kitty-graphics--mpv-overlay
                   (overlay-buffer kitty-graphics--mpv-overlay))
          (let ((ov kitty-graphics--mpv-overlay))
            (dolist (entry (copy-sequence
                            (overlay-get ov 'kitty-graphics-placements)))
              (let ((w (car entry)))
                (unless (and (window-live-p w)
                             (eq (window-buffer w)
                                 (overlay-buffer ov)))
                  (kitty-graphics--forget-image-placement ov w))))))))
    ;; Delete placements for buffers that are no longer in any window
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and kitty-graphics--overlays
                   (not (memq buf visible-bufs)))
          (kitty-graphics--log "on-buffer-change: deleting placements for hidden buf=%s"
                          (buffer-name))
          (dolist (ov kitty-graphics--overlays)
            (when (overlay-buffer ov)
              (if (overlay-get ov 'kitty-graphics-heading)
                  (kitty-graphics--heading-reset ov)
                ;; Image overlay — delete all terminal placements, including
                ;; multiple windows that were showing this buffer.
                (kitty-graphics--delete-image-placements ov))))))))
  ;; Reset cache for visible buffers so they re-place correctly.  Delete the
  ;; terminal placements FIRST (via `kitty-graphics--delete-image-placements',
  ;; which also clears the record + last-row/col) — nil-ing the record
  ;; without deleting would orphan the on-screen copy at its old position
  ;; (a ghost) because the next refresh allocates a fresh placement id.
  ;; Heading overlays preserve cache (same rationale as on-window-change).
  (kitty-graphics--sync-begin)
  (unwind-protect
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (dolist (ov kitty-graphics--overlays)
            (when (and (overlay-buffer ov)
                       (not (overlay-get ov 'kitty-graphics-heading)))
              (kitty-graphics--delete-image-placements ov)))))
    (kitty-graphics--sync-end))
  ;; Longer debounce: cancel any fast leading-edge cooldown and
  ;; schedule a 0.1s delayed refresh to let buffer switch settle.
  (when kitty-graphics--render-timer
    (cancel-timer kitty-graphics--render-timer))
  (setq kitty-graphics--refresh-pending nil
        kitty-graphics--render-timer
        (run-at-time 0.1 nil
                     (lambda ()
                       (setq kitty-graphics--render-timer nil
                             kitty-graphics--force-redisplay t)
                       (kitty-graphics--refresh)))))

(defun kitty-graphics--frame-resized-p (frame)
  "Return non-nil if FRAME's pixel size changed since the last call.
Records the new size on the frame so the next call compares against it.
A pixel-size change means a terminal-level resize (the kitty OS window
changed, e.g. a new split or `toggle_layout'), as opposed to a purely
internal Emacs window reconfiguration that leaves the frame untouched."
  (let ((size (cons (frame-pixel-width frame) (frame-pixel-height frame)))
        (prev (frame-parameter frame 'kitty-graphics-pixel-size)))
    (set-frame-parameter frame 'kitty-graphics-pixel-size size)
    (not (equal size prev))))

(defun kitty-graphics--forget-terminal-transmits (term)
  "Drop TERM's record of which images it holds so they re-transmit.
Kitty evicts a window's image data when its layout changes (a new
split, or `toggle_layout stack'), but Emacs's per-terminal transmitted
set still lists those ids, so the refresh only re-places them — against
bytes the terminal no longer has, leaving the image blank and
unrecoverable even via `org-toggle-inline-images' (issue #36).  Clearing
the set makes `kitty-graphics--ensure-transmitted' re-send the bytes before
the next placement."
  (let ((h (terminal-parameter term 'kitty-graphics-transmitted)))
    (when h
      (kitty-graphics--log "forget-terminal-transmits: dropping %d ids after resize"
                      (hash-table-count h))
      (clrhash h))))

(defun kitty-graphics--on-window-change (frame)
  "Handle window configuration change for image refresh.
Invalidates cell pixel size, deletes stale image placements, then
clears image position caches so the refresh cycle re-places images
at their new positions.  On a terminal-level resize, also forgets the
transmitted-image set so kitty re-receives evicted image data.  Uses a
longer debounce than normal refresh to let Emacs finish window layout
transitions (e.g., when closing a split, Emacs briefly shows two
windows for the same buffer before settling to one)."
  (kitty-graphics--log "on-window-change: deleting stale placements and invalidating cell size")
  (kitty-graphics--heading-scan-visible)
  (kitty-graphics--invalidate-window-signatures)
  (setq kitty-graphics--cell-pixel-width nil
        kitty-graphics--cell-pixel-height nil)
  ;; Invalidate FRAME's terminal cell-size parameter too, so the
  ;; per-terminal query guard re-queries it (a resize can change the
  ;; pixel cell size, and the guard keys on the parameter, not the global).
  ;; When the frame itself resized, the terminal may have dropped image
  ;; data during its relayout, so forget the transmitted set and let the
  ;; refresh re-transmit (issue #36).
  (let ((term (and (frame-live-p frame) (frame-terminal frame))))
    (when (and term (terminal-live-p term))
      (set-terminal-parameter term 'kitty-graphics-cell-w nil)
      (set-terminal-parameter term 'kitty-graphics-cell-h nil)
      (when (kitty-graphics--frame-resized-p frame)
        (kitty-graphics--forget-terminal-transmits term))))
  ;; Clear stale per-window records on any mpv overlay so the next
  ;; refresh recomputes coordinates against the new layout.  The mpv
  ;; overlay is NEVER pushed onto `kitty-graphics--overlays' (mpv has no
  ;; kitty placement ID), so the dolist below would not touch it; it
  ;; lives only on the buffer-local `kitty-graphics--mpv-overlay'.
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and kitty-graphics--mpv-overlay
                 (overlay-buffer kitty-graphics--mpv-overlay))
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics-placements nil))))
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
  ;; Heading multicell blocks are erased at their cached position here
  ;; too: unlike a scroll (handled by `kitty-graphics--on-window-scroll',
  ;; which preserves the cache for old→new comparison), a layout change
  ;; can drop a popup/minibuffer window over the buffer, and Emacs will
  ;; not repaint the cells the block occupies — so the stale glyphs would
  ;; bleed into the popup unless we wipe them explicitly.
  (kitty-graphics--sync-begin)
  (unwind-protect
      (progn
        (kitty-graphics--heading-erase-all)
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (dolist (ov kitty-graphics--overlays)
              (when (and (overlay-buffer ov)
                         (not (overlay-get ov 'kitty-graphics-heading)))
                (kitty-graphics--delete-image-placements ov))))))
    (kitty-graphics--sync-end))
  ;; Longer debounce: cancel any fast leading-edge cooldown and
  ;; schedule a 0.1s delayed refresh to let window layout settle.
  (when kitty-graphics--render-timer
    (cancel-timer kitty-graphics--render-timer))
  (setq kitty-graphics--refresh-pending nil
        kitty-graphics--render-timer
        (run-at-time 0.1 nil
                     (lambda ()
                       (setq kitty-graphics--render-timer nil
                             kitty-graphics--force-redisplay t)
                       (kitty-graphics--refresh)))))

(defun kitty-graphics--any-visible-overlays-p ()
  "Return non-nil when any visible window's buffer holds kitty-graphics overlays.
Cheap O(n_windows) check used by `kitty-graphics--on-redisplay' to avoid
scheduling timers in unrelated buffers — issue #19."
  (catch 'found
    (walk-windows
     (lambda (w)
       (when (buffer-local-value 'kitty-graphics--overlays (window-buffer w))
         (throw 'found t)))
     nil 'visible)
    nil))

(defun kitty-graphics--window-signature (win)
  "Return a cheap signature of WIN's displayed content.
Captures buffer identity, the buffer's text-change tick, the displayed
region, hscroll, and pixel geometry.  `window-end' is called
non-forcing so computing a signature never triggers redisplay work."
  (let ((buf (window-buffer win)))
    (list buf
          (buffer-chars-modified-tick buf)
          (window-start win)
          (window-end win nil)
          (window-hscroll win)
          (window-pixel-width win)
          (window-pixel-height win))))

(defun kitty-graphics--windows-clean-p ()
  "Return non-nil when every visible overlay window matches its stored signature.
A clean result means nothing an image placement depends on has changed
since the last successful refresh, so `kitty-graphics--on-redisplay' can
skip scheduling one.  Windows showing an mpv or browser overlay are
never considered clean — their terminal-side frames move independently
of any buffer-visible state the signature captures.  Overlay windows on
the selected frame's terminal are also dirty while that terminal's cell
size is still unqueried: `kitty-graphics--refresh' can only run the
capability queries while their terminal is the selected one, so
skipping here would leave a late-attaching client on fallback geometry
forever."
  (let ((selected-term (unless (display-graphic-p) (frame-terminal))))
    (catch 'dirty
      (walk-windows
       (lambda (w)
         (let ((buf (window-buffer w)))
           (when (or (buffer-local-value 'kitty-graphics--mpv-overlay buf)
                     (buffer-local-value 'kitty-graphics--browser-overlay buf))
             (throw 'dirty nil))
           (when (buffer-local-value 'kitty-graphics--overlays buf)
             (when (and selected-term
                        (eq (frame-terminal (window-frame w)) selected-term)
                        (not (terminal-parameter selected-term 'kitty-graphics-cell-w)))
               (throw 'dirty nil))
             (unless (equal (kitty-graphics--window-signature w)
                            (window-parameter w 'kitty-graphics-sig))
               (throw 'dirty nil)))))
       nil 'visible)
      t)))

(defun kitty-graphics--update-window-signatures ()
  "Store the current signature on every visible overlay window.
Called at the end of a successful `kitty-graphics--refresh' pass; a refresh
that bailed early leaves the old signatures so the next
`kitty-graphics--on-redisplay' retries."
  (walk-windows
   (lambda (w)
     (when (buffer-local-value 'kitty-graphics--overlays (window-buffer w))
       (set-window-parameter w 'kitty-graphics-sig (kitty-graphics--window-signature w))))
   nil 'visible))

(defun kitty-graphics--invalidate-window-signatures ()
  "Drop every window's stored refresh signature so the next refresh runs."
  (walk-windows
   (lambda (w) (set-window-parameter w 'kitty-graphics-sig nil))
   nil t))

(defun kitty-graphics--on-redisplay ()
  "Post-command hook to schedule image refresh.
Early-exits when no visible window has any kitty-graphics overlays so
unrelated buffers (dired, magit, scratch, ...) pay no timer or
redisplay cost, and skips while user feedback is in the echo area.
When `kitty-graphics-skip-clean-refresh' is enabled and no forced refresh
is pending, windows whose signatures are unchanged since the last
refresh schedule nothing at all."
  (when (and (kitty-graphics--any-visible-overlays-p)
             (not (active-minibuffer-window))
             (not (current-message))
             (not (and kitty-graphics-skip-clean-refresh
                       (not kitty-graphics--force-redisplay)
                       (kitty-graphics--windows-clean-p))))
    (kitty-graphics--schedule-refresh)))

;;;; Image processing

(defun kitty-graphics--base64-cache-store (file mtime b64)
  "Cache B64 for FILE at MTIME, evicting LRU entries over the byte cap.
Payloads larger than `kitty-graphics-base64-cache-bytes' are not cached."
  (when (<= (length b64) kitty-graphics-base64-cache-bytes)
    (let ((old (gethash file kitty-graphics--base64-cache)))
      (when old
        (setq kitty-graphics--base64-cache-total
              (- kitty-graphics--base64-cache-total (length (cdr old))))))
    (puthash file (cons mtime b64) kitty-graphics--base64-cache)
    (setq kitty-graphics--base64-cache-lru
          (cons file (delete file kitty-graphics--base64-cache-lru)))
    (setq kitty-graphics--base64-cache-total
          (+ kitty-graphics--base64-cache-total (length b64)))
    (while (and (> kitty-graphics--base64-cache-total kitty-graphics-base64-cache-bytes)
                (cdr kitty-graphics--base64-cache-lru))
      (let* ((victim (car (last kitty-graphics--base64-cache-lru)))
             (entry (gethash victim kitty-graphics--base64-cache)))
        (when entry
          (setq kitty-graphics--base64-cache-total
                (- kitty-graphics--base64-cache-total (length (cdr entry)))))
        (remhash victim kitty-graphics--base64-cache)
        (setq kitty-graphics--base64-cache-lru
              (butlast kitty-graphics--base64-cache-lru))
        (kitty-graphics--log "base64-cache-evict: %s (total=%d cap=%d)"
                        (file-name-nondirectory victim)
                        kitty-graphics--base64-cache-total
                        kitty-graphics-base64-cache-bytes)))))

(defun kitty-graphics--read-file-base64 (file)
  "Read FILE and return base64-encoded string.
Results are cached keyed on FILE and its modification time (bounded by
`kitty-graphics-base64-cache-bytes'), so transmitting the same image to a
second terminal skips the read+encode cost."
  (let* ((mtime (file-attribute-modification-time (file-attributes file)))
         (entry (gethash file kitty-graphics--base64-cache)))
    (if (and entry (equal (car entry) mtime))
        (progn
          (setq kitty-graphics--base64-cache-lru
                (cons file (delete file kitty-graphics--base64-cache-lru)))
          (kitty-graphics--log "read-file-base64: cache hit %s b64-len=%d"
                          file (length (cdr entry)))
          (cdr entry))
      (kitty-graphics--log "read-file-base64: %s size=%s"
                      file (ignore-errors (file-attribute-size (file-attributes file))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (base64-encode-region (point-min) (point-max) t)
        (let ((result (buffer-string)))
          (kitty-graphics--log "read-file-base64: done b64-len=%d" (length result))
          (kitty-graphics--base64-cache-store file mtime result)
          result)))))

(defun kitty-graphics--image-pixel-size (file)
  "Return (WIDTH . HEIGHT) in pixels for image FILE, or nil."
  (let ((identify (or (executable-find "magick")
                      (executable-find "identify"))))
    (when identify
      (when (string-suffix-p "identify" identify)
        (kitty-graphics--log "image-pixel-size: WARNING deprecated `identify' binary resolved: %s (use `magick' instead)" identify))
      (with-temp-buffer
        (let* ((args (if (string-suffix-p "magick" identify)
                         (list "identify" "-format" "%w %h"
                               (concat file "[0]"))  ; first frame only
                       (list "-format" "%w %h" (concat file "[0]"))))
               (status (kitty-graphics--run-process identify args
                                               kitty-graphics-process-timeout
                                               (current-buffer))))
          (kitty-graphics--log "identify: status=%s output=%S" status (buffer-string))
          (when (eql status 0)
            (goto-char (point-min))
            (when (looking-at "\\([0-9]+\\) \\([0-9]+\\)")
              (let ((w (string-to-number (match-string 1)))
                    (h (string-to-number (match-string 2))))
                (kitty-graphics--log "identify: %dx%d pixels" w h)
                (cons w h)))))))))

(defun kitty-graphics--png-cache-get (file)
  "Return the cached PNG path for FILE, or nil if absent or stale."
  (let ((entry (gethash file kitty-graphics--png-cache)))
    (when entry
      (let ((mtime (file-attribute-modification-time (file-attributes file))))
        (if (and (equal (car entry) mtime)
                 (file-exists-p (cdr entry)))
            (cdr entry)
          (remhash file kitty-graphics--png-cache)
          (unless (string= (cdr entry) file)
            (ignore-errors (delete-file (cdr entry))))
          nil)))))

(defun kitty-graphics--png-cache-put (file png)
  "Record PNG as FILE's conversion result at FILE's current mtime."
  (let ((old (gethash file kitty-graphics--png-cache)))
    (when (and old
               (not (string= (cdr old) png))
               (not (string= (cdr old) file)))
      (ignore-errors (delete-file (cdr old)))))
  (puthash file
           (cons (file-attribute-modification-time (file-attributes file)) png)
           kitty-graphics--png-cache)
  png)

(defun kitty-graphics--cleanup-temp-files ()
  "Delete converted temp PNGs and any leftover mpv/casty IPC socket files.
Runs from `kill-emacs-hook' so the `kitty-graphics--png-cache' temp files do
not accumulate in /tmp across sessions.  Cache entries whose PNG path is
the source file itself are skipped — that is user data, not ours."
  (maphash (lambda (file entry)
             (let ((png (cdr entry)))
               (unless (string= png file)
                 (ignore-errors (delete-file png)))))
           kitty-graphics--png-cache)
  (clrhash kitty-graphics--png-cache)
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (dolist (sock (list (buffer-local-value 'kitty-graphics--mpv-ipc-socket buf)
                          (buffer-local-value 'kitty-graphics--browser-ipc-socket buf)))
        (when sock
          (ignore-errors (delete-file sock)))))))

(add-hook 'kill-emacs-hook #'kitty-graphics--cleanup-temp-files)

(defun kitty-graphics--convert-program ()
  "Return the ImageMagick binary to use for PNG conversion, or nil."
  (or (executable-find "magick")
      (executable-find "convert")))

(defun kitty-graphics--magick-input (file)
  "Return the ImageMagick input spec for converting FILE to a still PNG.
Animated containers (GIF, WebP) explode into one PNG per frame when
converted whole, so the target file never appears and the conversion
looks like a failure.  Select the first frame with a [0] read modifier;
the inline preview only ever shows a still anyway."
  (let ((ext (and (file-name-extension file)
                  (downcase (file-name-extension file)))))
    (if (member ext '("gif" "webp"))
        (concat file "[0]")
      file)))

(defun kitty-graphics--warn-no-imagemagick (file)
  "Tell the user once that FILE needs ImageMagick that is not installed.
Both the synchronous and background conversion paths call this so a
missing `magick'/`convert' surfaces an echo-area message instead of
images silently failing to appear."
  (kitty-graphics--message-once
   "imagemagick-missing"
   (format "kitty-graphics: %s needs ImageMagick (magick/convert) to display; it is not on PATH"
           (file-name-nondirectory file))))

(defun kitty-graphics--convert-to-png (file)
  "Convert FILE to PNG if needed.  Returns path to PNG file.
Returns FILE unchanged if it is already PNG.  Successful conversions
are cached in `kitty-graphics--png-cache' keyed on FILE's mtime, so repeat
displays (and the async path's later synchronous prepare) skip the
shell-out.  Returns nil if FILE is not PNG and ImageMagick is
unavailable or conversion fails — callers must handle nil gracefully."
  (if (string-suffix-p ".png" file t)
      (progn
        (kitty-graphics--log "convert-to-png: %s already PNG" file)
        file)
    (or (kitty-graphics--png-cache-get file)
        (let ((convert (kitty-graphics--convert-program)))
          (if (not convert)
              (progn
                (kitty-graphics--log "convert-to-png: no ImageMagick, cannot convert %s" file)
                (kitty-graphics--warn-no-imagemagick file)
                nil)
            (let ((out (make-temp-file "kitty-graphics-" nil ".png")))
              (kitty-graphics--log "convert-to-png: %s -> %s via %s" file out convert)
              (let ((status
                     (kitty-graphics--run-process convert
                                             (list (kitty-graphics--magick-input file) out)
                                             kitty-graphics-process-timeout nil)))
                (kitty-graphics--log "convert-to-png: status=%s" status)
                (if (and (file-exists-p out)
                         (> (file-attribute-size (file-attributes out)) 0))
                    (progn
                      (kitty-graphics--log "convert-to-png: success out-size=%d"
                                      (file-attribute-size (file-attributes out)))
                      (kitty-graphics--png-cache-put file out))
                  (kitty-graphics--log "convert-to-png: FAILED (empty or missing output)")
                  (ignore-errors (delete-file out))
                  nil))))))))

(defun kitty-graphics--convert-to-png-async (file callback)
  "Convert FILE to PNG in a background process, then funcall CALLBACK.
CALLBACK receives the PNG path on success, nil on failure.  Cache hits
and already-PNG files invoke CALLBACK immediately.  Concurrent requests
for the same FILE share one conversion process; their callbacks all run
when it finishes."
  (let ((cached (and (string-suffix-p ".png" file t) file)))
    (unless cached
      (setq cached (kitty-graphics--png-cache-get file)))
    (cond
     (cached (funcall callback cached))
     ((gethash file kitty-graphics--converting)
      (puthash file (cons callback (gethash file kitty-graphics--converting))
               kitty-graphics--converting))
     (t
      (let ((convert (kitty-graphics--convert-program)))
        (if (not convert)
            (progn
              (kitty-graphics--log "convert-to-png-async: no ImageMagick for %s" file)
              (kitty-graphics--warn-no-imagemagick file)
              (funcall callback nil))
          (let ((out (make-temp-file "kitty-graphics-" nil ".png"))
                (proc nil))
            (puthash file (list callback) kitty-graphics--converting)
            (kitty-graphics--log "convert-to-png-async: %s -> %s via %s" file out convert)
            (setq proc
             (make-process
             :name "kitty-graphics-convert"
             :command (list convert (kitty-graphics--magick-input file) out)
             :noquery t
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (let ((callbacks (gethash file kitty-graphics--converting))
                       (ok (and (eq (process-status proc) 'exit)
                                (zerop (process-exit-status proc))
                                (file-exists-p out)
                                (> (file-attribute-size (file-attributes out)) 0))))
                   (remhash file kitty-graphics--converting)
                   (if ok
                       (progn
                         (kitty-graphics--log "convert-to-png-async: success %s out-size=%d"
                                         file
                                         (file-attribute-size (file-attributes out)))
                         (kitty-graphics--png-cache-put file out))
                     (kitty-graphics--log "convert-to-png-async: FAILED %s status=%s exit=%s"
                                     file (process-status proc)
                                     (process-exit-status proc))
                     (ignore-errors (delete-file out)))
                   (dolist (cb (nreverse callbacks))
                     (funcall cb (and ok out))))))))
            (when (and (numberp kitty-graphics-process-timeout)
                       (> kitty-graphics-process-timeout 0)
                       proc)
              (run-at-time
               kitty-graphics-process-timeout nil
               (lambda (p)
                 (when (process-live-p p)
                   (kitty-graphics--log "convert-to-png-async: TIMEOUT killing %s" file)
                   (delete-process p)))
               proc)))))))))

(defvar kitty-graphics--dim-scale nil
  "When a positive float, multiply natural image cell dims by this factor.
Bound dynamically by callers (e.g. the shr integration) to render images
at a fraction of their natural size.  The result is still clamped to the
max cols/rows.  nil means shrink-to-fit the max dimensions (the default).")

(defun kitty-graphics--compute-cell-dims (pixel-w pixel-h max-cols max-rows)
  "Compute (COLS . ROWS) in terminal cells for image placement.
With direct placements, COLS and ROWS map directly to terminal columns/rows."
  (let* ((cw (or kitty-graphics--cell-pixel-width 8))
         (ch (or kitty-graphics--cell-pixel-height 16))
         (img-cols (max 1 (ceiling (/ (float pixel-w) cw))))
         (img-rows (max 1 (ceiling (/ (float pixel-h) ch))))
         (fit (min (if (> img-cols max-cols)
                       (/ (float max-cols) img-cols) 1.0)
                   (if (> img-rows max-rows)
                       (/ (float max-rows) img-rows) 1.0)))
         (scale (if (and (numberp kitty-graphics--dim-scale)
                         (> kitty-graphics--dim-scale 0))
                    kitty-graphics--dim-scale
                  fit))
         (cols (max 1 (min (round (* img-cols scale)) max-cols)))
         (rows (max 1 (min (round (* img-rows scale)) max-rows))))
    (kitty-graphics--log "cell-dims: pixel=%dx%d cw=%d ch=%d img=%dx%d scale=%.2f result=%dx%d"
                     pixel-w pixel-h cw ch img-cols img-rows scale cols rows)
    (cons cols rows)))

;;;; Overlay management

(defun kitty-graphics--alloc-id ()
  "Allocate a new image ID (1-4294967295)."
  (let ((id kitty-graphics--next-id))
    (setq kitty-graphics--next-id (1+ kitty-graphics--next-id))
    (when (> kitty-graphics--next-id 4294967295)
      (kitty-graphics--log "alloc-id: WRAP next-id reset to 1")
      (setq kitty-graphics--next-id 1))
    (kitty-graphics--log "alloc-id: %d" id)
    id))

(defun kitty-graphics--cache-touch (file)
  "Move FILE to the front of the LRU list (most recently used)."
  (setq kitty-graphics--cache-lru
        (cons file (delete file kitty-graphics--cache-lru)))
  (kitty-graphics--log "cache-touch: %s (lru-len=%d)" (file-name-nondirectory file)
                   (length kitty-graphics--cache-lru)))

(defun kitty-graphics--evict-image-everywhere (file id)
  "Free image FILE/ID on every terminal that holds it.
Each Kitty terminal that received ID gets a delete APC and has ID dropped
from its transmitted set; per-file Sixel temp data is removed once.  Run
on cache eviction so a later id reuse cannot collide with stale terminal
data and the per-terminal transmitted sets do not grow without bound."
  (when id
    (dolist (term (terminal-list))
      (when (and (terminal-live-p term)
                 (kitty-graphics--terminal-transmitted-p term id))
        (kitty-graphics--with-terminal term
          (kitty-graphics--delete-by-id id))
        (kitty-graphics--terminal-unmark-transmitted term id)
        (let ((dims-by-id (terminal-parameter term 'kitty-graphics-virtual-dims)))
          (when dims-by-id (remhash id dims-by-id)))))
    (let ((sixel-cleanup (alist-get 'cleanup (alist-get 'sixel kitty-graphics--backends))))
      (when sixel-cleanup (funcall sixel-cleanup file id)))))

(defun kitty-graphics--cleanup-all-terminals ()
  "Delete every transmitted image on every terminal and reset their sets.
Also runs the Sixel backend's global cleanup for per-file temp data.  Used
where a single-terminal `cleanup-all' would leave images stranded on the
other daemon clients."
  (dolist (term (terminal-list))
    (when (and (terminal-live-p term)
               (terminal-parameter term 'kitty-graphics-transmitted))
      (kitty-graphics--with-terminal term
        (kitty-graphics--delete-all-images))
      (set-terminal-parameter term 'kitty-graphics-transmitted nil)
      (set-terminal-parameter term 'kitty-graphics-virtual-dims nil)))
  (let ((sixel-ca (alist-get 'cleanup-all (alist-get 'sixel kitty-graphics--backends))))
    (when sixel-ca (funcall sixel-ca))))

(defun kitty-graphics--cache-put (file image-id)
  "Store IMAGE-ID for FILE in cache, evicting LRU entries if needed."
  (kitty-graphics--log "cache-put: %s id=%d (cache-count=%d max=%d)"
                   (file-name-nondirectory file) image-id
                   (hash-table-count kitty-graphics--image-cache) kitty-graphics-cache-size)
  ;; Evict oldest entries if cache is full
  (while (and (> (hash-table-count kitty-graphics--image-cache)
                 (max 1 kitty-graphics-cache-size))
              kitty-graphics--cache-lru)
    (let* ((victim (car (last kitty-graphics--cache-lru)))
           (victim-id (gethash victim kitty-graphics--image-cache)))
      (when victim-id
        (kitty-graphics--evict-image-everywhere victim victim-id))
      (remhash victim kitty-graphics--image-cache)
      (setq kitty-graphics--cache-lru (butlast kitty-graphics--cache-lru))
      (kitty-graphics--log "cache-evict: %s id=%s (remaining=%d)"
                       (file-name-nondirectory victim) victim-id
                       (hash-table-count kitty-graphics--image-cache))))
  (puthash file image-id kitty-graphics--image-cache)
  (kitty-graphics--cache-touch file))

(defun kitty-graphics--cache-get (file)
  "Return cached image ID for FILE, or nil.  Moves FILE to front of LRU."
  (let ((id (gethash file kitty-graphics--image-cache)))
    (kitty-graphics--log "cache-get: %s -> %s" (file-name-nondirectory file)
                     (if id (format "id=%d (hit)" id) "nil (miss)"))
    (when id
      (kitty-graphics--cache-touch file))
    id))

(defun kitty-graphics--cache-remove (file)
  "Remove FILE from the cache and LRU list."
  (kitty-graphics--log "cache-remove: %s" (file-name-nondirectory file))
  (remhash file kitty-graphics--image-cache)
  (setq kitty-graphics--cache-lru (delete file kitty-graphics--cache-lru)))

(defun kitty-graphics--make-blank-display (cols rows)
  "Create a blank display string of COLS terminal columns x ROWS lines.
Each line is propertized with face `default' to prevent org-link
underline/color from bleeding through the overlay."
  (mapconcat (lambda (_) (propertize (make-string cols ?\s) 'face 'default))
             (number-sequence 1 rows) "\n"))

(defun kitty-graphics--make-overlay (beg end image-id cols rows file &optional reuse-pid)
  "Create overlay from BEG to END for image IMAGE-ID (COLS x ROWS).
FILE is the source file path (needed by some backends for re-encoding).

The overlay's `display' property contains either:
- blank cells (direct placement mode): the terminal paints the image
  on top of them via `a=p,c,r' APC.
- Unicode placeholder cells (placeholder mode): the terminal renders
  the image at exactly the cells whose contents match the placeholder
  + diacritic + image-id-as-fg-color pattern.  No further APC needed.

When REUSE-PID is non-nil, reuse that placement ID instead of
allocating a new one.  This lets the terminal atomically replace
the old placement (same PID, new dimensions/position) without a
delete step, avoiding visual glitches in some terminals."
  (let ((ov (make-overlay beg end nil t nil))
        (pid (or reuse-pid (kitty-graphics--alloc-placement-id))))
    ;; Always reserve screen space with blank cells.  For placeholder
    ;; mode the actual U+10EEEE + diacritic cells get painted on top
    ;; by `kitty-graphics--emit-placeholder-cells' during refresh (Emacs's
    ;; display engine cannot emit those combining marks itself).
    (overlay-put ov 'display
                 (concat (kitty-graphics--make-blank-display cols rows) "\n"))
    (overlay-put ov 'face 'default)  ; override inherited faces (org-link underline etc.)
    (overlay-put ov 'kitty-graphics t)
    (overlay-put ov 'kitty-graphics-id image-id)
    (overlay-put ov 'kitty-graphics-pid pid)
    (overlay-put ov 'kitty-graphics-cols cols)
    (overlay-put ov 'kitty-graphics-rows rows)
    (overlay-put ov 'kitty-graphics-file file)
    ;; Don't set evaporate — zero-width overlays (beg==end) would be
    ;; deleted immediately if evaporate is set.
    (add-hook 'change-major-mode-hook #'kitty-graphics--remove-buffer-graphics nil t)
    (push ov kitty-graphics--overlays)
    (kitty-graphics--log "make-overlay: id=%d pid=%d cols=%d rows=%d beg=%d end=%d buf=%s (total=%d)"
                     image-id pid cols rows beg end (buffer-name) (length kitty-graphics--overlays))
    ov))

(defun kitty-graphics--image-placement (ov win)
  "Return OV's recorded image placement for WIN, or nil."
  (assq win (overlay-get ov 'kitty-graphics-placements)))

(defun kitty-graphics--record-image-placement (ov win row col cols rows pid)
  "Record that OV is placed in WIN at ROW COL with COLS ROWS.
Returns the effective placement id, which the caller must use for the
terminal placement so the recorded and emitted ids never diverge.
Reuses WIN's existing placement id when one is recorded (a move is an
atomic same-id re-place); otherwise uses PID when non-nil, else
allocates a fresh id.  Each (overlay, window) pair thus owns a stable,
unique id — a single overlay shown in N windows needs N distinct
on-screen copies."
  (let* ((existing (cdr (kitty-graphics--image-placement ov win)))
         (pid (or (plist-get existing :pid)
                  pid
                  (kitty-graphics--alloc-placement-id)))
         (placements (assq-delete-all win (copy-sequence
                                           (overlay-get ov 'kitty-graphics-placements)))))
    (overlay-put ov 'kitty-graphics-placements
                 (cons (cons win (list :row row :col col
                                       :cols cols :rows rows
                                       :pid pid))
                       placements))
    pid))

(defun kitty-graphics--forget-image-placement (ov win)
  "Forget OV's recorded image placement for WIN."
  (overlay-put ov 'kitty-graphics-placements
               (assq-delete-all win (copy-sequence
                                     (overlay-get ov 'kitty-graphics-placements)))))

(defun kitty-graphics--delete-image-placement (ov placement)
  "Delete one recorded image PLACEMENT for OV.
The delete escape is routed to the terminal of the window the
placement was recorded for, so killing a buffer shown on another
daemon client erases that client's copy rather than whatever
terminal happens to be selected.  When the window or its terminal
is gone, output falls back to the currently targeted terminal."
  (let* ((win (car placement))
         (data (cdr placement))
         (id (overlay-get ov 'kitty-graphics-id))
         (pid (plist-get data :pid))
         (row (plist-get data :row))
         (col (plist-get data :col))
         (cols (plist-get data :cols))
         (rows (plist-get data :rows))
         (old-row (overlay-get ov 'kitty-graphics-last-row))
         (old-col (overlay-get ov 'kitty-graphics-last-col))
         (old-cols (overlay-get ov 'kitty-graphics-cols))
         (old-rows (overlay-get ov 'kitty-graphics-rows))
         (term (and (window-live-p win)
                    (frame-terminal (window-frame win)))))
    (when (and id pid row col cols rows kitty-graphics--active-backend)
      ;; Sixel deletion is position-based and reads these properties from OV;
      ;; Kitty deletion ignores them and deletes by PID.  Temporarily bind the
      ;; recorded geometry so both backends can share the same helper.
      (unwind-protect
          (progn
            (overlay-put ov 'kitty-graphics-last-row row)
            (overlay-put ov 'kitty-graphics-last-col col)
            (overlay-put ov 'kitty-graphics-cols cols)
            (overlay-put ov 'kitty-graphics-rows rows)
            (if (and term (terminal-live-p term))
                (kitty-graphics--with-terminal term
                  (funcall (kitty-graphics--backend-fn 'delete) ov id pid))
              (funcall (kitty-graphics--backend-fn 'delete) ov id pid)))
        (overlay-put ov 'kitty-graphics-last-row old-row)
        (overlay-put ov 'kitty-graphics-last-col old-col)
        (overlay-put ov 'kitty-graphics-cols old-cols)
        (overlay-put ov 'kitty-graphics-rows old-rows)))))

(defun kitty-graphics--delete-image-placements (ov)
  "Delete all recorded terminal placements for image overlay OV."
  (let ((placements (overlay-get ov 'kitty-graphics-placements)))
    (if placements
        (dolist (placement placements)
          (condition-case err
              (kitty-graphics--delete-image-placement ov placement)
            (error
             (kitty-graphics--log "delete-image-placements: error: %s"
                              (error-message-string err)))))
      ;; Backward-compatible fallback for overlays created before per-window
      ;; placement tracking or for callers that only populated last-row/col.
      (let ((id (overlay-get ov 'kitty-graphics-id))
            (pid (overlay-get ov 'kitty-graphics-pid)))
        (when (and id pid kitty-graphics--active-backend
                   (overlay-get ov 'kitty-graphics-last-row))
          (condition-case err
              (funcall (kitty-graphics--backend-fn 'delete) ov id pid)
            (error
             (kitty-graphics--log "delete-image-placements: fallback error: %s"
                              (error-message-string err))))))))
  (overlay-put ov 'kitty-graphics-placements nil)
  (overlay-put ov 'kitty-graphics-last-row nil)
  (overlay-put ov 'kitty-graphics-last-col nil))

(defun kitty-graphics--delete-placement (id pid)
  "Delete a specific placement PID of image ID from terminal.
Uses d=i (lowercase) to remove the placement but keep stored image
data so the image can be re-placed without retransmitting."
  (kitty-graphics--log "delete-placement: id=%d pid=%d" id pid)
  (kitty-graphics--terminal-send
   (format "\e_Ga=d,d=i,i=%d,p=%d,q=2\e\\" id pid)))

(defun kitty-graphics--remove-overlay (ov &optional keep-placement)
  "Remove overlay OV and delete its placement from terminal.
When KEEP-PLACEMENT is non-nil, skip the terminal-side delete so
the placement ID can be reused by a subsequent overlay (avoids
visual glitches from delete+re-place sequences in some terminals).

KEEP-PLACEMENT is ignored for backends without placement IDs
\(Sixel): they have no atomic-replace semantics, so skipping the
delete would leave the old pixel block on screen as a ghost when
the next placement lands at a different position or size
\(issue #13)."
  (let* ((id (overlay-get ov 'kitty-graphics-id))
         (pid (overlay-get ov 'kitty-graphics-pid))
         (temp-file (overlay-get ov 'kitty-graphics-delete-file))
         (placement-id-backend (memq kitty-graphics--active-backend '(kitty)))
         (must-delete (or (not keep-placement)
                          (not placement-id-backend))))
    (when (and keep-placement placement-id-backend)
      ;; Kitty: drop the per-window placement records so the next
      ;; placement starts fresh with the reused PID.  Sixel needs the
      ;; records intact below so the backend `delete' can erase pixels.
      (overlay-put ov 'kitty-graphics-placements nil))
    (kitty-graphics--log "remove-overlay: id=%s pid=%s keep=%s buf=%s"
                     id pid keep-placement
                     (when (overlay-buffer ov) (buffer-name (overlay-buffer ov))))
    (when (overlay-buffer ov)
      (when must-delete
        (kitty-graphics--delete-image-placements ov))
      (delete-overlay ov))
    (when temp-file
      (ignore-errors (delete-file temp-file)))
    (setq kitty-graphics--overlays (delq ov kitty-graphics--overlays))
    (kitty-graphics--log "remove-overlay: done (remaining=%d)" (length kitty-graphics--overlays))))

;;;; Public API

(defun kitty-graphics--async-prepare-p (file)
  "Return non-nil when FILE's display should use background conversion.
True for non-PNG files with no fresh entry in `kitty-graphics--png-cache'
while `kitty-graphics-async-conversion' is enabled."
  (and kitty-graphics-async-conversion
       (not (string-suffix-p ".png" file t))
       (not (kitty-graphics--png-cache-get file))))

(defun kitty-graphics--start-async-prepare (file)
  "Convert FILE in the background, then force a refresh to place it.
The caller has already created the overlay (blank placeholder) and
registered FILE in the image cache; until the conversion lands,
`kitty-graphics--ensure-transmitted' defers placement.  On success the PNG
is also stored for the Sixel backend and a forced refresh makes the
image appear.  On failure the overlay and cache entry are removed,
matching the synchronous path's no-overlay-on-failure behaviour."
  (kitty-graphics--convert-to-png-async
   file
   (lambda (png)
     (if (not png)
         (progn
           (kitty-graphics--log "async-prepare: conversion failed, dropping %s" file)
           (kitty-graphics--cache-remove file)
           (dolist (buf (buffer-list))
             (with-current-buffer buf
               (dolist (ov (copy-sequence kitty-graphics--overlays))
                 (when (equal (overlay-get ov 'kitty-graphics-file) file)
                   (kitty-graphics--remove-overlay ov)))))
           (kitty-graphics--schedule-refresh t))
       (puthash file png kitty-graphics--sixel-cache)
       (kitty-graphics--schedule-refresh t)))))

;;;###autoload
(defun kitty-graphics-display-image (file &optional beg end max-cols max-rows)
  "Display image FILE in the current buffer.
BEG/END span the overlay region.  MAX-COLS/MAX-ROWS limit size."
  (interactive "fImage file: ")
  (unless kitty-graphics--active-backend
    (user-error "Terminal does not support graphics"))
  (let* ((max-c (or max-cols kitty-graphics-max-width))
         (max-r (or max-rows kitty-graphics-max-height))
         (abs-file (expand-file-name file))
         (cached-id (kitty-graphics--cache-get abs-file))
         (image-id (or cached-id (kitty-graphics--alloc-id)))
         ;; Always compute dimensions fresh — they depend on max-cols/rows
         ;; which vary by display context (org inline vs image-mode vs dired).
         (dims (let ((px (kitty-graphics--image-pixel-size abs-file)))
                 (if px
                     (kitty-graphics--compute-cell-dims
                      (car px) (cdr px) max-c max-r)
                   (cons (min 40 max-c) (min 15 max-r)))))
         (cols (car dims))
         (rows (cdr dims))
         (start (or beg (point)))
         (stop (or end (point))))
    (kitty-graphics--log "display-image: file=%s id=%d cols=%d rows=%d beg=%s end=%s cached=%s"
                    abs-file image-id cols rows start stop (if cached-id "yes" "no"))
    ;; Prepare image if not cached (backend-specific: transmit or validate)
    (unless cached-id
      (if (kitty-graphics--async-prepare-p abs-file)
          (progn
            (kitty-graphics--cache-put abs-file image-id)
            (kitty-graphics--start-async-prepare abs-file))
        (when (funcall (kitty-graphics--backend-fn 'prepare) abs-file image-id)
          (kitty-graphics--cache-put abs-file image-id))))
    ;; Create overlay with blank space (even for cached images, dims are fresh)
    (when (or cached-id (gethash abs-file kitty-graphics--image-cache))
      (let ((ov (kitty-graphics--make-overlay start stop image-id cols rows abs-file)))
        ;; Schedule initial render (force-redisplay: new overlay's display
        ;; property must be processed before `posn-at-point' measurement).
        (kitty-graphics--schedule-refresh t)
        ov))))

(define-obsolete-function-alias 'kitty-gfx-display-image 'kitty-graphics-display-image "1.3.0")

(defun kitty-graphics--display-image-centered (file max-cols max-rows
                                                &optional win-cols win-rows
                                                scale reuse-pid)
  "Display FILE centered in the current buffer.
MAX-COLS and MAX-ROWS are the maximum image dimensions at scale 1.0.
WIN-COLS and WIN-ROWS are the available window dimensions for centering;
they default to MAX-COLS and MAX-ROWS if not provided.
SCALE (default 1.0) multiplies the computed cell dims for zoom.
REUSE-PID, when non-nil, is passed to `kitty-graphics--make-overlay' so the
new placement atomically replaces the old one (same PID, new dims).
The buffer should be writable (caller handles `inhibit-read-only')."
  (let* ((s (or scale 1.0))
         (wc (or win-cols max-cols))
         (wr (or win-rows max-rows))
         (abs-file (expand-file-name file))
         (px (kitty-graphics--image-pixel-size abs-file))
         ;; Compute natural cell dims (capped at max)
         (base-dims (if px
                        (kitty-graphics--compute-cell-dims
                         (car px) (cdr px) max-cols max-rows)
                      (cons (min 40 max-cols) (min 15 max-rows))))
         ;; Apply zoom scale
         (img-cols (max 1 (round (* s (car base-dims)))))
         (img-rows (max 1 (round (* s (cdr base-dims)))))
         (h-pad (max 0 (/ (- wc img-cols) 2)))
         (v-pad (max 0 (/ (- wr img-rows) 2))))
    (kitty-graphics--log "centered: file=%s px=%S base=%S scale=%.2f img=%dx%d win=%dx%d pad=h%d,v%d"
                     (file-name-nondirectory abs-file) px base-dims s
                     img-cols img-rows wc wr h-pad v-pad)
    ;; Vertical centering: newlines before the image
    (dotimes (_ v-pad) (insert "\n"))
    ;; Horizontal centering: spaces to shift the overlay start column
    (insert (make-string h-pad ?\s))
    (let* ((img-start (point))
           (_ (insert "\n"))
           ;; Ensure image is transmitted (cache stores only the ID)
           (cached-id (kitty-graphics--cache-get abs-file))
           (image-id (or cached-id (kitty-graphics--alloc-id))))
      (unless cached-id
        (if (kitty-graphics--async-prepare-p abs-file)
            (progn
              (kitty-graphics--cache-put abs-file image-id)
              (kitty-graphics--start-async-prepare abs-file))
          (when (funcall (kitty-graphics--backend-fn 'prepare) abs-file image-id)
            (kitty-graphics--cache-put abs-file image-id))))
      ;; Create overlay at the scaled dimensions.
      (when (or cached-id (gethash abs-file kitty-graphics--image-cache))
        (kitty-graphics--make-overlay img-start (point) image-id
                                  img-cols img-rows abs-file reuse-pid)
        (kitty-graphics--schedule-refresh t)))))

(defun kitty-graphics-remove-images (&optional beg end)
  "Remove all kitty-graphics overlays in region BEG..END.
Defaults to the whole buffer."
  (interactive)
  (let ((count 0))
    (dolist (ov (overlays-in (or beg (point-min)) (or end (point-max))))
      (when (overlay-get ov 'kitty-graphics)
        (cl-incf count)
        (kitty-graphics--remove-overlay ov)))
    (kitty-graphics--log "remove-images: removed %d overlays from %s" count (buffer-name))))

(define-obsolete-function-alias 'kitty-gfx-remove-images 'kitty-graphics-remove-images "1.3.0")

(defun kitty-graphics--remove-buffer-graphics ()
  "Remove every kitty-graphics rendering from the current buffer.
Reuses the existing removal paths: heading size overlays are erased
\(with their conflicting minor modes restored), then all remaining
kitty-graphics overlays are removed along with their terminal placements.
Runs when `kitty-graphics-mode' is disabled and, via a buffer-local
`change-major-mode-hook', before a major-mode change (revert-buffer,
mode switch) kills the buffer-local overlay list and orphans the
placements."
  (when (or kitty-graphics--heading-sizes-enabled
            (cl-some (lambda (ov) (overlay-get ov 'kitty-graphics-heading))
                     kitty-graphics--overlays))
    (kitty-graphics--org-remove-heading-sizes)
    (kitty-graphics--heading-restore-modes))
  (when kitty-graphics--overlays
    (kitty-graphics-remove-images)))

(defun kitty-graphics-clear-all ()
  "Remove all images from all buffers and the terminal."
  (interactive)
  (kitty-graphics--log "clear-all: begin (cache=%d lru=%d)"
                   (hash-table-count kitty-graphics--image-cache) (length kitty-graphics--cache-lru))
  ;; Walk all buffers, not just current
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when kitty-graphics--overlays
        (kitty-graphics-remove-images))))
  (kitty-graphics--cleanup-all-terminals)
  (clrhash kitty-graphics--image-cache)
  (setq kitty-graphics--cache-lru nil)
  (setq kitty-graphics--next-placement-id 1)
  (kitty-graphics--log "clear-all: done"))

(define-obsolete-function-alias 'kitty-gfx-clear-all 'kitty-graphics-clear-all "1.3.0")

;;;; Debug commands

(defun kitty-graphics-debug-state ()
  "Dump all critical kitty-graphics state to *kitty-graphics-debug-state* buffer."
  (interactive)
  (let ((buf (get-buffer-create "*kitty-graphics-debug-state*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "=== kitty-graphics debug state ===\n")
      (insert (format "Timestamp: %s\n" (format-time-string "%Y-%m-%d %H:%M:%S.%3N")))
      (insert (format "Backend: %s\n" kitty-graphics--active-backend))
      (insert (format "Cell pixel size: %sx%s\n"
                      kitty-graphics--cell-pixel-width kitty-graphics--cell-pixel-height))
      (insert (format "Text sizing: %s\n" kitty-graphics--text-sizing-support))
      (insert (format "ImageMagick: magick=%s convert=%s identify=%s\n"
                      (executable-find "magick")
                      (executable-find "convert")
                      (executable-find "identify")))
      (insert (format "Next ID: %d  Next PID: %d\n"
                      kitty-graphics--next-id kitty-graphics--next-placement-id))
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
          (let ((ovs (buffer-local-value 'kitty-graphics--overlays b)))
            (when ovs
              (dolist (ov ovs)
                (cl-incf count)
                (let ((alive (not (null (overlay-buffer ov))))
                      (heading-p (overlay-get ov 'kitty-graphics-heading)))
                  (insert (format "  [%d] buf=%s alive=%s type=%s cols=%s rows=%s\n"
                                  count (buffer-name b) alive
                                  (if heading-p "heading" "image")
                                  (overlay-get ov 'kitty-graphics-cols)
                                  (overlay-get ov 'kitty-graphics-rows)))
                  (if heading-p
                      (insert (format "       text=%S scale=%.2f level=%s s=%s\n"
                                      (overlay-get ov 'kitty-graphics-heading-text)
                                      (or (overlay-get ov 'kitty-graphics-heading-scale) 0)
                                      (overlay-get ov 'kitty-graphics-heading-level)
                                      (overlay-get ov 'kitty-graphics-heading-cell-s)))
                    (insert (format "       id=%s pid=%s file=%s\n"
                                    (overlay-get ov 'kitty-graphics-id)
                                    (overlay-get ov 'kitty-graphics-pid)
                                    (overlay-get ov 'kitty-graphics-file))))
                  (insert (format "       buf-pos=%s-%s last-row=%s last-col=%s\n"
                                  (and alive (overlay-start ov))
                                  (and alive (overlay-end ov))
                                  (overlay-get ov 'kitty-graphics-last-row)
                                  (overlay-get ov 'kitty-graphics-last-col)))
                  (when alive
                    (let ((screen-pos (kitty-graphics--overlay-screen-pos ov)))
                      (insert (format "       computed-screen-pos=%S\n" screen-pos)))))))))
        (insert (format "\nTotal overlays: %d\n" count)))
      (insert "\n--- Image cache ---\n")
      (insert (format "  entries=%d lru-len=%d\n"
                      (hash-table-count kitty-graphics--image-cache)
                      (length kitty-graphics--cache-lru)))
      (maphash (lambda (k v) (insert (format "  %s -> %s\n" k v)))
               kitty-graphics--image-cache)
      (insert "\n--- Sixel cache ---\n")
      (insert (format "  entries=%d\n" (hash-table-count kitty-graphics--sixel-cache)))
      (maphash (lambda (k v) (insert (format "  %s -> %s\n" k v)))
               kitty-graphics--sixel-cache))
    (display-buffer buf)
    (message "kitty-graphics: debug state dumped to *kitty-graphics-debug-state*")))

(define-obsolete-function-alias 'kitty-gfx-debug-state 'kitty-graphics-debug-state "1.3.0")

(defun kitty-graphics-debug-overlay-at-point ()
  "Show deep debug info for the kitty-graphics overlay at point."
  (interactive)
  (let ((found nil))
    (dolist (ov (overlays-at (point)))
      (when (overlay-get ov 'kitty-graphics-id)
        (setq found ov)))
    (if (not found)
        (message "kitty-graphics: no overlay at point")
      (let* ((id (overlay-get found 'kitty-graphics-id))
             (pid (overlay-get found 'kitty-graphics-pid))
             (cols (overlay-get found 'kitty-graphics-cols))
             (rows (overlay-get found 'kitty-graphics-rows))
             (file (overlay-get found 'kitty-graphics-file))
             (cw (or kitty-graphics--cell-pixel-width 8))
             (ch (or kitty-graphics--cell-pixel-height 16))
             (pixel-w (* (or cols 0) cw))
             (pixel-h (* (or rows 0) ch))
             (last-row (overlay-get found 'kitty-graphics-last-row))
             (last-col (overlay-get found 'kitty-graphics-last-col))
             (pos (overlay-start found))
             (win (selected-window))
             (win-pos (and pos (posn-at-point pos win)))
             (col-row (and win-pos (posn-col-row win-pos)))
             (edges (window-edges win))
             (body-edges (window-body-edges win))
             (buf-col (save-excursion
                        (goto-char pos)
                        (current-column)))
             (screen-pos (kitty-graphics--overlay-screen-pos found))
             (disp-prop (overlay-get found 'display))
             (disp-len (if (stringp disp-prop) (length disp-prop) nil)))
        (message (concat
                  "kitty-graphics overlay: id=%s pid=%s file=%s\n"
                  "  cols=%s rows=%s cell=%dx%d pixel=%dx%d\n"
                  "  posn-col-row=%S win-edges=%S body-edges=%S buf-col=%d\n"
                  "  computed-screen-pos=%S last-row=%s last-col=%s\n"
                  "  display-prop-len=%s")
                 id pid file
                 cols rows cw ch pixel-w pixel-h
                 col-row edges body-edges buf-col
                 screen-pos last-row last-col
                 disp-len)))))

(define-obsolete-function-alias 'kitty-gfx-debug-overlay-at-point 'kitty-graphics-debug-overlay-at-point "1.3.0")

;;;; Minor mode

;;;###autoload
(define-minor-mode kitty-graphics-mode
  "Display images in terminal Emacs via graphics protocol (Kitty or Sixel)."
  :global t
  :lighter (:eval (concat " KittyGfx["
                          (pcase kitty-graphics--active-backend
                            ('kitty "K")
                            ('sixel "S")
                            (_ "?"))
                          (if (eq kitty-graphics--text-sizing-support 'scale)
                              "+T" "")
                          "]"))
  (if kitty-graphics-mode
      (if (kitty-graphics--detect-protocol)
          (progn
            (kitty-graphics--log "mode: enabling (backend=%s)" kitty-graphics--active-backend)
            (when kitty-graphics--active-backend
              (funcall (kitty-graphics--backend-fn 'cleanup-all)))  ; clear stale state
            ;; Defer terminal probing off the synchronous enable path.  These
            ;; queries read the terminal with `read-event', which does not run
            ;; `input-decode-map', so doing it here consumes replies another
            ;; tty-setup consumer is still waiting for (e.g. kkp.el's async
            ;; keyboard-protocol query) and breaks it (issue #33).  An idle
            ;; timer lets the command loop route those replies first; the
            ;; probes are idempotent (guarded per terminal parameter) and also
            ;; run on the first refresh.
            (run-with-idle-timer
             0 nil
             (lambda ()
               (kitty-graphics--query-cell-size)
               (when (eq kitty-graphics--active-backend 'kitty)
                 (kitty-graphics--query-text-sizing-support))
               (kitty-graphics--invalidate-window-signatures)
               (kitty-graphics--schedule-refresh)))
            (kitty-graphics--install-hooks)
            (kitty-graphics--install-integrations)
            (kitty-graphics--invalidate-window-signatures)
            ;; Sixel backend silently drops images when no encoder is on
            ;; PATH.  Warn loudly so users notice before they wonder why
            ;; nothing renders.
            (when (and (eq kitty-graphics--active-backend 'sixel)
                       (not (kitty-graphics--sixel-resolve-encoder)))
              (kitty-graphics--log "mode: WARNING no Sixel encoder on PATH")
              (display-warning
               'kitty-graphics
               "Sixel backend active but no encoder on PATH.
Install `img2sixel' (libsixel; strongly recommended) or
ImageMagick (`magick'/`convert').  Without an encoder, no images
will render even though detection reports Sixel as supported."
               :warning))
            (kitty-graphics--log "mode: enabled (backend=%s cell=%dx%d text-sizing=%s)"
                             kitty-graphics--active-backend
                             kitty-graphics--cell-pixel-width kitty-graphics--cell-pixel-height
                             kitty-graphics--text-sizing-support)
            (message "Kitty graphics mode enabled (%s backend%s)"
                     kitty-graphics--active-backend
                     (if (eq kitty-graphics--text-sizing-support 'scale)
                         ", text sizing" "")))
        (let ((reason (kitty-graphics--unsupported-reason)))
          (kitty-graphics--log "mode: terminal not supported (%s), aborting enable" reason)
          (setq kitty-graphics-mode nil)
          (message "Kitty graphics: terminal not supported - %s" reason)))
    (kitty-graphics--log "mode: disabling")
    (kitty-graphics-stop-video)
    (kitty-graphics--stop-all-browsers)
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (kitty-graphics--remove-buffer-graphics))))
    (kitty-graphics--uninstall-hooks)
    (kitty-graphics--uninstall-integrations)
    (kitty-graphics--cleanup-all-terminals)
    (when kitty-graphics--render-timer
      (cancel-timer kitty-graphics--render-timer))
    (kitty-graphics--transmit-queue-reset)
    (kitty-graphics--invalidate-window-signatures)
    (setq kitty-graphics--render-timer nil
          kitty-graphics--refresh-pending nil
          kitty-graphics--active-backend nil
          kitty-graphics--text-sizing-support nil)
    ;; The mode is global; drop every terminal's per-client state so a
    ;; later re-enable re-detects and re-queries each client cleanly.
    (dolist (term (terminal-list))
      (when (terminal-live-p term)
        (kitty-graphics--clear-terminal-state term)))
    (kitty-graphics--log "mode: disabled")))

(defun kitty-graphics--on-new-frame (&optional frame)
  "Detect graphics support for a newly created client FRAME's terminal.
Runs on `server-after-make-frame-hook' (a normal hook that passes no
argument, so FRAME defaults to the selected frame) and on
`after-make-frame-functions' (which passes the new frame), so each
`emacsclient' terminal gets its own backend detected.  Capability queries
are deferred to the first refresh in which FRAME is the selected frame
\(see `kitty-graphics--refresh'), since they read the selected terminal."
  (let ((frame (or frame (selected-frame))))
    (when (and kitty-graphics-mode
               (frame-live-p frame)
               (not (display-graphic-p frame)))
      (with-selected-frame frame
        (kitty-graphics--detect-protocol)))))

(defun kitty-graphics--on-delete-terminal (term)
  "Free kitty-graphics state bound to TERM as it is being deleted.
Runs on `delete-terminal-functions': stops any video/browser launched on
TERM and drops its per-client parameters (backend, cell size, text-sizing,
transmitted set) plus any transmits still queued for it.  The terminal's
stored images need no explicit deletion - they vanish with the terminal."
  (kitty-graphics--stop-terminal-processes term)
  (kitty-graphics--clear-terminal-state term)
  (setq kitty-graphics--transmit-queue
        (cl-remove-if (lambda (entry) (eq (nth 0 entry) term))
                      kitty-graphics--transmit-queue))
  (when (and (null kitty-graphics--transmit-queue)
             kitty-graphics--transmit-drain-timer)
    (cancel-timer kitty-graphics--transmit-drain-timer)
    (setq kitty-graphics--transmit-drain-timer nil)))

(defun kitty-graphics--install-hooks ()
  "Install redisplay hooks for image refresh."
  (add-hook 'window-scroll-functions #'kitty-graphics--on-window-scroll)
  (add-hook 'window-size-change-functions #'kitty-graphics--on-window-change)
  (add-hook 'window-buffer-change-functions #'kitty-graphics--on-buffer-change)
  (add-hook 'post-command-hook #'kitty-graphics--on-redisplay)
  (add-hook 'kill-buffer-hook #'kitty-graphics--kill-buffer-hook)
  (add-hook 'server-after-make-frame-hook #'kitty-graphics--on-new-frame)
  (add-hook 'after-make-frame-functions #'kitty-graphics--on-new-frame)
  (add-hook 'delete-terminal-functions #'kitty-graphics--on-delete-terminal))

(defun kitty-graphics--uninstall-hooks ()
  "Remove redisplay hooks."
  (remove-hook 'window-scroll-functions #'kitty-graphics--on-window-scroll)
  (remove-hook 'window-size-change-functions #'kitty-graphics--on-window-change)
  (remove-hook 'window-buffer-change-functions #'kitty-graphics--on-buffer-change)
  (remove-hook 'post-command-hook #'kitty-graphics--on-redisplay)
  (remove-hook 'kill-buffer-hook #'kitty-graphics--kill-buffer-hook)
  (remove-hook 'server-after-make-frame-hook #'kitty-graphics--on-new-frame)
  (remove-hook 'after-make-frame-functions #'kitty-graphics--on-new-frame)
  (remove-hook 'delete-terminal-functions #'kitty-graphics--on-delete-terminal))

(defun kitty-graphics--enable-on-tty-frame (&optional frame)
  "Enable `kitty-graphics-mode' once a text-terminal FRAME connects.
Used as a `server-after-make-frame-hook' / `after-make-frame-functions'
entry by `kitty-graphics-setup'.  No-op once the mode is already on or
when FRAME is graphical; after the mode enables itself it installs its
own per-frame detection, so later clients are handled automatically."
  (when (and (not kitty-graphics-mode)
             (not (display-graphic-p frame)))
    (with-selected-frame (or frame (selected-frame))
      (kitty-graphics-mode 1))))

;;;###autoload
(defun kitty-graphics-setup ()
  "Enable `kitty-graphics-mode' for both `emacs -nw' and `emacs --daemon'.

The global mode self-disables if it cannot detect a graphics-capable
terminal when enabled, and a daemon has no terminal attached at startup.
So instead of enabling unconditionally, register a hook that turns the
mode on at the first text-terminal client frame, and additionally enable
it right away when Emacs is already running in a terminal.

Put a single `(kitty-graphics-setup)' in your init; it is safe to call in
a daemon, a GUI Emacs running a server, or a plain `emacs -nw'."
  (interactive)
  (add-hook 'server-after-make-frame-hook #'kitty-graphics--enable-on-tty-frame)
  (add-hook 'after-make-frame-functions #'kitty-graphics--enable-on-tty-frame)
  (unless (or (daemonp) (display-graphic-p))
    (kitty-graphics-mode 1)))

;;;###autoload
(defun kitty-graphics-doctor ()
  "Show a terminal-graphics diagnostic report in a help buffer.
Reports the active backend, detection result and (when nothing is
supported) the likely reason, the queried cell size and text-sizing
level, tmux state, the resolved Sixel encoder, and which external
programs kitty-graphics relies on are installed.  Run this when images do
not appear and you want to see what the package actually detected."
  (interactive)
  (let* ((frame (selected-frame))
         (gui (display-graphic-p frame))
         (backend kitty-graphics--active-backend)
         (in-tmux (kitty-graphics--frame-getenv "TMUX" frame))
         (term (frame-terminal frame))
         (cell-w (or (terminal-parameter term 'kitty-graphics-cell-w)
                     kitty-graphics--cell-pixel-width))
         (cell-h (or (terminal-parameter term 'kitty-graphics-cell-h)
                     kitty-graphics--cell-pixel-height))
         (text-sizing (or (terminal-parameter term 'kitty-graphics-text-sizing)
                          kitty-graphics--text-sizing-support))
         (encoder (kitty-graphics--sixel-resolve-encoder))
         (programs '(("magick" . "ImageMagick: PNG conversion and sizing")
                     ("convert" . "ImageMagick legacy fallback")
                     ("identify" . "ImageMagick legacy size probe")
                     ("img2sixel" . "libsixel encoder (best Sixel quality)")
                     ("ffmpeg" . "video thumbnails")
                     ("typst" . "typst math preview")
                     ("mpv" . "inline video")
                     ("tmux" . "tmux passthrough")
                     ("casty" . "inline web browser"))))
    (with-help-window "*kitty-graphics-doctor*"
      (with-current-buffer standard-output
        (princ "kitty-graphics doctor\n================\n\n")
        (princ (format "Mode enabled:    %s\n" (if kitty-graphics-mode "yes" "no")))
        (princ (format "Frame type:      %s\n"
                       (if gui "graphical (no terminal graphics)" "text terminal")))
        (princ (format "Active backend:  %s\n" (or backend "none")))
        (princ (format "Preferred:       %s\n" kitty-graphics-preferred-protocol))
        (unless backend
          (princ (format "Why unsupported: %s\n"
                         (kitty-graphics--unsupported-reason frame))))
        (princ (format "Cell size (px):  %dx%d%s\n"
                       (or cell-w 8) (or cell-h 16)
                       (if (and cell-w cell-h) "" "  (default; terminal did not answer CSI 16 t)")))
        (princ (format "Text sizing:     %s\n" (or text-sizing "unknown")))
        (when in-tmux
          (let ((ver (kitty-graphics--tmux-version frame)))
            (princ (format "tmux:            yes (version %s, passthrough %s, sixel-ok %s)\n"
                           (if ver (format "%d.%d" (car ver) (cadr ver)) "unknown")
                           (kitty-graphics--tmux-passthrough-state frame)
                           (cond
                            ((kitty-graphics--outer-terminal-no-sixel-p frame)
                             "no (this terminal has no Sixel)")
                            ((kitty-graphics--tmux-sixel-supported-p frame) "yes")
                            (t "no"))))))
        (princ (format "Process timeout: %ss\n"
                       (or kitty-graphics-process-timeout "disabled")))
        (princ (format "Sixel timeout:   %ss\n"
                       (or kitty-graphics-sixel-encoder-timeout "disabled")))
        (princ (format "Sixel encoder:   %s\n"
                       (if encoder (format "%s (%s)" (cdr encoder) (car encoder))
                         "none found")))
        (princ "\nExternal programs\n-----------------\n")
        (dolist (p programs)
          (let ((path (executable-find (car p))))
            (princ (format "  %-10s %s  %s\n"
                           (car p)
                           (if path "found  " "MISSING")
                           (or path (cdr p))))))
        (princ (format "\nDebug log: %s (logging %s; toggle with `kitty-graphics-debug')\n"
                       kitty-graphics--log-file
                       (if kitty-graphics-debug "ON" "off")))))))

(define-obsolete-function-alias 'kitty-gfx-doctor 'kitty-graphics-doctor "1.3.0")

;;;; Org-mode integration

(defun kitty-graphics--org-mode-heading-hook ()
  "Org-mode hook to auto-apply heading sizes.
Only activates when `kitty-graphics-heading-sizes-auto' is set and
the terminal supports text sizing.  Enters preview mode by
disabling conflicting minor modes."
  (when (and kitty-graphics-mode
             (eq kitty-graphics--text-sizing-support 'scale)
             (not (display-graphic-p)))
    ;; Use run-at-time 0 so conflicting modes have finished
    ;; their own org-mode-hook setup before we disable them.
    (let ((buf (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (setq kitty-graphics--heading-sizes-enabled t)
                         (kitty-graphics--heading-disable-conflicting)
                         (kitty-graphics--heading-apply-initial))))))))

(defun kitty-graphics--on-org-cycle (&rest _args)
  "Handle org visibility cycling.
Deletes image placements and clears their position caches, erases
every emitted heading's multicell block at its cached coordinates and
resets it to plain text, then schedules a forced refresh that
re-places only the overlays still visible (not inside a fold).  The
heading erase must happen here, at hook time: the screen still shows
the pre-fold layout, so the cached positions are valid — once the
post-fold redraw lands they would point at live content."
  (kitty-graphics--log "on-org-cycle: overlays=%d" (length kitty-graphics--overlays))
  (when (and kitty-graphics-mode kitty-graphics--overlays)
    (kitty-graphics--invalidate-window-signatures)
    (kitty-graphics--sync-begin)
    (unwind-protect
        (dolist (ov kitty-graphics--overlays)
          (when (overlay-buffer ov)
            (if (overlay-get ov 'kitty-graphics-heading)
                (when (and (overlay-get ov 'kitty-graphics-heading-emitted)
                           (overlay-get ov 'kitty-graphics-last-row)
                           (overlay-get ov 'kitty-graphics-last-col))
                  (kitty-graphics--erase-heading-at
                   (overlay-get ov 'kitty-graphics-last-row)
                   (overlay-get ov 'kitty-graphics-last-col)
                   (or (overlay-get ov 'kitty-graphics-cols) 0)
                   (or (overlay-get ov 'kitty-graphics-rows) 1))
                  (kitty-graphics--heading-reset ov))
              (let ((id (overlay-get ov 'kitty-graphics-id))
                    (pid (overlay-get ov 'kitty-graphics-pid)))
                (when (and id pid kitty-graphics--active-backend)
                  (funcall (kitty-graphics--backend-fn 'delete) ov id pid)))
              (overlay-put ov 'kitty-graphics-last-row nil)
              (overlay-put ov 'kitty-graphics-last-col nil))))
      (kitty-graphics--sync-end))
    ;; Force-redisplay: folds change visibility, posn-at-point must re-measure.
    (kitty-graphics--schedule-refresh t)))

(defun kitty-graphics--image-file-p (file)
  "Return non-nil if FILE has an image extension.
GIF files are detected so they get routed through the image pipeline,
but only the first frame is rendered (no animation in terminal)."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext)
                     '("png" "jpg" "jpeg" "bmp" "svg"
                       "webp" "tiff" "tif" "gif")))))

(defun kitty-graphics--video-extension-p (file)
  "Return non-nil if FILE has a registered video extension.
Checks only the extension; see `kitty-graphics--mpv-available-p' for
whether playback is actually wired up."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext) kitty-graphics-video-file-extensions))))

(defun kitty-graphics--mpv-playable-extension-p (file)
  "Return non-nil if opening FILE should hand it to mpv for playback.
True for video extensions, and for GIF when `kitty-graphics-play-gifs-with-mpv'
is enabled so an opened GIF animates instead of showing a still.  Used
by the open/play routes only; the preview dispatch keeps GIF on the
still-thumbnail image path."
  (let ((ext (and (file-name-extension file)
                  (downcase (file-name-extension file)))))
    (or (and ext (member ext kitty-graphics-video-file-extensions))
        (and kitty-graphics-play-gifs-with-mpv (equal ext "gif")))))

(defun kitty-graphics--video-file-p (file)
  "Return non-nil if FILE is a video that the mpv preview can handle.
Requires `kitty-graphics-enable-video' to be enabled, mpv on PATH, and
a backend with a usable mpv video output -- the same gates as
`kitty-graphics--mpv-available-p'."
  (and (kitty-graphics--mpv-available-p)
       (kitty-graphics--video-extension-p file)))

(defvar kitty-graphics--video-thumbnail-cache-dir
  (expand-file-name "kitty-graphics-thumbs/" temporary-file-directory)
  "Directory holding cached video thumbnail PNGs.")

(defvar kitty-graphics--ffmpeg-warned nil
  "Non-nil once we have echoed a missing-ffmpeg warning in this session.
Prevents flooding the echo area when dirvish previews many videos
in a row without ffmpeg installed.")

(defun kitty-graphics--video-thumbnail (file)
  "Return a PNG thumbnail path for video FILE.
Extracts the frame at `kitty-graphics-video-thumbnail-seek' via ffmpeg
and caches it under `kitty-graphics--video-thumbnail-cache-dir', keyed
by file path + mtime so an edited video gets a fresh thumbnail.
Returns nil if ffmpeg is missing or extraction fails.  Echoes a
one-shot warning on the first call when ffmpeg is missing so the
user knows why their videos have no thumbnails."
  (let ((ffmpeg (executable-find "ffmpeg")))
    (cond
     ((not ffmpeg)
      (unless kitty-graphics--ffmpeg-warned
        (setq kitty-graphics--ffmpeg-warned t)
        (message "kitty-graphics: ffmpeg not on PATH; video thumbnails disabled"))
      nil)
     (t
      (unless (file-directory-p kitty-graphics--video-thumbnail-cache-dir)
        (make-directory kitty-graphics--video-thumbnail-cache-dir t))
      (let* ((file (expand-file-name file))
             (attrs (file-attributes file))
             (mtime (format-time-string "%s" (nth 5 attrs)))
             (key (sha1 (format "%s\0%s" file mtime)))
             (out (expand-file-name (concat key ".png")
                                    kitty-graphics--video-thumbnail-cache-dir)))
        (if (file-exists-p out)
            out
          (let ((status (kitty-graphics--run-process
                         ffmpeg
                         (list "-y" "-loglevel" "error"
                               "-ss" kitty-graphics-video-thumbnail-seek
                               "-i" file
                               "-frames:v" "1"
                               "-vf" "scale=640:-1"
                               out)
                         kitty-graphics-process-timeout nil)))
            (kitty-graphics--log "video-thumbnail: status=%s file=%s out=%s"
                            status file out)
            (when (and (eql status 0) (file-exists-p out)) out))))))))

(defun kitty-graphics--org-display-image (file start end)
  "Display org inline image FILE honoring `kitty-graphics-org-image-scale'.
Mirrors `kitty-graphics--shr-display-image': `fit' scales into a
window-relative box, a number scales by that factor, nil uses the full
`kitty-graphics-max-width'/`kitty-graphics-max-height' caps."
  (pcase kitty-graphics-org-image-scale
    ('fit
     (let ((box (kitty-graphics--fit-box (get-buffer-window (current-buffer))
                                    kitty-graphics-org-image-fit-width
                                    kitty-graphics-org-image-fit-height)))
       (kitty-graphics-display-image file start end (car box) (cdr box))))
    ((and (pred numberp) factor)
     (let ((kitty-graphics--dim-scale factor))
       (kitty-graphics-display-image file start end)))
    (_ (kitty-graphics-display-image file start end
                                kitty-graphics-max-width kitty-graphics-max-height))))

(defun kitty-graphics--org-display-inline-images-tty (&optional _include-linked beg end)
  "Display inline images in org buffer via Kitty graphics.
Scans for file:, attachment:, and relative path links.

Relative links are resolved against the buffer file's directory (as
org itself does for inline images), not `default-directory', which
packages like Projectile or dired re-bind to the project root and
would otherwise make every relative image path fail to resolve."
  (when (derived-mode-p 'org-mode)
    (let ((start (or beg (point-min)))
          (stop (or end (point-max)))
          (default-directory (if buffer-file-name
                                 (file-name-directory buffer-file-name)
                               default-directory)))
      (kitty-graphics--log "org-display: scanning region %d..%d in %s (dir %s)"
                      start stop (buffer-name) default-directory)
      (save-restriction
        (widen)
        (save-excursion
          (goto-char start)
          ;; Match file:, attachment:, relative (./) and absolute (/) paths.
          ;; Parse each candidate with `org-element-link-parser' at the
          ;; link start rather than `org-element-context': the latter
          ;; consults the org-element cache and, in long-running sessions
          ;; with caching on, returns the containing paragraph/headline
          ;; instead of the link object, so every image gets skipped.  The
          ;; parser reads the link directly at point, independent of cache.
          (while (re-search-forward
                  "\\[\\[\\(file:\\|attachment:\\|[./~]\\)" stop t)
            (goto-char (match-beginning 0))
            ;; Skip links on commented-out lines (`# [[...]]').  Native
            ;; `org-display-inline-images' works off the parse tree, where a
            ;; comment line holds no link element, so it never renders these.
            ;; This TTY scanner walks raw text, so it has to recognize the
            ;; comment itself; otherwise commented images still display.  A
            ;; link the user just commented out keeps a live preview overlay,
            ;; so remove it here: an orphaned image overlay on the commented
            ;; line otherwise lingers and the refresh cycle keeps re-placing
            ;; it, perturbing the layout into a scroll/refresh feedback loop.
            (if (save-excursion
                  (beginning-of-line)
                  (looking-at-p org-comment-regexp))
                (progn
                  (kitty-graphics-remove-images (line-beginning-position)
                                           (line-end-position))
                  (forward-line 1))
              (let ((link (org-element-link-parser)))
                (if (not link)
                    (goto-char (match-end 0))
                  (let* ((link-beg (org-element-property :begin link))
                         (link-end (org-element-property :end link))
                         (path (org-element-property :path link))
                         (link-type (org-element-property :type link))
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
                               (kitty-graphics--image-file-p file)
                               (not (cl-some (lambda (ov)
                                               (overlay-get ov 'kitty-graphics))
                                             (overlays-in link-beg link-end))))
                      (kitty-graphics--log "org-display: found link %s at %d..%d"
                                      file link-beg link-end)
                      (condition-case err
                          (kitty-graphics--org-display-image
                           (expand-file-name file) link-beg link-end)
                        (error
                         (kitty-graphics--log "org-display: ERROR %s: %s"
                                         file (error-message-string err))
                         (message "kitty-graphics: %s: %s"
                                  file (error-message-string err)))))
                    ;; Continue past this link so the next search does not
                    ;; re-match inside it.
                    (goto-char (max (or link-end (match-end 0))
                                    (1+ (point))))))))))))))


(defun kitty-graphics--org-display-advice (orig-fn &rest args)
  "Around advice for `org-display-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (kitty-graphics--log "advice: org-display-inline-images (terminal path)")
        (apply #'kitty-graphics--org-display-inline-images-tty args))
    (apply orig-fn args)))

(defun kitty-graphics--org-remove-advice (orig-fn &rest args)
  "Around advice for `org-remove-inline-images'."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    (kitty-graphics--log "advice: org-remove-inline-images")
    (kitty-graphics-remove-images))
  (apply orig-fn args))

(defun kitty-graphics--org-toggle-advice (orig-fn &rest args)
  "Around advice for `org-toggle-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (let ((has-images (cl-some (lambda (ov) (overlay-get ov 'kitty-graphics))
                                 (overlays-in (point-min) (point-max)))))
        (kitty-graphics--log "advice: org-toggle has-images=%s" has-images)
        (if has-images
            (kitty-graphics-remove-images)
          (kitty-graphics--org-display-inline-images-tty)))
    (apply orig-fn args)))

;; org 10.0+ uses org-link-preview instead of org-toggle-inline-images

(defun kitty-graphics--org-link-preview-advice (orig-fn &optional arg beg end)
  "Around advice for `org-link-preview' (org 9.7+).
Mirrors org's own toggle semantics: with no prefix ARG, hide the
previews when any are already shown in the region (or buffer) and
otherwise display them.  \\[universal-argument] clears the region;
\\[universal-argument] \\[universal-argument] \\[universal-argument] clears the whole buffer."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (cond
       ;; C-u = clear
       ((equal arg '(4))
        (kitty-graphics-remove-images beg end))
       ;; C-u C-u C-u = clear whole buffer
       ((equal arg '(64))
        (kitty-graphics-remove-images))
       ;; No prefix: toggle — remove if anything is shown, else display.
       (t
        (if (cl-some (lambda (ov) (overlay-get ov 'kitty-graphics))
                     (overlays-in (or beg (point-min)) (or end (point-max))))
            (kitty-graphics-remove-images beg end)
          (kitty-graphics--org-display-inline-images-tty nil beg end))))
    (funcall orig-fn arg beg end)))

(defun kitty-graphics--org-link-preview-region-advice (orig-fn &optional include-linked refresh beg end)
  "Around advice for `org-link-preview-region' (org 10.0+)."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (kitty-graphics--org-display-inline-images-tty include-linked beg end)
    (funcall orig-fn include-linked refresh beg end)))

;;;; markdown-mode integration

(defun kitty-graphics--markdown-resolve-url (url)
  "Resolve markdown image URL to an absolute file path, or nil.
Skips remote http/https URLs, ftp links, and mailto links.  Relative
paths are expanded against `default-directory' (the caller binds this
to the buffer file's directory when appropriate)."
  (when (and url (not (string-match-p "\\`\\(https?://\\|ftp://\\|mailto:\\)" url)))
    (cond
     ((string-prefix-p "file:" url) (substring url 5))
     ((file-name-absolute-p url) url)
     (t (expand-file-name url default-directory)))))

(defun kitty-graphics--markdown-display-image (file start end)
  "Display markdown inline image FILE.
Honors `kitty-graphics-markdown-image-scale'.
Mirrors `kitty-graphics--org-display-image': `fit' scales into a
window-relative box, a number scales by that factor, nil uses the full
`kitty-graphics-max-width'/`kitty-graphics-max-height' caps."
  (pcase kitty-graphics-markdown-image-scale
    ('fit
     (let ((box (kitty-graphics--fit-box (get-buffer-window (current-buffer))
                                    kitty-graphics-markdown-image-fit-width
                                    kitty-graphics-markdown-image-fit-height)))
       (kitty-graphics-display-image file start end (car box) (cdr box))))
    ((and (pred numberp) factor)
     (let ((kitty-graphics--dim-scale factor))
       (kitty-graphics-display-image file start end)))
    (_ (kitty-graphics-display-image file start end
                                kitty-graphics-max-width kitty-graphics-max-height))))

(defun kitty-graphics--markdown-in-comment-p (pos)
  "Non-nil if POS is inside an HTML comment `<!-- ... -->'."
  (save-excursion
    (goto-char pos)
    (let ((comment-open (re-search-backward "<!--" nil t))
          (comment-close (re-search-forward "-->" nil t)))
      (and comment-open comment-close
           (< comment-open pos)
           (> comment-close pos)))))

(defun kitty-graphics--markdown-display-inline-images-tty (&optional begin end)
  "Display inline markdown images via Kitty graphics in terminal.
Scans BEGIN..END (defaults to whole buffer) for `![alt](url)' links and
displays local image files.  Relative URLs are resolved against the
buffer file's directory.  Remote URLs are skipped; use a browser or a
dedicated download step if you need them rendered.  Links inside HTML
comments (`<!-- ... -->') are ignored and any stale overlay on the
commented line is removed, matching the org-mode comment behaviour."
  (when (derived-mode-p 'markdown-mode)
    (let ((start (or begin (point-min)))
          (stop (or end (point-max)))
          (default-directory (if buffer-file-name
                                 (file-name-directory buffer-file-name)
                               default-directory)))
      (kitty-graphics--log "markdown-display: scanning region %d..%d in %s (dir %s)"
                      start stop (buffer-name) default-directory)
      (save-excursion
        (goto-char start)
        ;; Match ![alt text](url).  Nested brackets in alt text are not
        ;; supported by this simple scanner, which covers the common case.
        (while (re-search-forward "!\\[\\([^]]*\\)\\](\\([^)]+\\))" stop t)
          (let* ((link-beg (match-beginning 0))
                 (link-end (match-end 0))
                 (url (match-string-no-properties 2))
                 (file (kitty-graphics--markdown-resolve-url url)))
            (if (kitty-graphics--markdown-in-comment-p link-beg)
                (progn
                  (kitty-graphics--log "markdown-display: skipping commented link at %d..%d"
                                  link-beg link-end)
                  (kitty-graphics-remove-images (line-beginning-position)
                                           (line-end-position)))
              (when (and file
                         (file-exists-p file)
                         (kitty-graphics--image-file-p file)
                         (not (cl-some (lambda (ov)
                                         (overlay-get ov 'kitty-graphics))
                                       (overlays-in link-beg link-end))))
                (kitty-graphics--log "markdown-display: found %s at %d..%d"
                                file link-beg link-end)
                (condition-case err
                    (kitty-graphics--markdown-display-image file link-beg link-end)
                  (error
                   (kitty-graphics--log "markdown-display: ERROR %s: %s"
                                   file (error-message-string err))
                   (message "kitty-graphics: %s: %s"
                            file (error-message-string err))))))))))))

(defun kitty-graphics--markdown-display-advice (orig-fn &optional begin end)
  "Around advice for `markdown-display-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (kitty-graphics--log "advice: markdown-display-inline-images (terminal path)")
        (kitty-graphics--markdown-display-inline-images-tty begin end))
    (funcall orig-fn begin end)))

(defun kitty-graphics--markdown-remove-advice (orig-fn &rest args)
  "Around advice for `markdown-remove-inline-images'."
  (when (and kitty-graphics-mode (not (display-graphic-p)))
    (kitty-graphics--log "advice: markdown-remove-inline-images")
    (kitty-graphics-remove-images))
  (apply orig-fn args))

(defun kitty-graphics--markdown-toggle-advice (orig-fn &rest args)
  "Around advice for `markdown-toggle-inline-images'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (let ((has-images (cl-some (lambda (ov) (overlay-get ov 'kitty-graphics))
                                 (overlays-in (point-min) (point-max)))))
        (kitty-graphics--log "advice: markdown-toggle has-images=%s" has-images)
        (if has-images
            (kitty-graphics-remove-images)
          (kitty-graphics--markdown-display-inline-images-tty)))
    (apply orig-fn args)))

;;;; LaTeX fragment preview integration

(defun kitty-graphics--org-latex-preview-advice (orig-fn &optional arg beg end)
  "Around advice for `org-latex-preview'.
Bypasses org's `display-graphic-p' guard so LaTeX fragments are
rendered to images via dvipng/dvisvgm and displayed via
kitty-graphics (works with both Kitty and Sixel backends).
The image generation pipeline does not require a GUI."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (cond
       ;; C-u = clear previews in region/subtree
       ((equal arg '(4))
        (kitty-graphics--org-clear-latex-preview beg end))
       ;; C-u C-u = clear all previews in buffer
       ((equal arg '(16))
        (kitty-graphics--org-clear-latex-preview))
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

(defun kitty-graphics--org-make-preview-overlay-advice (orig-fn beg end movefile imagetype)
  "Around advice for `org--make-preview-overlay'.
Intercepts LaTeX preview overlay creation to display the generated
image via Kitty graphics instead of an Emacs image spec."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when (and movefile (file-exists-p movefile))
        ;; Don't create duplicate overlays at the same position
        (unless (cl-some (lambda (ov) (overlay-get ov 'kitty-graphics))
                         (overlays-in beg end))
          ;; Size like org inline images so a wide display equation fits
          ;; the window; `fit' never enlarges, so normal text-sized
          ;; fragments are unchanged (`kitty-graphics-org-image-scale').
          (kitty-graphics--org-display-image movefile beg end)
          ;; Tag the most recently created overlay with org properties
          ;; so org-clear-latex-preview can find and clean it up.
          (when-let* ((ov (car kitty-graphics--overlays)))
            (overlay-put ov 'org-overlay-type 'org-latex-overlay)
            (overlay-put ov 'modification-hooks
                         (list (lambda (o after &rest _)
                                 (when after
                                   (kitty-graphics--remove-overlay o)))))
            ov)))
    (funcall orig-fn beg end movefile imagetype)))

(defun kitty-graphics--org-clear-latex-preview (&optional beg end)
  "Remove Kitty graphics LaTeX preview overlays in region BEG..END."
  (let ((start (or beg (point-min)))
        (stop (or end (point-max))))
    (dolist (ov (overlays-in start stop))
      (when (and (overlay-get ov 'kitty-graphics)
                 (eq (overlay-get ov 'org-overlay-type) 'org-latex-overlay))
        (kitty-graphics--remove-overlay ov)))))

;;;; Typst inline equation preview

(define-obsolete-variable-alias 'kitty-gfx-typst-command 'kitty-graphics-typst-command "1.3.0")

(defcustom kitty-graphics-typst-command "typst"
  "Path to the typst executable used for inline math previews."
  :type 'string
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-typst-ppi 'kitty-graphics-typst-ppi "1.3.0")

(defcustom kitty-graphics-typst-ppi 300
  "Pixels-per-inch passed to `typst compile' for math previews.
Higher values give crisper images at the cost of compile time."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-typst-text-size 'kitty-graphics-typst-text-size "1.3.0")

(defcustom kitty-graphics-typst-text-size 11
  "Text size in points used when rendering typst math fragments."
  :type 'integer
  :group 'kitty-graphics)

(define-obsolete-variable-alias 'kitty-gfx-typst-preamble 'kitty-graphics-typst-preamble "1.3.0")

(defcustom kitty-graphics-typst-preamble nil
  "Extra typst code prepended to each math fragment before compilation.
When nil, a default preamble is used that auto-sizes the page,
disables the page fill, and applies `kitty-graphics-typst-text-size' with
the current Emacs foreground color."
  :type '(choice (const :tag "Default" nil) string)
  :group 'kitty-graphics)

(defvar kitty-graphics--typst-cache-dir nil
  "Directory holding cached typst-rendered PNGs.")

(defun kitty-graphics--typst-cache-dir ()
  "Return the cache directory for typst PNGs, creating it if needed."
  (unless (and kitty-graphics--typst-cache-dir
               (file-directory-p kitty-graphics--typst-cache-dir))
    (setq kitty-graphics--typst-cache-dir
          (expand-file-name "kitty-graphics-typst" temporary-file-directory))
    (make-directory kitty-graphics--typst-cache-dir t))
  kitty-graphics--typst-cache-dir)

(defun kitty-graphics--typst-color-hex (color)
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

(defun kitty-graphics--typst-default-preamble ()
  "Build the default typst preamble using current Emacs foreground color."
  (let* ((raw (face-attribute 'default :foreground nil))
         (fg (kitty-graphics--typst-color-hex
              (and (stringp raw)
                   (not (string-prefix-p "unspecified" raw))
                   raw))))
    (format "#set page(width: auto, height: auto, margin: 2pt, fill: none)
#set text(size: %dpt, fill: rgb(\"%s\"))
"
            kitty-graphics-typst-text-size fg)))

(defconst kitty-graphics--typst-math-regexp
  "\\$\\(?:[^$\n\\\\]\\|\\\\.\\)+\\$"
  "Regexp matching a single `$...$' typst math fragment on one line.
Backslash-escaped characters within the fragment are allowed; newlines
end the match.")

(defun kitty-graphics--typst-render (fragment)
  "Compile FRAGMENT (typst source including the surrounding `$') to PNG.
Return the absolute path to the generated PNG, or nil on failure.
Results are cached under `kitty-graphics--typst-cache-dir', keyed by SHA-1
of the full preamble + fragment + ppi."
  (unless (executable-find kitty-graphics-typst-command)
    (user-error "typst executable not found: %s" kitty-graphics-typst-command))
  (let* ((preamble (or kitty-graphics-typst-preamble
                       (kitty-graphics--typst-default-preamble)))
         (body (concat preamble fragment "\n"))
         (key (sha1 (format "%s|%d" body kitty-graphics-typst-ppi)))
         (dir (kitty-graphics--typst-cache-dir))
         (typ (expand-file-name (concat key ".typ") dir))
         (png (expand-file-name (concat key ".png") dir)))
    (unless (file-exists-p png)
      (with-temp-file typ (insert body))
      (let* ((log-buf (get-buffer-create "*kitty-graphics-typst*"))
             (status (kitty-graphics--run-process
                      kitty-graphics-typst-command
                      (list "compile" "--format" "png"
                            "--ppi" (number-to-string kitty-graphics-typst-ppi)
                            typ png)
                      kitty-graphics-process-timeout log-buf)))
        (unless (eql status 0)
          (kitty-graphics--log "typst-render: compile failed (status=%s) for %s"
                          status typ)
          (setq png nil))))
    (and png (file-exists-p png) png)))

;;;###autoload
(defun kitty-graphics-typst-preview (&optional beg end)
  "Render typst `$...$' math fragments as inline PNG images.
With an active region, restrict to it; otherwise scan the whole buffer.
Existing typst preview overlays in the range are replaced.
Requires `kitty-graphics-mode' and a working `typst' executable."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (unless kitty-graphics-mode
    (user-error "kitty-graphics-mode is not active"))
  (unless kitty-graphics--active-backend
    (user-error "Terminal does not support graphics"))
  (let ((start (or beg (point-min)))
        (stop (or end (point-max)))
        (count 0))
    (kitty-graphics-typst-clear-preview start stop)
    (save-excursion
      (goto-char start)
      (while (re-search-forward kitty-graphics--typst-math-regexp stop t)
        (let* ((m-beg (match-beginning 0))
               (m-end (match-end 0))
               (frag (match-string-no-properties 0))
               (png (kitty-graphics--typst-render frag)))
          (when png
            (kitty-graphics-display-image png m-beg m-end)
            (when-let* ((ov (car kitty-graphics--overlays)))
              (overlay-put ov 'kitty-graphics-typst t)
              (overlay-put ov 'modification-hooks
                           (list (lambda (o after &rest _)
                                   (when after
                                     (kitty-graphics--remove-overlay o))))))
            (cl-incf count)))))
    (when (called-interactively-p 'any)
      (message "kitty-graphics: rendered %d typst fragment%s"
               count (if (= count 1) "" "s")))
    count))

(define-obsolete-function-alias 'kitty-gfx-typst-preview 'kitty-graphics-typst-preview "1.3.0")

;;;###autoload
(defun kitty-graphics-typst-clear-preview (&optional beg end)
  "Remove kitty-graphics typst preview overlays between BEG and END.
With an active region, restrict to it; otherwise clear the whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let ((start (or beg (point-min)))
        (stop (or end (point-max))))
    (dolist (ov (overlays-in start stop))
      (when (overlay-get ov 'kitty-graphics-typst)
        (kitty-graphics--remove-overlay ov)))))

(define-obsolete-function-alias 'kitty-gfx-typst-clear-preview 'kitty-graphics-typst-clear-preview "1.3.0")

;;;; image-mode integration

(defvar-local kitty-graphics--image-scale 1.0
  "Zoom scale factor for image-mode display.
Values > 1.0 zoom in, < 1.0 zoom out.")

(defun kitty-graphics--image-mode-render (&optional reuse-placement)
  "Render the current image file centered at current scale.
When REUSE-PLACEMENT is non-nil, reuse the old terminal placement
ID instead of deleting it first.  This is useful for zoom commands
where the new placement immediately replaces the old one, but it is
intentionally not used for window size changes because stale pixels
can otherwise remain over newly-created window separators."
  (when-let* ((file (buffer-file-name)))
    (when (kitty-graphics--image-file-p file)
      (let* ((inhibit-read-only t)
             (win-w (- (window-body-width) 2))
             (win-h (- (window-body-height) 2))
             (max-cols (min win-w kitty-graphics-max-width))
             (max-rows (min win-h kitty-graphics-max-height))
             ;; Save the old placement ID only when the caller explicitly
             ;; wants to reuse it.  Reusing avoids delete+re-place glitches
             ;; for zoom commands (WezTerm #5892), but window splits/resizes
             ;; must delete first so stale terminal pixels are cleared.
             (old-pid (when (and reuse-placement (car kitty-graphics--overlays))
                        (overlay-get (car kitty-graphics--overlays) 'kitty-graphics-pid))))
        (kitty-graphics--log "image-mode-render: file=%s scale=%.2f win=%dx%d max=%dx%d reuse-pid=%s"
                         (file-name-nondirectory file) kitty-graphics--image-scale
                         win-w win-h max-cols max-rows old-pid)
        ;; Snapshot the old overlay's per-window placement records so we
        ;; can transplant them onto the new overlay.  Without this, the
        ;; new overlay starts with no recorded placement, the refresh
        ;; allocates a fresh per-window PID, and Kitty draws the
        ;; resized image at a NEW placement while the old placement
        ;; (which we deliberately did not delete to allow atomic
        ;; replacement) remains on screen as a ghost (issue #13).
        (let ((old-placements
               (when reuse-placement
                 (let ((ov (car kitty-graphics--overlays)))
                   (and ov (copy-sequence
                            (overlay-get ov 'kitty-graphics-placements)))))))
          ;; Remove overlays.  When OLD-PID is non-nil, skip terminal-side
          ;; delete so the new placement atomically replaces it; otherwise
          ;; delete/erase the old placement before changing the buffer text.
          (dolist (ov (overlays-in (point-min) (point-max)))
            (when (overlay-get ov 'kitty-graphics)
              (kitty-graphics--remove-overlay ov old-pid)))
          (erase-buffer)
          (kitty-graphics--display-image-centered
           file max-cols max-rows win-w win-h
           kitty-graphics--image-scale old-pid)
          ;; Transplant old placements onto the freshly-made overlay so the
          ;; next refresh re-uses the recorded per-window PIDs.  Recorded
          ;; row/col/cols/rows are intentionally OLD — refresh-overlay sees
          ;; them as the "moved" baseline and re-places at the same PID
          ;; (Kitty atomic-replace) at the new position.
          (when old-placements
            (when-let* ((new-ov (car kitty-graphics--overlays)))
              (overlay-put new-ov 'kitty-graphics-placements old-placements))))
        (goto-char (point-min))
        (set-buffer-modified-p nil)))))

(defun kitty-graphics-image-increase-size ()
  "Zoom in on the image in image-mode."
  (interactive)
  (setq kitty-graphics--image-scale (* kitty-graphics--image-scale 1.25))
  (kitty-graphics--image-mode-render t))

(define-obsolete-function-alias 'kitty-gfx-image-increase-size 'kitty-graphics-image-increase-size "1.3.0")

(defun kitty-graphics-image-decrease-size ()
  "Zoom out on the image in image-mode."
  (interactive)
  (setq kitty-graphics--image-scale (max 0.1 (* kitty-graphics--image-scale 0.8)))
  (kitty-graphics--image-mode-render t))

(define-obsolete-function-alias 'kitty-gfx-image-decrease-size 'kitty-graphics-image-decrease-size "1.3.0")

(defun kitty-graphics-image-reset-size ()
  "Reset image zoom to default in image-mode."
  (interactive)
  (setq kitty-graphics--image-scale 1.0)
  (kitty-graphics--image-mode-render t))

(define-obsolete-function-alias 'kitty-gfx-image-reset-size 'kitty-graphics-image-reset-size "1.3.0")

(defun kitty-graphics--image-mode-advice (orig-fn &rest args)
  "Around advice for `image-mode'."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (progn
        (major-mode-suspend)
        ;; Use our own major-mode symbol so evil-collection's
        ;; image-mode bindings (which call native image functions
        ;; that fail in terminal) don't override our keymap.
        (setq major-mode 'kitty-graphics-image-mode
              mode-name (format "Image[%s]"
                                (pcase kitty-graphics--active-backend
                                  ('kitty "Kitty") ('sixel "Sixel") (_ "GFX"))))
        (let ((map (make-sparse-keymap)))
          (set-keymap-parent map special-mode-map)
          (define-key map (kbd "q") #'kill-current-buffer)
          (define-key map (kbd "+") #'kitty-graphics-image-increase-size)
          (define-key map (kbd "=") #'kitty-graphics-image-increase-size)
          (define-key map (kbd "-") #'kitty-graphics-image-decrease-size)
          (define-key map (kbd "0") #'kitty-graphics-image-reset-size)
          (use-local-map map))
        ;; If evil is loaded, bind zoom keys in normal state so they
        ;; aren't shadowed by evil's default normal-state bindings.
        (when (fboundp 'evil-local-set-key)
          (evil-local-set-key 'normal (kbd "+") #'kitty-graphics-image-increase-size)
          (evil-local-set-key 'normal (kbd "=") #'kitty-graphics-image-increase-size)
          (evil-local-set-key 'normal (kbd "-") #'kitty-graphics-image-decrease-size)
          (evil-local-set-key 'normal (kbd "0") #'kitty-graphics-image-reset-size)
          (evil-local-set-key 'normal (kbd "q") #'kill-current-buffer))
        (setq-local buffer-read-only t)
        ;; Re-render when window size changes (e.g., split/unsplit)
        ;; so centering and overflow checks use correct dimensions.
        (add-hook 'window-size-change-functions
                  (lambda (_frame)
                    (when (eq major-mode 'kitty-graphics-image-mode)
                      (kitty-graphics--image-mode-render)))
                  nil t)
        (kitty-graphics--image-mode-render)
        (set-buffer-modified-p nil))
    (apply orig-fn args)))

;;;; shr integration (eww, mu4e, gnus)

(defun kitty-graphics--fit-box (win fit-width fit-height)
  "Return (MAX-COLS . MAX-ROWS) for fitting an image into WIN.
MAX-COLS is FIT-WIDTH of WIN's body width, MAX-ROWS is FIT-HEIGHT, each
capped at `kitty-graphics-max-width'/`kitty-graphics-max-height'.
Used by both the
shr and org `fit' image sizing paths."
  (let ((win-w (if (window-live-p win)
                   (window-body-width win)
                 kitty-graphics-max-width)))
    (cons (max 1 (min kitty-graphics-max-width (round (* win-w fit-width))))
          (max 1 (min kitty-graphics-max-height fit-height)))))

(defun kitty-graphics--shr-display-image (file start end)
  "Display FILE for the shr backends, honoring `kitty-graphics-shr-scale'."
  (pcase kitty-graphics-shr-scale
    ('fit
     (let ((box (kitty-graphics--fit-box (get-buffer-window (current-buffer))
                                    kitty-graphics-shr-fit-width
                                    kitty-graphics-shr-fit-height)))
       (kitty-graphics-display-image file start end (car box) (cdr box))))
    ((and (pred numberp) factor)
     (let ((kitty-graphics--dim-scale factor))
       (kitty-graphics-display-image file start end)))
    (_ (kitty-graphics-display-image file start end))))

(defun kitty-graphics--shr-put-image-advice (orig-fn spec alt &rest args)
  "Around advice for `shr-put-image'.
SPEC is an image descriptor — typically a create-image result.
We extract the :file or :data from the image properties."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (let* ((start (point))
             ;; Accept SHR's raw DATA/(DATA CONTENT-TYPE) form, with
             ;; image-spec plist handling as a fallback for other callers.
             (props (and (consp spec) (cdr spec)))
             (data (cond
                    ((stringp spec) spec)
                    ((and (consp spec) (stringp (car spec))) (car spec))
                    (t (plist-get props :data))))
             (url (plist-get props :file))
             (type (if (and (consp spec) (stringp (car spec)))
                       (cadr spec)
                     (plist-get props :type))))
        (kitty-graphics--log "shr-put-image: type=%s url=%s data-len=%s alt=%s"
                         type url (when data (length data)) alt)
        (insert (or alt "[image]"))
        (let ((end (point)))
          (let* ((suffix (cond
                          ((member type '(jpeg image/jpeg "image/jpeg")) ".jpg")
                          ((member type '(gif image/gif "image/gif")) ".gif")
                          ((member type '(webp image/webp "image/webp")) ".webp")
                          ((member type '(svg image/svg+xml "image/svg+xml")) ".svg")
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
            (condition-case err
                (when file
                  (let ((ov (kitty-graphics--shr-display-image file start end)))
                    (if (and ov temp-p)
                        (overlay-put ov 'kitty-graphics-delete-file file)
                      (when temp-p
                        (ignore-errors (delete-file file))))))
              (error
               (when temp-p
                 (ignore-errors (delete-file file)))
               (kitty-graphics--log "shr-put-image error: %s" (error-message-string err)))))))
    (apply orig-fn spec alt args)))

;;;; doc-view integration

(defun kitty-graphics--doc-view-mode-p-advice (orig-fn type)
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

(defun kitty-graphics--clear-image-cache-advice (orig-fn &rest args)
  "Around advice for `clear-image-cache'.
On a terminal, `clear-image-cache' signals \"Window system frame
should be used\".  doc-view's conversion-completion callback calls it
before re-displaying, so the error propagates through `doc-view-sentinel'
and kills the whole conversion chain (no re-display, no resolution.el).
kitty-graphics transmits pixels directly and never uses the image.c
cache on a terminal, so skipping the call there is safe."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      nil
    (apply orig-fn args)))

(defvar-local kitty-graphics--doc-view-overlay nil
  "The Kitty graphics overlay used for doc-view page display.")

(defvar-local kitty-graphics--doc-view-scale 1.0
  "Zoom scale factor for doc-view page display.
Values > 1.0 zoom in, < 1.0 zoom out.")

(defvar-local kitty-graphics--doc-view-current-file nil
  "Path to the current doc-view page image file.
Stored so zoom commands can re-render without querying `doc-view-current-image'.")

(defvar-local kitty-graphics--doc-view-scroll-col 0
  "Horizontal scroll offset, in cells, into the zoomed doc-view page.")

(defvar-local kitty-graphics--doc-view-scroll-row 0
  "Vertical scroll offset, in cells, into the zoomed doc-view page.")

(defvar-local kitty-graphics--doc-view-fit nil
  "Page size in cells at scale 1.0 as (COLS . ROWS).")

(defvar-local kitty-graphics--doc-view-src nil
  "Source page image pixel size as (WIDTH . HEIGHT).")

(defun kitty-graphics--doc-view-terminal-p ()
  "Non-nil when Kitty graphics is handling a doc-view buffer in a terminal."
  (and kitty-graphics-mode
       (not (display-graphic-p))
       (eq major-mode 'doc-view-mode)))

(defun kitty-graphics--doc-view-win-dims (&optional win)
  "Return the usable doc-view area of WIN (or selected) as (COLS . ROWS)."
  (cons (max 1 (1- (window-body-width win)))
        (max 1 (1- (window-body-height win)))))

(defun kitty-graphics--doc-view-total-size ()
  "Return the zoomed page size in cells as (COLS . ROWS), or nil.
This is the scale-1.0 fit size scaled by `kitty-graphics--doc-view-scale'."
  (when kitty-graphics--doc-view-fit
    (cons (max 1 (round (* kitty-graphics--doc-view-scale
                           (car kitty-graphics--doc-view-fit))))
          (max 1 (round (* kitty-graphics--doc-view-scale
                           (cdr kitty-graphics--doc-view-fit)))))))

(defun kitty-graphics--doc-view-max-hscroll ()
  "Return the maximum horizontal cell scroll for the zoomed page."
  (let ((total (kitty-graphics--doc-view-total-size)))
    (max 0 (- (or (car total) 0) (car (kitty-graphics--doc-view-win-dims))))))

(defun kitty-graphics--doc-view-max-vscroll ()
  "Return the maximum vertical cell scroll for the zoomed page."
  (let ((total (kitty-graphics--doc-view-total-size)))
    (max 0 (- (or (cdr total) 0) (cdr (kitty-graphics--doc-view-win-dims))))))

(defun kitty-graphics--doc-view-set-hscroll (ncols)
  "Scroll horizontally to NCOLS cells into the page and re-render."
  (let ((new (max 0 (min ncols (kitty-graphics--doc-view-max-hscroll)))))
    (setq kitty-graphics--doc-view-scroll-col new)
    (kitty-graphics--schedule-refresh)
    new))

(defun kitty-graphics--doc-view-set-vscroll (nrows)
  "Scroll vertically to NROWS cells into the page and re-render."
  (let ((new (max 0 (min nrows (kitty-graphics--doc-view-max-vscroll)))))
    (setq kitty-graphics--doc-view-scroll-row new)
    (kitty-graphics--schedule-refresh)
    new))

(defun kitty-graphics--doc-view-forward-hscroll (&optional n)
  "Scroll the page rightward by N cells."
  (kitty-graphics--doc-view-set-hscroll (+ kitty-graphics--doc-view-scroll-col (or n 1))))

(defun kitty-graphics--doc-view-next-line (&optional n)
  "Scroll the page downward by N cell rows."
  (kitty-graphics--doc-view-set-vscroll (+ kitty-graphics--doc-view-scroll-row (or n 1))))

(defun kitty-graphics--doc-view-scroll-left (&optional n)
  "Scroll the page leftward by about a screenful of columns."
  (kitty-graphics--doc-view-forward-hscroll
   (cond
    ((null n) (max 1 (- (car (kitty-graphics--doc-view-win-dims)) 2)))
    ((eq n '-) (min -1 (- 2 (car (kitty-graphics--doc-view-win-dims)))))
    (t (prefix-numeric-value n)))))

(defun kitty-graphics--doc-view-scroll-up (&optional n)
  "Scroll the page upward by about a screenful of rows."
  (kitty-graphics--doc-view-next-line
   (cond
    ((null n) (max 1 (- (cdr (kitty-graphics--doc-view-win-dims)) next-screen-context-lines)))
    ((eq n '-) (min -1 (- next-screen-context-lines (cdr (kitty-graphics--doc-view-win-dims)))))
    (t (prefix-numeric-value n)))))

(defun kitty-graphics--doc-view-image-forward-hscroll-advice (orig-fn &optional n)
  "Around advice for `image-forward-hscroll' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-forward-hscroll n)
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-backward-hscroll-advice (orig-fn &optional n)
  "Around advice for `image-backward-hscroll' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-forward-hscroll (- (or n 1)))
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-next-line-advice (orig-fn &optional n)
  "Around advice for `image-next-line' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-next-line n)
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-previous-line-advice (orig-fn &optional n)
  "Around advice for `image-previous-line' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-next-line (- (or n 1)))
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-scroll-left-advice (orig-fn &optional n)
  "Around advice for `image-scroll-left' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-scroll-left n)
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-scroll-right-advice (orig-fn &optional n)
  "Around advice for `image-scroll-right' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-scroll-left
       (cond
        ((null n) (min 0 (- 2 (window-body-width))))
        ((eq n '-) (max 0 (- (window-body-width) 2)))
        (t (- (prefix-numeric-value n)))))
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-scroll-up-advice (orig-fn &optional n)
  "Around advice for `image-scroll-up' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-scroll-up n)
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-scroll-down-advice (orig-fn &optional n)
  "Around advice for `image-scroll-down' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (kitty-graphics--doc-view-scroll-up
       (cond
        ((null n) (min 0 (- next-screen-context-lines (window-body-height))))
        ((eq n '-) (max 0 (- (window-body-height) next-screen-context-lines)))
        (t (- (prefix-numeric-value n)))))
    (funcall orig-fn n)))

(defun kitty-graphics--doc-view-image-bol-advice (orig-fn &optional arg)
  "Around advice for `image-bol' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (progn
        (when (and arg (/= (prefix-numeric-value arg) 1))
          (kitty-graphics--doc-view-next-line (- (prefix-numeric-value arg) 1)))
        (kitty-graphics--doc-view-set-hscroll 0))
    (funcall orig-fn arg)))

(defun kitty-graphics--doc-view-image-eol-advice (orig-fn &optional arg)
  "Around advice for `image-eol' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (progn
        (when (and arg (/= (prefix-numeric-value arg) 1))
          (kitty-graphics--doc-view-next-line (- (prefix-numeric-value arg) 1)))
        (kitty-graphics--doc-view-set-hscroll (kitty-graphics--doc-view-max-hscroll)))
    (funcall orig-fn arg)))

(defun kitty-graphics--doc-view-image-bob-advice (orig-fn)
  "Around advice for `image-bob' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (progn
        (kitty-graphics--doc-view-set-hscroll 0)
        (kitty-graphics--doc-view-set-vscroll 0))
    (funcall orig-fn)))

(defun kitty-graphics--doc-view-image-eob-advice (orig-fn)
  "Around advice for `image-eob' in Kitty doc-view buffers."
  (if (kitty-graphics--doc-view-terminal-p)
      (progn
        (kitty-graphics--doc-view-set-hscroll (kitty-graphics--doc-view-max-hscroll))
        (kitty-graphics--doc-view-set-vscroll (kitty-graphics--doc-view-max-vscroll)))
    (funcall orig-fn)))

(defun kitty-graphics--doc-view-refresh-overlay (ov win)
  "Render doc-view page OV in WIN at the current zoom and scroll.
The page is centered when it fits the window width; when zoomed past
the window it is clipped to the visible region (Kitty source crop) and
panned via `kitty-graphics--doc-view-scroll-col'/`-row'.  Placeholder mode
\(tmux) falls back to a plain clamped placement that Emacs clips."
  (let ((id (overlay-get ov 'kitty-graphics-id))
        (pos (kitty-graphics--overlay-screen-pos ov win))
        (kitty (eq kitty-graphics--active-backend 'kitty)))
    (if (not (and pos kitty-graphics--doc-view-fit))
        ;; Off-screen — drop this window's placement (per-window, so other
        ;; windows showing the same page keep theirs).
        (let ((placement (kitty-graphics--image-placement ov win)))
          (when placement
            (kitty-graphics--delete-image-placement ov placement)
            (kitty-graphics--forget-image-placement ov win)
            (overlay-put ov 'kitty-graphics-last-row nil)))
      (let* ((dims (kitty-graphics--doc-view-win-dims win))
             (winw (car dims)) (winh (cdr dims))
             ;; Zoom/crop/pan is Kitty-only (needs source cropping).  Other
             ;; backends (Sixel) render at the fit size so the page stays
             ;; stable and artifact-free; their scale/scroll are ignored.
             (total (if kitty (kitty-graphics--doc-view-total-size) kitty-graphics--doc-view-fit))
             (tc (car total)) (tr (cdr total))
             (scol (if kitty (min kitty-graphics--doc-view-scroll-col (max 0 (- tc winw))) 0))
             (srow (if kitty (min kitty-graphics--doc-view-scroll-row (max 0 (- tr winh))) 0))
             (vc (max 1 (min winw (- tc scol))))
             (vr (max 1 (min winh (- tr srow))))
             (hpad (if (< tc winw) (/ (- winw tc) 2) 0))
             (term-row (car pos))
             (term-col (+ (cdr pos) hpad)))
        (if kitty
            ;; Per-window placement id so the same page in two windows gets
            ;; two distinct on-screen copies (mirrors the image path).
            (let* ((src kitty-graphics--doc-view-src)
                   (pw (car src)) (ph (cdr src))
                   (spx (/ (float pw) tc)) (spy (/ (float ph) tr))
                   (x (round (* scol spx))) (y (round (* srow spy)))
                   (w (max 1 (min (- pw x) (round (* vc spx)))))
                   (h (max 1 (min (- ph y) (round (* vr spy)))))
                   (pid (kitty-graphics--record-image-placement ov win term-row term-col vc vr nil)))
              (if (eq (kitty-graphics--effective-placement-mode) 'direct)
                  (kitty-graphics--place-image id pid vc vr term-row term-col x y w h)
                (kitty-graphics--kitty-place ov id pid vc vr term-row term-col)))
          ;; Sixel (or other): erase the previous area first when it moved or
          ;; resized, since the stateless backend would otherwise leave old
          ;; pixels behind; then re-encode the page at the fit cell size.
          (let ((prev (kitty-graphics--image-placement ov win)))
            (when (and prev
                       (let ((d (cdr prev)))
                         (not (and (eql (plist-get d :row) term-row)
                                   (eql (plist-get d :col) term-col)
                                   (eql (plist-get d :cols) vc)
                                   (eql (plist-get d :rows) vr)))))
              (kitty-graphics--delete-image-placement ov prev)
              (kitty-graphics--forget-image-placement ov win)))
          (let ((pid (kitty-graphics--record-image-placement ov win term-row term-col vc vr nil)))
            (funcall (kitty-graphics--backend-fn 'place) ov id pid vc vr term-row term-col)))
        (overlay-put ov 'kitty-graphics-last-row term-row)
        (overlay-put ov 'kitty-graphics-last-col term-col)))))

(defvar kitty-graphics--doc-view-max-resolution 1200
  "Upper bound for the DPI `kitty-graphics--doc-view-ensure-resolution' sets.
A sanity ceiling so a miscalculation can never request an absurd
render size from the converter.")

(defvar-local kitty-graphics--doc-view-requested-resolution nil
  "DPI already requested by `kitty-graphics--doc-view-ensure-resolution'.
Prevents stacking reconversions: while a reconvert runs, further page
inserts compute the same target and are skipped.  A reconvert is only
triggered when the newly computed target differs from what was already
requested (e.g. the window grew).")

(defun kitty-graphics--doc-view-ensure-resolution (file px win-w win-h)
  "Re-render the current document at a higher DPI when PX is too small.
FILE is the page image, PX its pixel size (W . H); WIN-W and WIN-H
are the usable window size in cells.  When the page has fewer pixels
than `kitty-graphics-doc-view-resolution-scale' times the exact-fit
display area, raise the buffer-local `doc-view-resolution'
accordingly and reconvert the document; the conversion callback
re-displays the page at the new resolution.  Returns non-nil when a
reconversion was triggered and the caller should skip displaying
this stale page.

MuPDF SVG pages (`doc-view-mupdf-use-svg') are vector graphics: the
-r flag does not change their nominal pixel size, so a DPI bump can
never satisfy the check.  Switch the buffer to PNG rendering
instead, computing the target DPI from the SVG's nominal size,
which is in PDF points (72 per inch)."
  (when (and kitty-graphics-doc-view-resolution-scale
             px
             (numberp doc-view-resolution))
    ;; The global cell size is invalidated on every window change and
    ;; re-queried lazily, so it may be nil here; fall back to the
    ;; per-terminal parameter, then re-query, before assuming 8x16 --
    ;; a fallback cell size undersizes the render target and the page
    ;; ends up blurry anyway.
    (let* ((cw (or kitty-graphics--cell-pixel-width
                   (terminal-parameter nil 'kitty-graphics-cell-w)
                   (progn (kitty-graphics--query-cell-size)
                          kitty-graphics--cell-pixel-width)
                   8))
           (ch (or kitty-graphics--cell-pixel-height
                   (terminal-parameter nil 'kitty-graphics-cell-h)
                   16))
           ;; Bind the globals so `kitty-graphics--compute-cell-dims' uses
           ;; the same cell size.
           (kitty-graphics--cell-pixel-width cw)
           (kitty-graphics--cell-pixel-height ch)
           (fit (kitty-graphics--compute-cell-dims (car px) (cdr px) win-w win-h))
           (need-w (* (car fit) cw kitty-graphics-doc-view-resolution-scale))
           (need-h (* (cdr fit) ch kitty-graphics-doc-view-resolution-scale))
           (ratio (max (/ need-w (float (car px)))
                       (/ need-h (float (cdr px))))))
      ;; 10% tolerance so the re-rendered page itself passes the check.
      (when (> ratio 1.1)
        (if (and (string-suffix-p ".svg" file t)
                 (boundp 'doc-view-mupdf-use-svg)
                 (fboundp 'doc-view-set-up-single-converter))
            (let ((new (min kitty-graphics--doc-view-max-resolution
                            (ceiling (* 72 ratio)))))
              (unless (eql new kitty-graphics--doc-view-requested-resolution)
                (kitty-graphics--log
                 "doc-view: SVG page cannot honor a DPI bump; switching to PNG at %d dpi"
                 new)
                (setq-local doc-view-mupdf-use-svg nil)
                (doc-view-set-up-single-converter)
                (setq-local doc-view-resolution new)
                (setq kitty-graphics--doc-view-requested-resolution new)
                (doc-view-reconvert-doc)
                t))
          (let ((new (min kitty-graphics--doc-view-max-resolution
                          (ceiling (* ratio doc-view-resolution)))))
            ;; `/=' (not `>'): a resolution above the ceiling (e.g. a
            ;; cache poisoned by an earlier bug) is pulled back down to
            ;; it, healing the cache on the next reconvert.
            (when (and (/= new doc-view-resolution)
                       (not (eql new kitty-graphics--doc-view-requested-resolution)))
              (kitty-graphics--log
               "doc-view: page %dx%d px too small for %dx%d cells x%.1f (need %.0fx%.0f px); resolution %d -> %d dpi"
               (car px) (cdr px) win-w win-h
               kitty-graphics-doc-view-resolution-scale need-w need-h
               doc-view-resolution new)
              (setq-local doc-view-resolution new)
              (setq kitty-graphics--doc-view-requested-resolution new)
              (doc-view-reconvert-doc)
              t)))))))

(defun kitty-graphics--doc-view-insert-image-advice (orig-fn file &rest args)
  "Around advice for `doc-view-insert-image'.
Displays the page image via Kitty graphics instead of an Emacs
image spec.  FILE is the path to the rendered page image (PNG, or
SVG when `doc-view-mupdf-use-svg' is in effect)."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when (and file (file-exists-p file))
        (kitty-graphics--log "doc-view-insert: file=%s scale=%.2f" file kitty-graphics--doc-view-scale)
        ;; Remember current file for zoom commands
        (setq kitty-graphics--doc-view-current-file file)
        (let* ((abs-file (expand-file-name file))
               (size (or (file-attribute-size (file-attributes abs-file)) 0))
               (dims (kitty-graphics--doc-view-win-dims))
               (win-w (car dims))
               (win-h (cdr dims))
               (px (kitty-graphics--image-pixel-size abs-file)))
          (cond
           ;; The page file exists but is not readable yet: doc-view calls
           ;; us while its converter is still writing it (reconvert's force
           ;; display and the refresh timer both race the converter).
           ;; Transmitting now would cache an empty/corrupt image under
           ;; this path and blank the page for the rest of the session, so
           ;; keep the stale page; doc-view force-re-displays when the
           ;; conversion completes and calls us again with the whole file.
           ;; A nil PX only counts as not-ready when an identify binary is
           ;; available -- without ImageMagick PX is always nil and there
           ;; is nothing to wait for.
           ((or (zerop size)
                (and (null px)
                     (or (executable-find "magick")
                         (executable-find "identify"))))
            (kitty-graphics--log
             "doc-view-insert: %s not fully written yet (size=%d), keeping stale page"
             file size))
           ((kitty-graphics--doc-view-ensure-resolution abs-file px win-w win-h)
              ;; The page was rendered too small for a sharp display; a
              ;; reconversion at higher DPI is now running and its
              ;; callback re-displays the page.  Keep the stale page
              ;; (and its overlay) on screen until then.
              (kitty-graphics--log
               "doc-view-insert: page too small, reconverting at higher dpi"))
           (t
            ;; Drop doc-view's own "Welcome to DocView!" conversion-progress text
            ;; (left on doc-view's overlay by `doc-view-buffer-message'); our
            ;; overlay is separate, so it would otherwise show through behind the page.
            (when (fboundp 'doc-view-current-overlay)
              (let ((dv-ov (ignore-errors (doc-view-current-overlay))))
                (when (overlayp dv-ov)
                  (overlay-put dv-ov 'display nil))))
            ;; Retire the previous page overlay.  Re-rendering the SAME page (same
            ;; image id, e.g. doc-view's double insert): keep the placement so the
            ;; new one atomically replaces it (no flash, WezTerm #5892), and
            ;; transplant its per-window placement so the same pid is reused.  A
            ;; DIFFERENT page (new image id): Kitty placement ids are scoped per
            ;; image id, so a new page at the same pid would NOT replace the old
            ;; one and it would ghost — really delete the old placement (a=d).
            (let* ((cached-id (kitty-graphics--cache-get abs-file))
                   (old-ov kitty-graphics--doc-view-overlay)
                   (old-id (and old-ov (overlay-get old-ov 'kitty-graphics-id)))
                   (same-page (and old-id cached-id (eql old-id cached-id)))
                   (old-pid (and old-ov (overlay-get old-ov 'kitty-graphics-pid)))
                   (old-placements (and same-page old-ov
                                        (copy-sequence
                                         (overlay-get old-ov 'kitty-graphics-placements)))))
              (when old-ov
                (kitty-graphics--remove-overlay old-ov (and same-page old-pid))
                (setq kitty-graphics--doc-view-overlay nil))
              ;; Display the rendered page using only an overlay.  Do not erase
              ;; or insert text here: doc-view buffers visit the original PDF, so
              ;; mutating buffer text can corrupt the document if it is saved.
              (let* ((base-dims (if px
                                    (kitty-graphics--compute-cell-dims
                                     (car px) (cdr px) win-w win-h)
                                  (cons (min 40 win-w) (min 15 win-h))))
                     (image-id (or cached-id (kitty-graphics--alloc-id))))
                ;; Record the scale-1.0 fit size and source pixels; clamp any
                ;; carried-over scroll to the new page's limits.  The page is
                ;; drawn by `kitty-graphics--doc-view-refresh-overlay', which centers
                ;; and crops it; the overlay only reserves the whole window.
                (setq kitty-graphics--doc-view-fit base-dims
                      kitty-graphics--doc-view-src
                      (or px (cons (* win-w (or kitty-graphics--cell-pixel-width 8))
                                   (* win-h (or kitty-graphics--cell-pixel-height 16))))
                      kitty-graphics--doc-view-scroll-col
                      (min kitty-graphics--doc-view-scroll-col (kitty-graphics--doc-view-max-hscroll))
                      kitty-graphics--doc-view-scroll-row
                      (min kitty-graphics--doc-view-scroll-row (kitty-graphics--doc-view-max-vscroll)))
                (unless cached-id
                  (when (funcall (kitty-graphics--backend-fn 'prepare) abs-file image-id)
                    (kitty-graphics--cache-put abs-file image-id)))
                (when (or cached-id (gethash abs-file kitty-graphics--image-cache))
                  (setq kitty-graphics--doc-view-overlay
                        (kitty-graphics--make-overlay (point-min) (point-max)
                                                 image-id win-w win-h
                                                 abs-file (and same-page old-pid)))
                  (when kitty-graphics--doc-view-overlay
                    (overlay-put kitty-graphics--doc-view-overlay 'kitty-graphics-doc-view t))
                  (when (and old-placements kitty-graphics--doc-view-overlay)
                    (overlay-put kitty-graphics--doc-view-overlay
                                 'kitty-graphics-placements old-placements))
                  (kitty-graphics--schedule-refresh)))))))
        (goto-char (point-min)))
    (apply orig-fn file args)))

(defun kitty-graphics--doc-view-enlarge-advice (orig-fn factor)
  "Around advice for `doc-view-enlarge'.
Updates `kitty-graphics--doc-view-scale' and re-renders the page in place.
The stored page image is reused; only the crop/scale changes.  Pages
stay sharp up to the render headroom provided by
`kitty-graphics-doc-view-resolution-scale'; zooming beyond that upscales."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when kitty-graphics--doc-view-overlay
        (setq kitty-graphics--doc-view-scale (* kitty-graphics--doc-view-scale factor))
        (kitty-graphics--schedule-refresh))
    (funcall orig-fn factor)))

(defun kitty-graphics--doc-view-scale-reset-advice (orig-fn &rest args)
  "Around advice for `doc-view-scale-reset'.
Resets scale to 1.0, recenters, and re-renders the page in place."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when kitty-graphics--doc-view-overlay
        (setq kitty-graphics--doc-view-scale 1.0
              kitty-graphics--doc-view-scroll-col 0
              kitty-graphics--doc-view-scroll-row 0)
        (kitty-graphics--schedule-refresh))
    (apply orig-fn args)))

;;;; Dired integration

(defun kitty-graphics--preview-quit ()
  "Close the kitty-graphics preview window.
Stops any inline mpv playback first so the mpv process does not
outlive its preview buffer.  When the preview occupies the only
window in the frame (full-frame dirvish RET path), keep the
window alive and let `kill-buffer' surface the previous buffer."
  (interactive)
  (let ((win (get-buffer-window (current-buffer))))
    (when (and (boundp 'kitty-graphics--mpv-process) kitty-graphics--mpv-process)
      (kitty-graphics--mpv-cleanup))
    (kitty-graphics-remove-images)
    (kill-buffer (current-buffer))
    (when (and (window-live-p win) (not (one-window-p t)))
      (delete-window win))))

(defun kitty-graphics--install-preview-quit-key ()
  "Bind `q' to close the current preview/playback buffer.
Sets a buffer-local map and, under evil, the normal-state key too.
The mpv overlay carries its own `q' while a video plays, but that
overlay is deleted when the video ends; without a buffer-local binding
evil's normal-state `q' (record macro) then shadows the close key and
the buffer cannot be quit.  Mirrors the image-mode setup."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'kitty-graphics--preview-quit)
    (use-local-map map))
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "q") #'kitty-graphics--preview-quit)))

(defun kitty-graphics--make-preview-buffer (file)
  "Create the preview side-window buffer for FILE.
Returns (BUF . WIN).  Sets up the standard `q'-to-close keymap
shared by image and video previews."
  (let* ((buf-name (format "*kitty-preview: %s*" (file-name-nondirectory file)))
         (buf (get-buffer-create buf-name))
         (win (display-buffer-in-side-window
               buf '((side . right) (window-width . 0.5)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "  %s\n\n" (file-name-nondirectory file))))
      (setq-local buffer-read-only t)
      (kitty-graphics--install-preview-quit-key))
    (cons buf win)))

(defun kitty-graphics--preview-display (image-path win buf)
  "Place IMAGE-PATH into preview BUF shown in WIN, sized to WIN."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (kitty-graphics-remove-images)
      (kitty-graphics-display-image
       image-path (point-min) (point-max)
       (min (- (window-width win) 2) kitty-graphics-max-width)
       (min (- (window-height win) 3) kitty-graphics-max-height)))
    (goto-char (point-min))))

;;;###autoload
(defun kitty-graphics-dired-preview ()
  "Preview the file at point in dired.
Images render via the Kitty graphics protocol; video files render
as a single-frame thumbnail extracted by ffmpeg (cached under
`kitty-graphics--video-thumbnail-cache-dir').  Press `q' in the preview
buffer to close it."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a dired buffer"))
  (let ((file (dired-get-file-for-visit)))
    (kitty-graphics--log "dired-preview: %s" file)
    (cond
     ((kitty-graphics--image-file-p file)
      (let* ((bw (kitty-graphics--make-preview-buffer file)))
        (kitty-graphics--preview-display file (cdr bw) (car bw))))
     ((kitty-graphics--video-file-p file)
      (let ((thumb (kitty-graphics--video-thumbnail file)))
        (if thumb
            (let* ((bw (kitty-graphics--make-preview-buffer file)))
              (kitty-graphics--preview-display thumb (cdr bw) (car bw)))
          (user-error
           "Could not extract video thumbnail (ffmpeg missing or failed)"))))
     (t
      (user-error "Not an image or video file")))))

(define-obsolete-function-alias 'kitty-gfx-dired-preview 'kitty-graphics-dired-preview "1.3.0")

(defvar-local kitty-graphics--dired-auto-preview-timer nil
  "Debounce timer for `kitty-graphics-dired-auto-preview-mode'.")

(defun kitty-graphics--dired-auto-preview-now (buf)
  "Run `kitty-graphics-dired-preview' in BUF if cursor is on a known file.
When dirvish is managing BUF, dirvish's own preview pane handles
the rendering -- skip so the cursor move does not spawn a second,
redundant side window."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and (derived-mode-p 'dired-mode)
                 (eq buf (window-buffer (selected-window)))
                 ;; Skip when dirvish has its own preview running.
                 (not (and (fboundp 'dirvish-curr) (dirvish-curr))))
        (let ((file (ignore-errors (dired-get-file-for-visit))))
          (when (and file
                     (file-regular-p file)
                     (or (kitty-graphics--image-file-p file)
                         (kitty-graphics--video-file-p file)))
            (condition-case err
                (kitty-graphics-dired-preview)
              (user-error
               (kitty-graphics--log "dired-auto-preview: skip (%s)"
                               (error-message-string err))))))))))

(defun kitty-graphics--dired-auto-preview-hook ()
  "Schedule a debounced auto-preview after a dired cursor move."
  (when kitty-graphics--dired-auto-preview-timer
    (cancel-timer kitty-graphics--dired-auto-preview-timer))
  (setq kitty-graphics--dired-auto-preview-timer
        (run-with-idle-timer
         kitty-graphics-dired-preview-debounce nil
         #'kitty-graphics--dired-auto-preview-now (current-buffer))))

;;;###autoload
(define-minor-mode kitty-graphics-dired-auto-preview-mode
  "Auto-preview the file at point in dired in a side window.
Idles `kitty-graphics-dired-preview-debounce' seconds, then calls
`kitty-graphics-dired-preview'.  Videos render as a single-frame
thumbnail; images render directly.  Closing the preview window
(`q' in the preview buffer) re-opens on the next cursor move
unless the mode is turned off."
  :lighter " kPrev"
  (if kitty-graphics-dired-auto-preview-mode
      (add-hook 'post-command-hook
                #'kitty-graphics--dired-auto-preview-hook nil t)
    (remove-hook 'post-command-hook
                 #'kitty-graphics--dired-auto-preview-hook t)
    (when kitty-graphics--dired-auto-preview-timer
      (cancel-timer kitty-graphics--dired-auto-preview-timer)
      (setq kitty-graphics--dired-auto-preview-timer nil))))

(define-obsolete-function-alias 'kitty-gfx-dired-auto-preview-mode 'kitty-graphics-dired-auto-preview-mode "1.3.0")

;;;###autoload
(defun kitty-graphics-dired-play-video ()
  "Play the video at point in dired inline via mpv.
Distinct from `kitty-graphics-dired-preview', which shows only a
single-frame thumbnail.  Useful when bound separately on a
heavier shortcut for full playback."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a dired buffer"))
  (let ((file (dired-get-file-for-visit)))
    (unless (kitty-graphics--mpv-playable-extension-p file)
      (user-error "Not a playable video/GIF file"))
    (when-let* ((reason (kitty-graphics--mpv-unavailable-reason)))
      (user-error "kitty-graphics: cannot play video: %s" reason))
    ;; Single-video invariant: kill any other live playback first.
    (let ((existing (kitty-graphics--mpv-buffer)))
      (when existing (with-current-buffer existing (kitty-graphics--mpv-cleanup))))
    (let* ((bw (kitty-graphics--make-preview-buffer file))
           (buf (car bw))
           (win (cdr bw)))
      (with-selected-window win
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (kitty-graphics-play-video file)))))))

(define-obsolete-function-alias 'kitty-gfx-dired-play-video 'kitty-graphics-dired-play-video "1.3.0")

(defvar kitty-graphics--mpv-warn-throttle 0
  "Float-time of the last \"mpv unavailable\" message.
Used to throttle repeat warnings to at most once every few
seconds, so navigating across multiple video files in dired or
dirvish does not flood the echo area.")

(defun kitty-graphics--warn-mpv-unavailable (reason)
  "Echo REASON for mpv unavailability, throttled to once per ~3s."
  (let ((now (float-time)))
    (when (> (- now kitty-graphics--mpv-warn-throttle) 3.0)
      (setq kitty-graphics--mpv-warn-throttle now)
      (message "kitty-graphics: inline video preview disabled (%s)" reason))))

(defun kitty-graphics--dired-find-file-advice (orig-fn &rest args)
  "Around advice on `dired-find-file' that routes videos to mpv.
Avoids Emacs's \"file too big\" prompt for multi-MB videos by
delegating to `kitty-graphics-dired-play-video' when the file at point
has a video extension and mpv is available.  Non-video files pass
through.

When the file has a video extension but mpv playback is
unavailable (no mpv binary, kitty backend off, etc.), echo a
one-shot warning explaining why and fall through to ORIG-FN.

Inside an active dirvish session, pass through to ORIG-FN so
`kitty-graphics--dirvish-find-entry-hook' can play the video in the
appropriate window.  Going through `display-buffer-in-side-window'
there would cause dirvish to rebuild its layout (transient
`delete-other-windows'), which the user sees as the preview
buffer briefly going full-frame before mpv starts."
  (let ((file (ignore-errors (dired-get-file-for-visit))))
    (cond
     ((not (and file (kitty-graphics--mpv-playable-extension-p file)))
      (apply orig-fn args))
     ((kitty-graphics--mpv-unavailable-reason)
      (kitty-graphics--warn-mpv-unavailable
       (kitty-graphics--mpv-unavailable-reason))
      (apply orig-fn args))
     ((and (featurep 'dirvish)
           (fboundp 'dirvish-curr)
           (dirvish-curr))
      (apply orig-fn args))
     (t (kitty-graphics-dired-play-video)))))

(defun kitty-graphics--dired-find-file-other-window-advice (orig-fn &rest args)
  "Around advice on `dired-find-file-other-window' that routes videos to mpv."
  (let ((file (ignore-errors (dired-get-file-for-visit))))
    (cond
     ((not (and file (kitty-graphics--mpv-playable-extension-p file)))
      (apply orig-fn args))
     ((kitty-graphics--mpv-unavailable-reason)
      (kitty-graphics--warn-mpv-unavailable
       (kitty-graphics--mpv-unavailable-reason))
      (apply orig-fn args))
     ((and (featurep 'dirvish)
           (fboundp 'dirvish-curr)
           (dirvish-curr))
      (apply orig-fn args))
     (t (kitty-graphics-dired-play-video)))))

(declare-function dirvish-curr "dirvish" ())
(declare-function dv-preview-window "dirvish" (dv))
(declare-function dirvish--clear-session "dirvish" (dv &optional from-quit))

(defun kitty-graphics--dirvish-find-entry-hook (entry find-fn)
  "Hook on `dirvish-find-entry-hook' that intercepts video files.
Default behaviour: tear down the dirvish layout and play ENTRY in
a full-frame preview buffer, mirroring how dirvish opens regular
files and images.  Set `kitty-graphics-dirvish-video-inline-preview'
to non-nil to instead keep the layout and play ENTRY inside the
existing dirvish preview side window."
  (when (and (memq find-fn '(find-file find-alternate-file))
             (stringp entry)
             (kitty-graphics--mpv-playable-extension-p entry)
             ;; mpv unreachable: warn and yield to dirvish's normal
             ;; find-fn (returns nil from the hook).  We've still
             ;; told the user why we didn't preview.
             (let ((reason (kitty-graphics--mpv-unavailable-reason)))
               (if reason
                   (progn (kitty-graphics--warn-mpv-unavailable reason) nil)
                 t)))
    (let* ((dv (ignore-errors (dirvish-curr)))
           (pwin (and dv (ignore-errors (dv-preview-window dv))))
           (basename (file-name-nondirectory entry))
           ;; Reuse the same buffer name the side-window preview path
           ;; uses, so SPC/q/? bindings + cleanup hooks behave the same.
           (buf (get-buffer-create (format "*kitty-preview: %s*" basename))))
      ;; Stop any prior playback first.
      (let ((existing (kitty-graphics--mpv-buffer)))
        (when existing
          (with-current-buffer existing (kitty-graphics--mpv-cleanup))))
      ;; Drop dirvish's per-file thumbnail buffer for ENTRY.  Its
      ;; placement is the dispatcher's stale image and would race
      ;; the mpv overlay for the same cells otherwise.
      (let ((thumb-buf (get-buffer
                        (format " *kitty-dirvish: %s*" basename))))
        (when thumb-buf
          (with-current-buffer thumb-buf (kitty-graphics-remove-images))
          (kill-buffer thumb-buf)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (kitty-graphics-remove-images)
          (erase-buffer)
          (insert (format "  %s\n\n" basename)))
        (setq-local buffer-read-only t)
        (kitty-graphics--install-preview-quit-key))
      (cond
       ;; Opt-in: play inside the existing dirvish preview side window.
       ((and kitty-graphics-dirvish-video-inline-preview
             pwin (window-live-p pwin))
        (set-window-buffer pwin buf)
        (with-selected-window pwin
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (kitty-graphics-play-video entry)))))
       ;; Default: tear down dirvish, play full-frame in selected window.
       (dv
        (when (fboundp 'dirvish--clear-session)
          (dirvish--clear-session dv))
        (let* ((w (selected-window))
               (ded (and (window-live-p w) (window-dedicated-p w))))
          (when (window-live-p w) (set-window-dedicated-p w nil))
          (switch-to-buffer buf)
          (when (and ded (window-live-p w))
            (set-window-dedicated-p w ded)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (kitty-graphics-play-video entry))))
       ;; No dirvish session at all (layout-less edge case): fall
       ;; back to the side-window dired flow.
       (t (kitty-graphics-dired-play-video))))
    t))

;;;; Dirvish integration

;; Forward declarations for dirvish
(declare-function dirvish-define-preview "dirvish" (&rest args))
(declare-function dirvish--special-buffer "dirvish" (type dv &optional new))
(defvar dirvish-image-exts)
(defvar dirvish-preview-dispatchers)
(defvar dirvish--available-preview-dispatchers)

(defun kitty-graphics--dirvish-preview (file _ext preview-window _dv)
  "Dirvish preview dispatcher for image / video files via Kitty + mpv.
FILE is the file to preview, PREVIEW-WINDOW is the target window.
Returns a buffer recipe, or nil if neither image nor video."
  (when (and kitty-graphics-mode
             (not (display-graphic-p))
             kitty-graphics--active-backend)
    (kitty-graphics--log "dirvish-preview: %s" file)
    (let* ((buf-name (format " *kitty-dirvish: %s*" (file-name-nondirectory file)))
           (buf (get-buffer-create buf-name))
           (max-cols (min (- (window-width preview-window) 2) kitty-graphics-max-width))
           (max-rows (min (- (window-height preview-window) 3) kitty-graphics-max-height))
           (is-image (kitty-graphics--image-file-p file))
           (is-video (and (not is-image) (kitty-graphics--video-file-p file))))
      (cond
       (is-image
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (kitty-graphics-remove-images)
            (erase-buffer)
            (insert (format "\n  %s\n\n" (file-name-nondirectory file))))
          (setq-local buffer-read-only t)
          (kitty-graphics-display-image file (point-min) (point-max) max-cols max-rows)
          (goto-char (point-min)))
        `(buffer . ,buf))
       (is-video
        (let ((thumb (kitty-graphics--video-thumbnail file)))
          (when thumb
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (kitty-graphics-remove-images)
                (erase-buffer)
                (insert (format "\n  %s\n\n" (file-name-nondirectory file))))
              (setq-local buffer-read-only t)
              (kitty-graphics-display-image
               thumb (point-min) (point-max) max-cols max-rows)
              (goto-char (point-min)))
            `(buffer . ,buf))))))))

(defun kitty-graphics--dirvish-image-dp (file ext preview-window dv)
  "Dirvish preview dispatcher for images and videos via Kitty graphics.
FILE is the file to preview, EXT its extension, PREVIEW-WINDOW the
dirvish preview window and DV the dirvish instance."
  ;; Use kitty-graphics's own extension predicates so the match is
  ;; case-insensitive (PNG, JPG, …) and consistent with the
  ;; branching inside `kitty-graphics--dirvish-preview'.  Earlier the
  ;; image arm relied on bare `member ext dirvish-image-exts'
  ;; which is case-sensitive and missed uppercase extensions —
  ;; the file then fell through to `dirvish-image-dp' and
  ;; crashed with "Window system frame should be used" on TTY.
  (when (or (kitty-graphics--image-file-p file)
            (kitty-graphics--video-extension-p file))
    (kitty-graphics--dirvish-preview file ext preview-window dv)))

(defun kitty-graphics--install-dirvish ()
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
    ;; Create the dispatcher function that dirvish expects.  Trigger
    ;; for image *and* video extensions; the dispatcher itself
    ;; branches on file type.  dirvish resolves dispatchers by name as
    ;; `dirvish-NAME-dp', so the dirvish-facing symbol keeps its name
    ;; as a compatibility alias for our own function.
    (defalias 'dirvish-kitty-image-dp #'kitty-graphics--dirvish-image-dp)
    ;; Prepend kitty-image to dispatchers if not already there
    (unless (memq 'kitty-image dirvish-preview-dispatchers)
      (setq dirvish-preview-dispatchers
            (cons 'kitty-image dirvish-preview-dispatchers)))
    (kitty-graphics--log "dirvish: installed kitty-image dispatcher")))

(defun kitty-graphics--uninstall-dirvish ()
  "Remove kitty-graphics dirvish preview dispatcher."
  (when (boundp 'dirvish-preview-dispatchers)
    (setq dirvish-preview-dispatchers
          (delq 'kitty-image dirvish-preview-dispatchers)))
  (when (boundp 'dirvish--available-preview-dispatchers)
    (setq dirvish--available-preview-dispatchers
          (assq-delete-all 'kitty-image dirvish--available-preview-dispatchers)))
  (fmakunbound 'dirvish-kitty-image-dp))

;;;; markdown-overlays integration (agent-shell)

(defun kitty-graphics--markdown-overlays-fontify-image-advice (orig-fn start end url-start url-end)
  "Around advice for `markdown-overlays--fontify-image'.
Displays markdown images ![alt](url) via Kitty graphics in terminal.
Falls back to ORIG-FN in GUI."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when-let* ((url (buffer-substring-no-properties url-start url-end))
                  (path (markdown-overlays--resolve-image-url url))
                  ((file-exists-p path))
                  ((kitty-graphics--image-file-p path)))
        (kitty-graphics--log "markdown-overlays-image: %s" path)
        (condition-case err
            (kitty-graphics-display-image
             path start end
             kitty-graphics-max-width kitty-graphics-max-height)
          (error
           (kitty-graphics--log "markdown-overlays-image error: %s" (error-message-string err)))))
    (funcall orig-fn start end url-start url-end)))

(defun kitty-graphics--markdown-overlays-fontify-image-file-path-advice (orig-fn start end path-start path-end)
  "Around advice for `markdown-overlays--fontify-image-file-path'.
Displays bare image file paths via Kitty graphics in terminal.
Falls back to ORIG-FN in GUI."
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      (when-let* ((raw (buffer-substring-no-properties path-start path-end))
                  (path (markdown-overlays--resolve-image-url raw))
                  ((file-exists-p path))
                  ((kitty-graphics--image-file-p path)))
        (kitty-graphics--log "markdown-overlays-path: %s" path)
        (condition-case err
            (kitty-graphics-display-image
             path start end
             kitty-graphics-max-width kitty-graphics-max-height)
          (error
           (kitty-graphics--log "markdown-overlays-path error: %s" (error-message-string err)))))
    (funcall orig-fn start end path-start path-end)))

;;;; mpv video integration

(defun kitty-graphics--mpv-vo-sixel-p ()
  "Return non-nil when the mpv binary was built with the sixel video output.
Runs `mpv --vo=help' once per session and caches the result in
`kitty-graphics--mpv-vo-sixel-cache'; vo_sixel is only compiled in when
mpv was built against libsixel."
  (when (eq kitty-graphics--mpv-vo-sixel-cache 'unknown)
    (setq kitty-graphics--mpv-vo-sixel-cache
          (let ((mpv (executable-find "mpv")))
            (and mpv
                 (with-temp-buffer
                   (ignore-errors (call-process mpv nil t nil "--vo=help"))
                   (goto-char (point-min))
                   (and (re-search-forward "^  sixel" nil t) t))))))
  kitty-graphics--mpv-vo-sixel-cache)

(defun kitty-graphics--mpv-backend ()
  "Return the graphics backend for the terminal mpv would play on.
Reads the per-terminal backend parameter for the target terminal
and falls back to the global `kitty-graphics--active-backend', the same
resolution `kitty-graphics--with-terminal' applies."
  (or (kitty-graphics--tparam 'kitty-graphics-backend) kitty-graphics--active-backend))

(defun kitty-graphics--mpv-backend-vo ()
  "Return the mpv video output name for the active backend, or nil.
The Kitty backend plays through vo_kitty; the Sixel backend plays
through vo_sixel when the mpv binary has it (`kitty-graphics--mpv-vo-sixel-p').
nil means the active backend has no usable mpv video output."
  (pcase (kitty-graphics--mpv-backend)
    ('kitty "kitty")
    ('sixel (and (kitty-graphics--mpv-vo-sixel-p) "sixel"))))

(defun kitty-graphics--mpv-available-p ()
  "Return non-nil if mpv video playback is available.
Available on the Kitty backend, and on the Sixel backend when mpv was
built with libsixel.  Unavailable inside tmux: mpv's raw frame stream
is forwarded verbatim and bypasses the tmux passthrough wrapper, so
tmux would eat every frame."
  (and kitty-graphics-enable-video
       kitty-graphics-mode
       (not (display-graphic-p))
       (not (kitty-graphics--frame-getenv "TMUX"))
       (executable-find "mpv")
       (kitty-graphics--mpv-backend-vo)
       t))

(defun kitty-graphics--mpv-unavailable-reason ()
  "Return a user-facing string explaining why mpv playback is unavailable.
Returns nil when mpv playback is available."
  (cond
   ((not kitty-graphics-enable-video)
    "kitty-graphics-enable-video is nil (set it to t to enable mpv)")
   ((not kitty-graphics-mode)
    "kitty-graphics-mode is disabled")
   ((display-graphic-p)
    "running in GUI Emacs (inline mpv is a terminal feature)")
   ((kitty-graphics--frame-getenv "TMUX")
    "running inside tmux (mpv's raw frame stream bypasses the tmux passthrough wrapper)")
   ((not (memq (kitty-graphics--mpv-backend) '(kitty sixel)))
    "no Kitty or Sixel backend active")
   ((not (executable-find "mpv"))
    "mpv executable not found on PATH")
   ((not (kitty-graphics--mpv-backend-vo))
    "mpv was built without libsixel so it has no --vo=sixel; on Nix use an mpv built with sixel support, e.g. wrapMpv (mpv-unwrapped.override { sixelSupport = true; }) { }")))

(defun kitty-graphics--mpv-ipc-send (command)
  "Send COMMAND (a list) to mpv via JSON IPC.
COMMAND is encoded as {\"command\": COMMAND}."
  (when (and kitty-graphics--mpv-ipc-connection
             (process-live-p kitty-graphics--mpv-ipc-connection))
    ;; `json' is not autoloaded; require here so callers don't have to.
    ;; Use the built-in `json-serialize' (Emacs 27+, C-coded) when
    ;; available -- it's faster and needs no library load.
    (let ((json (concat
                 (if (fboundp 'json-serialize)
                     (json-serialize `(:command ,(vconcat command)))
                   (require 'json)
                   (json-encode `(("command" . ,command))))
                 "\n")))
      (condition-case err
          (process-send-string kitty-graphics--mpv-ipc-connection json)
        (error
         (kitty-graphics--log "mpv-ipc-send error: %s" (error-message-string err)))))))

(defun kitty-graphics--mpv-ipc-connect (socket-path buffer)
  "Poll for SOCKET-PATH existence, then connect and store the process in BUFFER.
Polls every 50ms, times out after 2 seconds.  The poll timer is stored
buffer-locally in BUFFER so `kitty-graphics--mpv-cleanup' can cancel it, and
polling stops on its own when BUFFER no longer records SOCKET-PATH as
its mpv IPC socket (the session was torn down or replaced)."
  (let ((attempts 0)
        (max-attempts 40))
    (cl-labels
        ((session-live-p ()
           (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (equal kitty-graphics--mpv-ipc-socket socket-path))))
         (retry ()
           (cl-incf attempts)
           (if (>= attempts max-attempts)
               (progn
                 (kitty-graphics--log "mpv: IPC socket timeout after 2s")
                 (message "kitty-graphics: mpv IPC connection timed out"))
             (let ((timer (run-at-time 0.05 nil #'try-connect)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq kitty-graphics--mpv-ipc-timer timer))))))
         (try-connect ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq kitty-graphics--mpv-ipc-timer nil)))
           (cond
            ((not (session-live-p))
             (kitty-graphics--log "mpv: IPC poll abandoned, session gone (%s)"
                             socket-path))
            ((file-exists-p socket-path)
             (condition-case err
                 (let ((proc (make-network-process
                              :name "kitty-graphics-mpv-ipc"
                              :family 'local
                              :service socket-path
                              :buffer nil
                              :noquery t
                              :filter (lambda (_proc output)
                                        (kitty-graphics--log "mpv-ipc: %s" output)))))
                   (with-current-buffer buffer
                     (setq kitty-graphics--mpv-ipc-connection proc))
                   (kitty-graphics--log "mpv: IPC connected to %s" socket-path))
               (error
                (kitty-graphics--log "mpv: IPC connect failed: %s" (error-message-string err))
                (retry))))
            (t (retry)))))
      (try-connect))))

(defun kitty-graphics--mpv-compute-geometry ()
  "Compute video geometry as (COL ROW WIDTH-PX HEIGHT-PX COLS ROWS).
Uses the selected window dimensions and cell pixel size."
  (kitty-graphics--query-cell-size)
  (let* ((cw (or kitty-graphics--cell-pixel-width 8))
         (ch (or kitty-graphics--cell-pixel-height 16))
         (max-cols (min (- (window-body-width) 2) kitty-graphics-max-width))
         (max-rows (min (- (window-body-height) 4) kitty-graphics-max-height))
         ;; 16:9 aspect ratio, fit within max bounds
         (video-cols max-cols)
         (video-rows (min max-rows (max 10 (/ (* video-cols 9) 16))))
         (width-px (* video-cols cw))
         (height-px (* video-rows ch)))
    (list 1 1 width-px height-px video-cols video-rows)))

(defun kitty-graphics--mpv-overlay-position (win)
  "Return (ROW . COL) terminal position of the mpv overlay in WIN, or nil.
ROW and COL are 1-based terminal cell coordinates.  Returns nil when
the overlay is not visible in WIN or when a minibuffer is currently
active -- during minibuffer activation the source window is in a
transient state and `posn-at-point' tends to return origin
coordinates that would yank the video to (1,1)."
  (when (and kitty-graphics--mpv-overlay
             (overlay-buffer kitty-graphics--mpv-overlay)
             win
             (not (active-minibuffer-window)))
    (let* ((ov kitty-graphics--mpv-overlay)
           (start (overlay-start ov)))
      (when (and (eq (window-buffer win) (overlay-buffer ov))
                 (pos-visible-in-window-p start win))
        ;; In terminal Emacs, `window-edges' already returns character
        ;; cell coordinates; the pixelwise flag is a no-op on TTY frames.
        (let* ((win-edges (window-edges win nil nil nil))
               (win-top (nth 1 win-edges))
               (win-left (nth 0 win-edges))
               (posn (posn-at-point start win)))
          (when posn
            (let* ((coords (posn-col-row posn))
                   (col (+ win-left (car coords) 1))
                   (row (+ win-top (cdr coords) 1)))
              (cons row col))))))))

(defun kitty-graphics--mpv-canonical-window ()
  "Return the window that should drive mpv IPC repositioning, or nil.
Prefers `selected-window' when it shows the mpv overlay's buffer,
otherwise the first visible window displaying that buffer."
  (when (and kitty-graphics--mpv-overlay
             (overlay-buffer kitty-graphics--mpv-overlay))
    (let* ((buf (overlay-buffer kitty-graphics--mpv-overlay))
           (term kitty-graphics--mpv-terminal)
           ;; Only windows on the launching terminal count: mpv paints there
           ;; alone, so a copy of the buffer on another client must not pull
           ;; the video to that client's coordinates.
           (on-term (lambda (w)
                      (and (window-live-p w)
                           (or (null term)
                               (eq (frame-terminal (window-frame w)) term)))))
           (sel (selected-window)))
      (if (and (funcall on-term sel) (eq (window-buffer sel) buf))
          sel
        (seq-find on-term (get-buffer-window-list buf nil 'visible))))))

(defun kitty-graphics--refresh-mpv-overlay ()
  "Update mpv position if the overlay has moved.
Uses the per-window placement record on the mpv overlay (same
`kitty-graphics-placements' alist used by image overlays) as the source
of truth, with the canonical window from
`kitty-graphics--mpv-canonical-window'.  No IPC is sent while a
minibuffer is active so M-x / vertico / helm prompts do not yank
the video to the top of the screen."
  (when (and kitty-graphics--mpv-process
             (process-live-p kitty-graphics--mpv-process)
             kitty-graphics--mpv-overlay)
    (cond
     ;; Bug fix: hold position while a minibuffer prompt is up.
     ((active-minibuffer-window)
      (kitty-graphics--log "mpv: minibuffer active, holding position"))
     (t
      (let ((win (kitty-graphics--mpv-canonical-window)))
        (if (not win)
            ;; Overlay not visible in any window — auto-pause mpv to
            ;; stop audio + frame work, but keep the placement record
            ;; so we can re-emit cleanly when the buffer returns.
            (progn
              (when kitty-graphics--mpv-last-row
                (kitty-graphics--log "mpv: overlay hidden")
                (setq kitty-graphics--mpv-last-row nil
                      kitty-graphics--mpv-last-col nil))
              (unless (or kitty-graphics--mpv-paused kitty-graphics--mpv-auto-paused)
                (kitty-graphics--log "mpv: auto-paused (buffer hidden)")
                (setq kitty-graphics--mpv-auto-paused t)
                (kitty-graphics--mpv-ipc-send
                 (list "set_property" "pause" t))))
          ;; Visible again — if we auto-paused earlier, resume now.
          ;; A user-driven pause (`kitty-graphics--mpv-paused') is preserved.
          (when (and kitty-graphics--mpv-auto-paused
                     (not kitty-graphics--mpv-paused))
            (kitty-graphics--log "mpv: auto-resumed")
            (setq kitty-graphics--mpv-auto-paused nil)
            (kitty-graphics--mpv-ipc-send
             (list "set_property" "pause" :false)))
          (let ((pos (kitty-graphics--mpv-overlay-position win))
                (ov kitty-graphics--mpv-overlay))
            (when pos
              (let* ((row (car pos))
                     (col (cdr pos))
                     (record (kitty-graphics--image-placement ov win))
                     (rec-data (cdr record))
                     (rec-row (and rec-data (plist-get rec-data :row)))
                     (rec-col (and rec-data (plist-get rec-data :col))))
                (cond
                 ;; Already recorded at the same coordinates -- nothing to do.
                 ((and rec-row (eql row rec-row) (eql col rec-col)))
                 ;; Belt-and-suspenders guard for any other transient-window
                 ;; mishap: drop the update if a non-origin record exists
                 ;; and the freshly computed pos is (1, 1).
                 ((and rec-row (not (and (eql rec-row 1) (eql rec-col 1)))
                       (eql row 1) (eql col 1))
                  (kitty-graphics--log "mpv: ignoring suspicious origin reposition"))
                 (t
                  (kitty-graphics--log "mpv: reposition to row=%d col=%d" row col)
                  (let ((vo (or kitty-graphics--mpv-vo "kitty")))
                    (kitty-graphics--mpv-ipc-send
                     (list "set_property" (format "vo-%s-top" vo) row))
                    (kitty-graphics--mpv-ipc-send
                     (list "set_property" (format "vo-%s-left" vo) col)))
                  (kitty-graphics--record-image-placement ov win row col 0 0 0)
                  (setq kitty-graphics--mpv-last-row row
                        kitty-graphics--mpv-last-col col))))))))))))

(defun kitty-graphics--mpv-process-sentinel (proc event)
  "Handle mpv process state changes.
PROC is the mpv process, EVENT describes the state change."
  (kitty-graphics--log "mpv: process event: %s" (string-trim event))
  (when (memq (process-status proc) '(exit signal))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (eq kitty-graphics--mpv-process proc)
          (kitty-graphics--mpv-cleanup))))))

(defun kitty-graphics--mpv-cleanup ()
  "Clean up mpv state in the current buffer."
  (when kitty-graphics--mpv-ipc-timer
    (cancel-timer kitty-graphics--mpv-ipc-timer)
    (setq kitty-graphics--mpv-ipc-timer nil))
  (when kitty-graphics--mpv-ipc-connection
    (ignore-errors (delete-process kitty-graphics--mpv-ipc-connection))
    (setq kitty-graphics--mpv-ipc-connection nil))
  (when kitty-graphics--mpv-process
    (when (process-live-p kitty-graphics--mpv-process)
      (ignore-errors (kill-process kitty-graphics--mpv-process)))
    (setq kitty-graphics--mpv-process nil))
  (when kitty-graphics--mpv-ipc-socket
    (ignore-errors (delete-file kitty-graphics--mpv-ipc-socket))
    (setq kitty-graphics--mpv-ipc-socket nil))
  (when (and (equal kitty-graphics--mpv-vo "sixel")
             kitty-graphics--mpv-overlay
             kitty-graphics--mpv-last-row
             kitty-graphics--mpv-last-col)
    (let ((cols (overlay-get kitty-graphics--mpv-overlay 'kitty-graphics-cols))
          (rows (overlay-get kitty-graphics--mpv-overlay 'kitty-graphics-rows)))
      (when (and cols rows)
        (ignore-errors
          (send-string-to-terminal
           (kitty-graphics--blank-rect-string
            kitty-graphics--mpv-last-row kitty-graphics--mpv-last-col cols rows)
           kitty-graphics--mpv-terminal)))))
  (when kitty-graphics--mpv-overlay
    ;; Drop the per-window placement records before deleting the
    ;; overlay, mirroring image-overlay cleanup.
    (let* ((ov kitty-graphics--mpv-overlay)
           (buf (overlay-buffer ov))
           (beg (overlay-get ov 'kitty-graphics-inserted-beg))
           (end (overlay-get ov 'kitty-graphics-inserted-end)))
      (overlay-put ov 'kitty-graphics-placements nil)
      (ignore-errors (delete-overlay ov))
      (when (and (buffer-live-p buf)
                 (markerp beg) (markerp end)
                 (eq (marker-buffer beg) buf)
                 (eq (marker-buffer end) buf)
                 (< beg end))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (ignore-errors (delete-region beg end)))))
      (when (markerp beg) (set-marker beg nil))
      (when (markerp end) (set-marker end nil)))
    (setq kitty-graphics--mpv-overlay nil))
  (setq kitty-graphics--mpv-last-row nil
        kitty-graphics--mpv-last-col nil
        kitty-graphics--mpv-paused nil
        kitty-graphics--mpv-auto-paused nil
        kitty-graphics--mpv-vo nil)
  ;; mpv's kitty VO may hide the cursor; restore it on the terminal that
  ;; played the video.  Also force a full redisplay so Emacs repaints the
  ;; region mpv was occupying.
  (ignore-errors (send-string-to-terminal "\e[?25h" kitty-graphics--mpv-terminal))
  (setq kitty-graphics--mpv-terminal nil)
  (force-mode-line-update t)
  (when (fboundp 'redraw-display) (redraw-display)))

(defun kitty-graphics--mpv-vo-args (vo col row width-px height-px video-cols video-rows)
  "Return the mpv argument list selecting and configuring video output VO.
VO is \"kitty\" or \"sixel\".  COL and ROW are the 1-based terminal
cell coordinates of the video's top-left corner, WIDTH-PX and
HEIGHT-PX its pixel bounds, VIDEO-COLS and VIDEO-ROWS its size in
cells.  vo_kitty sends frames via shared memory rather than base64
inside APC escapes -- orders of magnitude less data through the pty
filter.  vo_sixel maps `kitty-graphics-sixel-dither' onto mpv's libsixel
dither names and a non-default `kitty-graphics-sixel-colors' onto
--vo-sixel-reqcolors (with the fixed palette disabled, which
reqcolors requires to take effect)."
  (pcase vo
    ("kitty"
     (list "--vo=kitty"
           "--vo-kitty-use-shm=yes"
           (format "--vo-kitty-cols=%d" video-cols)
           (format "--vo-kitty-rows=%d" video-rows)
           (format "--vo-kitty-width=%d" width-px)
           (format "--vo-kitty-height=%d" height-px)
           (format "--vo-kitty-left=%d" col)
           (format "--vo-kitty-top=%d" row)
           "--vo-kitty-config-clear=no"
           "--vo-kitty-alt-screen=no"))
    ("sixel"
     (append
      (list "--vo=sixel"
            (format "--vo-sixel-cols=%d" video-cols)
            (format "--vo-sixel-rows=%d" video-rows)
            (format "--vo-sixel-width=%d" width-px)
            (format "--vo-sixel-height=%d" height-px)
            (format "--vo-sixel-left=%d" col)
            (format "--vo-sixel-top=%d" row)
            "--vo-sixel-config-clear=no"
            "--vo-sixel-alt-screen=no")
      (when kitty-graphics-sixel-dither
        (list (format "--vo-sixel-dither=%s" kitty-graphics-sixel-dither)))
      (when (and kitty-graphics-sixel-colors (/= kitty-graphics-sixel-colors 256))
        (list "--vo-sixel-fixedpalette=no"
              (format "--vo-sixel-reqcolors=%d" kitty-graphics-sixel-colors)))))))

;;;###autoload
(defun kitty-graphics-play-video (file)
  "Play video FILE inline in the current buffer via mpv.
Requires `kitty-graphics-enable-video' to be non-nil and mpv installed.
Plays through vo_kitty on the Kitty backend and vo_sixel on the
Sixel backend (mpv built with libsixel)."
  (interactive "fVideo file: ")
  (unless kitty-graphics-enable-video
    (user-error "Video playback disabled; set kitty-graphics-enable-video to t"))
  (when-let* ((reason (kitty-graphics--mpv-unavailable-reason)))
    (user-error "kitty-graphics: cannot play video: %s" reason))
  ;; Stop any existing video in this buffer
  (when kitty-graphics--mpv-process
    (kitty-graphics--mpv-cleanup))
  (let* ((file (expand-file-name file))
         (vo (kitty-graphics--mpv-backend-vo))
         (geom (kitty-graphics--mpv-compute-geometry))
         (col (nth 0 geom))
         (row (nth 1 geom))
         (width-px (nth 2 geom))
         (height-px (nth 3 geom))
         (video-cols (nth 4 geom))
         (video-rows (nth 5 geom))
         (socket (make-temp-name (expand-file-name "kitty-graphics-mpv-" temporary-file-directory)))
         (socket-path (concat socket ".sock")))
    ;; Create overlay to reserve space
    (let* ((start (point))
           (inhibit-read-only t))
      ;; Insert blank lines for the overlay to cover
      (insert (make-string video-rows ?\n))
      (let ((end (point)))
        (setq kitty-graphics--mpv-overlay
              (make-overlay start end nil t nil))
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics t)
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics-mpv t)
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics-cols video-cols)
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics-rows video-rows)
        (overlay-put kitty-graphics--mpv-overlay 'evaporate t)
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics-inserted-beg
                     (copy-marker start))
        (overlay-put kitty-graphics--mpv-overlay 'kitty-graphics-inserted-end
                     (copy-marker end t))
        ;; Local bindings on the video region: SPC toggles, q stops + back.
        (overlay-put kitty-graphics--mpv-overlay 'keymap
                     kitty-graphics-video-overlay-map)
        (goto-char start)))
    ;; Compute initial terminal position and seed the per-window
    ;; placement record so the first refresh after IPC connect does
    ;; not re-emit identical coordinates.
    (let* ((win (selected-window))
           (pos (kitty-graphics--mpv-overlay-position win)))
      (when pos
        (setq row (car pos) col (cdr pos))
        (kitty-graphics--record-image-placement
         kitty-graphics--mpv-overlay win row col 0 0 0)
        (setq kitty-graphics--mpv-last-row row
              kitty-graphics--mpv-last-col col)))
    ;; Store socket path
    (setq kitty-graphics--mpv-ipc-socket socket-path)
    ;; Spawn mpv on a pty so its VO escape stream can be captured.
    ;; mpv writes graphics sequences (APC for kitty, DCS for sixel) to
    ;; stdout; we forward each chunk to the Emacs controlling terminal
    ;; via `send-string-to-terminal'.
    (let* ((process-connection-type t) ; pty so mpv sees a tty for VO
           (proc (make-process
                  :name "kitty-graphics-mpv"
                  :buffer nil
                  :noquery t
                  :connection-type 'pty
                  :coding '(binary . binary)
                  :command
                  (append
                   (list "mpv"
                         ;; Ignore user's mpv.conf and scripts: keeps
                         ;; embed playback predictable and avoids loading
                         ;; heavy scripts (thumbfast, uosc, mpris, …) that
                         ;; spike CPU and pollute IPC with `client-message'
                         ;; events.
                         ;;
                         ;; Three flags are needed for distro builds that
                         ;; wrap mpv with prepended `--script=…' args (Nix
                         ;; `mpv-with-scripts', some Flatpaks):
                         ;;   --no-config        skip mpv.conf
                         ;;   --load-scripts=no  skip auto-discovered scripts
                         ;;   --scripts-clr      clear the list option, so
                         ;;                      wrapper-injected `--script='
                         ;;                      entries are dropped too
                         ;;                      (explicit `--script=' loads
                         ;;                      regardless of `--load-scripts').
                         "--no-config"
                         "--load-scripts=no"
                         "--scripts-clr"
                         ;; Hardware-decode to keep CPU down.
                         "--hwdec=auto-safe")
                   (kitty-graphics--mpv-vo-args vo col row width-px height-px
                                           video-cols video-rows)
                   (list "--really-quiet"
                         "--no-input-terminal"
                         (format "--input-ipc-server=%s" socket-path)
                         file))
                  :filter #'kitty-graphics--mpv-filter
                  :sentinel #'kitty-graphics--mpv-process-sentinel)))
      (setq kitty-graphics--mpv-process proc)
      (setq kitty-graphics--mpv-vo vo)
      ;; Bind playback to the launching terminal: the filter forwards mpv's
      ;; VO bytes only there, so other daemon clients are not painted over.
      (setq kitty-graphics--mpv-terminal (frame-terminal (selected-frame)))
      (process-put proc 'kitty-graphics-terminal kitty-graphics--mpv-terminal)
      (kitty-graphics--log "mpv: started pid=%s file=%s" (process-id proc) file)
      ;; Connect IPC after mpv creates the socket
      (kitty-graphics--mpv-ipc-connect socket-path (current-buffer)))))

(define-obsolete-function-alias 'kitty-gfx-play-video 'kitty-graphics-play-video "1.3.0")

(defun kitty-graphics--mpv-filter (proc chunk)
  "Forward mpv/casty stdout CHUNK to the terminal PROC was launched on.
mpv with `--vo=kitty' (and casty in embed mode) emit APC graphics escapes
to stdout; mpv with `--vo=sixel' emits raw DCS sixel frames instead.
When spawned as a subprocess of Emacs, those bytes land here.
Writing them back out with `send-string-to-terminal' makes the terminal
paint the frames inline.  The target terminal is the one recorded on PROC
at launch, so under a daemon only the launching client is painted; nil
falls back to the selected terminal for the single-client case.
Chunks are dropped while the process carries the `kitty-graphics-suppress'
flag, set by `kitty-graphics--refresh-browser-overlay' while no window shows
the browser buffer."
  (when (and chunk (> (length chunk) 0)
             (not (process-get proc 'kitty-graphics-suppress)))
    (condition-case err
        (send-string-to-terminal chunk (process-get proc 'kitty-graphics-terminal))
      (error
       (kitty-graphics--log "mpv-filter error: %s" (error-message-string err))))))

(defun kitty-graphics--mpv-buffer ()
  "Return the buffer currently hosting an mpv playback, or nil.
Prefers the current buffer when it owns an mpv process; otherwise
walks `buffer-list' for the first buffer with a live mpv process."
  (if (and kitty-graphics--mpv-process (process-live-p kitty-graphics--mpv-process))
      (current-buffer)
    (cl-loop for b in (buffer-list)
             when (buffer-local-value 'kitty-graphics--mpv-process b)
             when (process-live-p (buffer-local-value 'kitty-graphics--mpv-process b))
             return b)))

(defun kitty-graphics-stop-video ()
  "Stop inline video playback.
Acts on the current buffer's video when present, otherwise on
whichever buffer currently owns a live mpv process so the command
works from M-x regardless of which buffer the user is in."
  (interactive)
  (let ((buf (kitty-graphics--mpv-buffer)))
    (if buf
        (with-current-buffer buf
          (kitty-graphics--mpv-cleanup)
          (message "kitty-graphics: video stopped (buffer %s)" (buffer-name buf)))
      (message "kitty-graphics: no video playing"))))

(define-obsolete-function-alias 'kitty-gfx-stop-video 'kitty-graphics-stop-video "1.3.0")

(defun kitty-graphics-stop-video-and-back ()
  "Stop inline video playback and switch to the previously shown buffer."
  (interactive)
  (kitty-graphics-stop-video)
  (previous-buffer))

(define-obsolete-function-alias 'kitty-gfx-stop-video-and-back 'kitty-graphics-stop-video-and-back "1.3.0")

(defun kitty-graphics-video-help ()
  "Echo the inline-video keymap to the minibuffer."
  (interactive)
  (message "SPC pause/resume  q stop+back  ? help"))

(define-obsolete-function-alias 'kitty-gfx-video-help 'kitty-graphics-video-help "1.3.0")

(defun kitty-graphics--mpv-set-paused-mark (paused)
  "Set the visible pause indicator on the mpv overlay.
PAUSED non-nil shows \" \\u23F8\" as a `before-string'; nil clears."
  (when kitty-graphics--mpv-overlay
    (overlay-put kitty-graphics--mpv-overlay
                 'before-string
                 (when paused
                   (propertize " \u23F8 " 'face 'mode-line-emphasis)))))

(defun kitty-graphics-toggle-video ()
  "Toggle pause/resume of inline video playback.
Acts on the current buffer's video when present, otherwise on
whichever buffer currently owns a live mpv process."
  (interactive)
  (let ((buf (kitty-graphics--mpv-buffer)))
    (if buf
        (with-current-buffer buf
          (setq kitty-graphics--mpv-paused (not kitty-graphics--mpv-paused)
                ;; User-driven pause overrides any auto-pause: clear
                ;; the auto flag so we don't re-resume against the
                ;; user's wishes when the buffer is shown again.
                kitty-graphics--mpv-auto-paused nil)
          (kitty-graphics--mpv-ipc-send
           (list "set_property" "pause"
                 (if kitty-graphics--mpv-paused t :false)))
          (kitty-graphics--mpv-set-paused-mark kitty-graphics--mpv-paused)
          (kitty-graphics--log "mpv: %s (buffer %s)"
                          (if kitty-graphics--mpv-paused "paused" "resumed")
                          (buffer-name))
          (message "kitty-graphics: video %s"
                   (if kitty-graphics--mpv-paused "paused" "resumed")))
      (message "kitty-graphics: no video playing"))))

(define-obsolete-function-alias 'kitty-gfx-toggle-video 'kitty-graphics-toggle-video "1.3.0")

;;;; casty browser integration

(defun kitty-graphics--browser-available-p ()
  "Return non-nil if the inline casty browser is available.
Unavailable inside tmux: casty's raw Kitty frame stream is forwarded
verbatim and bypasses the tmux passthrough wrapper, so tmux would eat
every frame."
  (and kitty-graphics-enable-browser
       kitty-graphics-mode
       (not (display-graphic-p))
       (not (kitty-graphics--frame-getenv "TMUX"))
       (eq kitty-graphics--active-backend 'kitty)
       (executable-find kitty-graphics-casty-program)))

(defun kitty-graphics--browser-unavailable-reason ()
  "Return a user-facing string explaining why the browser is unavailable."
  (cond
   ((not kitty-graphics-enable-browser)
    "kitty-graphics-enable-browser is nil (set it to t to enable)")
   ((not kitty-graphics-mode)
    "kitty-graphics-mode is disabled")
   ((display-graphic-p)
    "running in GUI Emacs (the inline browser is a terminal feature)")
   ((kitty-graphics--frame-getenv "TMUX")
    "running inside tmux (casty's raw frame stream bypasses the tmux passthrough wrapper)")
   ((not (eq kitty-graphics--active-backend 'kitty))
    "Kitty backend not active")
   ((not (executable-find kitty-graphics-casty-program))
    (format "casty program %S not found on PATH" kitty-graphics-casty-program))))

(defun kitty-graphics--browser-send (plist)
  "Send PLIST as a newline-terminated JSON command to this buffer's casty.
PLIST uses keyword keys, e.g. (:cmd \"scroll\" :dy 300)."
  (let ((conn kitty-graphics--browser-ipc-connection))
    (when (and conn (process-live-p conn))
      (condition-case err
          (process-send-string conn (concat (json-serialize plist) "\n"))
        (error
         (kitty-graphics--log "browser-ipc-send error: %s" (error-message-string err)))))))

(defun kitty-graphics--browser-ipc-filter (proc output)
  "Parse casty IPC replies (OUTPUT) for PROC.
Replies are newline-delimited JSON.  Partial lines are buffered on the
process.  A reply with `hintActive' false clears the owning buffer's
`kitty-graphics--browser-hint-active' flag, which ends the hint transient map."
  (kitty-graphics--log "browser-ipc: %s" (string-trim output))
  (let* ((buf (concat (or (process-get proc 'kitty-graphics-ipc-buf) "") output))
         (lines (split-string buf "\n")))
    ;; Last element is the (possibly empty) trailing partial line.
    (process-put proc 'kitty-graphics-ipc-buf (car (last lines)))
    (dolist (line (butlast lines))
      (when (> (length (string-trim line)) 0)
        (let ((obj (ignore-errors
                     (json-parse-string line :object-type 'plist
                                        :false-object nil :null-object nil))))
          (when (and obj (plist-member obj :hintActive)
                     (not (plist-get obj :hintActive)))
            (let ((owner (process-get proc 'kitty-graphics-buffer)))
              (when (buffer-live-p owner)
                (with-current-buffer owner
                  (setq kitty-graphics--browser-hint-active nil))))))))))

(defun kitty-graphics--browser-ipc-connect (socket-path buffer)
  "Poll for SOCKET-PATH, then connect and store the process in BUFFER.
Polls every 50ms, times out after 2 seconds (mirrors the mpv path).
The poll timer is stored buffer-locally in BUFFER so
`kitty-graphics--browser-cleanup' can cancel it, and polling stops on its
own when BUFFER no longer records SOCKET-PATH as its casty socket."
  (let ((attempts 0)
        (max-attempts 40))
    (cl-labels
        ((session-live-p ()
           (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (equal kitty-graphics--browser-ipc-socket socket-path))))
         (retry ()
           (cl-incf attempts)
           (if (>= attempts max-attempts)
               (progn
                 (kitty-graphics--log "browser: IPC socket timeout after 2s")
                 (message "kitty-graphics: casty IPC connection timed out"))
             (let ((timer (run-at-time 0.05 nil #'try-connect)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq kitty-graphics--browser-ipc-timer timer))))))
         (try-connect ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq kitty-graphics--browser-ipc-timer nil)))
           (cond
            ((not (session-live-p))
             (kitty-graphics--log "browser: IPC poll abandoned, session gone (%s)"
                             socket-path))
            ((file-exists-p socket-path)
             (condition-case err
                 (let ((proc (make-network-process
                              :name "kitty-graphics-browser-ipc"
                              :family 'local
                              :service socket-path
                              :buffer nil
                              :noquery t
                              :filter #'kitty-graphics--browser-ipc-filter)))
                   (process-put proc 'kitty-graphics-buffer buffer)
                   (with-current-buffer buffer
                     (setq kitty-graphics--browser-ipc-connection proc))
                   (kitty-graphics--log "browser: IPC connected to %s" socket-path))
               (error
                (kitty-graphics--log "browser: IPC connect failed: %s" (error-message-string err))
                (retry))))
            (t (retry)))))
      (try-connect))))

(defun kitty-graphics--browser-compute-geometry ()
  "Compute browser geometry as (COLS ROWS WIDTH-PX HEIGHT-PX).
Fills the selected window body, clamped to the configured maxima."
  (kitty-graphics--query-cell-size)
  (let* ((cw (or kitty-graphics--cell-pixel-width 8))
         (ch (or kitty-graphics--cell-pixel-height 16))
         (cols (max 1 (min (1- (window-body-width)) kitty-graphics-browser-max-width)))
         (rows (max 1 (min (1- (window-body-height)) kitty-graphics-browser-max-height))))
    (list cols rows (* cols cw) (* rows ch))))

(defun kitty-graphics--browser-overlay-position (win)
  "Return (ROW . COL) terminal position of the browser overlay in WIN, or nil.
ROW and COL are 1-based.  Returns nil when the overlay is not visible
in WIN or while a minibuffer is active (mirrors the mpv logic)."
  (when (and kitty-graphics--browser-overlay
             (overlay-buffer kitty-graphics--browser-overlay)
             win
             (not (active-minibuffer-window)))
    (let* ((ov kitty-graphics--browser-overlay)
           (start (overlay-start ov)))
      (when (and (eq (window-buffer win) (overlay-buffer ov))
                 (pos-visible-in-window-p start win))
        (let* ((win-edges (window-edges win nil nil nil))
               (win-top (nth 1 win-edges))
               (win-left (nth 0 win-edges))
               (posn (posn-at-point start win)))
          (when posn
            (let* ((coords (posn-col-row posn))
                   (col (+ win-left (car coords) 1))
                   (row (+ win-top (cdr coords) 1)))
              (cons row col))))))))

(defun kitty-graphics--browser-canonical-window ()
  "Return the window that should drive browser repositioning, or nil."
  (when (and kitty-graphics--browser-overlay
             (overlay-buffer kitty-graphics--browser-overlay))
    (let* ((buf (overlay-buffer kitty-graphics--browser-overlay))
           (sel (selected-window)))
      (if (and (window-live-p sel) (eq (window-buffer sel) buf))
          sel
        (car (get-buffer-window-list buf nil 'visible))))))

(defun kitty-graphics--refresh-browser-overlay ()
  "Send a `set-geometry' IPC command when the browser overlay has moved.
No IPC is sent while a minibuffer is active so prompts do not yank the
frame to the top of the screen.  When no window shows the browser
buffer, frame forwarding is suppressed (mirroring the mpv auto-pause):
a flag on the casty process makes `kitty-graphics--mpv-filter' drop frames,
and the on-screen image is deleted on the launch terminal so it does
not paint over unrelated content.  When a window shows the buffer
again the flag is cleared and the geometry is re-emitted, which makes
casty repaint the frame."
  (when (and kitty-graphics--browser-process
             (process-live-p kitty-graphics--browser-process)
             kitty-graphics--browser-overlay)
    (cond
     ((active-minibuffer-window)
      (kitty-graphics--log "browser: minibuffer active, holding position"))
     (t
      (let ((win (kitty-graphics--browser-canonical-window))
            (proc kitty-graphics--browser-process))
        (if (not win)
            (unless (process-get proc 'kitty-graphics-suppress)
              (kitty-graphics--log "browser: buffer hidden, suppressing frames")
              (process-put proc 'kitty-graphics-suppress t)
              (setq kitty-graphics--browser-last-row nil
                    kitty-graphics--browser-last-col nil)
              (when (and kitty-graphics--browser-image-id
                         (terminal-live-p kitty-graphics--browser-terminal))
                (kitty-graphics--with-terminal kitty-graphics--browser-terminal
                  (kitty-graphics--delete-by-id kitty-graphics--browser-image-id))))
          (when (process-get proc 'kitty-graphics-suppress)
            (kitty-graphics--log "browser: buffer visible again, resuming frames")
            (process-put proc 'kitty-graphics-suppress nil)
            (setq kitty-graphics--browser-last-row nil
                  kitty-graphics--browser-last-col nil))
          (let ((pos (kitty-graphics--browser-overlay-position win)))
            (when pos
              (let ((row (car pos))
                    (col (cdr pos)))
                (cond
                 ((and (eql row kitty-graphics--browser-last-row)
                       (eql col kitty-graphics--browser-last-col)))
                 ((and kitty-graphics--browser-last-row
                       (not (and (eql kitty-graphics--browser-last-row 1)
                                 (eql kitty-graphics--browser-last-col 1)))
                       (eql row 1) (eql col 1))
                  (kitty-graphics--log "browser: ignoring suspicious origin reposition"))
                 (t
                  (kitty-graphics--log "browser: reposition row=%d col=%d" row col)
                  (kitty-graphics--browser-send (list :cmd "set-geometry" :top row :left col))
                  (setq kitty-graphics--browser-last-row row
                        kitty-graphics--browser-last-col col))))))))))))

(defun kitty-graphics--browser-process-sentinel (proc event)
  "Clean up when the casty PROC exits.  EVENT describes the change."
  (kitty-graphics--log "browser: process event: %s" (string-trim event))
  (when (memq (process-status proc) '(exit signal))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (eq kitty-graphics--browser-process proc)
          (kitty-graphics--browser-cleanup))))))

(defun kitty-graphics--browser-cleanup ()
  "Tear down the casty browser in the current buffer.
Safe to call more than once."
  (when kitty-graphics--browser-ipc-timer
    (cancel-timer kitty-graphics--browser-ipc-timer)
    (setq kitty-graphics--browser-ipc-timer nil))
  (when kitty-graphics--browser-ipc-connection
    (ignore-errors (delete-process kitty-graphics--browser-ipc-connection))
    (setq kitty-graphics--browser-ipc-connection nil))
  (when kitty-graphics--browser-process
    (when (process-live-p kitty-graphics--browser-process)
      (ignore-errors (kill-process kitty-graphics--browser-process)))
    (setq kitty-graphics--browser-process nil))
  (when kitty-graphics--browser-ipc-socket
    (ignore-errors (delete-file kitty-graphics--browser-ipc-socket))
    (setq kitty-graphics--browser-ipc-socket nil))
  (let ((log (get-buffer "*kitty-casty-log*")))
    (when (and log
               (not (cl-some
                     (lambda (b)
                       (let ((p (buffer-local-value 'kitty-graphics--browser-process b)))
                         (and p (process-live-p p))))
                     (buffer-list))))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer log)))))
  ;; Free the kitty image casty was drawing into.
  (when kitty-graphics--browser-image-id
    (kitty-graphics--with-terminal (and (terminal-live-p kitty-graphics--browser-terminal)
                                   kitty-graphics--browser-terminal)
      (ignore-errors (kitty-graphics--delete-by-id kitty-graphics--browser-image-id)))
    (setq kitty-graphics--browser-image-id nil))
  (when kitty-graphics--browser-overlay
    (ignore-errors (delete-overlay kitty-graphics--browser-overlay))
    (setq kitty-graphics--browser-overlay nil))
  (setq kitty-graphics--browser-last-row nil
        kitty-graphics--browser-last-col nil)
  ;; Restore xterm-mouse-mode if we turned it on for this buffer.
  (when kitty-graphics--browser-xterm-mouse-was-off
    (setq kitty-graphics--browser-xterm-mouse-was-off nil)
    (when (bound-and-true-p xterm-mouse-mode)
      (xterm-mouse-mode -1)))
  ;; casty hid nothing in embed mode, but restore the cursor defensively on
  ;; the launching terminal and force a repaint of the region it occupied.
  (ignore-errors (send-string-to-terminal "\e[?25h" kitty-graphics--browser-terminal))
  (setq kitty-graphics--browser-terminal nil)
  (force-mode-line-update t)
  (when (fboundp 'redraw-display) (redraw-display)))

(defun kitty-graphics--stop-all-browsers ()
  "Tear down every live casty browser session across all buffers."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when kitty-graphics--browser-process
          (kitty-graphics--browser-cleanup))))))

(defun kitty-graphics--stop-terminal-processes (term)
  "Stop any mpv/casty playback launched on terminal TERM.
Called from `kitty-graphics--on-delete-terminal' so a disconnecting client
leaves no subprocess streaming Kitty frames to a dead tty."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and kitty-graphics--mpv-process
                   (eq kitty-graphics--mpv-terminal term))
          (kitty-graphics--mpv-cleanup))
        (when (and kitty-graphics--browser-process
                   (eq kitty-graphics--browser-terminal term))
          (kitty-graphics--browser-cleanup))))))

;;;###autoload
(defun kitty-graphics-browse (url)
  "Open URL in an inline casty browser buffer (`*kitty-browser*').
Requires `kitty-graphics-enable-browser' to be non-nil and casty installed."
  (interactive (list (read-string "URL: " "https://")))
  (unless (kitty-graphics--browser-available-p)
    (user-error "casty browser unavailable: %s" (kitty-graphics--browser-unavailable-reason)))
  (let ((buf (get-buffer-create "*kitty-browser*")))
    (switch-to-buffer buf)
    (unless (eq major-mode 'kitty-graphics-browser-mode)
      (kitty-graphics-browser-mode))
    ;; Replace any existing session in this buffer.
    (when kitty-graphics--browser-process
      (kitty-graphics--browser-cleanup))
    (let* ((geom (kitty-graphics--browser-compute-geometry))
           (cols (nth 0 geom))
           (rows (nth 1 geom))
           (width-px (nth 2 geom))
           (height-px (nth 3 geom))
           (id (kitty-graphics--alloc-id))
           (socket (concat (make-temp-name (expand-file-name "kitty-graphics-casty-" temporary-file-directory)) ".sock"))
           (inhibit-read-only t))
      (erase-buffer)
      (insert (make-string rows ?\n))
      (goto-char (point-min))
      (setq kitty-graphics--browser-image-id id
            kitty-graphics--browser-ipc-socket socket
            kitty-graphics--browser-cols cols
            kitty-graphics--browser-rows rows)
      (let ((ov (make-overlay (point-min) (point-max) nil t nil)))
        (overlay-put ov 'kitty-graphics t)
        (overlay-put ov 'kitty-graphics-browser t)
        (overlay-put ov 'kitty-graphics-id id)
        (overlay-put ov 'evaporate t)
        (setq kitty-graphics--browser-overlay ov))
      ;; Seed the initial terminal position so the first refresh after the
      ;; IPC connects does not re-emit identical coordinates.
      (let* ((win (selected-window))
             (pos (kitty-graphics--browser-overlay-position win)))
        (when pos
          (setq kitty-graphics--browser-last-row (car pos)
                kitty-graphics--browser-last-col (cdr pos))))
      (let* ((row (or kitty-graphics--browser-last-row 1))
             (col (or kitty-graphics--browser-last-col 1))
             (process-environment
              (append
               (list (format "CASTY_CELL_WIDTH=%d" (or kitty-graphics--cell-pixel-width 8))
                     (format "CASTY_CELL_HEIGHT=%d" (or kitty-graphics--cell-pixel-height 16)))
               ;; With debug on, ask casty to log each click's resolved CSS
               ;; pixel + the element under it to *kitty-casty-log* so a missed
               ;; click is visible (NONE) instead of a silent no-op.
               (when kitty-graphics-debug (list "CASTY_DEBUG=1"))
               ;; A configured browser means we also skip casty's
               ;; Chrome-Headless-Shell auto-install bootstrap.
               (when kitty-graphics-casty-chrome
                 (list (format "CASTY_CHROME=%s" kitty-graphics-casty-chrome)
                       "CASTY_ENSURE_CHROME=1"))
               process-environment))
             (proc (make-process
                    :name "kitty-graphics-casty"
                    :buffer nil
                    :noquery t
                    :connection-type 'pty
                    :coding '(binary . binary)
                    ;; Keep casty's stderr (status/error logs) OFF the pty so
                    ;; it is never forwarded into the kitty graphics stream and
                    ;; painted as garbage; route it to a debug buffer instead.
                    :stderr (get-buffer-create "*kitty-casty-log*")
                    :command
                    (list kitty-graphics-casty-program "--embed"
                          "--ipc" socket
                          "--image-id" (number-to-string id)
                          "--cols" (number-to-string cols)
                          "--rows" (number-to-string rows)
                          "--top" (number-to-string row)
                          "--left" (number-to-string col)
                          "--width" (number-to-string width-px)
                          "--height" (number-to-string height-px)
                          url)
                    :filter #'kitty-graphics--mpv-filter
                    :sentinel #'kitty-graphics--browser-process-sentinel)))
        (setq kitty-graphics--browser-process proc)
        ;; Bind the browser to its launching terminal (see mpv above).
        (setq kitty-graphics--browser-terminal (frame-terminal (selected-frame)))
        (process-put proc 'kitty-graphics-terminal kitty-graphics--browser-terminal)
        (kitty-graphics--log "browser: started pid=%s url=%s" (process-id proc) url)
        (kitty-graphics--browser-ipc-connect socket buf))
      (message "kitty-graphics: browsing %s" url))))

(define-obsolete-function-alias 'kitty-gfx-browse 'kitty-graphics-browse "1.3.0")

;; ── browser commands (bound in the mode map) ──

(defun kitty-graphics-browser-scroll-down ()
  "Scroll the browser page down."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "scroll" :dy kitty-graphics-browser-scroll-step)))

(define-obsolete-function-alias 'kitty-gfx-browser-scroll-down 'kitty-graphics-browser-scroll-down "1.3.0")

(defun kitty-graphics-browser-scroll-up ()
  "Scroll the browser page up."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "scroll" :dy (- kitty-graphics-browser-scroll-step))))

(define-obsolete-function-alias 'kitty-gfx-browser-scroll-up 'kitty-graphics-browser-scroll-up "1.3.0")

(defun kitty-graphics-browser-page-down ()
  "Scroll the browser one page down."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "key" :name "PageDown")))

(define-obsolete-function-alias 'kitty-gfx-browser-page-down 'kitty-graphics-browser-page-down "1.3.0")

(defun kitty-graphics-browser-page-up ()
  "Scroll the browser one page up."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "key" :name "PageUp")))

(define-obsolete-function-alias 'kitty-gfx-browser-page-up 'kitty-graphics-browser-page-up "1.3.0")

(defun kitty-graphics-browser-back ()
  "Go back in browser history."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "back")))

(define-obsolete-function-alias 'kitty-gfx-browser-back 'kitty-graphics-browser-back "1.3.0")

(defun kitty-graphics-browser-forward ()
  "Go forward in browser history."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "forward")))

(define-obsolete-function-alias 'kitty-gfx-browser-forward 'kitty-graphics-browser-forward "1.3.0")

(defun kitty-graphics-browser-reload ()
  "Reload the current browser page."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "reload")))

(define-obsolete-function-alias 'kitty-gfx-browser-reload 'kitty-graphics-browser-reload "1.3.0")

(defun kitty-graphics-browser-open-url (url)
  "Navigate the browser to URL."
  (interactive (list (read-string "URL: " "https://")))
  (kitty-graphics--browser-send (list :cmd "navigate" :url url)))

(define-obsolete-function-alias 'kitty-gfx-browser-open-url 'kitty-graphics-browser-open-url "1.3.0")

(defun kitty-graphics-browser-quit ()
  "Stop the browser and kill its buffer."
  (interactive)
  (kitty-graphics--browser-send (list :cmd "quit"))
  (let ((buf (current-buffer)))
    (kitty-graphics--browser-cleanup)
    (kill-buffer buf)))

(define-obsolete-function-alias 'kitty-gfx-browser-quit 'kitty-graphics-browser-quit "1.3.0")

;; ── link hints (Vimium-style, casty draws the labels) ──

(define-obsolete-variable-alias 'kitty-gfx-browser-hint-chars 'kitty-graphics-browser-hint-chars "1.3.0")

(defvar kitty-graphics-browser-hint-chars '(?a ?s ?d ?f ?j ?k ?l)
  "Label characters casty uses for link hints (casty `HINT_CHARS').")

(defun kitty-graphics--browser-hint-key ()
  "Forward the just-typed key to casty as a hint-mode keystroke."
  (interactive)
  (let ((e last-command-event))
    (kitty-graphics--browser-send
     (list :cmd "hint-key"
           :key (cond ((memq e '(?\d backspace)) "\x7f")
                      ((characterp e) (char-to-string e))
                      (t ""))))))

(defun kitty-graphics-browser-hint-abort ()
  "Cancel link-hint mode (tell casty to remove the labels)."
  (interactive)
  (setq kitty-graphics--browser-hint-active nil)
  (kitty-graphics--browser-send (list :cmd "hint-key" :key "\e")))

(define-obsolete-function-alias 'kitty-gfx-browser-hint-abort 'kitty-graphics-browser-hint-abort "1.3.0")

(defun kitty-graphics-browser-hints ()
  "Show Vimium-style link hints and follow the one whose label you type.
casty injects the labels into the page (they appear in the next frame);
subsequent label keystrokes are forwarded until a link is chosen or
`escape'/`C-g' cancels."
  (interactive)
  (setq kitty-graphics--browser-hint-active t)
  (kitty-graphics--browser-send (list :cmd "hints"))
  (let ((map (make-sparse-keymap)))
    (dolist (c kitty-graphics-browser-hint-chars)
      (define-key map (char-to-string c) #'kitty-graphics--browser-hint-key))
    (define-key map (kbd "DEL")      #'kitty-graphics--browser-hint-key)
    (define-key map (kbd "<escape>") #'kitty-graphics-browser-hint-abort)
    (define-key map (kbd "C-g")      #'kitty-graphics-browser-hint-abort)
    (set-transient-map map (lambda () kitty-graphics--browser-hint-active))))

(define-obsolete-function-alias 'kitty-gfx-browser-hints 'kitty-graphics-browser-hints "1.3.0")

(defun kitty-graphics-browser-click (event)
  "Forward a left click in the browser frame to casty as a page click.
The browser overlay sits at the window's top-left and never scrolls, so
the clicked cell from EVENT maps directly to casty's 1-based content cell.
Clicks past the rendered grid (the 1-cell margin that `compute-geometry'
leaves, or any over-wide window) fall outside casty's viewport and would
be no-ops, so they are dropped rather than sent."
  (interactive "e")
  (let* ((cr (posn-col-row (event-start event)))
         (col (1+ (car cr)))
         (row (1+ (cdr cr)))
         (cols (or kitty-graphics--browser-cols col))
         (rows (or kitty-graphics--browser-rows row)))
    (if (or (> col cols) (> row rows))
        (kitty-graphics--log "browser: click col=%d row=%d outside grid %dx%d (ignored)"
                        col row cols rows)
      (kitty-graphics--log "browser: click col=%d row=%d" col row)
      (kitty-graphics--browser-send (list :cmd "click" :col col :row row)))))

(define-obsolete-function-alias 'kitty-gfx-browser-click 'kitty-graphics-browser-click "1.3.0")

(define-obsolete-variable-alias 'kitty-gfx-browser-mode-map 'kitty-graphics-browser-mode-map "1.3.0")

(defvar kitty-graphics-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "j"       #'kitty-graphics-browser-scroll-down)
    (define-key map "k"       #'kitty-graphics-browser-scroll-up)
    (define-key map (kbd "C-f") #'kitty-graphics-browser-page-down)
    (define-key map (kbd "C-b") #'kitty-graphics-browser-page-up)
    ;; Mouse wheel → scroll the page instead of the Emacs window.
    (define-key map [wheel-down] #'kitty-graphics-browser-scroll-down)
    (define-key map [wheel-up]   #'kitty-graphics-browser-scroll-up)
    (define-key map [mouse-5]    #'kitty-graphics-browser-scroll-down)
    (define-key map [mouse-4]    #'kitty-graphics-browser-scroll-up)
    (define-key map "H"       #'kitty-graphics-browser-back)
    (define-key map "L"       #'kitty-graphics-browser-forward)
    (define-key map "r"       #'kitty-graphics-browser-reload)
    (define-key map "o"       #'kitty-graphics-browser-open-url)
    (define-key map (kbd ":") #'kitty-graphics-browser-open-url)
    (define-key map "f"       #'kitty-graphics-browser-hints)
    (define-key map [mouse-1] #'kitty-graphics-browser-click)
    (define-key map "q"       #'kitty-graphics-browser-quit)
    map)
  "Keymap for `kitty-graphics-browser-mode'.")

(define-derived-mode kitty-graphics-browser-mode special-mode "KittyBrowser"
  "Major mode for the inline casty web browser.
Frames are rendered by casty and forwarded to the terminal; keys are
translated to casty IPC commands."
  (setq buffer-read-only t)
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  ;; Terminal Emacs only receives mouse events (wheel scroll, click-to-follow
  ;; links) when xterm-mouse-mode is on.  Enable it for the browser, remembering
  ;; to restore the prior state on cleanup.
  (when (and (not (display-graphic-p))
             (not (bound-and-true-p xterm-mouse-mode)))
    (setq kitty-graphics--browser-xterm-mouse-was-off t)
    (xterm-mouse-mode 1))
  ;; Tear the browser down with the buffer.
  (add-hook 'kill-buffer-hook #'kitty-graphics--browser-cleanup nil t)
  ;; Mirror the bindings into evil normal/motion state so evil's defaults
  ;; (j/k motions, etc.) do not shadow them -- same pattern as image-mode.
  (when (and kitty-graphics-browser-evil-bindings (fboundp 'evil-local-set-key))
    (dolist (state '(normal motion))
      (evil-local-set-key state "j" #'kitty-graphics-browser-scroll-down)
      (evil-local-set-key state "k" #'kitty-graphics-browser-scroll-up)
      (evil-local-set-key state (kbd "C-f") #'kitty-graphics-browser-page-down)
      (evil-local-set-key state (kbd "C-b") #'kitty-graphics-browser-page-up)
      (evil-local-set-key state "H" #'kitty-graphics-browser-back)
      (evil-local-set-key state "L" #'kitty-graphics-browser-forward)
      (evil-local-set-key state "r" #'kitty-graphics-browser-reload)
      (evil-local-set-key state "o" #'kitty-graphics-browser-open-url)
      (evil-local-set-key state (kbd ":") #'kitty-graphics-browser-open-url)
      (evil-local-set-key state "f" #'kitty-graphics-browser-hints)
      (evil-local-set-key state [mouse-1] #'kitty-graphics-browser-click)
      (evil-local-set-key state "q" #'kitty-graphics-browser-quit))))

(define-obsolete-function-alias 'kitty-gfx-browser-mode 'kitty-graphics-browser-mode "1.3.0")

;;;; Integration install/uninstall

(defun kitty-graphics--install-integrations ()
  "Install advice on org-mode, markdown-mode, image-mode, shr, dirvish."
  (with-eval-after-load 'org
    (advice-add 'org-display-inline-images :around
                #'kitty-graphics--org-display-advice)
    (advice-add 'org-remove-inline-images :around
                #'kitty-graphics--org-remove-advice)
    (advice-add 'org-toggle-inline-images :around
                #'kitty-graphics--org-toggle-advice)
    ;; org 10.0+: org-link-preview replaces org-toggle-inline-images
    (when (fboundp 'org-link-preview)
      (advice-add 'org-link-preview :around
                  #'kitty-graphics--org-link-preview-advice))
    (when (fboundp 'org-link-preview-region)
      (advice-add 'org-link-preview-region :around
                  #'kitty-graphics--org-link-preview-region-advice))
    ;; Refresh images when org cycles heading visibility
    (add-hook 'org-cycle-hook #'kitty-graphics--on-org-cycle)
    ;; Auto-apply heading sizes when entering org buffers
    (when kitty-graphics-heading-sizes-auto
      (add-hook 'org-mode-hook #'kitty-graphics--org-mode-heading-hook))
    ;; LaTeX fragment preview in terminal
    (advice-add 'org-latex-preview :around
                #'kitty-graphics--org-latex-preview-advice)
    (advice-add 'org--make-preview-overlay :around
                #'kitty-graphics--org-make-preview-overlay-advice))
  (with-eval-after-load 'image-mode
    (advice-add 'image-mode :around
                #'kitty-graphics--image-mode-advice))
  (with-eval-after-load 'shr
    (advice-add 'shr-put-image :around
                #'kitty-graphics--shr-put-image-advice))
  (with-eval-after-load 'doc-view
    (advice-add 'clear-image-cache :around
                #'kitty-graphics--clear-image-cache-advice)
    (advice-add 'doc-view-mode-p :around
                #'kitty-graphics--doc-view-mode-p-advice)
    (advice-add 'doc-view-insert-image :around
                #'kitty-graphics--doc-view-insert-image-advice)
    (advice-add 'doc-view-enlarge :around
                #'kitty-graphics--doc-view-enlarge-advice)
    (advice-add 'doc-view-scale-reset :around
                #'kitty-graphics--doc-view-scale-reset-advice)
    (advice-add 'image-forward-hscroll :around
                #'kitty-graphics--doc-view-image-forward-hscroll-advice)
    (advice-add 'image-backward-hscroll :around
                #'kitty-graphics--doc-view-image-backward-hscroll-advice)
    (advice-add 'image-next-line :around
                #'kitty-graphics--doc-view-image-next-line-advice)
    (advice-add 'image-previous-line :around
                #'kitty-graphics--doc-view-image-previous-line-advice)
    (advice-add 'image-scroll-left :around
                #'kitty-graphics--doc-view-image-scroll-left-advice)
    (advice-add 'image-scroll-right :around
                #'kitty-graphics--doc-view-image-scroll-right-advice)
    (advice-add 'image-scroll-up :around
                #'kitty-graphics--doc-view-image-scroll-up-advice)
    (advice-add 'image-scroll-down :around
                #'kitty-graphics--doc-view-image-scroll-down-advice)
    (advice-add 'image-bol :around
                #'kitty-graphics--doc-view-image-bol-advice)
    (advice-add 'image-eol :around
                #'kitty-graphics--doc-view-image-eol-advice)
    (advice-add 'image-bob :around
                #'kitty-graphics--doc-view-image-bob-advice)
    (advice-add 'image-eob :around
                #'kitty-graphics--doc-view-image-eob-advice))
  (with-eval-after-load 'markdown-overlays
    (advice-add 'markdown-overlays--fontify-image :around
                #'kitty-graphics--markdown-overlays-fontify-image-advice)
    (advice-add 'markdown-overlays--fontify-image-file-path :around
                #'kitty-graphics--markdown-overlays-fontify-image-file-path-advice))
  (with-eval-after-load 'markdown-mode
    (advice-add 'markdown-display-inline-images :around
                #'kitty-graphics--markdown-display-advice)
    (advice-add 'markdown-remove-inline-images :around
                #'kitty-graphics--markdown-remove-advice)
    (advice-add 'markdown-toggle-inline-images :around
                #'kitty-graphics--markdown-toggle-advice))
  (with-eval-after-load 'dired
    (advice-add 'dired-find-file :around
                #'kitty-graphics--dired-find-file-advice)
    (advice-add 'dired-find-file-other-window :around
                #'kitty-graphics--dired-find-file-other-window-advice))
  (with-eval-after-load 'dirvish
    (add-hook 'dirvish-find-entry-hook
              #'kitty-graphics--dirvish-find-entry-hook))
  (kitty-graphics--install-dirvish))

(defun kitty-graphics--uninstall-integrations ()
  "Remove all advice."
  (remove-hook 'org-mode-hook #'kitty-graphics--org-mode-heading-hook)
  (advice-remove 'org-display-inline-images #'kitty-graphics--org-display-advice)
  (advice-remove 'org-remove-inline-images #'kitty-graphics--org-remove-advice)
  (advice-remove 'org-toggle-inline-images #'kitty-graphics--org-toggle-advice)
  (when (fboundp 'org-link-preview)
    (advice-remove 'org-link-preview #'kitty-graphics--org-link-preview-advice))
  (when (fboundp 'org-link-preview-region)
    (advice-remove 'org-link-preview-region #'kitty-graphics--org-link-preview-region-advice))
  (remove-hook 'org-cycle-hook #'kitty-graphics--on-org-cycle)
  (advice-remove 'org-latex-preview #'kitty-graphics--org-latex-preview-advice)
  (advice-remove 'org--make-preview-overlay #'kitty-graphics--org-make-preview-overlay-advice)
  (advice-remove 'clear-image-cache #'kitty-graphics--clear-image-cache-advice)
  (advice-remove 'doc-view-mode-p #'kitty-graphics--doc-view-mode-p-advice)
  (advice-remove 'doc-view-insert-image #'kitty-graphics--doc-view-insert-image-advice)
  (advice-remove 'doc-view-enlarge #'kitty-graphics--doc-view-enlarge-advice)
  (advice-remove 'doc-view-scale-reset #'kitty-graphics--doc-view-scale-reset-advice)
  (advice-remove 'image-forward-hscroll #'kitty-graphics--doc-view-image-forward-hscroll-advice)
  (advice-remove 'image-backward-hscroll #'kitty-graphics--doc-view-image-backward-hscroll-advice)
  (advice-remove 'image-next-line #'kitty-graphics--doc-view-image-next-line-advice)
  (advice-remove 'image-previous-line #'kitty-graphics--doc-view-image-previous-line-advice)
  (advice-remove 'image-scroll-left #'kitty-graphics--doc-view-image-scroll-left-advice)
  (advice-remove 'image-scroll-right #'kitty-graphics--doc-view-image-scroll-right-advice)
  (advice-remove 'image-scroll-up #'kitty-graphics--doc-view-image-scroll-up-advice)
  (advice-remove 'image-scroll-down #'kitty-graphics--doc-view-image-scroll-down-advice)
  (advice-remove 'image-bol #'kitty-graphics--doc-view-image-bol-advice)
  (advice-remove 'image-eol #'kitty-graphics--doc-view-image-eol-advice)
  (advice-remove 'image-bob #'kitty-graphics--doc-view-image-bob-advice)
  (advice-remove 'image-eob #'kitty-graphics--doc-view-image-eob-advice)
  (advice-remove 'image-mode #'kitty-graphics--image-mode-advice)
  (advice-remove 'shr-put-image #'kitty-graphics--shr-put-image-advice)
  (advice-remove 'markdown-overlays--fontify-image #'kitty-graphics--markdown-overlays-fontify-image-advice)
  (advice-remove 'markdown-overlays--fontify-image-file-path #'kitty-graphics--markdown-overlays-fontify-image-file-path-advice)
  (advice-remove 'markdown-display-inline-images #'kitty-graphics--markdown-display-advice)
  (advice-remove 'markdown-remove-inline-images #'kitty-graphics--markdown-remove-advice)
  (advice-remove 'markdown-toggle-inline-images #'kitty-graphics--markdown-toggle-advice)
  (advice-remove 'dired-find-file #'kitty-graphics--dired-find-file-advice)
  (advice-remove 'dired-find-file-other-window
                 #'kitty-graphics--dired-find-file-other-window-advice)
  (when (boundp 'dirvish-find-entry-hook)
    (remove-hook 'dirvish-find-entry-hook
                 #'kitty-graphics--dirvish-find-entry-hook))
  (kitty-graphics--uninstall-dirvish))

;;;; Buffer cleanup

(defun kitty-graphics--image-id-in-other-buffers-p (id &optional exclude-buf)
  "Non-nil if image ID is used by overlays in buffers other than EXCLUDE-BUF.
EXCLUDE-BUF defaults to the current buffer."
  (let ((skip (or exclude-buf (current-buffer)))
        (found nil))
    (dolist (buf (buffer-list))
      (unless (or found (eq buf skip))
        (with-current-buffer buf
          (dolist (ov kitty-graphics--overlays)
            (when (and (not found)
                       (overlay-buffer ov)
                       (eql (overlay-get ov 'kitty-graphics-id) id))
              (setq found t))))))
    found))

(defun kitty-graphics--kill-buffer-hook ()
  "Clean up images when buffer is killed.
Deletes terminal-side placements for this buffer's overlays.
Only deletes terminal-side image data (and cache entries) if no
other buffer has overlays referencing the same image ID — this
prevents breaking shared images (e.g., same file open in org-mode
and image-mode simultaneously)."
  (when kitty-graphics--mpv-process
    (kitty-graphics--mpv-cleanup))
  (when (and kitty-graphics-mode kitty-graphics--overlays)
    (kitty-graphics--log "kill-buffer-hook: buf=%s overlays=%d" (buffer-name) (length kitty-graphics--overlays))
    (let ((deleted-ids nil))
      (dolist (ov kitty-graphics--overlays)
        (condition-case nil
            (let ((id (overlay-get ov 'kitty-graphics-id))
                  (pid (overlay-get ov 'kitty-graphics-pid))
                  (temp-file (overlay-get ov 'kitty-graphics-delete-file)))
              (when (and id pid kitty-graphics--active-backend)
                ;; Always delete the placements (they're buffer-specific)
                (kitty-graphics--delete-image-placements ov))
              (when temp-file
                (ignore-errors (delete-file temp-file)))
              ;; Only delete the image data if no other buffer uses it
              (when (and id (not (memq id deleted-ids)))
                (if (kitty-graphics--image-id-in-other-buffers-p id)
                    (kitty-graphics--log "kill-buffer-hook: id=%d still used in other buffers, keeping" id)
                  (push id deleted-ids))))
          (error nil)))
      ;; Remove cache entries only for IDs we actually deleted
      (when deleted-ids
        (kitty-graphics--log "kill-buffer-hook: cleaning cache for ids=%S" deleted-ids)
        (maphash (lambda (file id)
                   (when (memq id deleted-ids)
                     (kitty-graphics--evict-image-everywhere file id)
                     (kitty-graphics--cache-remove file)))
                 (copy-hash-table kitty-graphics--image-cache)))
      (setq kitty-graphics--overlays nil)
      (kitty-graphics--log "kill-buffer-hook: done (cache-count=%d)"
                       (hash-table-count kitty-graphics--image-cache)))))

(provide 'kitty-graphics)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; kitty-graphics.el ends here
