;;; kitty-graphics.el --- Display images in terminal Emacs via Kitty graphics protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026
;;
;; Author: cashmere
;; Version: 0.6.0
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
;;   ;; Then org-mode C-c C-x C-v, image-mode, eww images all work.
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

(defcustom kitty-gfx-shr-scale nil
  "Image sizing for the shr backends (eww, elfeed, mu4e, gnus).
nil renders images at natural size, shrinking only to fit
`kitty-gfx-max-width' and `kitty-gfx-max-height'.
A float (e.g. 0.25) renders every image at that fraction of its
natural size, still capped at the max dimensions.
The symbol `fit' dynamically scales each image into a box derived
from the live window: `kitty-gfx-shr-fit-width' of the window width
and `kitty-gfx-shr-fit-height' rows tall, preserving aspect ratio and
never enlarging images that already fit."
  :type '(choice (const :tag "Natural size (shrink to fit max)" nil)
                 (number :tag "Fraction of natural size")
                 (const :tag "Dynamic window-relative fit" fit))
  :group 'kitty-graphics)

(defcustom kitty-gfx-shr-fit-width 0.6
  "Fraction of the window width an image may occupy under `fit' sizing.
Only consulted when `kitty-gfx-shr-scale' is `fit'."
  :type 'number
  :group 'kitty-graphics)

(defcustom kitty-gfx-shr-fit-height 20
  "Maximum image height in rows under `fit' sizing.
Only consulted when `kitty-gfx-shr-scale' is `fit'."
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

(defcustom kitty-gfx-skip-clean-refresh t
  "When non-nil, skip scheduling a refresh when no window content changed.
`kitty-gfx--on-redisplay' compares each visible overlay window against
the signature stored after the last successful refresh (see
`kitty-gfx--window-signature') and schedules nothing when they all
match.  Set to nil to restore the old refresh-on-every-command
behaviour as an escape hatch."
  :type 'boolean
  :group 'kitty-graphics)

(defcustom kitty-gfx-async-conversion t
  "When non-nil, convert non-PNG images to PNG asynchronously.
The overlay reserves its blank screen area immediately and the image
appears via a forced refresh once the background conversion finishes.
When nil, conversion blocks Emacs as before."
  :type 'boolean
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

(defcustom kitty-gfx-enable-browser nil
  "When non-nil, enable the inline casty web browser.
Requires the casty program (see `kitty-gfx-casty-program') built
with embed-mode support, and the Kitty backend."
  :type 'boolean
  :group 'kitty-graphics)

(defcustom kitty-gfx-casty-program "casty"
  "Program name or path used to launch the casty browser in embed mode."
  :type 'string
  :group 'kitty-graphics)

(defcustom kitty-gfx-casty-chrome nil
  "Path to a Chromium-based browser for casty to drive, or nil.
When set, it is passed to casty as the CASTY_CHROME environment
variable so casty reuses an already-installed browser (Chromium,
Helium, Brave, …) instead of downloading Chrome Headless Shell."
  :type '(choice (const :tag "casty default" nil) (file :tag "Browser binary"))
  :group 'kitty-graphics)

(defcustom kitty-gfx-browser-max-width 200
  "Maximum width in columns for the inline browser frame."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-browser-max-height 60
  "Maximum height in rows for the inline browser frame."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-browser-scroll-step 300
  "Pixels scrolled per `j'/`k' keypress in the inline browser."
  :type 'integer
  :group 'kitty-graphics)

(defcustom kitty-gfx-browser-evil-bindings t
  "When non-nil, mirror the browser keymap into evil normal/motion state."
  :type 'boolean
  :group 'kitty-graphics)

(defcustom kitty-gfx-video-file-extensions
  '("mp4" "mkv" "webm" "mov" "m4v" "avi")
  "File extensions handled by inline mpv preview in dired / dirvish.
Compared lowercase against `file-name-extension'."
  :type '(repeat string)
  :group 'kitty-graphics)

(defcustom kitty-gfx-video-thumbnail-seek "0.5"
  "Seconds offset into a video at which thumbnails are extracted.
Passed verbatim as `-ss' to ffmpeg.  A small positive offset
avoids the all-black title frame some encoders produce at t=0."
  :type 'string
  :group 'kitty-graphics)

(defcustom kitty-gfx-dired-preview-debounce 0.3
  "Idle seconds before `kitty-gfx-dired-auto-preview-mode' previews
the file at point after the cursor moves."
  :type 'number
  :group 'kitty-graphics)

(defcustom kitty-gfx-dirvish-video-inline-preview nil
  "Where to play a video opened with RET inside a dirvish session.
When nil (the default), tear down the dirvish layout and play the
video full-frame, matching dirvish's behaviour for regular files
and images.  When non-nil, keep the dirvish layout and play the
video inside the existing preview side window."
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
      ;; Write silently: `append-to-file' echoes "Added to <file>" to the echo
      ;; area, which would set `current-message' and make
      ;; `kitty-gfx--refresh-inhibited-p' treat every debug-log write as user
      ;; feedback — permanently inhibiting the refresh that paints images.
      (ignore-errors
        (let ((inhibit-message t)
              (message-log-max nil))
          (write-region msg nil kitty-gfx--log-file 'append 'silent)))
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

(defvar kitty-gfx--messaged-once (make-hash-table :test 'equal)
  "Keys of one-time user messages already shown this session.
Used by `kitty-gfx--message-once' so recurring conditions (encode
failures, tmux misconfiguration) surface exactly one echo-area
message instead of spamming on every refresh.")

(defun kitty-gfx--message-once (key msg)
  "Show MSG in the echo area at most once per session for KEY.
Repeat calls with the same KEY only log MSG.  Returns MSG."
  (if (gethash key kitty-gfx--messaged-once)
      (kitty-gfx--log "message-once: suppressed %s" key)
    (puthash key t kitty-gfx--messaged-once)
    (message "%s" msg))
  msg)

(defcustom kitty-gfx-tmux-passthrough t
  "When non-nil, wrap Kitty graphics APC sequences with the tmux DCS
passthrough envelope inside tmux.  Required for the Kitty protocol to
traverse tmux when `allow-passthrough' is on.  Plain CSI sequences and
text bytes are never wrapped — tmux handles those natively and needs to
see them to keep its own grid in sync.  Sixel DCS is also left unwrapped
because tmux 3.4+ renders Sixel itself.  Set to nil to disable entirely."
  :type 'boolean
  :group 'kitty-gfx)

(defcustom kitty-gfx-kitty-placement-mode 'auto
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
  :group 'kitty-gfx)

(defvar kitty-gfx--target-terminal nil
  "Terminal object `kitty-gfx--terminal-send' should write to.
nil means the selected frame's terminal — the historical default and
the only behaviour outside a multi-client daemon.  `kitty-gfx--refresh'
binds this per window so each client's escapes reach its own tty, and
the mpv/casty filters bind it to the terminal playback started on.")

(defun kitty-gfx--target-frame ()
  "Return a live frame for `kitty-gfx--target-terminal', else the selected frame.
Resolves per-client environment (e.g. TMUX) for the terminal that
`kitty-gfx--terminal-send' is currently writing to."
  (or (and kitty-gfx--target-terminal
           (terminal-live-p kitty-gfx--target-terminal)
           (car (frames-on-display-list kitty-gfx--target-terminal)))
      (selected-frame)))

(defun kitty-gfx--tparam (key)
  "Read terminal-parameter KEY for `kitty-gfx--target-terminal'.
nil target means the selected frame's terminal."
  (terminal-parameter kitty-gfx--target-terminal key))

(defun kitty-gfx--set-tparam (key value)
  "Set terminal-parameter KEY to VALUE for `kitty-gfx--target-terminal'.
nil target means the selected frame's terminal.  Returns VALUE."
  (set-terminal-parameter kitty-gfx--target-terminal key value)
  value)

(defun kitty-gfx--clear-terminal-state (term)
  "Drop all kitty-graphics per-client state stored on terminal TERM.
Clears the detected backend, queried cell size, text-sizing level,
tmux probe results, and the query/transmission bookkeeping so the
terminal is treated as fresh."
  (when (terminal-live-p term)
    (set-terminal-parameter term 'kitty-gfx-backend nil)
    (set-terminal-parameter term 'kitty-gfx-cell-w nil)
    (set-terminal-parameter term 'kitty-gfx-cell-h nil)
    (set-terminal-parameter term 'kitty-gfx-text-sizing nil)
    (set-terminal-parameter term 'kitty-gfx-tmux-version nil)
    (set-terminal-parameter term 'kitty-gfx-tmux-passthrough nil)
    (set-terminal-parameter term 'kitty-gfx-transmitted nil)
    (set-terminal-parameter term 'kitty-gfx-virtual-dims nil)))

;; Kitty stores transmitted image data per terminal: an `a=t' transmit to
;; client A's tty does not exist on client B's tty.  The global file->id
;; cache assigns one id per file for all clients, but whether that id's
;; bytes have actually reached a given terminal is tracked here, per
;; terminal, so each new client re-transmits on first use.
(defun kitty-gfx--transmitted-p (id)
  "Non-nil if image ID was transmitted to `kitty-gfx--target-terminal'."
  (let ((h (kitty-gfx--tparam 'kitty-gfx-transmitted)))
    (and h (gethash id h))))

(defun kitty-gfx--mark-transmitted (id)
  "Record that image ID has been transmitted to `kitty-gfx--target-terminal'."
  (let ((h (or (kitty-gfx--tparam 'kitty-gfx-transmitted)
               (kitty-gfx--set-tparam 'kitty-gfx-transmitted
                                      (make-hash-table)))))
    (puthash id t h)))

(defun kitty-gfx--terminal-transmitted-p (term id)
  "Non-nil if image ID was transmitted to terminal TERM."
  (let ((h (terminal-parameter term 'kitty-gfx-transmitted)))
    (and h (gethash id h))))

(defun kitty-gfx--terminal-unmark-transmitted (term id)
  "Forget that image ID was transmitted to terminal TERM."
  (let ((h (terminal-parameter term 'kitty-gfx-transmitted)))
    (when h (remhash id h))))

(defmacro kitty-gfx--with-terminal (term &rest body)
  "Evaluate BODY with output routed to TERM and per-terminal state bound.
Shadows the backend, cell-size, and text-sizing globals with TERM's
stored terminal parameters (falling back to the current global default),
so the render-path read sites observe per-terminal values without each
needing terminal awareness.  The globals are special variables, so these
`let*' bindings are dynamic and visible throughout BODY's call tree."
  (declare (indent 1) (debug (form body)))
  (let ((tv (make-symbol "term")))
    `(let* ((,tv ,term)
            (kitty-gfx--target-terminal ,tv)
            (kitty-gfx--active-backend
             (or (terminal-parameter ,tv 'kitty-gfx-backend)
                 kitty-gfx--active-backend))
            (kitty-gfx--cell-pixel-width
             (or (terminal-parameter ,tv 'kitty-gfx-cell-w)
                 kitty-gfx--cell-pixel-width))
            (kitty-gfx--cell-pixel-height
             (or (terminal-parameter ,tv 'kitty-gfx-cell-h)
                 kitty-gfx--cell-pixel-height))
            (kitty-gfx--text-sizing-support
             (or (terminal-parameter ,tv 'kitty-gfx-text-sizing)
                 kitty-gfx--text-sizing-support)))
       ,@body)))

(defun kitty-gfx--wrap-tmux-passthrough (str)
  "Wrap STR with tmux DCS passthrough envelope.
Doubles every ESC in STR and surrounds with `\\ePtmux;' ... `\\e\\\\'.
Requires `allow-passthrough on' in tmux for the outer terminal to
actually see the unwrapped payload."
  (concat "\ePtmux;"
          (replace-regexp-in-string "\e" "\e\e" str t t)
          "\e\\"))

(defun kitty-gfx--needs-tmux-wrap-p (str)
  "Return non-nil if STR contains a Kitty graphics APC that tmux would eat.
Only APC sequences starting with `\\e_G' (the Kitty graphics indicator)
need the passthrough wrapper; plain CSI movement, SGR, OSC, and raw
text all pass through tmux untouched and must NOT be wrapped (tmux
needs them to update its own grid for tmux-window-switch correctness)."
  (and kitty-gfx-tmux-passthrough
       (kitty-gfx--frame-getenv "TMUX" (kitty-gfx--target-frame))
       (string-match-p "\e_G" str)))

(defun kitty-gfx--terminal-send (str)
  "Send STR to terminal, or log it in dry-run mode.
All terminal escape output should go through this function.

Inside tmux, Kitty graphics APC sequences are wrapped with the tmux DCS
passthrough envelope so they reach the outer terminal.  Everything else
is emitted raw."
  (let ((payload (if (kitty-gfx--needs-tmux-wrap-p str)
                     (kitty-gfx--wrap-tmux-passthrough str)
                   str)))
    (if kitty-gfx--dry-run
        (kitty-gfx--log "DRY-RUN-SEND: %S" payload)
      (ignore-errors
        (send-string-to-terminal payload kitty-gfx--target-terminal)))))

;;;; Unicode placeholder protocol constants

(defconst kitty-gfx--placeholder-char ?\x10EEEE
  "Base code point of a Kitty graphics Unicode placeholder cell.
Each rendered cell consists of this character followed by two
combining marks from `kitty-gfx--diacritics' encoding the (row,
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
(set-char-table-range char-width-table kitty-gfx--placeholder-char 1)

(defconst kitty-gfx--diacritics
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
image is referenced by appending `(aref kitty-gfx--diacritics Y)' then
`(aref kitty-gfx--diacritics X)' after `kitty-gfx--placeholder-char'.
Hard limit: images > 297 cells in either dimension cannot use this
mode.  Order is significant — do not sort.")

(defun kitty-gfx--effective-placement-mode ()
  "Resolve `kitty-gfx-kitty-placement-mode' to `direct' or `placeholder'.
The `auto' value chooses `placeholder' inside tmux (where direct
placement leaks images across pane switches) and `direct' outside
\(where direct is simpler and the ghost problem does not apply).
TMUX is read from the target frame's environment, matching the frame
`kitty-gfx--needs-tmux-wrap-p' wraps for, so a multi-tty daemon does
not resolve a tmux client's mode from whichever frame is selected."
  (pcase kitty-gfx-kitty-placement-mode
    ('direct 'direct)
    ('placeholder 'placeholder)
    (_ (if (kitty-gfx--frame-getenv "TMUX" (kitty-gfx--target-frame))
           'placeholder
         'direct))))

(defun kitty-gfx--emit-placeholder-cells (image-id cols rows term-row term-col)
  "Emit a COLS x ROWS block of Kitty Unicode placeholder cells.

Bytes are written via `kitty-gfx--terminal-send' rather than going
through Emacs's display engine: Emacs strips combining diacritics
attached to private-use base characters such as U+10EEEE, which
would silently break the protocol.  Calling this from a TTY display
context is therefore correct only when something else (an overlay
display string, in our case) has already reserved the screen cells.

Each cell encodes the image identifier via the truecolor SGR
foreground and the cell's image-relative (row, col) via two
combining diacritics from `kitty-gfx--diacritics'.  IMAGE-ID must
fit in 24 bits; the protocol's optional fourth combining character
for an extra MSB byte is not produced here.

TERM-ROW and TERM-COL are 1-based terminal coordinates of the
image area's top-left.  COLS and ROWS beyond the diacritic table's
297 entries are clamped — the protocol cannot address further cells,
and signaling here would abort the whole refresh cycle.  The emission
is bracketed by DECSC/DECRC \(`\\e7' / `\\e8') so the caller's cursor
and SGR state are preserved."
  (let ((max (length kitty-gfx--diacritics)))
    (when (> image-id #xffffff)
      (error "kitty-gfx: image id %d exceeds 24 bits — \
placeholder mode cannot encode it" image-id))
    (when (or (> rows max) (> cols max))
      (kitty-gfx--log "emit-placeholder-cells: clamping %dx%d to grid max %d"
                      cols rows max)
      (setq cols (min cols max)
            rows (min rows max))))
  (let* ((sgr (format "\e[38;2;%d;%d;%dm"
                      (logand (ash image-id -16) #xff)
                      (logand (ash image-id -8)  #xff)
                      (logand image-id           #xff)))
         (ph (string kitty-gfx--placeholder-char))
         (parts (list "\e7" sgr)))
    (dotimes (y rows)
      (push (format "\e[%d;%dH" (+ term-row y) term-col) parts)
      (let ((row-dia (string (aref kitty-gfx--diacritics y))))
        (dotimes (x cols)
          (push ph parts)
          (push row-dia parts)
          (push (string (aref kitty-gfx--diacritics x)) parts))))
    (push "\e[0m\e8" parts)
    (kitty-gfx--terminal-send (mapconcat #'identity (nreverse parts) ""))))

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

(defcustom kitty-gfx-base64-cache-bytes 67108864
  "Maximum total bytes of base64-encoded image data to cache in memory.
`kitty-gfx--read-file-base64' keeps encoded payloads keyed by file and
modification time so re-transmits to additional terminals skip the
read+encode cost.  Least-recently-used entries are evicted when the
total exceeds this cap; a single payload larger than the cap is never
cached."
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
The raw escape hatch: appended after the dither/palette arguments
derived from `kitty-gfx-sixel-dither' and `kitty-gfx-sixel-colors'.
For img2sixel these come before the per-invocation size flags and the
input file; for ImageMagick they come after the `-geometry' resize and
before the `sixel:-' output."
  :type '(repeat string)
  :group 'kitty-graphics)

(defcustom kitty-gfx-sixel-dither nil
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

(defcustom kitty-gfx-sixel-colors 256
  "Number of palette colors for Sixel encoding.
Passed as `-p N' to img2sixel and `-colors N' to ImageMagick.
Lower values shrink the Sixel payload at the cost of color fidelity;
nil leaves the palette size to the encoder."
  :type '(choice (const :tag "Encoder default" nil) integer)
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

(defcustom kitty-gfx-heading-scan-visible-only t
  "When non-nil, instrument org headings only around the visible region.
Heading overlays are created lazily for the displayed window region
plus a margin of two screenfuls in each direction, driven by scroll
and window-change hooks.  Keeps activation cheap in buffers with
thousands of headings.  Set to nil to scan the whole buffer up front
\(the pre-0.7 behavior)."
  :type 'boolean
  :group 'kitty-graphics)

(defcustom kitty-gfx-heading-conflicting-modes
  '(org-modern-mode org-appear-mode org-indent-mode visual-line-mode olivetti-mode)
  "Minor modes temporarily disabled while OSC 66 heading sizes are active.
These modes attach display properties, virtual indentation, soft
wrapping, or window margins that corrupt the heading position math or
the OSC 66 payload.  Their prior state is saved and restored when
heading sizes are turned off."
  :type '(repeat symbol)
  :group 'kitty-graphics)

(defvar kitty-gfx--image-cache (make-hash-table :test 'equal)
  "Maps file paths to image IDs (integers).
Only stores the terminal-side image ID — display dimensions are
computed fresh each time to avoid stale values from different
display contexts (window sizes, zoom levels, etc.).")

(defvar kitty-gfx--cache-lru nil
  "LRU list of file paths in `kitty-gfx--image-cache'.
Most recently used at the front.")

(defvar kitty-gfx--png-cache (make-hash-table :test 'equal)
  "Maps source file paths to (MTIME . PNG-PATH) conversion results.
Consulted by `kitty-gfx--convert-to-png' before shelling out and
populated after every successful conversion (sync or async).  Stale
entries (source mtime changed) are reconverted and their old temp PNG
deleted.")

(defvar kitty-gfx--converting (make-hash-table :test 'equal)
  "Maps file paths to the list of callbacks awaiting an async conversion.
A key's presence means a conversion process for that file is in
flight; further requests append their callback instead of spawning a
second process.")

(defvar kitty-gfx--transmit-queue nil
  "Pending image transmits as a list of (TERMINAL FILE IMAGE-ID).
Filled by `kitty-gfx--ensure-transmitted' when a terminal lacks an
image's data; drained one entry per tick by
`kitty-gfx--transmit-drain' so a newly attached client does not block
Emacs transmitting its whole backlog inside one refresh.")

(defvar kitty-gfx--transmit-drain-timer nil
  "Repeating timer that drains `kitty-gfx--transmit-queue'.")

(defvar kitty-gfx--transmit-drain-succeeded nil
  "Non-nil when the current drain cycle transmitted at least one image.
Gates the trailing forced refresh in `kitty-gfx--transmit-drain': a
cycle of pure failures must not force a refresh, because that refresh
would re-queue the same failing transmit and spin forever.")

(defvar kitty-gfx--base64-cache (make-hash-table :test 'equal)
  "Maps file paths to (MTIME . BASE64-STRING) for transmitted images.
Bounded by `kitty-gfx-base64-cache-bytes'; see
`kitty-gfx--base64-cache-lru' for eviction order.")

(defvar kitty-gfx--base64-cache-lru nil
  "LRU list of file paths in `kitty-gfx--base64-cache'.
Most recently used at the front.")

(defvar kitty-gfx--base64-cache-total 0
  "Total bytes of base64 payloads currently in `kitty-gfx--base64-cache'.")

(defvar-local kitty-gfx--overlays nil
  "Image overlays in this buffer.")

(defvar kitty-gfx--render-timer nil
  "Timer for deferred re-rendering.")

(defvar kitty-gfx--force-redisplay nil
  "Non-nil when the next refresh must call `(redisplay t)' first.
See full docstring near `kitty-gfx--schedule-refresh'.")

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
Prevents queuing redundant stale-heading updates when multiple
characters are typed rapidly.")

(defvar-local kitty-gfx--heading-sizes-enabled nil
  "Non-nil while scaled heading sizes are active in this org buffer.
Set by `kitty-gfx-org-heading-sizes' and the auto-enable hook;
consulted by the scroll/window-change hooks that drive
visible-region heading scans.")

(defvar kitty-gfx--heading-flush-needed nil
  "Non-nil when a heading reservation changed during refresh phase 1.
Set by `kitty-gfx--heading-sync-reservation' whenever an overlay's
space-reservation display strings were just mutated.  Consumed by
`kitty-gfx--refresh', which must flush those strings to the terminal
with `redisplay' BEFORE phase 2 emits OSC 66 — otherwise the next
redisplay would draw the spaces on top of the freshly painted
multicell block and clip its leading glyphs.")

(defvar-local kitty-gfx--mpv-process nil
  "The mpv process object for the current buffer's video.")

(defvar-local kitty-gfx--mpv-ipc-socket nil
  "Path to the mpv JSON IPC socket file.")

(defvar-local kitty-gfx--mpv-ipc-connection nil
  "Network process connected to mpv's IPC socket.")

(defvar-local kitty-gfx--mpv-ipc-timer nil
  "Pending socket-poll timer of `kitty-gfx--mpv-ipc-connect'.
Stored so `kitty-gfx--mpv-cleanup' can cancel an in-flight poll.")

(defvar-local kitty-gfx--mpv-overlay nil
  "The overlay reserving space for the video.")

(defvar-local kitty-gfx--mpv-terminal nil
  "Terminal object the mpv playback was launched on.
mpv writes one Kitty VO byte stream to a single fd, so it cannot fan out
to several daemon clients; its frames are bound to the terminal that
started playback.  The process filter routes output here and the
canonical-window search is restricted to this terminal's windows.")

(defvar-local kitty-gfx--mpv-last-row nil
  "Last known terminal row of the video overlay.")

(defvar-local kitty-gfx--mpv-last-col nil
  "Last known terminal column of the video overlay.")

(defvar-local kitty-gfx--mpv-paused nil
  "Local pause state mirror for the current buffer's mpv process.
Flipped by `kitty-gfx-toggle-video' so the user gets immediate
echo-area feedback without round-tripping through mpv IPC.")

(defvar-local kitty-gfx--mpv-auto-paused nil
  "Non-nil when the refresh cycle auto-paused mpv because the buffer
was no longer shown in any window.  Distinct from
`kitty-gfx--mpv-paused' so the user-driven pause state is preserved
across window hide/show.")

(defvar-local kitty-gfx--browser-process nil
  "The casty process object for the current browser buffer.")

(defvar-local kitty-gfx--browser-ipc-socket nil
  "Path to the casty JSON IPC socket file.")

(defvar-local kitty-gfx--browser-ipc-connection nil
  "Network process connected to casty's IPC socket.")

(defvar-local kitty-gfx--browser-ipc-timer nil
  "Pending socket-poll timer of `kitty-gfx--browser-ipc-connect'.
Stored so `kitty-gfx--browser-cleanup' can cancel an in-flight poll.")

(defvar-local kitty-gfx--browser-overlay nil
  "The overlay reserving space for the browser frame.")

(defvar-local kitty-gfx--browser-terminal nil
  "Terminal object the casty browser was launched on.
Like `kitty-gfx--mpv-terminal', casty emits a single byte stream and is
bound to its launching terminal; output is routed here.")

(defvar-local kitty-gfx--browser-image-id nil
  "Kitty image id allocated for this buffer's casty frames.")

(defvar-local kitty-gfx--browser-cols nil
  "Current browser frame width in columns.")

(defvar-local kitty-gfx--browser-rows nil
  "Current browser frame height in rows.")

(defvar-local kitty-gfx--browser-last-row nil
  "Last known terminal row of the browser overlay.")

(defvar-local kitty-gfx--browser-last-col nil
  "Last known terminal column of the browser overlay.")

(defvar-local kitty-gfx--browser-xterm-mouse-was-off nil
  "Non-nil if `kitty-gfx-browser-mode' turned on `xterm-mouse-mode'.
Terminal Emacs only delivers mouse events (wheel scroll, click-to-follow)
while `xterm-mouse-mode' is enabled; we enable it for the browser and
restore the prior state on cleanup.")

(defvar-local kitty-gfx--browser-hint-active nil
  "Non-nil while casty link-hint mode is active in this buffer.
Set by `kitty-gfx-browser-hints' and cleared when casty replies
`{\"hintActive\":false}' (a label was chosen or hints were cancelled);
used as the keep-predicate of the hint transient keymap.")

(defvar kitty-gfx-video-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'kitty-gfx-toggle-video)
    (define-key map (kbd "q")   #'kitty-gfx-stop-video-and-back)
    (define-key map (kbd "?")   #'kitty-gfx-video-help)
    map)
  "Keymap active when point is inside the inline mpv video region.
Attached as the `keymap' property of the mpv overlay so the
bindings only shadow normal editing while the cursor is on the
blank lines covered by the video frame.")

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
        (kitty-gfx--set-tparam 'kitty-gfx-backend nil)
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
        (kitty-gfx--set-tparam 'kitty-gfx-backend detected)
        (kitty-gfx--log "detect-protocol: result=%s" detected)
        detected)))

(defun kitty-gfx--unread-non-reply (response patterns events)
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
        (kitty-gfx--log "unread-non-reply: pushing back %d events"
                        (length pending))
        (setq unread-command-events
              (append pending unread-command-events))))))

(defun kitty-gfx--cpr-columns (response)
  "Return the cursor column of every full CPR reply in RESPONSE, in order."
  (let ((cols nil)
        (start 0))
    (while (string-match "\e\\[[0-9]+;\\([0-9]+\\)R" response start)
      (push (string-to-number (match-string 1 response)) cols)
      (setq start (match-end 0)))
    (nreverse cols)))

(defun kitty-gfx--query-cell-size ()
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
  (unless (terminal-parameter nil 'kitty-gfx-cell-w)
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
                  (kitty-gfx--log "cell-size query: %dx%d pixels" w h))))
            (kitty-gfx--unread-non-reply response (list reply-re)
                                         (nreverse extra)))
        (error nil))
      ;; Fallback if query failed, then publish to both the global default
      ;; and this terminal's parameter.
      (setq w (or w 8) h (or h 16))
      (setq kitty-gfx--cell-pixel-width w
            kitty-gfx--cell-pixel-height h)
      (set-terminal-parameter nil 'kitty-gfx-cell-w w)
      (set-terminal-parameter nil 'kitty-gfx-cell-h h)
      (kitty-gfx--log "cell-size final: %dx%d" w h))))

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

Uses DSR (device status report) as a sentinel to avoid hanging.
The read completes only on a full match of the DSR reply, so user
keystrokes cannot end it early; keystrokes consumed while waiting
are pushed back onto `unread-command-events'."
  (if (terminal-parameter nil 'kitty-gfx-text-sizing)
      ;; Already detected for this terminal — reuse the cached result
      (progn
        (setq kitty-gfx--text-sizing-support
              (terminal-parameter nil 'kitty-gfx-text-sizing))
        (kitty-gfx--log "text-sizing: cached result=%s"
                        kitty-gfx--text-sizing-support))
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
                (when (>= (length (kitty-gfx--cpr-columns response)) 3)
                  (setq done t)))))
          ;; Parse three CPR responses: ESC [ row ; col R
          (let ((cols (kitty-gfx--cpr-columns response)))
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
              (let ((ch (read-event nil nil 0.02)))
                (if ch
                    (if (characterp ch)
                        (setq response (concat response (string ch)))
                      (push ch extra))
                  (setq flush-deadline 0)))))
          (kitty-gfx--unread-non-reply
           response '("\e\\[[0-9]+;[0-9]+R" "\e\\[0n") (nreverse extra)))
      (error
       (kitty-gfx--log "text-sizing: query error: %s"
                        (error-message-string err))
       (setq kitty-gfx--text-sizing-support 'none))))
  (set-terminal-parameter nil 'kitty-gfx-text-sizing kitty-gfx--text-sizing-support)
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
  "Transmit image data with `a=t' (store-only) under image id ID.
BASE64-DATA is the PNG bytes, base64-encoded.  Chunked into
`kitty-gfx-chunk-size'-byte pieces using `m=1/0' continuation
markers per the Kitty graphics protocol.

This call only stores the image; how it is later rendered depends
on the active placement mode:

- `direct': `kitty-gfx--place-image' later emits an `a=p,c,r' APC
  at screen coordinates.
- `placeholder': `kitty-gfx--place-placeholder' later registers a
  `U=1' virtual placement sized to the rendered cell grid and paints
  placeholder cells that reference it."
  (let* ((mode (kitty-gfx--effective-placement-mode))
         (chunk-size kitty-gfx-chunk-size)
         (len (length base64-data))
         (offset 0)
         (first t)
         (chunk-count 0))
    (kitty-gfx--log "transmit-begin: id=%d b64-len=%d chunk-size=%d chunks=%d mode=%s"
                     id len chunk-size (ceiling (/ (float len) chunk-size)) mode)
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

(defun kitty-gfx--register-virtual-placement (id cols rows)
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
  (let ((dims-by-id (or (kitty-gfx--tparam 'kitty-gfx-virtual-dims)
                        (kitty-gfx--set-tparam 'kitty-gfx-virtual-dims
                                               (make-hash-table))))
        (dims (cons cols rows)))
    (unless (equal (gethash id dims-by-id) dims)
      (kitty-gfx--log "register-virtual-placement: id=%d cols=%d rows=%d"
                      id cols rows)
      (kitty-gfx--terminal-send
       (format "\e_Ga=p,U=1,i=%d,p=1,c=%d,r=%d,q=2\e\\" id cols rows))
      (puthash id dims dims-by-id))))

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
Uses direct placement: move cursor, then `a=p' with `c' and `r' params.
The cursor movement and the APC are sent separately: inside tmux only
the APC may travel through the passthrough envelope — wrapping the
cursor moves with it would make them execute on the outer terminal
with pane-relative coordinates."
  (kitty-gfx--log "place: id=%d pid=%d cols=%d rows=%d row=%d col=%d"
                   image-id placement-id cols rows term-row term-col)
  (kitty-gfx--terminal-send (format "\e7\e[%d;%dH" term-row term-col))
  (kitty-gfx--terminal-send
   (format "\e_Gq=2,a=p,i=%d,p=%d,c=%d,r=%d\e\\"
           image-id placement-id cols rows))
  (kitty-gfx--terminal-send "\e8"))

;;;; Kitty backend

(defun kitty-gfx--frame-getenv (var &optional frame)
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

(defun kitty-gfx--kitty-detect ()
  "Return non-nil if the terminal supports Kitty graphics protocol.
Reads env vars via `kitty-gfx--frame-getenv' so emacs --daemon
clients see the attached terminal's environment.

Inside tmux `TERM_PROGRAM' is masked to \"tmux\", so we also accept
terminal-specific env markers (e.g. `GHOSTTY_RESOURCES_DIR') as
evidence that the outer terminal speaks the Kitty protocol.

When inside tmux with `allow-passthrough' off, the Kitty APC escapes
would be swallowed by tmux, so the backend reports unsupported (with
a one-time message naming the fix) and detection falls through to
Sixel when available."
  (let* ((frame (selected-frame))
         (kitty-pid (kitty-gfx--frame-getenv "KITTY_PID" frame))
         (term-prog (kitty-gfx--frame-getenv "TERM_PROGRAM" frame))
         (ghostty (or (kitty-gfx--frame-getenv "GHOSTTY_RESOURCES_DIR" frame)
                      (kitty-gfx--frame-getenv "GHOSTTY_BIN_DIR" frame)))
         (wezterm (kitty-gfx--frame-getenv "WEZTERM_EXECUTABLE" frame))
         (in-tmux (kitty-gfx--frame-getenv "TMUX" frame))
         (supported (or kitty-pid
                        ghostty
                        wezterm
                        (member term-prog '("kitty" "WezTerm" "ghostty")))))
    (when (and supported in-tmux (not (kitty-gfx--tmux-passthrough-p frame)))
      (kitty-gfx--log "kitty-detect: disabled, tmux allow-passthrough is off")
      (kitty-gfx--message-once
       "tmux-passthrough-off"
       "kitty-gfx: tmux blocks Kitty graphics (allow-passthrough is off); run: tmux set -g allow-passthrough on, then toggle kitty-graphics-mode to re-detect")
      (setq supported nil))
    (kitty-gfx--log "kitty-detect: %s (KITTY_PID=%s TERM_PROGRAM=%s GHOSTTY=%s WEZTERM=%s)"
                     supported kitty-pid term-prog
                     (if ghostty "set" "no") (if wezterm "set" "no"))
    supported))

(defun kitty-gfx--kitty-prepare (file image-id)
  "Prepare image FILE for Kitty display.
Converts to PNG if needed, encodes to base64, transmits to terminal.
Converted PNGs are owned by `kitty-gfx--png-cache' and kept for reuse.
Returns IMAGE-ID on success, nil on failure."
  (let* ((png (kitty-gfx--convert-to-png file))
         (b64 (when png (kitty-gfx--read-file-base64 png))))
    (if (not b64)
        (progn
          (kitty-gfx--log "kitty-prepare: skipped %s (conversion failed)" file)
          nil)
      (kitty-gfx--log "kitty-prepare: transmit id=%d b64-len=%d png=%s"
                       image-id (length b64) png)
      (kitty-gfx--transmit-image image-id b64)
      ;; The bytes now live on the terminal output was routed to;
      ;; record it so this client is not re-transmitted needlessly and
      ;; other clients still re-transmit on their own first use.
      (kitty-gfx--mark-transmitted image-id)
      image-id)))

(defun kitty-gfx--transmit-queue-reset ()
  "Cancel the drain timer and drop all queued transmits."
  (when kitty-gfx--transmit-drain-timer
    (cancel-timer kitty-gfx--transmit-drain-timer))
  (setq kitty-gfx--transmit-drain-timer nil
        kitty-gfx--transmit-queue nil
        kitty-gfx--transmit-drain-succeeded nil))

(defun kitty-gfx--transmit-drain ()
  "Transmit one queued image, then stop and force a refresh when done.
Each tick pops a single (TERMINAL FILE IMAGE-ID) entry and runs the
Kitty prepare with output routed to that entry's terminal.  When the
queue empties the timer cancels itself, and a forced refresh is
scheduled so the freshly transmitted images get placed — but only when
at least one transmit in the cycle succeeded; a failing transmit stays
untransmitted and would be re-queued by the forced refresh, looping
forever."
  (let ((entry (pop kitty-gfx--transmit-queue)))
    (when entry
      (let ((term (nth 0 entry))
            (file (nth 1 entry))
            (id (nth 2 entry)))
        (if (not (terminal-live-p term))
            (kitty-gfx--log "transmit-drain: dropped id=%d (dead terminal)" id)
          (kitty-gfx--log "transmit-drain: id=%d term=%s (queued=%d)"
                          id term (length kitty-gfx--transmit-queue))
          (when (kitty-gfx--with-terminal term
                  (kitty-gfx--kitty-prepare file id))
            (setq kitty-gfx--transmit-drain-succeeded t))))))
  (unless kitty-gfx--transmit-queue
    (when kitty-gfx--transmit-drain-timer
      (cancel-timer kitty-gfx--transmit-drain-timer)
      (setq kitty-gfx--transmit-drain-timer nil))
    (when kitty-gfx--transmit-drain-succeeded
      (setq kitty-gfx--transmit-drain-succeeded nil)
      (kitty-gfx--schedule-refresh t))))

(defun kitty-gfx--transmit-enqueue (term file image-id)
  "Queue IMAGE-ID/FILE for transmission to TERM and ensure the drain runs.
Duplicate (TERM, IMAGE-ID) pairs are not queued twice."
  (unless (cl-find-if (lambda (entry)
                        (and (eq (nth 0 entry) term)
                             (eql (nth 2 entry) image-id)))
                      kitty-gfx--transmit-queue)
    (kitty-gfx--log "transmit-enqueue: id=%d term=%s (queued=%d)"
                    image-id term (1+ (length kitty-gfx--transmit-queue)))
    (setq kitty-gfx--transmit-queue
          (append kitty-gfx--transmit-queue (list (list term file image-id)))))
  (unless kitty-gfx--transmit-drain-timer
    (setq kitty-gfx--transmit-drain-timer
          (run-at-time 0.01 0.01 #'kitty-gfx--transmit-drain))))

(defun kitty-gfx--ensure-transmitted (file image-id)
  "Return non-nil when IMAGE-ID is ready to place on the target terminal.
Called from the refresh path, where the target terminal is bound.  When
the terminal already holds the image (or the backend is Sixel, which
re-emits pixels on every placement) this returns t and the caller
places immediately.  When the image's data is missing, the transmit is
queued on `kitty-gfx--transmit-queue' instead of blocking the refresh
loop, and nil is returned so the caller skips this overlay; the drain
timer's trailing forced refresh places it once transmitted.  Also
returns nil while FILE's async PNG conversion is still in flight."
  (cond
   ((and file (gethash file kitty-gfx--converting))
    (kitty-gfx--log "ensure-transmitted: %s still converting, deferring" file)
    nil)
   ((not (and (eq kitty-gfx--active-backend 'kitty) file image-id)) t)
   ((kitty-gfx--transmitted-p image-id) t)
   (t
    (kitty-gfx--transmit-enqueue
     (or kitty-gfx--target-terminal (frame-terminal))
     file image-id)
    nil)))

(defun kitty-gfx--kitty-place (ov image-id placement-id cols rows term-row term-col)
  "Place Kitty image at (TERM-ROW, TERM-COL) using the active placement mode.
Dispatches to either `kitty-gfx--place-placeholder' (when
`kitty-gfx-kitty-placement-mode' resolves to `placeholder') or the
existing direct-placement `kitty-gfx--place-image' otherwise.

PLACEMENT-ID is window-specific (allocated per (overlay, window) by
`kitty-gfx--record-image-placement') and is reused by the
placeholder path as the per-window key for tracking previously-
emitted areas, so the same overlay shown in two windows does not
have its second window's cells erased by the first window's
re-placement."
  (pcase (kitty-gfx--effective-placement-mode)
    ('placeholder
     (kitty-gfx--place-placeholder ov placement-id image-id cols rows
                                   term-row term-col))
    (_
     (kitty-gfx--place-image image-id placement-id cols rows term-row term-col))))

(defun kitty-gfx--place-placeholder (ov pid image-id cols rows term-row term-col)
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
  (let ((max (length kitty-gfx--diacritics)))
    (when (or (> cols max) (> rows max))
      (kitty-gfx--log "place-placeholder: clamping %dx%d to grid max %d"
                      cols rows max)
      (setq cols (min cols max)
            rows (min rows max))))
  (kitty-gfx--register-virtual-placement image-id cols rows)
  (when (overlayp ov)
    (kitty-gfx--erase-placeholder-area ov pid))
  (kitty-gfx--emit-placeholder-cells image-id cols rows term-row term-col)
  (when (overlayp ov)
    (kitty-gfx--record-placeholder-area ov pid term-row term-col cols rows)))

(defun kitty-gfx--record-placeholder-area (ov pid row col cols rows)
  "Remember on OV that PID was emitted at (ROW, COL) sized COLS x ROWS.
Replaces any prior entry for PID in OV's `kitty-gfx-placeholder-areas'
alist."
  (let* ((areas (overlay-get ov 'kitty-gfx-placeholder-areas))
         (rest (assq-delete-all pid (copy-sequence areas))))
    (overlay-put ov 'kitty-gfx-placeholder-areas
                 (cons (cons pid (list row col cols rows)) rest))))

(defun kitty-gfx--erase-placeholder-area (ov pid)
  "Overwrite OV's PID-keyed placeholder cells with spaces.
Reads the saved (row col cols rows) tuple from OV's
`kitty-gfx-placeholder-areas' alist for PID and writes a rectangle
of spaces over those terminal cells, so the multiplexer no longer
holds placeholder bytes the outer terminal would expand back into
the image.  No-op when no prior area is recorded for PID.  Removes
PID's entry from the alist after erasing."
  (when-let* ((areas (overlay-get ov 'kitty-gfx-placeholder-areas))
              (entry (assq pid areas)))
    (pcase-let ((`(,row ,col ,cs ,rs) (cdr entry)))
      (kitty-gfx--log "erase-placeholder-area: pid=%d row=%d col=%d %dx%d"
                       pid row col cs rs)
      (let ((parts (list "\e7"))
            (blank (make-string cs ?\s)))
        (dotimes (y rs)
          (push (format "\e[%d;%dH%s" (+ row y) col blank) parts))
        (push "\e8" parts)
        (kitty-gfx--terminal-send (mapconcat #'identity (nreverse parts) ""))))
    (overlay-put ov 'kitty-gfx-placeholder-areas
                 (assq-delete-all pid (copy-sequence areas)))))

(defun kitty-gfx--kitty-delete (ov image-id placement-id)
  "Delete Kitty placement PLACEMENT-ID of IMAGE-ID for overlay OV.
In `direct' mode emit a per-placement delete APC.  In `placeholder'
mode overwrite OV's PID-keyed placeholder cells with spaces; the
stored image data is preserved either way so a subsequent re-place
is cheap."
  (pcase (kitty-gfx--effective-placement-mode)
    ('placeholder
     (when (overlayp ov)
       (kitty-gfx--erase-placeholder-area ov placement-id)))
    (_
     (kitty-gfx--delete-placement image-id placement-id))))

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

(defun kitty-gfx--tmux-socket (&optional frame)
  "Return the tmux server socket path for FRAME, or nil outside tmux.
Parsed from FRAME's TMUX env var, whose format is
\"SOCKET-PATH,SERVER-PID,SESSION-ID\".  Read via
`kitty-gfx--frame-getenv' so each daemon client resolves the tmux
server it is actually attached to."
  (let ((tmux (kitty-gfx--frame-getenv "TMUX" frame)))
    (when (and tmux (not (string-empty-p tmux)))
      (let ((sock (car (split-string tmux ","))))
        (and sock (not (string-empty-p sock)) sock)))))

(defun kitty-gfx--tmux-display-message (format-spec &optional frame)
  "Run tmux `display-message -p FORMAT-SPEC' against FRAME's server.
Targets the socket derived from FRAME's TMUX env var via `tmux -S',
so daemon clients sitting in different tmux servers each query their
own.  Returns the trimmed output string, or nil on failure."
  (when (executable-find "tmux")
    (let ((sock (kitty-gfx--tmux-socket frame)))
      (with-temp-buffer
        (let* ((args (append (when sock (list "-S" sock))
                             (list "display-message" "-p" format-spec)))
               (exit (ignore-errors
                       (apply #'call-process "tmux" nil '(t nil) nil args))))
          (when (eq exit 0)
            (string-trim (buffer-string))))))))

(defun kitty-gfx--tmux-version (&optional frame)
  "Return tmux version as (MAJOR MINOR) integers, or nil when unavailable.
Asks FRAME's tmux server for `#{version}' (falling back to the local
`tmux -V' client binary when the server query fails), since daemon
clients can sit in different tmux servers running different versions.
Cached per terminal under the `kitty-gfx-tmux-version' parameter;
sentinel `none' records a failed probe so it is not retried."
  (let* ((term (frame-terminal (or frame (selected-frame))))
         (cached (terminal-parameter term 'kitty-gfx-tmux-version)))
    (if cached
        (and (consp cached) cached)
      (let* ((raw (or (kitty-gfx--tmux-display-message "#{version}" frame)
                      (kitty-gfx--tmux-client-version)))
             (ver (when (and raw
                             (string-match
                              "\\(?:next-\\)?\\([0-9]+\\)\\.\\([0-9]+\\)" raw))
                    (list (string-to-number (match-string 1 raw))
                          (string-to-number (match-string 2 raw))))))
        (kitty-gfx--log "tmux-version: %S (raw=%S term=%s)" ver raw term)
        (set-terminal-parameter term 'kitty-gfx-tmux-version (or ver 'none))
        ver))))

(defun kitty-gfx--tmux-client-version ()
  "Return the raw output of `tmux -V', or nil when tmux is unavailable."
  (when (executable-find "tmux")
    (with-temp-buffer
      (when (eq (ignore-errors
                  (call-process "tmux" nil '(t nil) nil "-V"))
                0)
        (string-trim (buffer-string))))))

(defun kitty-gfx--tmux-passthrough-state (&optional frame)
  "Return FRAME's tmux `allow-passthrough' state: `on', `off', or `unknown'.
Queries `#{allow-passthrough}' on the socket from FRAME's TMUX env
var; \"on\" and \"all\" count as `on'.  An empty or failed reply maps
to `unknown' (tmux < 3.3 has no such option and always passes DCS
through).  Cached per terminal under `kitty-gfx-tmux-passthrough'."
  (let* ((term (frame-terminal (or frame (selected-frame))))
         (cached (terminal-parameter term 'kitty-gfx-tmux-passthrough)))
    (or cached
        (let* ((raw (kitty-gfx--tmux-display-message "#{allow-passthrough}" frame))
               (state (cond ((member raw '("on" "all")) 'on)
                            ((member raw '(nil "")) 'unknown)
                            (t 'off))))
          (kitty-gfx--log "tmux-passthrough: %s (raw=%S term=%s)" state raw term)
          (set-terminal-parameter term 'kitty-gfx-tmux-passthrough state)
          state))))

(defun kitty-gfx--tmux-passthrough-p (&optional frame)
  "Return non-nil when FRAME runs inside tmux with `allow-passthrough' enabled.
Returns nil outside tmux and nil when tmux reports the option as off;
an unknown state (old tmux, failed query) counts as enabled because
those servers pass DCS through unconditionally."
  (and (kitty-gfx--frame-getenv "TMUX" frame)
       (memq (kitty-gfx--tmux-passthrough-state frame) '(on unknown))
       t))

(defun kitty-gfx--tmux-sixel-supported-p (&optional frame)
  "Return non-nil when running under tmux >= 3.4 with Sixel allowed.
Returns nil outside tmux, nil when `kitty-gfx-tmux-allow-sixel' is off,
nil when tmux's version cannot be determined, and nil for tmux < 3.4.
TMUX is read via `kitty-gfx--frame-getenv' so this works under
emacs --daemon clients; FRAME defaults to the selected frame."
  (and (kitty-gfx--frame-getenv "TMUX" frame)
       kitty-gfx-tmux-allow-sixel
       (let ((ver (kitty-gfx--tmux-version frame)))
         (and ver
              (or (> (car ver) 3)
                  (and (= (car ver) 3) (>= (cadr ver) 4)))))))

(defun kitty-gfx--sixel-detect ()
  "Return non-nil if the terminal likely supports Sixel protocol.
Inside tmux, requires tmux >= 3.4 (native Sixel rendering, 2024-02-13)
and `kitty-gfx-tmux-allow-sixel'.  Older tmux versions still disable
Sixel because they drop the DCS payload.

Reads env vars via `kitty-gfx--frame-getenv' so emacs --daemon
clients see the attached terminal's environment.  Falls back to the
frame's `tty-type' parameter when TERM is missing or `dumb', which
is typical for daemons launched from a non-tty service unit."
  (let* ((frame (selected-frame))
         (frame-term (frame-parameter frame 'tty-type))
         (env-term (kitty-gfx--frame-getenv "TERM" frame))
         (term (cond ((and frame-term (not (equal frame-term "dumb"))) frame-term)
                     ((and env-term (not (equal env-term "dumb"))) env-term)
                     (t (or frame-term env-term))))
         (term-prog (kitty-gfx--frame-getenv "TERM_PROGRAM" frame))
         (in-tmux (kitty-gfx--frame-getenv "TMUX" frame))
         (tmux-ver (and in-tmux (kitty-gfx--tmux-version frame)))
         (tmux-ok (kitty-gfx--tmux-sixel-supported-p frame))
         ;; Windows Terminal's TERM value is not stable enough to rely on
         ;; alone, so accept its session markers when present.
         (windows-terminal (or (kitty-gfx--frame-getenv "WT_SESSION" frame)
                               (kitty-gfx--frame-getenv "WT_PROFILE_ID" frame)
                               (kitty-gfx--frame-getenv "WT_WINDOWID" frame)))
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
    (kitty-gfx--log
     "sixel-detect: %s (TERM=%s TERM_PROGRAM=%s TMUX=%s tmux-ver=%s tmux-ok=%s WT=%s)"
     supported term term-prog (if in-tmux "yes" "no")
     (if tmux-ver (format "%d.%d" (car tmux-ver) (cadr tmux-ver)) "n/a")
     (if tmux-ok "yes" "no")
     (if windows-terminal "yes" "no"))
    (when (and in-tmux (not tmux-ok) kitty-gfx-tmux-allow-sixel)
      (kitty-gfx--message-once
       "sixel-tmux-version"
       (if tmux-ver
           (format "kitty-gfx: tmux %d.%d cannot render Sixel; tmux >= 3.4 is required"
                   (car tmux-ver) (cadr tmux-ver))
         "kitty-gfx: tmux version unknown; Sixel inside tmux requires tmux >= 3.4")))
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

(defvar kitty-gfx--sixel-encode-timed-out nil
  "Non-nil when the most recent `kitty-gfx--sixel-run-encoder' timed out.
Reset at the start of every run; consulted by the failure-feedback
path so the user message can distinguish a hung encoder (watchdog
fired) from a plain non-zero exit.")

(defun kitty-gfx--sixel-run-encoder (program timeout dest-buffer args)
  "Run PROGRAM with ARGS, writing stdout into DEST-BUFFER.
TIMEOUT, when a positive number, terminates the process after that many
seconds and signals an error.  Errors include captured stderr.
Returns t on success, nil on failure (failures are logged, not signalled)."
  (setq kitty-gfx--sixel-encode-timed-out nil)
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
              (setq kitty-gfx--sixel-encode-timed-out t)
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
      (when (process-live-p proc) (delete-process proc))
      (when timer (cancel-timer timer))
      (when (buffer-live-p stderr-buf) (kill-buffer stderr-buf)))))

(defun kitty-gfx--sixel-img2sixel-tuning-args ()
  "Return img2sixel arguments for the dither and palette defcustoms."
  (append (when kitty-gfx-sixel-dither
            (list "-d" kitty-gfx-sixel-dither))
          (when kitty-gfx-sixel-colors
            (list "-p" (number-to-string kitty-gfx-sixel-colors)))))

(defun kitty-gfx--sixel-imagemagick-tuning-args ()
  "Return ImageMagick arguments for the dither and palette defcustoms.
\"atkinson\" falls back to Floyd-Steinberg since ImageMagick has no
Atkinson dither."
  (append (pcase kitty-gfx-sixel-dither
            ("none" (list "+dither"))
            ((or "fs" "atkinson") (list "-dither" "FloydSteinberg"))
            (_ nil))
          (when kitty-gfx-sixel-colors
            (list "-colors" (number-to-string kitty-gfx-sixel-colors)))))

(defun kitty-gfx--sixel-prescale (png-file pixel-w pixel-h)
  "Resize PNG-FILE to fit PIXEL-W x PIXEL-H, returning a temp PNG path.
Returns nil when the source already fits, when no ImageMagick binary
is available, or when the resize fails — callers then encode the
original file.  The resize is bounded by the same watchdog as the
encoder runs (`kitty-gfx--sixel-run-encoder').  The caller owns and
must delete the returned file."
  (let ((magick (or (executable-find "magick")
                    (executable-find "convert")))
        (px (kitty-gfx--image-pixel-size png-file)))
    (when (and magick px
               (or (> (car px) pixel-w) (> (cdr px) pixel-h)))
      (let ((out (make-temp-file "kitty-gfx-prescale-" nil ".png"))
            (ok nil))
        (unwind-protect
            (setq ok (with-temp-buffer
                       (kitty-gfx--sixel-run-encoder
                        magick kitty-gfx-sixel-encoder-timeout (current-buffer)
                        (list png-file "-resize"
                              (format "%dx%d" pixel-w pixel-h) out))))
          (unless ok (ignore-errors (delete-file out))))
        (when ok
          (kitty-gfx--log "sixel-prescale: %s %dx%d -> %s (fit %dx%d)"
                          png-file (car px) (cdr px) out pixel-w pixel-h)
          out)))))

(defun kitty-gfx--sixel-encode (png-file cols rows)
  "Encode PNG-FILE as Sixel data for COLS x ROWS cells.
Returns Sixel data string or nil on failure.
Computes pixel dimensions from cell size.  The encoder is selected via
`kitty-gfx-sixel-encoder-program' (auto-detected when nil) and bounded
by `kitty-gfx-sixel-encoder-timeout'.  Dither and palette size come
from `kitty-gfx-sixel-dither' and `kitty-gfx-sixel-colors', with
`kitty-gfx-sixel-encoder-args' appended as the raw escape hatch.
When img2sixel encodes a source larger than the target pixel box and
ImageMagick is available, the image is pre-scaled to a temp PNG first
so img2sixel quantizes the small image instead of the full-size one."
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
      (let ((kind (car resolved))
            (path (cdr resolved))
            (prescaled nil))
        (unwind-protect
            (progn
              (when (eq kind 'img2sixel)
                (setq prescaled
                      (kitty-gfx--sixel-prescale png-file pixel-w pixel-h)))
              (let* ((base (file-name-nondirectory path))
                     (input (or prescaled png-file))
                     (args (pcase kind
                             ('img2sixel
                              (append (kitty-gfx--sixel-img2sixel-tuning-args)
                                      kitty-gfx-sixel-encoder-args
                                      (unless prescaled
                                        (list "-w" (number-to-string pixel-w)
                                              "-h" (number-to-string pixel-h)))
                                      (list input)))
                             ('imagemagick
                              (append (list input)
                                      (list "-geometry"
                                            (format "%dx%d" pixel-w pixel-h))
                                      (kitty-gfx--sixel-imagemagick-tuning-args)
                                      kitty-gfx-sixel-encoder-args
                                      (list "sixel:-"))))))
                (when (string-prefix-p "convert" (downcase base))
                  (kitty-gfx--log "sixel-encode: WARNING deprecated `convert' resolved (%s); install `magick' or `img2sixel'" path))
                (kitty-gfx--log "sixel-encode: %s -> %dx%d pixels via %s (%s%s)"
                                input pixel-w pixel-h base kind
                                (if prescaled ", pre-scaled" ""))
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (if (kitty-gfx--sixel-run-encoder
                       path kitty-gfx-sixel-encoder-timeout
                       (current-buffer) args)
                      (let ((data (buffer-string)))
                        (kitty-gfx--log "sixel-encode: success (%d bytes)" (length data))
                        data)
                    nil))))
          (when prescaled
            (ignore-errors (delete-file prescaled))))))))

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

(defun kitty-gfx--sixel-file-stamp (file)
  "Return FILE's modification time, or t when FILE is unreadable.
Stored in the `kitty-gfx-sixel-failed' overlay property so a failed
encode is retried once the file changes on disk."
  (or (file-attribute-modification-time (file-attributes file)) t))

(defun kitty-gfx--sixel-failure-current-p (ov file)
  "Return non-nil when OV's recorded Sixel encode failure still applies.
The failure marker stores FILE's mtime at failure time; when FILE has
changed on disk since, the marker is cleared, OV's blank display cells
are restored, and nil is returned so the caller re-runs the encoder.
Returns nil when OV carries no failure marker."
  (let ((failed (overlay-get ov 'kitty-gfx-sixel-failed)))
    (cond
     ((null failed) nil)
     ((equal failed (kitty-gfx--sixel-file-stamp file)) t)
     (t
      (overlay-put ov 'kitty-gfx-sixel-failed nil)
      (overlay-put ov 'display
                   (concat (kitty-gfx--make-blank-display
                            (overlay-get ov 'kitty-gfx-cols)
                            (overlay-get ov 'kitty-gfx-rows))
                           "\n"))
      (kitty-gfx--log "sixel-place: %s changed on disk, retrying failed overlay"
                      file)
      nil))))

(defun kitty-gfx--sixel-report-encode-failure (ov file)
  "Surface a Sixel encode failure for FILE on overlay OV.
Replaces OV's blank display cells with a visible failure marker and
marks OV so subsequent refreshes stop retrying the encoder.  The
marker records FILE's current mtime; a change on disk clears it (see
`kitty-gfx--sixel-failure-current-p'), as does removing or
re-displaying the image.  Shows a one-time echo-area message (per
file, per session) naming the encoder and whether the timeout
watchdog killed it."
  (overlay-put ov 'kitty-gfx-sixel-failed (kitty-gfx--sixel-file-stamp file))
  (overlay-put ov 'display "[sixel: encode failed]\n")
  (let ((encoder (kitty-gfx--sixel-resolve-encoder)))
    (kitty-gfx--message-once
     (concat "sixel-encode-failed:" file)
     (format "kitty-gfx: Sixel encode %s for %s (encoder: %s)"
             (if kitty-gfx--sixel-encode-timed-out
                 (format "timed out after %gs" kitty-gfx-sixel-encoder-timeout)
               "failed")
             (file-name-nondirectory file)
             (if encoder (cdr encoder) "none found")))))

(defun kitty-gfx--sixel-place (ov _image-id _placement-id cols rows term-row term-col)
  "Place Sixel image at terminal position.
Encodes on-demand if not cached, then emits DCS sequence.  An overlay
whose encode already failed shows a text marker and is skipped, so a
broken or hanging encoder is not re-run on every refresh; the failure
sticks until the file changes on disk or the image is re-displayed."
  (let* ((file (overlay-get ov 'kitty-gfx-file))
         (png (gethash file kitty-gfx--sixel-cache))
         (cache-path (kitty-gfx--sixel-cache-path file cols rows))
         (sixel-data nil))
    (cond
     ((kitty-gfx--sixel-failure-current-p ov file)
      (kitty-gfx--log "sixel-place: skipping failed overlay for %s" file))
     ((not png)
      (kitty-gfx--log "sixel-place: no PNG cached for %s" file))
     (t
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
        (if (not sixel-data)
            (kitty-gfx--sixel-report-encode-failure ov file)
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
         (format "\e7\e[%d;%dH%s\e8" term-row term-col sixel-data)))))))

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

(defun kitty-gfx--truncate-utf8 (text max-bytes)
  "Return TEXT truncated so its UTF-8 encoding is at most MAX-BYTES.
Truncation happens on character boundaries, so the result is always
valid UTF-8."
  (while (> (length (encode-coding-string text 'utf-8)) max-bytes)
    (setq text (substring text 0 -1)))
  text)

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
  (let* ((raw-text (or (overlay-get ov 'kitty-gfx-render-text)
                       (overlay-get ov 'kitty-gfx-heading-text)))
         ;; Strip text properties — org-modern, font-lock, etc. can
         ;; attach display/face properties that corrupt OSC 66 payload.
         (text (kitty-gfx--truncate-utf8
                (substring-no-properties raw-text) 4096))
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
    (kitty-gfx--terminal-send
     (format "\e7\e[%d;%dH%s\e]66;%s;%s\a\e[0m\e8"
             row col sgr meta text))
    (overlay-put ov 'kitty-gfx-heading-emitted t)))

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

(defun kitty-gfx--heading-reset (ov)
  "Drop heading overlay OV's cached position and show its plain text.
Used whenever OV stops being rendered as a multicell block (scrolled
out, folded away, collapsed, buffer hidden).  Deliberately sends NO
erase sequence: the terminal scrolls or redraws those cells together
with the buffer text Emacs knows about, so erasing at a cached
position would wipe whatever content now lives there (issue seen as
blanked body lines after fold/scroll)."
  (overlay-put ov 'kitty-gfx-last-row nil)
  (overlay-put ov 'kitty-gfx-last-col nil)
  (overlay-put ov 'kitty-gfx-heading-emitted nil)
  (let ((text (overlay-get ov 'kitty-gfx-heading-text)))
    (when (and text (not (equal (overlay-get ov 'display) text)))
      (overlay-put ov 'display text))))

(defun kitty-gfx--heading-fit-text (text cell-s max-cols)
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

(defun kitty-gfx--heading-sync-reservation (ov cols cell-s)
  "Make OV reserve exactly COLS x CELL-S terminal cells with spaces.
Sets the `display' property to COLS spaces and the `after-string' to
\(CELL-S - 1) lines of COLS spaces, so Emacs's redisplay matrix tracks
the precise rectangle the multicell block will occupy.  Flags
`kitty-gfx--heading-flush-needed' when anything changed so the refresh
cycle flushes the spaces to the terminal before emitting OSC 66."
  (let ((spaces (make-string cols ?\s)))
    (unless (equal (overlay-get ov 'display) spaces)
      (overlay-put ov 'display spaces)
      (setq kitty-gfx--heading-flush-needed t))
    (when (> cell-s 1)
      (let ((after (apply #'concat
                          (make-list (1- cell-s) (concat spaces "\n")))))
        (unless (equal (overlay-get ov 'after-string) after)
          (overlay-put ov 'after-string after)
          (setq kitty-gfx--heading-flush-needed t))))))

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
  ;; heading-fit-text: full fit, truncation, and wide chars
  (cl-assert (equal (kitty-gfx--heading-fit-text "Hello World" 2 79)
                    "Hello World")
             nil "fit-text should keep text that fits")
  (cl-assert (equal (kitty-gfx--heading-fit-text "Hello World" 2 10)
                    "Hello")
             nil "fit-text should truncate to max-cols")
  (cl-assert (equal (kitty-gfx--heading-fit-text "日本語" 2 8) "日本")
             nil "fit-text should count double-width chars")
  (cl-assert (equal (kitty-gfx--heading-fit-text "abc" 2 1) "")
             nil "fit-text should return empty when nothing fits")
  ;; heading-sync-reservation: display + after-string sized to the block
  (with-temp-buffer
    (insert "* Reserve Me\nBody\n")
    (let* ((kitty-gfx--heading-flush-needed nil)
           (ov (kitty-gfx--make-heading-overlay 1 13 "Reserve Me" 2.0 1)))
      (kitty-gfx--heading-sync-reservation ov 20 2)
      (cl-assert kitty-gfx--heading-flush-needed
                 nil "reservation change should flag a flush")
      (cl-assert (equal (overlay-get ov 'display) (make-string 20 ?\s))
                 nil "display should be block-width spaces")
      (cl-assert (equal (overlay-get ov 'after-string)
                        (concat (make-string 20 ?\s) "\n"))
                 nil "after-string should be one block-width space line")
      (setq kitty-gfx--heading-flush-needed nil)
      (kitty-gfx--heading-sync-reservation ov 20 2)
      (cl-assert (not kitty-gfx--heading-flush-needed)
                 nil "unchanged reservation should not flag a flush")
      (kitty-gfx--heading-reset ov)
      (cl-assert (null (overlay-get ov 'kitty-gfx-last-row))
                 nil "reset should clear cached row")
      (cl-assert (equal (overlay-get ov 'display) "Reserve Me")
                 nil "reset should restore plain text display")
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
         (cols (* (string-width text) cell-s))
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
      (let ((spaceline (concat (make-string
                                (min cols (max 1 (1- (frame-width))))
                                ?\s)
                               "\n")))
        (overlay-put ov 'after-string
                     (apply #'concat
                            (make-list (1- cell-s) spaceline)))))
    ;; High priority so kitty-gfx overlays win over org-modern etc.
    (overlay-put ov 'priority 100)
    (overlay-put ov 'modification-hooks
                 (list #'kitty-gfx--heading-modified))
    (overlay-put ov 'insert-in-front-hooks
                 (list #'kitty-gfx--heading-modified))
    (overlay-put ov 'insert-behind-hooks
                 (list #'kitty-gfx--heading-modified))
    (add-hook 'change-major-mode-hook #'kitty-gfx--remove-buffer-graphics nil t)
    (push ov kitty-gfx--overlays)
    (kitty-gfx--log "make-heading-ov: L%d scale=%.2f s=%d n=%d d=%d text=%S beg=%d end=%d"
                     level (float scale) cell-s frac-n frac-d text beg end)
    ov))

(defun kitty-gfx--heading-modified (ov after &rest _args)
  "Modification hook for heading overlays.
When the heading text is edited (AFTER is non-nil), the overlay stays
in place: it is marked stale and its display property is dropped so
the live buffer text shows at normal size while typing — Emacs
redrawing the line over the multicell block erases it (kitty's
overwrite rule), so no manual erase is sent.  A debounced rescan then
updates the overlay in place (or removes it when the line is no
longer a heading)."
  (when (and after (overlay-buffer ov))
    (unless (overlay-get ov 'kitty-gfx-heading-stale)
      (kitty-gfx--log "heading-modified: marking overlay stale at %d"
                       (overlay-start ov))
      (overlay-put ov 'kitty-gfx-heading-stale t)
      (overlay-put ov 'kitty-gfx-heading-emitted nil)
      (overlay-put ov 'display nil)
      (overlay-put ov 'kitty-gfx-last-row nil)
      (overlay-put ov 'kitty-gfx-last-col nil))
    (when kitty-gfx--heading-rescan-timer
      (cancel-timer kitty-gfx--heading-rescan-timer))
    (setq kitty-gfx--heading-rescan-timer
          (let ((buf (current-buffer)))
            (run-at-time 0.2 nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (setq kitty-gfx--heading-rescan-timer nil)
                               (kitty-gfx--heading-rescan-stale)))))))))

(defun kitty-gfx--heading-rescan-stale ()
  "Update every stale heading overlay in the current buffer in place.
Overlays whose line still matches `org-heading-regexp' are re-anchored
and refreshed via `kitty-gfx--heading-update-overlay'; the rest are
removed and their line is re-scanned so a heading whose level (and thus
scale) changed gets a fresh overlay."
  (when (and kitty-graphics-mode (derived-mode-p 'org-mode))
    (let ((changed 0))
      (dolist (ov (copy-sequence kitty-gfx--overlays))
        (when (and (overlay-get ov 'kitty-gfx-heading)
                   (overlay-get ov 'kitty-gfx-heading-stale)
                   (overlay-buffer ov))
          (cl-incf changed)
          (unless (kitty-gfx--heading-update-overlay ov)
            (let ((line-beg (save-excursion
                              (goto-char (overlay-start ov))
                              (line-beginning-position)))
                  (line-end (save-excursion
                              (goto-char (overlay-start ov))
                              (line-end-position))))
              (kitty-gfx--remove-overlay ov)
              (kitty-gfx--org-apply-heading-sizes line-beg line-end)))))
      (when (> changed 0)
        (kitty-gfx--log "heading-rescan-stale: refreshed %d overlays" changed)
        (kitty-gfx--schedule-refresh t)))))

(defun kitty-gfx--heading-update-overlay (ov)
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
                                      (overlay-get other 'kitty-gfx-heading)
                                      (not (overlay-get other 'kitty-gfx-heading-stale))))
                               (overlays-in line-beg line-end))))
        (let* ((level (org-current-level))
               (scale (and level (alist-get level kitty-gfx-heading-scales)))
               (cell-s (overlay-get ov 'kitty-gfx-heading-cell-s))
               (decomposed (and scale (kitty-gfx--decompose-scale scale))))
          (when (and scale (> scale 1.0)
                     (= cell-s (nth 0 decomposed)))
            (let* ((raw (org-get-heading t t t t))
                   (text (substring-no-properties
                          (if (fboundp 'org-link-display-format)
                              (org-link-display-format raw)
                            raw))))
              (move-overlay ov line-beg line-end)
              (overlay-put ov 'kitty-gfx-heading-text text)
              (overlay-put ov 'kitty-gfx-heading-scale (float scale))
              (overlay-put ov 'kitty-gfx-heading-frac-n (nth 1 decomposed))
              (overlay-put ov 'kitty-gfx-heading-frac-d (nth 2 decomposed))
              (overlay-put ov 'kitty-gfx-heading-level level)
              (overlay-put ov 'kitty-gfx-cols (* (string-width text) cell-s))
              (overlay-put ov 'display text)
              (overlay-put ov 'kitty-gfx-heading-stale nil)
              (overlay-put ov 'kitty-gfx-heading-emitted nil)
              (kitty-gfx--log "heading-update: L%d re-anchored text=%S" level text)
              t)))))))

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
        (kitty-gfx--schedule-refresh t)))))

(defun kitty-gfx--heading-scan-window (win)
  "Apply heading sizes around WIN's displayed region.
Scans from two screenfuls above `window-start' to two screenfuls
below `window-end'.  Idempotent: already-instrumented headings are
skipped by `kitty-gfx--org-apply-heading-sizes'.  No-op unless WIN's
buffer has heading sizes enabled."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (when (and kitty-gfx--heading-sizes-enabled
                 (derived-mode-p 'org-mode))
        (let ((margin (* 2 (max 1 (window-body-height win)))))
          (save-excursion
            (goto-char (window-start win))
            (forward-line (- margin))
            (let ((beg (point)))
              (goto-char (or (window-end win t) (point-max)))
              (forward-line margin)
              (kitty-gfx--org-apply-heading-sizes beg (point)))))))))

(defun kitty-gfx--heading-scan-visible ()
  "Run a visible-region heading scan for every relevant window.
Covers windows whose buffer has heading sizes enabled when
`kitty-gfx-heading-scan-visible-only' is active."
  (when kitty-gfx-heading-scan-visible-only
    (walk-windows
     (lambda (w)
       (when (buffer-local-value 'kitty-gfx--heading-sizes-enabled
                                 (window-buffer w))
         (kitty-gfx--heading-scan-window w)))
     nil 'visible)))

(defun kitty-gfx--heading-apply-initial ()
  "Instrument headings after enabling sizes in the current buffer.
Scans only the displayed viewport when
`kitty-gfx-heading-scan-visible-only' is non-nil (later regions are
picked up by the scroll and window-change hooks); otherwise scans the
whole buffer."
  (if kitty-gfx-heading-scan-visible-only
      (let ((win (get-buffer-window nil 'visible)))
        (when win
          (kitty-gfx--heading-scan-window win)))
    (kitty-gfx--org-apply-heading-sizes)))

(defun kitty-gfx--org-remove-heading-sizes ()
  "Remove all heading size overlays from the current buffer.
Removing the overlays drops their space reservations, so the next
redisplay redraws the heading lines as plain text over the multicell
blocks, which erases them (kitty's overwrite rule)."
  (setq kitty-gfx--heading-sizes-enabled nil)
  (let ((count 0))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'kitty-gfx-heading)
        (kitty-gfx--remove-overlay ov)
        (cl-incf count)))
    (kitty-gfx--log "remove-heading-sizes: removed %d" count)
    (when (> count 0)
      (kitty-gfx--schedule-refresh t))))

(defvar-local kitty-gfx--heading-saved-modes nil
  "Alist of (MODE . WAS-ACTIVE) saved when heading sizes are enabled.
Used to restore conflicting minor modes when heading sizes are disabled.")

(defun kitty-gfx--heading-disable-conflicting ()
  "Disable minor modes that conflict with OSC 66 heading rendering.
The modes come from `kitty-gfx-heading-conflicting-modes'; their state
is saved for restoration by `kitty-gfx--heading-restore-modes'.
Folded headings are left alone — they are skipped during rendering via
`kitty-gfx--in-folded-region-p'."
  (setq kitty-gfx--heading-saved-modes nil)
  (dolist (mode kitty-gfx-heading-conflicting-modes)
    (when (and (boundp mode) (symbol-value mode) (fboundp mode))
      (push (cons mode t) kitty-gfx--heading-saved-modes)
      (funcall mode -1)
      (kitty-gfx--log "heading-preview: disabled %s" mode)))
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
Enters a clean preview mode: the minor modes listed in
`kitty-gfx-heading-conflicting-modes' are temporarily disabled.
Folding is preserved; folded headings render as plain text until
revealed.  Toggling off restores previous state.
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
    (setq kitty-gfx--heading-sizes-enabled t)
    (kitty-gfx--heading-disable-conflicting)
    (kitty-gfx--heading-apply-initial)
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

(defun kitty-gfx--terminal-image-rows (term)
  "Return the list of terminal rows covered by image placements on TERM.
Reads the per-window placements recorded by
`kitty-gfx--record-image-placement' across all buffers, keeping only
windows that live on TERM.  Used to keep scaled headings from
overwriting image pixels."
  (let ((rows nil))
    (dolist (buf (buffer-list))
      (dolist (ov (buffer-local-value 'kitty-gfx--overlays buf))
        (unless (overlay-get ov 'kitty-gfx-heading)
          (dolist (placement (overlay-get ov 'kitty-gfx-placements))
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

(defun kitty-gfx--emit-heading-overlays (term)
  "Phase 2: emit OSC 66 for visible heading overlays on terminal TERM.
Runs inside the caller's `kitty-gfx--with-terminal' + synchronized-output
block, so phase-1 placement and phase-2 emission stay in one terminal
frame (interleaved Emacs redisplay would otherwise corrupt freshly-placed
multicell blocks).  Only buffers whose canonical heading window lives on
TERM are processed — the cached row/col positions were computed for that
window, so emitting them on any other terminal would paint blocks at
coordinates belonging to a different client's screen.
Skips headings already emitted at their current position and
detects row collisions — if a heading would occupy terminal rows already
taken by another heading or by an image placement, it is skipped to
prevent multicell block / pixel corruption."
  (let ((image-rows (kitty-gfx--terminal-image-rows term)))
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((canonical (and kitty-gfx--overlays
                                (kitty-gfx--heading-canonical-window buf))))
            (when (and canonical
                       (eq (frame-terminal (window-frame canonical)) term))
              (let ((occupied (make-hash-table :test 'eql)))
                (dolist (r image-rows)
                  (puthash r t occupied))
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
                             (not (overlay-get ov 'kitty-gfx-heading-stale))
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
                        (kitty-gfx--place-heading ov)))))))))))))

(defun kitty-gfx--refresh-inhibited-p ()
  "Return non-nil if painting now would disturb user feedback.
Only an active minibuffer inhibits the actual paint: placing images
writes cursor-saved/restored escape sequences to the tty and never
touches the echo area, so a lingering `current-message' (e.g. doc-view's
\"Type ... to toggle\" or a mode-enable notice) must NOT block an
explicitly scheduled refresh — in an idle daemon client that message
never clears and the image would never appear.  The high-frequency
`post-command-hook' scheduler still backs off on `current-message' (see
`kitty-gfx--on-redisplay') to avoid flicker over transient feedback."
  (active-minibuffer-window))

(defun kitty-gfx--refresh ()
  "Re-place all visible images after redisplay using direct placements.
Relies on placement IDs (p=PID) — re-placing with the same PID
replaces the previous placement without needing to delete first.
Caches last position per overlay to skip redundant re-placements.
Deletes placements for overlays that scrolled out of view.
Output is routed per window to that window's terminal and wrapped in a
per-terminal synchronized-output pair (BSU/ESU) to prevent flicker, so
several daemon clients on different ttys render correctly at once."
  (when (and kitty-graphics-mode
             (kitty-gfx--any-visible-overlays-p)
             (not (kitty-gfx--refresh-inhibited-p)))
    ;; Force redisplay only when a caller flagged that display properties
    ;; were just mutated (overlay creation, window/buffer-change handlers)
    ;; so `posn-at-point' would otherwise see stale pixel positions.
    ;; Routine `post-command-hook' refreshes skip this — issue #19.
    (when kitty-gfx--force-redisplay
      (setq kitty-gfx--force-redisplay nil)
      (redisplay t))
    (let ((total-overlays 0)
          (placed 0)
          (hidden 0)
          (pruned 0)
          (by-term nil))
      (kitty-gfx--log "refresh: begin")
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
                (unless (terminal-parameter term 'kitty-gfx-backend)
                  (kitty-gfx--detect-protocol))
                (kitty-gfx--query-cell-size)
                (when (eq (terminal-parameter term 'kitty-gfx-backend) 'kitty)
                  (kitty-gfx--query-text-sizing-support)))
              (kitty-gfx--with-terminal term
                (kitty-gfx--sync-begin)
                (unwind-protect
                    (progn
                      ;; Phase 1: image placement + heading position/erase
                      ;; for every window on this terminal.
                      (dolist (win wins)
                        (with-current-buffer (window-buffer win)
                          (when kitty-gfx--overlays
                            ;; A single overlay can be visible in multiple
                            ;; windows showing the same buffer.  Its legacy
                            ;; last-row/last-col mirror the placement for the
                            ;; window currently refreshed; per-window tracking
                            ;; keeps individual terminal regions deletable
                            ;; when one window later disappears.
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
                              (kitty-gfx--log "refresh: win=%s buf=%s overlays=%d bottom=%d term=%s"
                                              win (buffer-name) (length kitty-gfx--overlays)
                                              win-bottom term)
                              (dolist (ov kitty-gfx--overlays)
                                (cl-incf total-overlays)
                                (kitty-gfx--refresh-overlay ov win win-bottom)
                                (if (overlay-get ov 'kitty-gfx-last-row)
                                    (cl-incf placed)
                                  (cl-incf hidden)))))))
                      ;; Phase 2: emit OSC 66 for heading overlays whose
                      ;; buffer is shown on this terminal, inside the SAME
                      ;; sync block as phase 1 so mini-redraws cannot corrupt
                      ;; the freshly-placed multicell blocks.
                      (if (and kitty-gfx--heading-flush-needed
                               (progn
                                 (setq kitty-gfx--heading-flush-needed nil)
                                 (not (redisplay))))
                          (kitty-gfx--schedule-refresh t)
                        (kitty-gfx--emit-heading-overlays term)))
                  (kitty-gfx--sync-end)))))
        ;; mpv/casty repositioning runs once, after all terminals.  These
        ;; send no direct terminal escapes (frames arrive via the routed
        ;; process filter), so they need not sit inside a sync block.  Each
        ;; picks its own canonical window, constrained to its launch
        ;; terminal, and fires at most once per refresh regardless of how
        ;; many windows show the buffer.
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when kitty-gfx--mpv-overlay
              (kitty-gfx--refresh-mpv-overlay))))
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when kitty-gfx--browser-overlay
              (kitty-gfx--refresh-browser-overlay)))))
      (kitty-gfx--log "refresh: done total=%d placed=%d hidden=%d pruned=%d"
                       total-overlays placed hidden pruned)
      (kitty-gfx--update-window-signatures))))

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
               ;; In `direct' mode the entire image must fit, since
               ;; `a=p,c,r' places an image at an absolute screen
               ;; position and some terminals corrupt or scroll when
               ;; that region overflows the window.  In `placeholder'
               ;; mode the cells are normal text that Emacs naturally
               ;; clips to the visible buffer area, so partial
               ;; visibility is fine.
               (or (eq (kitty-gfx--effective-placement-mode) 'placeholder)
                   (<= (+ (car pos) rows -1) win-bottom)))
          ;; Visible and fits — place if position changed
          (let ((new-row (car pos))
                (new-col (cdr pos)))
            (cond
             ((and (eql new-row last-row)
                   (eql new-col last-col))
              (kitty-gfx--log "refresh-ov: pid=%d unchanged at row=%d col=%d"
                              pid new-row new-col))
             ((not (kitty-gfx--ensure-transmitted
                    (overlay-get ov 'kitty-gfx-file) id))
              (kitty-gfx--log "refresh-ov: pid=%d deferred (transmit queued or converting)"
                              pid))
             (t
              (kitty-gfx--log "refresh-ov: pid=%d moved %s -> row=%d col=%d"
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
              ;; `kitty-gfx--place-placeholder', so it is not covered here.
              (when last-row
                (let* ((old-cols (plist-get placement-data :cols))
                       (old-rows (plist-get placement-data :rows))
                       (shrunk (or (and old-cols (< cols old-cols))
                                   (and old-rows (< rows old-rows)))))
                  (cond
                   ((eq kitty-gfx--active-backend 'sixel)
                    (funcall (kitty-gfx--backend-fn 'delete) ov id pid))
                   ((and (eq kitty-gfx--active-backend 'kitty)
                         (eq (kitty-gfx--effective-placement-mode) 'direct)
                         shrunk)
                    ;; The terminal placement was emitted with the
                    ;; per-window PID recorded on the overlay's
                    ;; placement, NOT the overlay-level PID, so the
                    ;; delete APC must address that PID.  Fall back to
                    ;; the overlay-level PID only when no per-window
                    ;; entry exists.
                    (let ((win-pid (or (plist-get placement-data :pid)
                                       pid)))
                      (kitty-gfx--log
                       "refresh-ov: pid=%d (win-pid=%d) shrink %dx%d -> %dx%d, delete first"
                       pid win-pid old-cols old-rows cols rows)
                      (funcall (kitty-gfx--backend-fn 'delete)
                               ov id win-pid))))))
              (overlay-put ov 'kitty-gfx-last-row new-row)
              (overlay-put ov 'kitty-gfx-last-col new-col)
              ;; Pass nil so a brand-new (overlay, window) placement gets its
              ;; own unique id instead of the shared overlay base pid; reuse
              ;; the recorded id on a move.  Use the returned effective id for
              ;; the terminal placement so record and emit never diverge.
              (setq pid (kitty-gfx--record-image-placement
                         ov win new-row new-col cols rows nil))
              (funcall (kitty-gfx--backend-fn 'place)
                       ov id pid cols rows new-row new-col))))
        ;; Not visible or overflows — delete if was placed in this window
        (when placement
          (kitty-gfx--log "refresh-ov: pid=%d hiding in win=%s (was row=%d col=%d)"
                          pid win last-row last-col)
          (kitty-gfx--delete-image-placement ov placement)
          (kitty-gfx--forget-image-placement ov win)
          (overlay-put ov 'kitty-gfx-last-row nil)
          (overlay-put ov 'kitty-gfx-last-col nil)))))))

(defun kitty-gfx--heading-canonical-window (buf)
  "Return the single window that renders BUF's scaled headings.
Mirrors `kitty-gfx--browser-canonical-window': prefers the selected
window when it shows BUF on a text terminal, else the first visible
text-terminal window showing BUF.  Heading overlays cache one terminal
position (`kitty-gfx-last-row'/`kitty-gfx-last-col') and one `window'
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

(defun kitty-gfx--refresh-heading-overlay (ov win win-bottom)
  "Refresh heading overlay OV in WIN.
WIN-BOTTOM is WIN's bottom edge.  Phase 1 of two-phase heading
refresh: computes the screen position, fits the heading text to the
window width, syncs the space reservation, and caches the new
position.  Does NOT emit OSC 66 — that happens in phase 2
\(`kitty-gfx--emit-heading-overlays') after the reservation spaces
were flushed to the terminal.  Never erases at cached coordinates:
when the heading moved, the terminal scrolled the old block together
with the surrounding text, so the cached position now holds live
content that an erase would destroy.  Collapsed headings (their own
fold ellipsis at end of line) and hidden ones fall back to plain text
via `kitty-gfx--heading-reset' — Emacs redrawing the line then clears
the block.  Stale overlays (mid-edit) are left untouched, and only
the buffer's canonical window is processed; the overlay's `window'
property is pinned to it so other windows showing the buffer display
plain heading text."
  (when (and (not (overlay-get ov 'kitty-gfx-heading-stale))
             (eq win (kitty-gfx--heading-canonical-window (overlay-buffer ov))))
    (unless (eq (overlay-get ov 'window) win)
      (overlay-put ov 'window win)
      (overlay-put ov 'kitty-gfx-last-row nil)
      (overlay-put ov 'kitty-gfx-last-col nil)
      (overlay-put ov 'kitty-gfx-heading-emitted nil)
      (kitty-gfx--schedule-refresh t))
    (let ((pos (kitty-gfx--overlay-screen-pos ov win))
          (rows (overlay-get ov 'kitty-gfx-rows))
          (last-row (overlay-get ov 'kitty-gfx-last-row))
          (last-col (overlay-get ov 'kitty-gfx-last-col)))
      (if (and pos
               (<= (car pos) win-bottom)
               (<= (+ (car pos) rows -1) win-bottom)
               (not (kitty-gfx--in-folded-region-p (overlay-end ov))))
          (let* ((new-row (car pos))
                 (new-col (cdr pos))
                 (cell-s (overlay-get ov 'kitty-gfx-heading-cell-s))
                 (max-cols (max 0 (- (nth 2 (window-body-edges win))
                                     new-col)))
                 (fit (kitty-gfx--heading-fit-text
                       (overlay-get ov 'kitty-gfx-heading-text)
                       cell-s max-cols))
                 (cols (* (string-width fit) cell-s)))
            (if (zerop cols)
                (kitty-gfx--heading-reset ov)
              (overlay-put ov 'kitty-gfx-render-text fit)
              (overlay-put ov 'kitty-gfx-cols cols)
              (unless (and (eql new-row last-row)
                           (eql new-col last-col))
                (overlay-put ov 'kitty-gfx-heading-emitted nil))
              (overlay-put ov 'kitty-gfx-last-row new-row)
              (overlay-put ov 'kitty-gfx-last-col new-col)
              (kitty-gfx--heading-sync-reservation ov cols cell-s)
              (kitty-gfx--log "refresh-heading: L%d visible at row=%d col=%d cols=%d"
                              (overlay-get ov 'kitty-gfx-heading-level)
                              new-row new-col cols)))
        (kitty-gfx--heading-reset ov)))))

(defvar kitty-gfx--refresh-pending nil
  "Non-nil if a refresh was requested during the cooldown period.")

;; `kitty-gfx--force-redisplay' is declared near top of file alongside
;; `kitty-gfx--render-timer'.  It is set by paths that just mutated
;; display properties (overlay creation, window/buffer-change handlers)
;; and consumed/cleared by `kitty-gfx--refresh'.  Routine
;; `post-command-hook' refreshes leave it nil so we don't pay the
;; forced-redisplay cost every keystroke — issue #19.

(defun kitty-gfx--schedule-refresh (&optional force-redisplay)
  "Schedule an image refresh using leading-edge debounce.
On the first call, refresh is scheduled via `run-at-time' 0 (fires
after the current redisplay completes) and a cooldown timer starts
\(duration `kitty-gfx-render-delay').  Calls during cooldown are
suppressed but flagged; when the cooldown expires a single trailing
refresh fires to capture the final state.

When FORCE-REDISPLAY is non-nil, the next refresh will call
`(redisplay t)' before measuring positions — needed when the caller
just mutated display properties and `posn-at-point' would otherwise
return stale coordinates."
  (when force-redisplay
    (setq kitty-gfx--force-redisplay t)
    (kitty-gfx--invalidate-window-signatures))
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
  "Handle window scroll for image refresh.
Also extends heading instrumentation around WIN's new region when
visible-only heading scanning is active."
  (when (and kitty-gfx-heading-scan-visible-only
             (buffer-local-value 'kitty-gfx--heading-sizes-enabled
                                 (window-buffer win)))
    (kitty-gfx--heading-scan-window win))
  (when (buffer-local-value 'kitty-gfx--overlays (window-buffer win))
    (kitty-gfx--log "on-scroll: win=%s buf=%s" win (buffer-name (window-buffer win)))
    (set-window-parameter win 'kitty-gfx-sig nil)
    (kitty-gfx--schedule-refresh)))

(defun kitty-gfx--on-buffer-change (_frame-or-window)
  "Handle buffer change for image refresh.
Deletes placements for buffers no longer visible in any window,
then invalidates position caches and schedules a refresh.
Newly displayed org buffers with heading sizes enabled get their
viewport instrumented via `kitty-gfx--heading-scan-visible'."
  (kitty-gfx--log "on-buffer-change: cleaning up non-visible placements")
  (kitty-gfx--heading-scan-visible)
  (kitty-gfx--invalidate-window-signatures)
  ;; Find which buffers are currently visible
  (let ((visible-bufs nil))
    (walk-windows (lambda (w) (push (window-buffer w) visible-bufs))
                  nil 'visible)
    (kitty-gfx--log "on-buffer-change: visible-bufs=(%s)"
                    (mapconcat #'buffer-name visible-bufs ", "))
    ;; Drop per-window records on any mpv overlay whose buffer is no
    ;; longer visible OR whose recorded window now shows a different
    ;; buffer.  Prevents stale window entries from confusing
    ;; `kitty-gfx--mpv-canonical-window'.
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and kitty-gfx--mpv-overlay
                   (overlay-buffer kitty-gfx--mpv-overlay))
          (let ((ov kitty-gfx--mpv-overlay))
            (dolist (entry (copy-sequence
                            (overlay-get ov 'kitty-gfx-placements)))
              (let ((w (car entry)))
                (unless (and (window-live-p w)
                             (eq (window-buffer w)
                                 (overlay-buffer ov)))
                  (kitty-gfx--forget-image-placement ov w))))))))
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
                  (kitty-gfx--heading-reset ov)
                ;; Image overlay — delete all terminal placements, including
                ;; multiple windows that were showing this buffer.
                (kitty-gfx--delete-image-placements ov))))))))
  ;; Reset cache for visible buffers so they re-place correctly.  Delete the
  ;; terminal placements FIRST (via `kitty-gfx--delete-image-placements',
  ;; which also clears the record + last-row/col) — nil-ing the record
  ;; without deleting would orphan the on-screen copy at its old position
  ;; (a ghost) because the next refresh allocates a fresh placement id.
  ;; Heading overlays preserve cache (same rationale as on-window-change).
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
  ;; schedule a 0.1s delayed refresh to let buffer switch settle.
  (when kitty-gfx--render-timer
    (cancel-timer kitty-gfx--render-timer))
  (setq kitty-gfx--refresh-pending nil
        kitty-gfx--render-timer
        (run-at-time 0.1 nil
                     (lambda ()
                       (setq kitty-gfx--render-timer nil
                             kitty-gfx--force-redisplay t)
                       (kitty-gfx--refresh)))))

(defun kitty-gfx--on-window-change (frame)
  "Handle window configuration change for image refresh.
Invalidates cell pixel size, deletes stale image placements, then
clears image position caches so the refresh cycle re-places images
at their new positions.  Uses a longer debounce than normal refresh
to let Emacs finish window layout transitions (e.g., when closing a
split, Emacs briefly shows two windows for the same buffer before
settling to one)."
  (kitty-gfx--log "on-window-change: deleting stale placements and invalidating cell size")
  (kitty-gfx--heading-scan-visible)
  (kitty-gfx--invalidate-window-signatures)
  (setq kitty-gfx--cell-pixel-width nil
        kitty-gfx--cell-pixel-height nil)
  ;; Invalidate FRAME's terminal cell-size parameter too, so the
  ;; per-terminal query guard re-queries it (a resize can change the
  ;; pixel cell size, and the guard keys on the parameter, not the global).
  (let ((term (and (frame-live-p frame) (frame-terminal frame))))
    (when (and term (terminal-live-p term))
      (set-terminal-parameter term 'kitty-gfx-cell-w nil)
      (set-terminal-parameter term 'kitty-gfx-cell-h nil)))
  ;; Clear stale per-window records on any mpv overlay so the next
  ;; refresh recomputes coordinates against the new layout.  The mpv
  ;; overlay is NEVER pushed onto `kitty-gfx--overlays' (mpv has no
  ;; kitty placement ID), so the dolist below would not touch it; it
  ;; lives only on the buffer-local `kitty-gfx--mpv-overlay'.
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and kitty-gfx--mpv-overlay
                 (overlay-buffer kitty-gfx--mpv-overlay))
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx-placements nil))))
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
                       (setq kitty-gfx--render-timer nil
                             kitty-gfx--force-redisplay t)
                       (kitty-gfx--refresh)))))

(defun kitty-gfx--any-visible-overlays-p ()
  "Return non-nil when any visible window's buffer holds kitty-gfx overlays.
Cheap O(n_windows) check used by `kitty-gfx--on-redisplay' to avoid
scheduling timers in unrelated buffers — issue #19."
  (catch 'found
    (walk-windows
     (lambda (w)
       (when (buffer-local-value 'kitty-gfx--overlays (window-buffer w))
         (throw 'found t)))
     nil 'visible)
    nil))

(defun kitty-gfx--window-signature (win)
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

(defun kitty-gfx--windows-clean-p ()
  "Return non-nil when every visible overlay window matches its stored signature.
A clean result means nothing an image placement depends on has changed
since the last successful refresh, so `kitty-gfx--on-redisplay' can
skip scheduling one.  Windows showing an mpv or browser overlay are
never considered clean — their terminal-side frames move independently
of any buffer-visible state the signature captures.  Overlay windows on
the selected frame's terminal are also dirty while that terminal's cell
size is still unqueried: `kitty-gfx--refresh' can only run the
capability queries while their terminal is the selected one, so
skipping here would leave a late-attaching client on fallback geometry
forever."
  (let ((selected-term (unless (display-graphic-p) (frame-terminal))))
    (catch 'dirty
      (walk-windows
       (lambda (w)
         (let ((buf (window-buffer w)))
           (when (or (buffer-local-value 'kitty-gfx--mpv-overlay buf)
                     (buffer-local-value 'kitty-gfx--browser-overlay buf))
             (throw 'dirty nil))
           (when (buffer-local-value 'kitty-gfx--overlays buf)
             (when (and selected-term
                        (eq (frame-terminal (window-frame w)) selected-term)
                        (not (terminal-parameter selected-term 'kitty-gfx-cell-w)))
               (throw 'dirty nil))
             (unless (equal (kitty-gfx--window-signature w)
                            (window-parameter w 'kitty-gfx-sig))
               (throw 'dirty nil)))))
       nil 'visible)
      t)))

(defun kitty-gfx--update-window-signatures ()
  "Store the current signature on every visible overlay window.
Called at the end of a successful `kitty-gfx--refresh' pass; a refresh
that bailed early leaves the old signatures so the next
`kitty-gfx--on-redisplay' retries."
  (walk-windows
   (lambda (w)
     (when (buffer-local-value 'kitty-gfx--overlays (window-buffer w))
       (set-window-parameter w 'kitty-gfx-sig (kitty-gfx--window-signature w))))
   nil 'visible))

(defun kitty-gfx--invalidate-window-signatures ()
  "Drop every window's stored refresh signature so the next refresh runs."
  (walk-windows
   (lambda (w) (set-window-parameter w 'kitty-gfx-sig nil))
   nil t))

(defun kitty-gfx--on-redisplay ()
  "Post-command hook to schedule image refresh.
Early-exits when no visible window has any kitty-gfx overlays so
unrelated buffers (dired, magit, scratch, ...) pay no timer or
redisplay cost, and skips while user feedback is in the echo area.
When `kitty-gfx-skip-clean-refresh' is enabled and no forced refresh
is pending, windows whose signatures are unchanged since the last
refresh schedule nothing at all."
  (when (and (kitty-gfx--any-visible-overlays-p)
             (not (active-minibuffer-window))
             (not (current-message))
             (not (and kitty-gfx-skip-clean-refresh
                       (not kitty-gfx--force-redisplay)
                       (kitty-gfx--windows-clean-p))))
    (kitty-gfx--schedule-refresh)))

;;;; Image processing

(defun kitty-gfx--base64-cache-store (file mtime b64)
  "Cache B64 for FILE at MTIME, evicting LRU entries over the byte cap.
Payloads larger than `kitty-gfx-base64-cache-bytes' are not cached."
  (when (<= (length b64) kitty-gfx-base64-cache-bytes)
    (let ((old (gethash file kitty-gfx--base64-cache)))
      (when old
        (setq kitty-gfx--base64-cache-total
              (- kitty-gfx--base64-cache-total (length (cdr old))))))
    (puthash file (cons mtime b64) kitty-gfx--base64-cache)
    (setq kitty-gfx--base64-cache-lru
          (cons file (delete file kitty-gfx--base64-cache-lru)))
    (setq kitty-gfx--base64-cache-total
          (+ kitty-gfx--base64-cache-total (length b64)))
    (while (and (> kitty-gfx--base64-cache-total kitty-gfx-base64-cache-bytes)
                (cdr kitty-gfx--base64-cache-lru))
      (let* ((victim (car (last kitty-gfx--base64-cache-lru)))
             (entry (gethash victim kitty-gfx--base64-cache)))
        (when entry
          (setq kitty-gfx--base64-cache-total
                (- kitty-gfx--base64-cache-total (length (cdr entry)))))
        (remhash victim kitty-gfx--base64-cache)
        (setq kitty-gfx--base64-cache-lru
              (butlast kitty-gfx--base64-cache-lru))
        (kitty-gfx--log "base64-cache-evict: %s (total=%d cap=%d)"
                        (file-name-nondirectory victim)
                        kitty-gfx--base64-cache-total
                        kitty-gfx-base64-cache-bytes)))))

(defun kitty-gfx--read-file-base64 (file)
  "Read FILE and return base64-encoded string.
Results are cached keyed on FILE and its modification time (bounded by
`kitty-gfx-base64-cache-bytes'), so transmitting the same image to a
second terminal skips the read+encode cost."
  (let* ((mtime (file-attribute-modification-time (file-attributes file)))
         (entry (gethash file kitty-gfx--base64-cache)))
    (if (and entry (equal (car entry) mtime))
        (progn
          (setq kitty-gfx--base64-cache-lru
                (cons file (delete file kitty-gfx--base64-cache-lru)))
          (kitty-gfx--log "read-file-base64: cache hit %s b64-len=%d"
                          file (length (cdr entry)))
          (cdr entry))
      (kitty-gfx--log "read-file-base64: %s size=%s"
                      file (ignore-errors (file-attribute-size (file-attributes file))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (base64-encode-region (point-min) (point-max) t)
        (let ((result (buffer-string)))
          (kitty-gfx--log "read-file-base64: done b64-len=%d" (length result))
          (kitty-gfx--base64-cache-store file mtime result)
          result)))))

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

(defun kitty-gfx--png-cache-get (file)
  "Return the cached PNG path for FILE, or nil if absent or stale."
  (let ((entry (gethash file kitty-gfx--png-cache)))
    (when entry
      (let ((mtime (file-attribute-modification-time (file-attributes file))))
        (if (and (equal (car entry) mtime)
                 (file-exists-p (cdr entry)))
            (cdr entry)
          (remhash file kitty-gfx--png-cache)
          (unless (string= (cdr entry) file)
            (ignore-errors (delete-file (cdr entry))))
          nil)))))

(defun kitty-gfx--png-cache-put (file png)
  "Record PNG as FILE's conversion result at FILE's current mtime."
  (let ((old (gethash file kitty-gfx--png-cache)))
    (when (and old
               (not (string= (cdr old) png))
               (not (string= (cdr old) file)))
      (ignore-errors (delete-file (cdr old)))))
  (puthash file
           (cons (file-attribute-modification-time (file-attributes file)) png)
           kitty-gfx--png-cache)
  png)

(defun kitty-gfx--cleanup-temp-files ()
  "Delete converted temp PNGs and any leftover mpv/casty IPC socket files.
Runs from `kill-emacs-hook' so the `kitty-gfx--png-cache' temp files do
not accumulate in /tmp across sessions.  Cache entries whose PNG path is
the source file itself are skipped — that is user data, not ours."
  (maphash (lambda (file entry)
             (let ((png (cdr entry)))
               (unless (string= png file)
                 (ignore-errors (delete-file png)))))
           kitty-gfx--png-cache)
  (clrhash kitty-gfx--png-cache)
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (dolist (sock (list (buffer-local-value 'kitty-gfx--mpv-ipc-socket buf)
                          (buffer-local-value 'kitty-gfx--browser-ipc-socket buf)))
        (when sock
          (ignore-errors (delete-file sock)))))))

(add-hook 'kill-emacs-hook #'kitty-gfx--cleanup-temp-files)

(defun kitty-gfx--convert-program ()
  "Return the ImageMagick binary to use for PNG conversion, or nil."
  (or (executable-find "magick")
      (executable-find "convert")))

(defun kitty-gfx--convert-to-png (file)
  "Convert FILE to PNG if needed.  Returns path to PNG file.
Returns FILE unchanged if it is already PNG.  Successful conversions
are cached in `kitty-gfx--png-cache' keyed on FILE's mtime, so repeat
displays (and the async path's later synchronous prepare) skip the
shell-out.  Returns nil if FILE is not PNG and ImageMagick is
unavailable or conversion fails — callers must handle nil gracefully."
  (if (string-suffix-p ".png" file t)
      (progn
        (kitty-gfx--log "convert-to-png: %s already PNG" file)
        file)
    (or (kitty-gfx--png-cache-get file)
        (let ((convert (kitty-gfx--convert-program)))
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
                (if (and (file-exists-p out)
                         (> (file-attribute-size (file-attributes out)) 0))
                    (progn
                      (kitty-gfx--log "convert-to-png: success out-size=%d"
                                      (file-attribute-size (file-attributes out)))
                      (kitty-gfx--png-cache-put file out))
                  (kitty-gfx--log "convert-to-png: FAILED (empty or missing output)")
                  (ignore-errors (delete-file out))
                  nil))))))))

(defun kitty-gfx--convert-to-png-async (file callback)
  "Convert FILE to PNG in a background process, then funcall CALLBACK.
CALLBACK receives the PNG path on success, nil on failure.  Cache hits
and already-PNG files invoke CALLBACK immediately.  Concurrent requests
for the same FILE share one conversion process; their callbacks all run
when it finishes."
  (let ((cached (and (string-suffix-p ".png" file t) file)))
    (unless cached
      (setq cached (kitty-gfx--png-cache-get file)))
    (cond
     (cached (funcall callback cached))
     ((gethash file kitty-gfx--converting)
      (puthash file (cons callback (gethash file kitty-gfx--converting))
               kitty-gfx--converting))
     (t
      (let ((convert (kitty-gfx--convert-program)))
        (if (not convert)
            (progn
              (kitty-gfx--log "convert-to-png-async: no ImageMagick for %s" file)
              (funcall callback nil))
          (let ((out (make-temp-file "kitty-gfx-" nil ".png")))
            (puthash file (list callback) kitty-gfx--converting)
            (kitty-gfx--log "convert-to-png-async: %s -> %s via %s" file out convert)
            (make-process
             :name "kitty-gfx-convert"
             :command (list convert file out)
             :noquery t
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (let ((callbacks (gethash file kitty-gfx--converting))
                       (ok (and (eq (process-status proc) 'exit)
                                (zerop (process-exit-status proc))
                                (file-exists-p out)
                                (> (file-attribute-size (file-attributes out)) 0))))
                   (remhash file kitty-gfx--converting)
                   (if ok
                       (progn
                         (kitty-gfx--log "convert-to-png-async: success %s out-size=%d"
                                         file
                                         (file-attribute-size (file-attributes out)))
                         (kitty-gfx--png-cache-put file out))
                     (kitty-gfx--log "convert-to-png-async: FAILED %s status=%s exit=%s"
                                     file (process-status proc)
                                     (process-exit-status proc))
                     (ignore-errors (delete-file out)))
                   (dolist (cb (nreverse callbacks))
                     (funcall cb (and ok out))))))))))))))

(defvar kitty-gfx--dim-scale nil
  "When a positive float, multiply natural image cell dims by this factor.
Bound dynamically by callers (e.g. the shr integration) to render images
at a fraction of their natural size.  The result is still clamped to the
max cols/rows.  nil means shrink-to-fit the max dimensions (the default).")

(defun kitty-gfx--compute-cell-dims (pixel-w pixel-h max-cols max-rows)
  "Compute (COLS . ROWS) in terminal cells for image placement.
With direct placements, COLS and ROWS map directly to terminal columns/rows."
  (let* ((cw (or kitty-gfx--cell-pixel-width 8))
         (ch (or kitty-gfx--cell-pixel-height 16))
         (img-cols (max 1 (ceiling (/ (float pixel-w) cw))))
         (img-rows (max 1 (ceiling (/ (float pixel-h) ch))))
         (fit (min (if (> img-cols max-cols)
                       (/ (float max-cols) img-cols) 1.0)
                   (if (> img-rows max-rows)
                       (/ (float max-rows) img-rows) 1.0)))
         (scale (if (and (numberp kitty-gfx--dim-scale)
                         (> kitty-gfx--dim-scale 0))
                    kitty-gfx--dim-scale
                  fit))
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

(defun kitty-gfx--evict-image-everywhere (file id)
  "Free image FILE/ID on every terminal that holds it.
Each Kitty terminal that received ID gets a delete APC and has ID dropped
from its transmitted set; per-file Sixel temp data is removed once.  Run
on cache eviction so a later id reuse cannot collide with stale terminal
data and the per-terminal transmitted sets do not grow without bound."
  (when id
    (dolist (term (terminal-list))
      (when (and (terminal-live-p term)
                 (kitty-gfx--terminal-transmitted-p term id))
        (kitty-gfx--with-terminal term
          (kitty-gfx--delete-by-id id))
        (kitty-gfx--terminal-unmark-transmitted term id)
        (let ((dims-by-id (terminal-parameter term 'kitty-gfx-virtual-dims)))
          (when dims-by-id (remhash id dims-by-id)))))
    (let ((sixel-cleanup (alist-get 'cleanup (alist-get 'sixel kitty-gfx--backends))))
      (when sixel-cleanup (funcall sixel-cleanup file id)))))

(defun kitty-gfx--cleanup-all-terminals ()
  "Delete every transmitted image on every terminal and reset their sets.
Also runs the Sixel backend's global cleanup for per-file temp data.  Used
where a single-terminal `cleanup-all' would leave images stranded on the
other daemon clients."
  (dolist (term (terminal-list))
    (when (and (terminal-live-p term)
               (terminal-parameter term 'kitty-gfx-transmitted))
      (kitty-gfx--with-terminal term
        (kitty-gfx--delete-all-images))
      (set-terminal-parameter term 'kitty-gfx-transmitted nil)
      (set-terminal-parameter term 'kitty-gfx-virtual-dims nil)))
  (let ((sixel-ca (alist-get 'cleanup-all (alist-get 'sixel kitty-gfx--backends))))
    (when sixel-ca (funcall sixel-ca))))

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
      (when victim-id
        (kitty-gfx--evict-image-everywhere victim victim-id))
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
        (pid (or reuse-pid (kitty-gfx--alloc-placement-id))))
    ;; Always reserve screen space with blank cells.  For placeholder
    ;; mode the actual U+10EEEE + diacritic cells get painted on top
    ;; by `kitty-gfx--emit-placeholder-cells' during refresh (Emacs's
    ;; display engine cannot emit those combining marks itself).
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
    (add-hook 'change-major-mode-hook #'kitty-gfx--remove-buffer-graphics nil t)
    (push ov kitty-gfx--overlays)
    (kitty-gfx--log "make-overlay: id=%d pid=%d cols=%d rows=%d beg=%d end=%d buf=%s (total=%d)"
                     image-id pid cols rows beg end (buffer-name) (length kitty-gfx--overlays))
    ov))

(defun kitty-gfx--image-placement (ov win)
  "Return OV's recorded image placement for WIN, or nil."
  (assq win (overlay-get ov 'kitty-gfx-placements)))

(defun kitty-gfx--record-image-placement (ov win row col cols rows pid)
  "Record that OV is placed in WIN at ROW COL with COLS ROWS.
Returns the effective placement id, which the caller must use for the
terminal placement so the recorded and emitted ids never diverge.
Reuses WIN's existing placement id when one is recorded (a move is an
atomic same-id re-place); otherwise uses PID when non-nil, else
allocates a fresh id.  Each (overlay, window) pair thus owns a stable,
unique id — a single overlay shown in N windows needs N distinct
on-screen copies."
  (let* ((existing (cdr (kitty-gfx--image-placement ov win)))
         (pid (or (plist-get existing :pid)
                  pid
                  (kitty-gfx--alloc-placement-id)))
         (placements (assq-delete-all win (copy-sequence
                                           (overlay-get ov 'kitty-gfx-placements)))))
    (overlay-put ov 'kitty-gfx-placements
                 (cons (cons win (list :row row :col col
                                       :cols cols :rows rows
                                       :pid pid))
                       placements))
    pid))

(defun kitty-gfx--forget-image-placement (ov win)
  "Forget OV's recorded image placement for WIN."
  (overlay-put ov 'kitty-gfx-placements
               (assq-delete-all win (copy-sequence
                                     (overlay-get ov 'kitty-gfx-placements)))))

(defun kitty-gfx--delete-image-placement (ov placement)
  "Delete one recorded image PLACEMENT for OV.
The delete escape is routed to the terminal of the window the
placement was recorded for, so killing a buffer shown on another
daemon client erases that client's copy rather than whatever
terminal happens to be selected.  When the window or its terminal
is gone, output falls back to the currently targeted terminal."
  (let* ((win (car placement))
         (data (cdr placement))
         (id (overlay-get ov 'kitty-gfx-id))
         (pid (plist-get data :pid))
         (row (plist-get data :row))
         (col (plist-get data :col))
         (cols (plist-get data :cols))
         (rows (plist-get data :rows))
         (old-row (overlay-get ov 'kitty-gfx-last-row))
         (old-col (overlay-get ov 'kitty-gfx-last-col))
         (old-cols (overlay-get ov 'kitty-gfx-cols))
         (old-rows (overlay-get ov 'kitty-gfx-rows))
         (term (and (window-live-p win)
                    (frame-terminal (window-frame win)))))
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
            (if (and term (terminal-live-p term))
                (kitty-gfx--with-terminal term
                  (funcall (kitty-gfx--backend-fn 'delete) ov id pid))
              (funcall (kitty-gfx--backend-fn 'delete) ov id pid)))
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
visual glitches from delete+re-place sequences in some terminals).

KEEP-PLACEMENT is ignored for backends without placement IDs
\(Sixel): they have no atomic-replace semantics, so skipping the
delete would leave the old pixel block on screen as a ghost when
the next placement lands at a different position or size
\(issue #13)."
  (let* ((id (overlay-get ov 'kitty-gfx-id))
         (pid (overlay-get ov 'kitty-gfx-pid))
         (temp-file (overlay-get ov 'kitty-gfx-delete-file))
         (placement-id-backend (memq kitty-gfx--active-backend '(kitty)))
         (must-delete (or (not keep-placement)
                          (not placement-id-backend))))
    (when (and keep-placement placement-id-backend)
      ;; Kitty: drop the per-window placement records so the next
      ;; placement starts fresh with the reused PID.  Sixel needs the
      ;; records intact below so the backend `delete' can erase pixels.
      (overlay-put ov 'kitty-gfx-placements nil))
    (kitty-gfx--log "remove-overlay: id=%s pid=%s keep=%s buf=%s"
                     id pid keep-placement
                     (when (overlay-buffer ov) (buffer-name (overlay-buffer ov))))
    (when (overlay-buffer ov)
      (when must-delete
        (kitty-gfx--delete-image-placements ov))
      (delete-overlay ov))
    (when temp-file
      (ignore-errors (delete-file temp-file)))
    (setq kitty-gfx--overlays (delq ov kitty-gfx--overlays))
    (kitty-gfx--log "remove-overlay: done (remaining=%d)" (length kitty-gfx--overlays))))

;;;; Public API

(defun kitty-gfx--async-prepare-p (file)
  "Return non-nil when FILE's display should use background conversion.
True for non-PNG files with no fresh entry in `kitty-gfx--png-cache'
while `kitty-gfx-async-conversion' is enabled."
  (and kitty-gfx-async-conversion
       (not (string-suffix-p ".png" file t))
       (not (kitty-gfx--png-cache-get file))))

(defun kitty-gfx--start-async-prepare (file)
  "Convert FILE in the background, then force a refresh to place it.
The caller has already created the overlay (blank placeholder) and
registered FILE in the image cache; until the conversion lands,
`kitty-gfx--ensure-transmitted' defers placement.  On success the PNG
is also stored for the Sixel backend and a forced refresh makes the
image appear.  On failure the overlay and cache entry are removed,
matching the synchronous path's no-overlay-on-failure behaviour."
  (kitty-gfx--convert-to-png-async
   file
   (lambda (png)
     (if (not png)
         (progn
           (kitty-gfx--log "async-prepare: conversion failed, dropping %s" file)
           (kitty-gfx--cache-remove file)
           (dolist (buf (buffer-list))
             (with-current-buffer buf
               (dolist (ov (copy-sequence kitty-gfx--overlays))
                 (when (equal (overlay-get ov 'kitty-gfx-file) file)
                   (kitty-gfx--remove-overlay ov)))))
           (kitty-gfx--schedule-refresh t))
       (puthash file png kitty-gfx--sixel-cache)
       (kitty-gfx--schedule-refresh t)))))

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
      (if (kitty-gfx--async-prepare-p abs-file)
          (progn
            (kitty-gfx--cache-put abs-file image-id)
            (kitty-gfx--start-async-prepare abs-file))
        (when (funcall (kitty-gfx--backend-fn 'prepare) abs-file image-id)
          (kitty-gfx--cache-put abs-file image-id))))
    ;; Create overlay with blank space (even for cached images, dims are fresh)
    (when (or cached-id (gethash abs-file kitty-gfx--image-cache))
      (let ((ov (kitty-gfx--make-overlay start stop image-id cols rows abs-file)))
        ;; Schedule initial render (force-redisplay: new overlay's display
        ;; property must be processed before `posn-at-point' measurement).
        (kitty-gfx--schedule-refresh t)
        ov))))

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
        (if (kitty-gfx--async-prepare-p abs-file)
            (progn
              (kitty-gfx--cache-put abs-file image-id)
              (kitty-gfx--start-async-prepare abs-file))
          (when (funcall (kitty-gfx--backend-fn 'prepare) abs-file image-id)
            (kitty-gfx--cache-put abs-file image-id))))
      ;; Create overlay at the scaled dimensions.
      (when (or cached-id (gethash abs-file kitty-gfx--image-cache))
        (kitty-gfx--make-overlay img-start (point) image-id
                                  img-cols img-rows abs-file reuse-pid)
        (kitty-gfx--schedule-refresh t)))))

(defun kitty-gfx-remove-images (&optional beg end)
  "Remove all kitty-gfx overlays in region BEG..END (defaults to whole buffer)."
  (interactive)
  (let ((count 0))
    (dolist (ov (overlays-in (or beg (point-min)) (or end (point-max))))
      (when (overlay-get ov 'kitty-gfx)
        (cl-incf count)
        (kitty-gfx--remove-overlay ov)))
    (kitty-gfx--log "remove-images: removed %d overlays from %s" count (buffer-name))))

(defun kitty-gfx--remove-buffer-graphics ()
  "Remove every kitty-gfx rendering from the current buffer.
Reuses the existing removal paths: heading size overlays are erased
\(with their conflicting minor modes restored), then all remaining
kitty-gfx overlays are removed along with their terminal placements.
Runs when `kitty-graphics-mode' is disabled and, via a buffer-local
`change-major-mode-hook', before a major-mode change (revert-buffer,
mode switch) kills the buffer-local overlay list and orphans the
placements."
  (when (or kitty-gfx--heading-sizes-enabled
            (cl-some (lambda (ov) (overlay-get ov 'kitty-gfx-heading))
                     kitty-gfx--overlays))
    (kitty-gfx--org-remove-heading-sizes)
    (kitty-gfx--heading-restore-modes))
  (when kitty-gfx--overlays
    (kitty-gfx-remove-images)))

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
  (kitty-gfx--cleanup-all-terminals)
  (clrhash kitty-gfx--image-cache)
  (setq kitty-gfx--cache-lru nil)
  (setq kitty-gfx--next-placement-id 1)
  (kitty-gfx--log "clear-all: done"))

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
            (kitty-gfx--invalidate-window-signatures)
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
    (kitty-gfx--stop-all-browsers)
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (kitty-gfx--remove-buffer-graphics))))
    (kitty-gfx--uninstall-hooks)
    (kitty-gfx--uninstall-integrations)
    (kitty-gfx--cleanup-all-terminals)
    (when kitty-gfx--render-timer
      (cancel-timer kitty-gfx--render-timer))
    (kitty-gfx--transmit-queue-reset)
    (kitty-gfx--invalidate-window-signatures)
    (setq kitty-gfx--render-timer nil
          kitty-gfx--refresh-pending nil
          kitty-gfx--active-backend nil
          kitty-gfx--text-sizing-support nil)
    ;; The mode is global; drop every terminal's per-client state so a
    ;; later re-enable re-detects and re-queries each client cleanly.
    (dolist (term (terminal-list))
      (when (terminal-live-p term)
        (kitty-gfx--clear-terminal-state term)))
    (kitty-gfx--log "mode: disabled")))

(defun kitty-gfx--on-new-frame (&optional frame)
  "Detect graphics support for a newly created client FRAME's terminal.
Runs on `server-after-make-frame-hook' (a normal hook that passes no
argument, so FRAME defaults to the selected frame) and on
`after-make-frame-functions' (which passes the new frame), so each
`emacsclient' terminal gets its own backend detected.  Capability queries
are deferred to the first refresh in which FRAME is the selected frame
\(see `kitty-gfx--refresh'), since they read the selected terminal."
  (let ((frame (or frame (selected-frame))))
    (when (and kitty-graphics-mode
               (frame-live-p frame)
               (not (display-graphic-p frame)))
      (with-selected-frame frame
        (kitty-gfx--detect-protocol)))))

(defun kitty-gfx--on-delete-terminal (term)
  "Free kitty-graphics state bound to TERM as it is being deleted.
Runs on `delete-terminal-functions': stops any video/browser launched on
TERM and drops its per-client parameters (backend, cell size, text-sizing,
transmitted set) plus any transmits still queued for it.  The terminal's
stored images need no explicit deletion - they vanish with the terminal."
  (kitty-gfx--stop-terminal-processes term)
  (kitty-gfx--clear-terminal-state term)
  (setq kitty-gfx--transmit-queue
        (cl-remove-if (lambda (entry) (eq (nth 0 entry) term))
                      kitty-gfx--transmit-queue))
  (when (and (null kitty-gfx--transmit-queue)
             kitty-gfx--transmit-drain-timer)
    (cancel-timer kitty-gfx--transmit-drain-timer)
    (setq kitty-gfx--transmit-drain-timer nil)))

(defun kitty-gfx--install-hooks ()
  "Install redisplay hooks for image refresh."
  (add-hook 'window-scroll-functions #'kitty-gfx--on-window-scroll)
  (add-hook 'window-size-change-functions #'kitty-gfx--on-window-change)
  (add-hook 'window-buffer-change-functions #'kitty-gfx--on-buffer-change)
  (add-hook 'post-command-hook #'kitty-gfx--on-redisplay)
  (add-hook 'kill-buffer-hook #'kitty-gfx--kill-buffer-hook)
  (add-hook 'server-after-make-frame-hook #'kitty-gfx--on-new-frame)
  (add-hook 'after-make-frame-functions #'kitty-gfx--on-new-frame)
  (add-hook 'delete-terminal-functions #'kitty-gfx--on-delete-terminal))

(defun kitty-gfx--uninstall-hooks ()
  "Remove redisplay hooks."
  (remove-hook 'window-scroll-functions #'kitty-gfx--on-window-scroll)
  (remove-hook 'window-size-change-functions #'kitty-gfx--on-window-change)
  (remove-hook 'window-buffer-change-functions #'kitty-gfx--on-buffer-change)
  (remove-hook 'post-command-hook #'kitty-gfx--on-redisplay)
  (remove-hook 'kill-buffer-hook #'kitty-gfx--kill-buffer-hook)
  (remove-hook 'server-after-make-frame-hook #'kitty-gfx--on-new-frame)
  (remove-hook 'after-make-frame-functions #'kitty-gfx--on-new-frame)
  (remove-hook 'delete-terminal-functions #'kitty-gfx--on-delete-terminal))

(defun kitty-gfx--enable-on-tty-frame (&optional frame)
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
  (add-hook 'server-after-make-frame-hook #'kitty-gfx--enable-on-tty-frame)
  (add-hook 'after-make-frame-functions #'kitty-gfx--enable-on-tty-frame)
  (unless (or (daemonp) (display-graphic-p))
    (kitty-graphics-mode 1)))

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
    (let ((buf (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (setq kitty-gfx--heading-sizes-enabled t)
                         (kitty-gfx--heading-disable-conflicting)
                         (kitty-gfx--heading-apply-initial))))))))

(defun kitty-gfx--on-org-cycle (&rest _args)
  "Handle org visibility cycling.
Deletes image placements and clears their position caches, then
schedules a forced refresh that re-places only the overlays still
visible (not inside a fold).  Heading overlays are left alone here:
Emacs's post-fold redraw clears or moves their blocks together with
the buffer text, and the refresh re-emits any heading whose screen
position changed."
  (kitty-gfx--log "on-org-cycle: overlays=%d" (length kitty-gfx--overlays))
  (when (and kitty-graphics-mode kitty-gfx--overlays)
    (kitty-gfx--invalidate-window-signatures)
    (kitty-gfx--sync-begin)
    (unwind-protect
        (dolist (ov kitty-gfx--overlays)
          (when (and (overlay-buffer ov)
                     (not (overlay-get ov 'kitty-gfx-heading)))
            (let ((id (overlay-get ov 'kitty-gfx-id))
                  (pid (overlay-get ov 'kitty-gfx-pid)))
              (when (and id pid kitty-gfx--active-backend)
                (funcall (kitty-gfx--backend-fn 'delete) ov id pid)))
            (overlay-put ov 'kitty-gfx-last-row nil)
            (overlay-put ov 'kitty-gfx-last-col nil)))
      (kitty-gfx--sync-end))
    ;; Force-redisplay: folds change visibility, posn-at-point must re-measure.
    (kitty-gfx--schedule-refresh t)))

(defun kitty-gfx--image-file-p (file)
  "Return non-nil if FILE has an image extension.
GIF files are detected so they get routed through the image pipeline,
but only the first frame is rendered (no animation in terminal)."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext)
                     '("png" "jpg" "jpeg" "bmp" "svg"
                       "webp" "tiff" "tif" "gif")))))

(defun kitty-gfx--video-extension-p (file)
  "Return non-nil if FILE has a registered video extension.
Checks only the extension; see `kitty-gfx--mpv-available-p' for
whether playback is actually wired up."
  (let ((ext (file-name-extension file)))
    (and ext (member (downcase ext) kitty-gfx-video-file-extensions))))

(defun kitty-gfx--video-file-p (file)
  "Return non-nil if FILE is a video that the mpv preview can handle.
Requires `kitty-gfx-enable-video' to be enabled, mpv on PATH, and
the Kitty backend active -- the same gates as
`kitty-gfx--mpv-available-p'."
  (and (kitty-gfx--mpv-available-p)
       (kitty-gfx--video-extension-p file)))

(defvar kitty-gfx--video-thumbnail-cache-dir
  (expand-file-name "kitty-gfx-thumbs/" temporary-file-directory)
  "Directory holding cached video thumbnail PNGs.")

(defvar kitty-gfx--ffmpeg-warned nil
  "Non-nil once we have echoed a missing-ffmpeg warning in this session.
Prevents flooding the echo area when dirvish previews many videos
in a row without ffmpeg installed.")

(defun kitty-gfx--video-thumbnail (file)
  "Return a PNG thumbnail path for video FILE.
Extracts the frame at `kitty-gfx-video-thumbnail-seek' via ffmpeg
and caches it under `kitty-gfx--video-thumbnail-cache-dir', keyed
by file path + mtime so an edited video gets a fresh thumbnail.
Returns nil if ffmpeg is missing or extraction fails.  Echoes a
one-shot warning on the first call when ffmpeg is missing so the
user knows why their videos have no thumbnails."
  (let ((ffmpeg (executable-find "ffmpeg")))
    (cond
     ((not ffmpeg)
      (unless kitty-gfx--ffmpeg-warned
        (setq kitty-gfx--ffmpeg-warned t)
        (message "kitty-gfx: ffmpeg not on PATH; video thumbnails disabled"))
      nil)
     (t
      (unless (file-directory-p kitty-gfx--video-thumbnail-cache-dir)
        (make-directory kitty-gfx--video-thumbnail-cache-dir t))
      (let* ((file (expand-file-name file))
             (attrs (file-attributes file))
             (mtime (format-time-string "%s" (nth 5 attrs)))
             (key (sha1 (format "%s\0%s" file mtime)))
             (out (expand-file-name (concat key ".png")
                                    kitty-gfx--video-thumbnail-cache-dir)))
        (if (file-exists-p out)
            out
          (with-temp-buffer
            (let ((exit (call-process
                         ffmpeg nil t nil
                         "-y" "-loglevel" "error"
                         "-ss" kitty-gfx-video-thumbnail-seek
                         "-i" file
                         "-frames:v" "1"
                         "-vf" "scale=640:-1"
                         out)))
              (kitty-gfx--log "video-thumbnail: exit=%s file=%s out=%s"
                              exit file out)
              (when (and (eq exit 0) (file-exists-p out)) out)))))))))

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
        ;; Snapshot the old overlay's per-window placement records so we
        ;; can transplant them onto the new overlay.  Without this, the
        ;; new overlay starts with no recorded placement, the refresh
        ;; allocates a fresh per-window PID, and Kitty draws the
        ;; resized image at a NEW placement while the old placement
        ;; (which we deliberately did not delete to allow atomic
        ;; replacement) remains on screen as a ghost (issue #13).
        (let ((old-placements
               (when reuse-placement
                 (let ((ov (car kitty-gfx--overlays)))
                   (and ov (copy-sequence
                            (overlay-get ov 'kitty-gfx-placements)))))))
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
          ;; Transplant old placements onto the freshly-made overlay so the
          ;; next refresh re-uses the recorded per-window PIDs.  Recorded
          ;; row/col/cols/rows are intentionally OLD — refresh-overlay sees
          ;; them as the "moved" baseline and re-places at the same PID
          ;; (Kitty atomic-replace) at the new position.
          (when old-placements
            (when-let* ((new-ov (car kitty-gfx--overlays)))
              (overlay-put new-ov 'kitty-gfx-placements old-placements))))
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

(defun kitty-gfx--shr-display-image (file start end)
  "Display FILE for the shr backends, honoring `kitty-gfx-shr-scale'."
  (pcase kitty-gfx-shr-scale
    ('fit
     (let* ((win (get-buffer-window (current-buffer)))
            (win-w (if win (window-body-width win) kitty-gfx-max-width))
            (max-c (max 1 (min kitty-gfx-max-width
                               (round (* win-w kitty-gfx-shr-fit-width)))))
            (max-r (max 1 (min kitty-gfx-max-height kitty-gfx-shr-fit-height))))
       (kitty-gfx-display-image file start end max-c max-r)))
    ((and (pred numberp) factor)
     (let ((kitty-gfx--dim-scale factor))
       (kitty-gfx-display-image file start end)))
    (_ (kitty-gfx-display-image file start end))))

(defun kitty-gfx--shr-put-image-advice (orig-fn spec alt &rest args)
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
        (kitty-gfx--log "shr-put-image: type=%s url=%s data-len=%s alt=%s"
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
                  (let ((ov (kitty-gfx--shr-display-image file start end)))
                    (if (and ov temp-p)
                        (overlay-put ov 'kitty-gfx-delete-file file)
                      (when temp-p
                        (ignore-errors (delete-file file))))))
              (error
               (when temp-p
                 (ignore-errors (delete-file file)))
               (kitty-gfx--log "shr-put-image error: %s" (error-message-string err)))))))
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
        ;; Also snapshot per-window placements for transplant onto the
        ;; new overlay below (see image-mode-render rationale, issue #13).
        (let ((old-pid (when kitty-gfx--doc-view-overlay
                         (overlay-get kitty-gfx--doc-view-overlay 'kitty-gfx-pid)))
              (old-placements (when kitty-gfx--doc-view-overlay
                                (copy-sequence
                                 (overlay-get kitty-gfx--doc-view-overlay
                                              'kitty-gfx-placements)))))
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
              (when (and old-placements kitty-gfx--doc-view-overlay)
                (overlay-put kitty-gfx--doc-view-overlay
                             'kitty-gfx-placements old-placements))
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

(defun kitty-gfx--preview-quit ()
  "Close the kitty-graphics preview window.
Stops any inline mpv playback first so the mpv process does not
outlive its preview buffer.  When the preview occupies the only
window in the frame (full-frame dirvish RET path), keep the
window alive and let `kill-buffer' surface the previous buffer."
  (interactive)
  (let ((win (get-buffer-window (current-buffer))))
    (when (and (boundp 'kitty-gfx--mpv-process) kitty-gfx--mpv-process)
      (kitty-gfx--mpv-cleanup))
    (kitty-gfx-remove-images)
    (kill-buffer (current-buffer))
    (when (and (window-live-p win) (not (one-window-p t)))
      (delete-window win))))

(defun kitty-gfx--make-preview-buffer (file)
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
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "q") #'kitty-gfx--preview-quit)
        (use-local-map map)))
    (cons buf win)))

(defun kitty-gfx--preview-display (image-path win buf)
  "Place IMAGE-PATH into preview BUF shown in WIN, sized to WIN."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (kitty-gfx-remove-images)
      (kitty-gfx-display-image
       image-path (point-min) (point-max)
       (min (- (window-width win) 2) kitty-gfx-max-width)
       (min (- (window-height win) 3) kitty-gfx-max-height)))
    (goto-char (point-min))))

;;;###autoload
(defun kitty-gfx-dired-preview ()
  "Preview the file at point in dired.
Images render via the Kitty graphics protocol; video files render
as a single-frame thumbnail extracted by ffmpeg (cached under
`kitty-gfx--video-thumbnail-cache-dir').  Press `q' in the preview
buffer to close it."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a dired buffer"))
  (let ((file (dired-get-file-for-visit)))
    (kitty-gfx--log "dired-preview: %s" file)
    (cond
     ((kitty-gfx--image-file-p file)
      (let* ((bw (kitty-gfx--make-preview-buffer file)))
        (kitty-gfx--preview-display file (cdr bw) (car bw))))
     ((kitty-gfx--video-file-p file)
      (let ((thumb (kitty-gfx--video-thumbnail file)))
        (if thumb
            (let* ((bw (kitty-gfx--make-preview-buffer file)))
              (kitty-gfx--preview-display thumb (cdr bw) (car bw)))
          (user-error
           "Could not extract video thumbnail (ffmpeg missing or failed)"))))
     (t
      (user-error "Not an image or video file")))))

(defvar-local kitty-gfx--dired-auto-preview-timer nil
  "Debounce timer for `kitty-gfx-dired-auto-preview-mode'.")

(defun kitty-gfx--dired-auto-preview-now (buf)
  "Run `kitty-gfx-dired-preview' in BUF if cursor is on a known file.
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
                     (or (kitty-gfx--image-file-p file)
                         (kitty-gfx--video-file-p file)))
            (condition-case err
                (kitty-gfx-dired-preview)
              (user-error
               (kitty-gfx--log "dired-auto-preview: skip (%s)"
                               (error-message-string err))))))))))

(defun kitty-gfx--dired-auto-preview-hook ()
  "Schedule a debounced auto-preview after a dired cursor move."
  (when kitty-gfx--dired-auto-preview-timer
    (cancel-timer kitty-gfx--dired-auto-preview-timer))
  (setq kitty-gfx--dired-auto-preview-timer
        (run-with-idle-timer
         kitty-gfx-dired-preview-debounce nil
         #'kitty-gfx--dired-auto-preview-now (current-buffer))))

;;;###autoload
(define-minor-mode kitty-gfx-dired-auto-preview-mode
  "Auto-preview the file at point in dired in a side window.
Idles `kitty-gfx-dired-preview-debounce' seconds, then calls
`kitty-gfx-dired-preview'.  Videos render as a single-frame
thumbnail; images render directly.  Closing the preview window
(`q' in the preview buffer) re-opens on the next cursor move
unless the mode is turned off."
  :lighter " kPrev"
  (if kitty-gfx-dired-auto-preview-mode
      (add-hook 'post-command-hook
                #'kitty-gfx--dired-auto-preview-hook nil t)
    (remove-hook 'post-command-hook
                 #'kitty-gfx--dired-auto-preview-hook t)
    (when kitty-gfx--dired-auto-preview-timer
      (cancel-timer kitty-gfx--dired-auto-preview-timer)
      (setq kitty-gfx--dired-auto-preview-timer nil))))

;;;###autoload
(defun kitty-gfx-dired-play-video ()
  "Play the video at point in dired inline via mpv.
Distinct from `kitty-gfx-dired-preview', which shows only a
single-frame thumbnail.  Useful when bound separately on a
heavier shortcut for full playback."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a dired buffer"))
  (let ((file (dired-get-file-for-visit)))
    (unless (kitty-gfx--video-extension-p file)
      (user-error "Not a video file"))
    (when-let* ((reason (kitty-gfx--mpv-unavailable-reason)))
      (user-error "kitty-gfx: cannot play video: %s" reason))
    ;; Single-video invariant: kill any other live playback first.
    (let ((existing (kitty-gfx--mpv-buffer)))
      (when existing (with-current-buffer existing (kitty-gfx--mpv-cleanup))))
    (let* ((bw (kitty-gfx--make-preview-buffer file))
           (buf (car bw))
           (win (cdr bw)))
      (with-selected-window win
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (kitty-gfx-play-video file)))))))

(defvar kitty-gfx--mpv-warn-throttle 0
  "Float-time of the last \"mpv unavailable\" message.
Used to throttle repeat warnings to at most once every few
seconds, so navigating across multiple video files in dired or
dirvish does not flood the echo area.")

(defun kitty-gfx--warn-mpv-unavailable (reason)
  "Echo REASON for mpv unavailability, throttled to once per ~3s."
  (let ((now (float-time)))
    (when (> (- now kitty-gfx--mpv-warn-throttle) 3.0)
      (setq kitty-gfx--mpv-warn-throttle now)
      (message "kitty-gfx: inline video preview disabled (%s)" reason))))

(defun kitty-gfx--dired-find-file-advice (orig-fn &rest args)
  "Around advice on `dired-find-file' that routes videos to mpv.
Avoids Emacs's \"file too big\" prompt for multi-MB videos by
delegating to `kitty-gfx-dired-play-video' when the file at point
has a video extension and mpv is available.  Non-video files pass
through.

When the file has a video extension but mpv playback is
unavailable (no mpv binary, kitty backend off, etc.), echo a
one-shot warning explaining why and fall through to ORIG-FN.

Inside an active dirvish session, pass through to ORIG-FN so
`kitty-gfx--dirvish-find-entry-hook' can play the video in the
appropriate window.  Going through `display-buffer-in-side-window'
there would cause dirvish to rebuild its layout (transient
`delete-other-windows'), which the user sees as the preview
buffer briefly going full-frame before mpv starts."
  (let ((file (ignore-errors (dired-get-file-for-visit))))
    (cond
     ((not (and file (kitty-gfx--video-extension-p file)))
      (apply orig-fn args))
     ((kitty-gfx--mpv-unavailable-reason)
      (kitty-gfx--warn-mpv-unavailable
       (kitty-gfx--mpv-unavailable-reason))
      (apply orig-fn args))
     ((and (featurep 'dirvish)
           (fboundp 'dirvish-curr)
           (dirvish-curr))
      (apply orig-fn args))
     (t (kitty-gfx-dired-play-video)))))

(defun kitty-gfx--dired-find-file-other-window-advice (orig-fn &rest args)
  "Around advice on `dired-find-file-other-window' that routes videos to mpv."
  (let ((file (ignore-errors (dired-get-file-for-visit))))
    (cond
     ((not (and file (kitty-gfx--video-extension-p file)))
      (apply orig-fn args))
     ((kitty-gfx--mpv-unavailable-reason)
      (kitty-gfx--warn-mpv-unavailable
       (kitty-gfx--mpv-unavailable-reason))
      (apply orig-fn args))
     ((and (featurep 'dirvish)
           (fboundp 'dirvish-curr)
           (dirvish-curr))
      (apply orig-fn args))
     (t (kitty-gfx-dired-play-video)))))

(declare-function dirvish-curr "dirvish" ())
(declare-function dv-preview-window "dirvish" (dv))
(declare-function dirvish--clear-session "dirvish" (dv &optional from-quit))

(defun kitty-gfx--dirvish-find-entry-hook (entry find-fn)
  "Hook on `dirvish-find-entry-hook' that intercepts video files.
Default behaviour: tear down the dirvish layout and play ENTRY in
a full-frame preview buffer, mirroring how dirvish opens regular
files and images.  Set `kitty-gfx-dirvish-video-inline-preview'
to non-nil to instead keep the layout and play ENTRY inside the
existing dirvish preview side window."
  (when (and (memq find-fn '(find-file find-alternate-file))
             (stringp entry)
             (kitty-gfx--video-extension-p entry)
             ;; mpv unreachable: warn and yield to dirvish's normal
             ;; find-fn (returns nil from the hook).  We've still
             ;; told the user why we didn't preview.
             (let ((reason (kitty-gfx--mpv-unavailable-reason)))
               (if reason
                   (progn (kitty-gfx--warn-mpv-unavailable reason) nil)
                 t)))
    (let* ((dv (ignore-errors (dirvish-curr)))
           (pwin (and dv (ignore-errors (dv-preview-window dv))))
           (basename (file-name-nondirectory entry))
           ;; Reuse the same buffer name the side-window preview path
           ;; uses, so SPC/q/? bindings + cleanup hooks behave the same.
           (buf (get-buffer-create (format "*kitty-preview: %s*" basename))))
      ;; Stop any prior playback first.
      (let ((existing (kitty-gfx--mpv-buffer)))
        (when existing
          (with-current-buffer existing (kitty-gfx--mpv-cleanup))))
      ;; Drop dirvish's per-file thumbnail buffer for ENTRY.  Its
      ;; placement is the dispatcher's stale image and would race
      ;; the mpv overlay for the same cells otherwise.
      (let ((thumb-buf (get-buffer
                        (format " *kitty-dirvish: %s*" basename))))
        (when thumb-buf
          (with-current-buffer thumb-buf (kitty-gfx-remove-images))
          (kill-buffer thumb-buf)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (kitty-gfx-remove-images)
          (erase-buffer)
          (insert (format "  %s\n\n" basename)))
        (setq-local buffer-read-only t)
        (let ((map (make-sparse-keymap)))
          (define-key map (kbd "q") #'kitty-gfx--preview-quit)
          (use-local-map map)))
      (cond
       ;; Opt-in: play inside the existing dirvish preview side window.
       ((and kitty-gfx-dirvish-video-inline-preview
             pwin (window-live-p pwin))
        (set-window-buffer pwin buf)
        (with-selected-window pwin
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (kitty-gfx-play-video entry)))))
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
            (kitty-gfx-play-video entry))))
       ;; No dirvish session at all (layout-less edge case): fall
       ;; back to the side-window dired flow.
       (t (kitty-gfx-dired-play-video))))
    t))

;;;; Dirvish integration

;; Forward declarations for dirvish
(declare-function dirvish-define-preview "dirvish" (&rest args))
(declare-function dirvish--special-buffer "dirvish" (type dv &optional new))
(defvar dirvish-image-exts)
(defvar dirvish-preview-dispatchers)
(defvar dirvish--available-preview-dispatchers)

(defun kitty-gfx--dirvish-preview (file _ext preview-window _dv)
  "Dirvish preview dispatcher for image / video files via Kitty + mpv.
FILE is the file to preview, PREVIEW-WINDOW is the target window.
Returns a buffer recipe, or nil if neither image nor video."
  (when (and kitty-graphics-mode
             (not (display-graphic-p))
             kitty-gfx--active-backend)
    (kitty-gfx--log "dirvish-preview: %s" file)
    (let* ((buf-name (format " *kitty-dirvish: %s*" (file-name-nondirectory file)))
           (buf (get-buffer-create buf-name))
           (max-cols (min (- (window-width preview-window) 2) kitty-gfx-max-width))
           (max-rows (min (- (window-height preview-window) 3) kitty-gfx-max-height))
           (is-image (kitty-gfx--image-file-p file))
           (is-video (and (not is-image) (kitty-gfx--video-file-p file))))
      (cond
       (is-image
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (kitty-gfx-remove-images)
            (erase-buffer)
            (insert (format "\n  %s\n\n" (file-name-nondirectory file))))
          (setq-local buffer-read-only t)
          (kitty-gfx-display-image file (point-min) (point-max) max-cols max-rows)
          (goto-char (point-min)))
        `(buffer . ,buf))
       (is-video
        (let ((thumb (kitty-gfx--video-thumbnail file)))
          (when thumb
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (kitty-gfx-remove-images)
                (erase-buffer)
                (insert (format "\n  %s\n\n" (file-name-nondirectory file))))
              (setq-local buffer-read-only t)
              (kitty-gfx-display-image
               thumb (point-min) (point-max) max-cols max-rows)
              (goto-char (point-min)))
            `(buffer . ,buf))))))))

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
    ;; Create the dispatcher function that dirvish expects.  Trigger
    ;; for image *and* video extensions; the dispatcher itself
    ;; branches on file type.
    (defalias 'dirvish-kitty-image-dp
      (lambda (file ext preview-window dv)
        ;; Use kitty-gfx's own extension predicates so the match is
        ;; case-insensitive (PNG, JPG, …) and consistent with the
        ;; branching inside `kitty-gfx--dirvish-preview'.  Earlier the
        ;; image arm relied on bare `member ext dirvish-image-exts'
        ;; which is case-sensitive and missed uppercase extensions —
        ;; the file then fell through to `dirvish-image-dp' and
        ;; crashed with "Window system frame should be used" on TTY.
        (when (or (kitty-gfx--image-file-p file)
                  (kitty-gfx--video-extension-p file))
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
  "Return non-nil if mpv video playback is available.
Unavailable inside tmux: mpv's raw Kitty frame stream is forwarded
verbatim and bypasses the tmux passthrough wrapper, so tmux would eat
every frame."
  (and kitty-gfx-enable-video
       kitty-graphics-mode
       (not (display-graphic-p))
       (not (kitty-gfx--frame-getenv "TMUX"))
       (eq kitty-gfx--active-backend 'kitty)
       (executable-find "mpv")))

(defun kitty-gfx--mpv-unavailable-reason ()
  "Return a user-facing string explaining why mpv playback is unavailable.
Returns nil when mpv playback is available."
  (cond
   ((not kitty-gfx-enable-video)
    "kitty-gfx-enable-video is nil (set it to t to enable mpv)")
   ((not kitty-graphics-mode)
    "kitty-graphics-mode is disabled")
   ((display-graphic-p)
    "running in GUI Emacs (inline mpv is a terminal feature)")
   ((kitty-gfx--frame-getenv "TMUX")
    "running inside tmux (mpv's raw frame stream bypasses the tmux passthrough wrapper)")
   ((not (eq kitty-gfx--active-backend 'kitty))
    "Kitty backend not active")
   ((not (executable-find "mpv"))
    "mpv executable not found on PATH")))

(defun kitty-gfx--mpv-ipc-send (command)
  "Send COMMAND (a list) to mpv via JSON IPC.
COMMAND is encoded as {\"command\": COMMAND}."
  (when (and kitty-gfx--mpv-ipc-connection
             (process-live-p kitty-gfx--mpv-ipc-connection))
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
          (process-send-string kitty-gfx--mpv-ipc-connection json)
        (error
         (kitty-gfx--log "mpv-ipc-send error: %s" (error-message-string err)))))))

(defun kitty-gfx--mpv-ipc-connect (socket-path buffer)
  "Poll for SOCKET-PATH existence, then connect and store the process in BUFFER.
Polls every 50ms, times out after 2 seconds.  The poll timer is stored
buffer-locally in BUFFER so `kitty-gfx--mpv-cleanup' can cancel it, and
polling stops on its own when BUFFER no longer records SOCKET-PATH as
its mpv IPC socket (the session was torn down or replaced)."
  (let ((attempts 0)
        (max-attempts 40))
    (cl-labels
        ((session-live-p ()
           (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (equal kitty-gfx--mpv-ipc-socket socket-path))))
         (retry ()
           (cl-incf attempts)
           (if (>= attempts max-attempts)
               (progn
                 (kitty-gfx--log "mpv: IPC socket timeout after 2s")
                 (message "kitty-gfx: mpv IPC connection timed out"))
             (let ((timer (run-at-time 0.05 nil #'try-connect)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq kitty-gfx--mpv-ipc-timer timer))))))
         (try-connect ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq kitty-gfx--mpv-ipc-timer nil)))
           (cond
            ((not (session-live-p))
             (kitty-gfx--log "mpv: IPC poll abandoned, session gone (%s)"
                             socket-path))
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
                   (with-current-buffer buffer
                     (setq kitty-gfx--mpv-ipc-connection proc))
                   (kitty-gfx--log "mpv: IPC connected to %s" socket-path))
               (error
                (kitty-gfx--log "mpv: IPC connect failed: %s" (error-message-string err))
                (retry))))
            (t (retry)))))
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

(defun kitty-gfx--mpv-overlay-position (win)
  "Return (ROW . COL) terminal position of the mpv overlay in WIN, or nil.
ROW and COL are 1-based terminal cell coordinates.  Returns nil when
the overlay is not visible in WIN or when a minibuffer is currently
active -- during minibuffer activation the source window is in a
transient state and `posn-at-point' tends to return origin
coordinates that would yank the video to (1,1)."
  (when (and kitty-gfx--mpv-overlay
             (overlay-buffer kitty-gfx--mpv-overlay)
             win
             (not (active-minibuffer-window)))
    (let* ((ov kitty-gfx--mpv-overlay)
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

(defun kitty-gfx--mpv-canonical-window ()
  "Return the window that should drive mpv IPC repositioning, or nil.
Prefers `selected-window' when it shows the mpv overlay's buffer,
otherwise the first visible window displaying that buffer."
  (when (and kitty-gfx--mpv-overlay
             (overlay-buffer kitty-gfx--mpv-overlay))
    (let* ((buf (overlay-buffer kitty-gfx--mpv-overlay))
           (term kitty-gfx--mpv-terminal)
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

(defun kitty-gfx--refresh-mpv-overlay ()
  "Update mpv position if the overlay has moved.
Uses the per-window placement record on the mpv overlay (same
`kitty-gfx-placements' alist used by image overlays) as the source
of truth, with the canonical window from
`kitty-gfx--mpv-canonical-window'.  No IPC is sent while a
minibuffer is active so M-x / vertico / helm prompts do not yank
the video to the top of the screen."
  (when (and kitty-gfx--mpv-process
             (process-live-p kitty-gfx--mpv-process)
             kitty-gfx--mpv-overlay)
    (cond
     ;; Bug fix: hold position while a minibuffer prompt is up.
     ((active-minibuffer-window)
      (kitty-gfx--log "mpv: minibuffer active, holding position"))
     (t
      (let ((win (kitty-gfx--mpv-canonical-window)))
        (if (not win)
            ;; Overlay not visible in any window — auto-pause mpv to
            ;; stop audio + frame work, but keep the placement record
            ;; so we can re-emit cleanly when the buffer returns.
            (progn
              (when kitty-gfx--mpv-last-row
                (kitty-gfx--log "mpv: overlay hidden")
                (setq kitty-gfx--mpv-last-row nil
                      kitty-gfx--mpv-last-col nil))
              (unless (or kitty-gfx--mpv-paused kitty-gfx--mpv-auto-paused)
                (kitty-gfx--log "mpv: auto-paused (buffer hidden)")
                (setq kitty-gfx--mpv-auto-paused t)
                (kitty-gfx--mpv-ipc-send
                 (list "set_property" "pause" t))))
          ;; Visible again — if we auto-paused earlier, resume now.
          ;; A user-driven pause (`kitty-gfx--mpv-paused') is preserved.
          (when (and kitty-gfx--mpv-auto-paused
                     (not kitty-gfx--mpv-paused))
            (kitty-gfx--log "mpv: auto-resumed")
            (setq kitty-gfx--mpv-auto-paused nil)
            (kitty-gfx--mpv-ipc-send
             (list "set_property" "pause" :false)))
          (let ((pos (kitty-gfx--mpv-overlay-position win))
                (ov kitty-gfx--mpv-overlay))
            (when pos
              (let* ((row (car pos))
                     (col (cdr pos))
                     (record (kitty-gfx--image-placement ov win))
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
                  (kitty-gfx--log "mpv: ignoring suspicious origin reposition"))
                 (t
                  (kitty-gfx--log "mpv: reposition to row=%d col=%d" row col)
                  (kitty-gfx--mpv-ipc-send
                   (list "set_property" "vo-kitty-top" row))
                  (kitty-gfx--mpv-ipc-send
                   (list "set_property" "vo-kitty-left" col))
                  (kitty-gfx--record-image-placement ov win row col 0 0 0)
                  (setq kitty-gfx--mpv-last-row row
                        kitty-gfx--mpv-last-col col))))))))))))

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
  (when kitty-gfx--mpv-ipc-timer
    (cancel-timer kitty-gfx--mpv-ipc-timer)
    (setq kitty-gfx--mpv-ipc-timer nil))
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
    ;; Drop the per-window placement records before deleting the
    ;; overlay, mirroring image-overlay cleanup.
    (let* ((ov kitty-gfx--mpv-overlay)
           (buf (overlay-buffer ov))
           (beg (overlay-get ov 'kitty-gfx-inserted-beg))
           (end (overlay-get ov 'kitty-gfx-inserted-end)))
      (overlay-put ov 'kitty-gfx-placements nil)
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
    (setq kitty-gfx--mpv-overlay nil))
  (setq kitty-gfx--mpv-last-row nil
        kitty-gfx--mpv-last-col nil
        kitty-gfx--mpv-paused nil
        kitty-gfx--mpv-auto-paused nil)
  ;; mpv's kitty VO may hide the cursor; restore it on the terminal that
  ;; played the video.  Also force a full redisplay so Emacs repaints the
  ;; region mpv was occupying.
  (ignore-errors (send-string-to-terminal "\e[?25h" kitty-gfx--mpv-terminal))
  (setq kitty-gfx--mpv-terminal nil)
  (force-mode-line-update t)
  (when (fboundp 'redraw-display) (redraw-display)))

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
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx-inserted-beg
                     (copy-marker start))
        (overlay-put kitty-gfx--mpv-overlay 'kitty-gfx-inserted-end
                     (copy-marker end t))
        ;; Local bindings on the video region: SPC toggles, q stops + back.
        (overlay-put kitty-gfx--mpv-overlay 'keymap
                     kitty-gfx-video-overlay-map)
        (goto-char start)))
    ;; Compute initial terminal position and seed the per-window
    ;; placement record so the first refresh after IPC connect does
    ;; not re-emit identical coordinates.
    (let* ((win (selected-window))
           (pos (kitty-gfx--mpv-overlay-position win)))
      (when pos
        (setq row (car pos) col (cdr pos))
        (kitty-gfx--record-image-placement
         kitty-gfx--mpv-overlay win row col 0 0 0)
        (setq kitty-gfx--mpv-last-row row
              kitty-gfx--mpv-last-col col)))
    ;; Store socket path
    (setq kitty-gfx--mpv-ipc-socket socket-path)
    ;; Spawn mpv on a pty so its kitty VO escape stream can be captured.
    ;; mpv writes APC graphics sequences to stdout; we forward each chunk
    ;; to the Emacs controlling terminal via `send-string-to-terminal'.
    (let* ((process-connection-type t) ; pty so mpv sees a tty for VO
           (proc (make-process
                  :name "kitty-gfx-mpv"
                  :buffer nil
                  :noquery t
                  :connection-type 'pty
                  :coding '(binary . binary)
                  :command
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
                        "--hwdec=auto-safe"
                        "--vo=kitty"
                        ;; Send frames via shared memory rather than
                        ;; base64 inside APC escapes -- orders of
                        ;; magnitude less data through the pty filter.
                        "--vo-kitty-use-shm=yes"
                        (format "--vo-kitty-cols=%d" video-cols)
                        (format "--vo-kitty-rows=%d" video-rows)
                        (format "--vo-kitty-width=%d" width-px)
                        (format "--vo-kitty-height=%d" height-px)
                        (format "--vo-kitty-left=%d" col)
                        (format "--vo-kitty-top=%d" row)
                        "--vo-kitty-config-clear=no"
                        "--vo-kitty-alt-screen=no"
                        "--really-quiet"
                        "--no-input-terminal"
                        (format "--input-ipc-server=%s" socket-path)
                        file)
                  :filter #'kitty-gfx--mpv-filter
                  :sentinel #'kitty-gfx--mpv-process-sentinel)))
      (setq kitty-gfx--mpv-process proc)
      ;; Bind playback to the launching terminal: the filter forwards mpv's
      ;; VO bytes only there, so other daemon clients are not painted over.
      (setq kitty-gfx--mpv-terminal (frame-terminal (selected-frame)))
      (process-put proc 'kitty-gfx-terminal kitty-gfx--mpv-terminal)
      (kitty-gfx--log "mpv: started pid=%s file=%s" (process-id proc) file)
      ;; Connect IPC after mpv creates the socket
      (kitty-gfx--mpv-ipc-connect socket-path (current-buffer)))))

(defun kitty-gfx--mpv-filter (proc chunk)
  "Forward mpv/casty stdout CHUNK to the terminal PROC was launched on.
mpv with `--vo=kitty' (and casty in embed mode) emit APC graphics escapes
to stdout.  When spawned as a subprocess of Emacs, those bytes land here.
Writing them back out with `send-string-to-terminal' makes the terminal
paint the frames inline.  The target terminal is the one recorded on PROC
at launch, so under a daemon only the launching client is painted; nil
falls back to the selected terminal for the single-client case.
Chunks are dropped while the process carries the `kitty-gfx-suppress'
flag, set by `kitty-gfx--refresh-browser-overlay' while no window shows
the browser buffer."
  (when (and chunk (> (length chunk) 0)
             (not (process-get proc 'kitty-gfx-suppress)))
    (condition-case err
        (send-string-to-terminal chunk (process-get proc 'kitty-gfx-terminal))
      (error
       (kitty-gfx--log "mpv-filter error: %s" (error-message-string err))))))

(defun kitty-gfx--mpv-buffer ()
  "Return the buffer currently hosting an mpv playback, or nil.
Prefers the current buffer when it owns an mpv process; otherwise
walks `buffer-list' for the first buffer with a live mpv process."
  (if (and kitty-gfx--mpv-process (process-live-p kitty-gfx--mpv-process))
      (current-buffer)
    (cl-loop for b in (buffer-list)
             when (buffer-local-value 'kitty-gfx--mpv-process b)
             when (process-live-p (buffer-local-value 'kitty-gfx--mpv-process b))
             return b)))

(defun kitty-gfx-stop-video ()
  "Stop inline video playback.
Acts on the current buffer's video when present, otherwise on
whichever buffer currently owns a live mpv process so the command
works from M-x regardless of which buffer the user is in."
  (interactive)
  (let ((buf (kitty-gfx--mpv-buffer)))
    (if buf
        (with-current-buffer buf
          (kitty-gfx--mpv-cleanup)
          (message "kitty-gfx: video stopped (buffer %s)" (buffer-name buf)))
      (message "kitty-gfx: no video playing"))))

(defun kitty-gfx-stop-video-and-back ()
  "Stop inline video playback and switch to the previously shown buffer."
  (interactive)
  (kitty-gfx-stop-video)
  (previous-buffer))

(defun kitty-gfx-video-help ()
  "Echo the inline-video keymap to the minibuffer."
  (interactive)
  (message "SPC pause/resume  q stop+back  ? help"))

(defun kitty-gfx--mpv-set-paused-mark (paused)
  "Set the visible pause indicator on the mpv overlay.
PAUSED non-nil shows \" \\u23F8\" as a `before-string'; nil clears."
  (when kitty-gfx--mpv-overlay
    (overlay-put kitty-gfx--mpv-overlay
                 'before-string
                 (when paused
                   (propertize " \u23F8 " 'face 'mode-line-emphasis)))))

(defun kitty-gfx-toggle-video ()
  "Toggle pause/resume of inline video playback.
Acts on the current buffer's video when present, otherwise on
whichever buffer currently owns a live mpv process."
  (interactive)
  (let ((buf (kitty-gfx--mpv-buffer)))
    (if buf
        (with-current-buffer buf
          (setq kitty-gfx--mpv-paused (not kitty-gfx--mpv-paused)
                ;; User-driven pause overrides any auto-pause: clear
                ;; the auto flag so we don't re-resume against the
                ;; user's wishes when the buffer is shown again.
                kitty-gfx--mpv-auto-paused nil)
          (kitty-gfx--mpv-ipc-send
           (list "set_property" "pause"
                 (if kitty-gfx--mpv-paused t :false)))
          (kitty-gfx--mpv-set-paused-mark kitty-gfx--mpv-paused)
          (kitty-gfx--log "mpv: %s (buffer %s)"
                          (if kitty-gfx--mpv-paused "paused" "resumed")
                          (buffer-name))
          (message "kitty-gfx: video %s"
                   (if kitty-gfx--mpv-paused "paused" "resumed")))
      (message "kitty-gfx: no video playing"))))

;;;; casty browser integration

(defun kitty-gfx--browser-available-p ()
  "Return non-nil if the inline casty browser is available.
Unavailable inside tmux: casty's raw Kitty frame stream is forwarded
verbatim and bypasses the tmux passthrough wrapper, so tmux would eat
every frame."
  (and kitty-gfx-enable-browser
       kitty-graphics-mode
       (not (display-graphic-p))
       (not (kitty-gfx--frame-getenv "TMUX"))
       (eq kitty-gfx--active-backend 'kitty)
       (executable-find kitty-gfx-casty-program)))

(defun kitty-gfx--browser-unavailable-reason ()
  "Return a user-facing string explaining why the browser is unavailable."
  (cond
   ((not kitty-gfx-enable-browser)
    "kitty-gfx-enable-browser is nil (set it to t to enable)")
   ((not kitty-graphics-mode)
    "kitty-graphics-mode is disabled")
   ((display-graphic-p)
    "running in GUI Emacs (the inline browser is a terminal feature)")
   ((kitty-gfx--frame-getenv "TMUX")
    "running inside tmux (casty's raw frame stream bypasses the tmux passthrough wrapper)")
   ((not (eq kitty-gfx--active-backend 'kitty))
    "Kitty backend not active")
   ((not (executable-find kitty-gfx-casty-program))
    (format "casty program %S not found on PATH" kitty-gfx-casty-program))))

(defun kitty-gfx--browser-send (plist)
  "Send PLIST as a newline-terminated JSON command to this buffer's casty.
PLIST uses keyword keys, e.g. (:cmd \"scroll\" :dy 300)."
  (let ((conn kitty-gfx--browser-ipc-connection))
    (when (and conn (process-live-p conn))
      (condition-case err
          (process-send-string conn (concat (json-serialize plist) "\n"))
        (error
         (kitty-gfx--log "browser-ipc-send error: %s" (error-message-string err)))))))

(defun kitty-gfx--browser-ipc-filter (proc output)
  "Parse casty IPC replies (OUTPUT) for PROC.
Replies are newline-delimited JSON.  Partial lines are buffered on the
process.  A reply with `hintActive' false clears the owning buffer's
`kitty-gfx--browser-hint-active' flag, which ends the hint transient map."
  (kitty-gfx--log "browser-ipc: %s" (string-trim output))
  (let* ((buf (concat (or (process-get proc 'kitty-gfx-ipc-buf) "") output))
         (lines (split-string buf "\n")))
    ;; Last element is the (possibly empty) trailing partial line.
    (process-put proc 'kitty-gfx-ipc-buf (car (last lines)))
    (dolist (line (butlast lines))
      (when (> (length (string-trim line)) 0)
        (let ((obj (ignore-errors
                     (json-parse-string line :object-type 'plist
                                        :false-object nil :null-object nil))))
          (when (and obj (plist-member obj :hintActive)
                     (not (plist-get obj :hintActive)))
            (let ((owner (process-get proc 'kitty-gfx-buffer)))
              (when (buffer-live-p owner)
                (with-current-buffer owner
                  (setq kitty-gfx--browser-hint-active nil))))))))))

(defun kitty-gfx--browser-ipc-connect (socket-path buffer)
  "Poll for SOCKET-PATH, then connect and store the process in BUFFER.
Polls every 50ms, times out after 2 seconds (mirrors the mpv path).
The poll timer is stored buffer-locally in BUFFER so
`kitty-gfx--browser-cleanup' can cancel it, and polling stops on its
own when BUFFER no longer records SOCKET-PATH as its casty socket."
  (let ((attempts 0)
        (max-attempts 40))
    (cl-labels
        ((session-live-p ()
           (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (equal kitty-gfx--browser-ipc-socket socket-path))))
         (retry ()
           (cl-incf attempts)
           (if (>= attempts max-attempts)
               (progn
                 (kitty-gfx--log "browser: IPC socket timeout after 2s")
                 (message "kitty-gfx: casty IPC connection timed out"))
             (let ((timer (run-at-time 0.05 nil #'try-connect)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq kitty-gfx--browser-ipc-timer timer))))))
         (try-connect ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq kitty-gfx--browser-ipc-timer nil)))
           (cond
            ((not (session-live-p))
             (kitty-gfx--log "browser: IPC poll abandoned, session gone (%s)"
                             socket-path))
            ((file-exists-p socket-path)
             (condition-case err
                 (let ((proc (make-network-process
                              :name "kitty-gfx-browser-ipc"
                              :family 'local
                              :service socket-path
                              :buffer nil
                              :noquery t
                              :filter #'kitty-gfx--browser-ipc-filter)))
                   (process-put proc 'kitty-gfx-buffer buffer)
                   (with-current-buffer buffer
                     (setq kitty-gfx--browser-ipc-connection proc))
                   (kitty-gfx--log "browser: IPC connected to %s" socket-path))
               (error
                (kitty-gfx--log "browser: IPC connect failed: %s" (error-message-string err))
                (retry))))
            (t (retry)))))
      (try-connect))))

(defun kitty-gfx--browser-compute-geometry ()
  "Compute browser geometry as (COLS ROWS WIDTH-PX HEIGHT-PX).
Fills the selected window body, clamped to the configured maxima."
  (kitty-gfx--query-cell-size)
  (let* ((cw (or kitty-gfx--cell-pixel-width 8))
         (ch (or kitty-gfx--cell-pixel-height 16))
         (cols (max 1 (min (1- (window-body-width)) kitty-gfx-browser-max-width)))
         (rows (max 1 (min (1- (window-body-height)) kitty-gfx-browser-max-height))))
    (list cols rows (* cols cw) (* rows ch))))

(defun kitty-gfx--browser-overlay-position (win)
  "Return (ROW . COL) terminal position of the browser overlay in WIN, or nil.
ROW and COL are 1-based.  Returns nil when the overlay is not visible
in WIN or while a minibuffer is active (mirrors the mpv logic)."
  (when (and kitty-gfx--browser-overlay
             (overlay-buffer kitty-gfx--browser-overlay)
             win
             (not (active-minibuffer-window)))
    (let* ((ov kitty-gfx--browser-overlay)
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

(defun kitty-gfx--browser-canonical-window ()
  "Return the window that should drive browser repositioning, or nil."
  (when (and kitty-gfx--browser-overlay
             (overlay-buffer kitty-gfx--browser-overlay))
    (let* ((buf (overlay-buffer kitty-gfx--browser-overlay))
           (sel (selected-window)))
      (if (and (window-live-p sel) (eq (window-buffer sel) buf))
          sel
        (car (get-buffer-window-list buf nil 'visible))))))

(defun kitty-gfx--refresh-browser-overlay ()
  "Send a `set-geometry' IPC command when the browser overlay has moved.
No IPC is sent while a minibuffer is active so prompts do not yank the
frame to the top of the screen.  When no window shows the browser
buffer, frame forwarding is suppressed (mirroring the mpv auto-pause):
a flag on the casty process makes `kitty-gfx--mpv-filter' drop frames,
and the on-screen image is deleted on the launch terminal so it does
not paint over unrelated content.  When a window shows the buffer
again the flag is cleared and the geometry is re-emitted, which makes
casty repaint the frame."
  (when (and kitty-gfx--browser-process
             (process-live-p kitty-gfx--browser-process)
             kitty-gfx--browser-overlay)
    (cond
     ((active-minibuffer-window)
      (kitty-gfx--log "browser: minibuffer active, holding position"))
     (t
      (let ((win (kitty-gfx--browser-canonical-window))
            (proc kitty-gfx--browser-process))
        (if (not win)
            (unless (process-get proc 'kitty-gfx-suppress)
              (kitty-gfx--log "browser: buffer hidden, suppressing frames")
              (process-put proc 'kitty-gfx-suppress t)
              (setq kitty-gfx--browser-last-row nil
                    kitty-gfx--browser-last-col nil)
              (when (and kitty-gfx--browser-image-id
                         (terminal-live-p kitty-gfx--browser-terminal))
                (kitty-gfx--with-terminal kitty-gfx--browser-terminal
                  (kitty-gfx--delete-by-id kitty-gfx--browser-image-id))))
          (when (process-get proc 'kitty-gfx-suppress)
            (kitty-gfx--log "browser: buffer visible again, resuming frames")
            (process-put proc 'kitty-gfx-suppress nil)
            (setq kitty-gfx--browser-last-row nil
                  kitty-gfx--browser-last-col nil))
          (let ((pos (kitty-gfx--browser-overlay-position win)))
            (when pos
              (let ((row (car pos))
                    (col (cdr pos)))
                (cond
                 ((and (eql row kitty-gfx--browser-last-row)
                       (eql col kitty-gfx--browser-last-col)))
                 ((and kitty-gfx--browser-last-row
                       (not (and (eql kitty-gfx--browser-last-row 1)
                                 (eql kitty-gfx--browser-last-col 1)))
                       (eql row 1) (eql col 1))
                  (kitty-gfx--log "browser: ignoring suspicious origin reposition"))
                 (t
                  (kitty-gfx--log "browser: reposition row=%d col=%d" row col)
                  (kitty-gfx--browser-send (list :cmd "set-geometry" :top row :left col))
                  (setq kitty-gfx--browser-last-row row
                        kitty-gfx--browser-last-col col))))))))))))

(defun kitty-gfx--browser-process-sentinel (proc event)
  "Clean up when the casty PROC exits.  EVENT describes the change."
  (kitty-gfx--log "browser: process event: %s" (string-trim event))
  (when (memq (process-status proc) '(exit signal))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (eq kitty-gfx--browser-process proc)
          (kitty-gfx--browser-cleanup))))))

(defun kitty-gfx--browser-cleanup ()
  "Tear down the casty browser in the current buffer.
Safe to call more than once."
  (when kitty-gfx--browser-ipc-timer
    (cancel-timer kitty-gfx--browser-ipc-timer)
    (setq kitty-gfx--browser-ipc-timer nil))
  (when kitty-gfx--browser-ipc-connection
    (ignore-errors (delete-process kitty-gfx--browser-ipc-connection))
    (setq kitty-gfx--browser-ipc-connection nil))
  (when kitty-gfx--browser-process
    (when (process-live-p kitty-gfx--browser-process)
      (ignore-errors (kill-process kitty-gfx--browser-process)))
    (setq kitty-gfx--browser-process nil))
  (when kitty-gfx--browser-ipc-socket
    (ignore-errors (delete-file kitty-gfx--browser-ipc-socket))
    (setq kitty-gfx--browser-ipc-socket nil))
  (let ((log (get-buffer "*kitty-casty-log*")))
    (when (and log
               (not (cl-some
                     (lambda (b)
                       (let ((p (buffer-local-value 'kitty-gfx--browser-process b)))
                         (and p (process-live-p p))))
                     (buffer-list))))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer log)))))
  ;; Free the kitty image casty was drawing into.
  (when kitty-gfx--browser-image-id
    (kitty-gfx--with-terminal (and (terminal-live-p kitty-gfx--browser-terminal)
                                   kitty-gfx--browser-terminal)
      (ignore-errors (kitty-gfx--delete-by-id kitty-gfx--browser-image-id)))
    (setq kitty-gfx--browser-image-id nil))
  (when kitty-gfx--browser-overlay
    (ignore-errors (delete-overlay kitty-gfx--browser-overlay))
    (setq kitty-gfx--browser-overlay nil))
  (setq kitty-gfx--browser-last-row nil
        kitty-gfx--browser-last-col nil)
  ;; Restore xterm-mouse-mode if we turned it on for this buffer.
  (when kitty-gfx--browser-xterm-mouse-was-off
    (setq kitty-gfx--browser-xterm-mouse-was-off nil)
    (when (bound-and-true-p xterm-mouse-mode)
      (xterm-mouse-mode -1)))
  ;; casty hid nothing in embed mode, but restore the cursor defensively on
  ;; the launching terminal and force a repaint of the region it occupied.
  (ignore-errors (send-string-to-terminal "\e[?25h" kitty-gfx--browser-terminal))
  (setq kitty-gfx--browser-terminal nil)
  (force-mode-line-update t)
  (when (fboundp 'redraw-display) (redraw-display)))

(defun kitty-gfx--stop-all-browsers ()
  "Tear down every live casty browser session across all buffers."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when kitty-gfx--browser-process
          (kitty-gfx--browser-cleanup))))))

(defun kitty-gfx--stop-terminal-processes (term)
  "Stop any mpv/casty playback launched on terminal TERM.
Called from `kitty-gfx--on-delete-terminal' so a disconnecting client
leaves no subprocess streaming Kitty frames to a dead tty."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and kitty-gfx--mpv-process
                   (eq kitty-gfx--mpv-terminal term))
          (kitty-gfx--mpv-cleanup))
        (when (and kitty-gfx--browser-process
                   (eq kitty-gfx--browser-terminal term))
          (kitty-gfx--browser-cleanup))))))

;;;###autoload
(defun kitty-gfx-browse (url)
  "Open URL in an inline casty browser buffer (`*kitty-browser*').
Requires `kitty-gfx-enable-browser' to be non-nil and casty installed."
  (interactive (list (read-string "URL: " "https://")))
  (unless (kitty-gfx--browser-available-p)
    (user-error "casty browser unavailable: %s" (kitty-gfx--browser-unavailable-reason)))
  (let ((buf (get-buffer-create "*kitty-browser*")))
    (switch-to-buffer buf)
    (unless (eq major-mode 'kitty-gfx-browser-mode)
      (kitty-gfx-browser-mode))
    ;; Replace any existing session in this buffer.
    (when kitty-gfx--browser-process
      (kitty-gfx--browser-cleanup))
    (let* ((geom (kitty-gfx--browser-compute-geometry))
           (cols (nth 0 geom))
           (rows (nth 1 geom))
           (width-px (nth 2 geom))
           (height-px (nth 3 geom))
           (id (kitty-gfx--alloc-id))
           (socket (concat (make-temp-name "/tmp/kitty-gfx-casty-") ".sock"))
           (inhibit-read-only t))
      (erase-buffer)
      (insert (make-string rows ?\n))
      (goto-char (point-min))
      (setq kitty-gfx--browser-image-id id
            kitty-gfx--browser-ipc-socket socket
            kitty-gfx--browser-cols cols
            kitty-gfx--browser-rows rows)
      (let ((ov (make-overlay (point-min) (point-max) nil t nil)))
        (overlay-put ov 'kitty-gfx t)
        (overlay-put ov 'kitty-gfx-browser t)
        (overlay-put ov 'kitty-gfx-id id)
        (overlay-put ov 'evaporate t)
        (setq kitty-gfx--browser-overlay ov))
      ;; Seed the initial terminal position so the first refresh after the
      ;; IPC connects does not re-emit identical coordinates.
      (let* ((win (selected-window))
             (pos (kitty-gfx--browser-overlay-position win)))
        (when pos
          (setq kitty-gfx--browser-last-row (car pos)
                kitty-gfx--browser-last-col (cdr pos))))
      (let* ((row (or kitty-gfx--browser-last-row 1))
             (col (or kitty-gfx--browser-last-col 1))
             (process-environment
              (append
               (list (format "CASTY_CELL_WIDTH=%d" (or kitty-gfx--cell-pixel-width 8))
                     (format "CASTY_CELL_HEIGHT=%d" (or kitty-gfx--cell-pixel-height 16)))
               ;; With debug on, ask casty to log each click's resolved CSS
               ;; pixel + the element under it to *kitty-casty-log* so a missed
               ;; click is visible (NONE) instead of a silent no-op.
               (when kitty-gfx-debug (list "CASTY_DEBUG=1"))
               ;; A configured browser means we also skip casty's
               ;; Chrome-Headless-Shell auto-install bootstrap.
               (when kitty-gfx-casty-chrome
                 (list (format "CASTY_CHROME=%s" kitty-gfx-casty-chrome)
                       "CASTY_ENSURE_CHROME=1"))
               process-environment))
             (proc (make-process
                    :name "kitty-gfx-casty"
                    :buffer nil
                    :noquery t
                    :connection-type 'pty
                    :coding '(binary . binary)
                    ;; Keep casty's stderr (status/error logs) OFF the pty so
                    ;; it is never forwarded into the kitty graphics stream and
                    ;; painted as garbage; route it to a debug buffer instead.
                    :stderr (get-buffer-create "*kitty-casty-log*")
                    :command
                    (list kitty-gfx-casty-program "--embed"
                          "--ipc" socket
                          "--image-id" (number-to-string id)
                          "--cols" (number-to-string cols)
                          "--rows" (number-to-string rows)
                          "--top" (number-to-string row)
                          "--left" (number-to-string col)
                          "--width" (number-to-string width-px)
                          "--height" (number-to-string height-px)
                          url)
                    :filter #'kitty-gfx--mpv-filter
                    :sentinel #'kitty-gfx--browser-process-sentinel)))
        (setq kitty-gfx--browser-process proc)
        ;; Bind the browser to its launching terminal (see mpv above).
        (setq kitty-gfx--browser-terminal (frame-terminal (selected-frame)))
        (process-put proc 'kitty-gfx-terminal kitty-gfx--browser-terminal)
        (kitty-gfx--log "browser: started pid=%s url=%s" (process-id proc) url)
        (kitty-gfx--browser-ipc-connect socket buf))
      (message "kitty-gfx: browsing %s" url))))

;; ── browser commands (bound in the mode map) ──

(defun kitty-gfx-browser-scroll-down ()
  "Scroll the browser page down."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "scroll" :dy kitty-gfx-browser-scroll-step)))

(defun kitty-gfx-browser-scroll-up ()
  "Scroll the browser page up."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "scroll" :dy (- kitty-gfx-browser-scroll-step))))

(defun kitty-gfx-browser-page-down ()
  "Scroll the browser one page down."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "key" :name "PageDown")))

(defun kitty-gfx-browser-page-up ()
  "Scroll the browser one page up."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "key" :name "PageUp")))

(defun kitty-gfx-browser-back ()
  "Go back in browser history."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "back")))

(defun kitty-gfx-browser-forward ()
  "Go forward in browser history."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "forward")))

(defun kitty-gfx-browser-reload ()
  "Reload the current browser page."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "reload")))

(defun kitty-gfx-browser-open-url (url)
  "Navigate the browser to URL."
  (interactive (list (read-string "URL: " "https://")))
  (kitty-gfx--browser-send (list :cmd "navigate" :url url)))

(defun kitty-gfx-browser-quit ()
  "Stop the browser and kill its buffer."
  (interactive)
  (kitty-gfx--browser-send (list :cmd "quit"))
  (let ((buf (current-buffer)))
    (kitty-gfx--browser-cleanup)
    (kill-buffer buf)))

;; ── link hints (Vimium-style, casty draws the labels) ──

(defvar kitty-gfx-browser-hint-chars '(?a ?s ?d ?f ?j ?k ?l)
  "Label characters casty uses for link hints (casty `HINT_CHARS').")

(defun kitty-gfx--browser-hint-key ()
  "Forward the just-typed key to casty as a hint-mode keystroke."
  (interactive)
  (let ((e last-command-event))
    (kitty-gfx--browser-send
     (list :cmd "hint-key"
           :key (cond ((memq e '(?\d backspace)) "\x7f")
                      ((characterp e) (char-to-string e))
                      (t ""))))))

(defun kitty-gfx-browser-hint-abort ()
  "Cancel link-hint mode (tell casty to remove the labels)."
  (interactive)
  (setq kitty-gfx--browser-hint-active nil)
  (kitty-gfx--browser-send (list :cmd "hint-key" :key "\e")))

(defun kitty-gfx-browser-hints ()
  "Show Vimium-style link hints and follow the one whose label you type.
casty injects the labels into the page (they appear in the next frame);
subsequent label keystrokes are forwarded until a link is chosen or
`escape'/`C-g' cancels."
  (interactive)
  (setq kitty-gfx--browser-hint-active t)
  (kitty-gfx--browser-send (list :cmd "hints"))
  (let ((map (make-sparse-keymap)))
    (dolist (c kitty-gfx-browser-hint-chars)
      (define-key map (char-to-string c) #'kitty-gfx--browser-hint-key))
    (define-key map (kbd "DEL")      #'kitty-gfx--browser-hint-key)
    (define-key map (kbd "<escape>") #'kitty-gfx-browser-hint-abort)
    (define-key map (kbd "C-g")      #'kitty-gfx-browser-hint-abort)
    (set-transient-map map (lambda () kitty-gfx--browser-hint-active))))

(defun kitty-gfx-browser-click (event)
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
         (cols (or kitty-gfx--browser-cols col))
         (rows (or kitty-gfx--browser-rows row)))
    (if (or (> col cols) (> row rows))
        (kitty-gfx--log "browser: click col=%d row=%d outside grid %dx%d (ignored)"
                        col row cols rows)
      (kitty-gfx--log "browser: click col=%d row=%d" col row)
      (kitty-gfx--browser-send (list :cmd "click" :col col :row row)))))

(defvar kitty-gfx-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "j"       #'kitty-gfx-browser-scroll-down)
    (define-key map "k"       #'kitty-gfx-browser-scroll-up)
    (define-key map (kbd "C-f") #'kitty-gfx-browser-page-down)
    (define-key map (kbd "C-b") #'kitty-gfx-browser-page-up)
    ;; Mouse wheel → scroll the page instead of the Emacs window.
    (define-key map [wheel-down] #'kitty-gfx-browser-scroll-down)
    (define-key map [wheel-up]   #'kitty-gfx-browser-scroll-up)
    (define-key map [mouse-5]    #'kitty-gfx-browser-scroll-down)
    (define-key map [mouse-4]    #'kitty-gfx-browser-scroll-up)
    (define-key map "H"       #'kitty-gfx-browser-back)
    (define-key map "L"       #'kitty-gfx-browser-forward)
    (define-key map "r"       #'kitty-gfx-browser-reload)
    (define-key map "o"       #'kitty-gfx-browser-open-url)
    (define-key map (kbd ":") #'kitty-gfx-browser-open-url)
    (define-key map "f"       #'kitty-gfx-browser-hints)
    (define-key map [mouse-1] #'kitty-gfx-browser-click)
    (define-key map "q"       #'kitty-gfx-browser-quit)
    map)
  "Keymap for `kitty-gfx-browser-mode'.")

(define-derived-mode kitty-gfx-browser-mode special-mode "KittyBrowser"
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
    (setq kitty-gfx--browser-xterm-mouse-was-off t)
    (xterm-mouse-mode 1))
  ;; Tear the browser down with the buffer.
  (add-hook 'kill-buffer-hook #'kitty-gfx--browser-cleanup nil t)
  ;; Mirror the bindings into evil normal/motion state so evil's defaults
  ;; (j/k motions, etc.) do not shadow them -- same pattern as image-mode.
  (when (and kitty-gfx-browser-evil-bindings (fboundp 'evil-local-set-key))
    (dolist (state '(normal motion))
      (evil-local-set-key state "j" #'kitty-gfx-browser-scroll-down)
      (evil-local-set-key state "k" #'kitty-gfx-browser-scroll-up)
      (evil-local-set-key state (kbd "C-f") #'kitty-gfx-browser-page-down)
      (evil-local-set-key state (kbd "C-b") #'kitty-gfx-browser-page-up)
      (evil-local-set-key state "H" #'kitty-gfx-browser-back)
      (evil-local-set-key state "L" #'kitty-gfx-browser-forward)
      (evil-local-set-key state "r" #'kitty-gfx-browser-reload)
      (evil-local-set-key state "o" #'kitty-gfx-browser-open-url)
      (evil-local-set-key state (kbd ":") #'kitty-gfx-browser-open-url)
      (evil-local-set-key state "f" #'kitty-gfx-browser-hints)
      (evil-local-set-key state [mouse-1] #'kitty-gfx-browser-click)
      (evil-local-set-key state "q" #'kitty-gfx-browser-quit))))

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
  (with-eval-after-load 'dired
    (advice-add 'dired-find-file :around
                #'kitty-gfx--dired-find-file-advice)
    (advice-add 'dired-find-file-other-window :around
                #'kitty-gfx--dired-find-file-other-window-advice))
  (with-eval-after-load 'dirvish
    (add-hook 'dirvish-find-entry-hook
              #'kitty-gfx--dirvish-find-entry-hook))
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
  (advice-remove 'dired-find-file #'kitty-gfx--dired-find-file-advice)
  (advice-remove 'dired-find-file-other-window
                 #'kitty-gfx--dired-find-file-other-window-advice)
  (when (boundp 'dirvish-find-entry-hook)
    (remove-hook 'dirvish-find-entry-hook
                 #'kitty-gfx--dirvish-find-entry-hook))
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
                  (pid (overlay-get ov 'kitty-gfx-pid))
                  (temp-file (overlay-get ov 'kitty-gfx-delete-file)))
              (when (and id pid kitty-gfx--active-backend)
                ;; Always delete the placements (they're buffer-specific)
                (kitty-gfx--delete-image-placements ov))
              (when temp-file
                (ignore-errors (delete-file temp-file)))
              ;; Only delete the image data if no other buffer uses it
              (when (and id (not (memq id deleted-ids)))
                (if (kitty-gfx--image-id-in-other-buffers-p id)
                    (kitty-gfx--log "kill-buffer-hook: id=%d still used in other buffers, keeping" id)
                  (push id deleted-ids))))
          (error nil)))
      ;; Remove cache entries only for IDs we actually deleted
      (when deleted-ids
        (kitty-gfx--log "kill-buffer-hook: cleaning cache for ids=%S" deleted-ids)
        (maphash (lambda (file id)
                   (when (memq id deleted-ids)
                     (kitty-gfx--evict-image-everywhere file id)
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
