# AGENTS.md -- kitty-graphics

## Project Overview

Pure Emacs Lisp package (`kitty-graphics.el`) for displaying images in
terminal Emacs (`emacs -nw`) using either the Kitty graphics protocol or
Sixel, with automatic protocol detection. Also renders org-mode headings
at scaled font sizes using the Kitty text sizing protocol (OSC 66).
Integrates with org-mode, image-mode, shr/eww/mu4e/gnus, dired, and dirvish.

Language: **Emacs Lisp** (`lexical-binding: t`). Single source file (~1876 lines).
Current version: **0.3.0** (see Versioning section).

## Build / Validate

### Byte-compile (primary lint check -- run after every change)

```sh
emacs -Q -batch -f batch-byte-compile kitty-graphics.el
```

**This is the closest thing to CI** -- always run it before considering
a change complete.

### Load-test (verify file evaluates without error)

```sh
emacs -Q -batch -l kitty-graphics.el -f kill-emacs
```

## Testing

No automated test framework. All testing is manual/interactive and
requires a supported terminal (Kitty, WezTerm, Ghostty for Kitty backend;
foot, Konsole, xterm, mlterm, mintty for Sixel backend).
The `tests/` directory contains `test-kitty-gfx.org`, `test-image.png`,
and `test-document.pdf` for manual testing -- use these rather than
creating new test files.

**Important**: Always set `TERM=xterm-256color` when launching terminal
Emacs -- the `xterm-kitty` terminfo is often missing.

### Test with org-mode

```sh
TERM=xterm-256color emacs -nw -Q -l kitty-graphics.el \
  --eval "(kitty-graphics-mode 1)" tests/test-kitty-gfx.org
# Then: C-c C-x C-v (org-toggle-inline-images)
```

### Test text sizing (org heading scales)

```sh
TERM=xterm-256color emacs -nw -Q -l kitty-graphics.el \
  --eval "(setq kitty-gfx-heading-sizes-auto t)" \
  --eval "(kitty-graphics-mode 1)" tests/test-kitty-gfx.org
# Headings should render at scaled sizes automatically.
# S-TAB to unfold all, then scroll to verify fold/unfold/scroll.
```

### Test image-mode

```sh
TERM=xterm-256color emacs -nw -Q -l kitty-graphics.el \
  --eval "(kitty-graphics-mode 1)" tests/test-image.png
```

### Debug logging

Set `kitty-gfx-debug` to `t` to log debug info to `/tmp/kitty-gfx.log`.

### Dev environment

The repo uses a Nix flake (`.envrc` → `use flake`). If you have direnv
and Nix, dependencies are provided automatically. This is optional --
only `emacs` and optionally `imagemagick` are needed.

### Agent workflow

When you need the user to manually test a feature in a Kitty-compatible
terminal, or have any question that requires user action, notify them:

```sh
notify-send "kitty-graphics" "Please test: <description of what to test>"
```

## Code Style

### File structure (mandatory order)

```
;;; file.el --- Description -*- lexical-binding: t; -*-
;;; Commentary:
;;; Code:
(require ...)           ; dependencies
(declare-function ...)  ; forward declarations for optional deps
(defgroup ...)          ; customization group
(defcustom ...)         ; user options
(defconst ...)          ; constants
(defvar / defvar-local) ; internal state
;; ... implementation sections with ;;;; headers ...
(provide 'feature)
;;; file.el ends here
```

### Formatting

- **Spaces only**, no tabs (`indent-tabs-mode: nil`; enforced by `Local Variables` block)
- `lexical-binding: t` required in the first line
- `;;;;` section headers to separate logical sections

### Naming conventions

| Category              | Pattern                        | Example                          |
|-----------------------|--------------------------------|----------------------------------|
| Public API            | `kitty-gfx-` prefix           | `kitty-gfx-display-image`       |
| Internal functions    | `kitty-gfx--` (double dash)   | `kitty-gfx--transmit-image`     |
| Buffer-local vars     | `defvar-local` + double dash  | `kitty-gfx--overlays`           |
| Customization vars    | `defcustom` + single dash     | `kitty-gfx-max-width`           |
| Global internal vars  | `defvar` + double dash        | `kitty-gfx--next-id`            |
| Advice functions      | `kitty-gfx--MODE-VERB-advice` | `kitty-gfx--org-display-advice` |
| Minor mode            | `kitty-graphics-mode`          |                                  |

All identifiers use `kebab-case`.

### Requires / Dependencies

- Only `cl-lib` is `require`d directly
- All other dependencies (org, image-mode, shr, dired, dirvish) use
  `declare-function` for forward declarations and `with-eval-after-load`
  for deferred integration -- **never `require` optional packages at
  top level**

### Error handling

- `user-error` for user-facing errors (e.g., unsupported terminal)
- `condition-case` around I/O (terminal queries, files, image processing)
- `ignore-errors` around `send-string-to-terminal` -- terminal writes
  must never crash Emacs
- `when`/`unless` guards rather than explicit error branches
- `unwind-protect` for cleanup (see `kitty-gfx--refresh`)

### Advice convention

All advice uses `:around` and guards on both mode and terminal:

```elisp
(defun kitty-gfx--FOO-advice (orig-fn &rest args)
  (if (and kitty-graphics-mode (not (display-graphic-p)))
      ... ;; terminal path
    (apply orig-fn args)))
```

New mode integrations **must** follow this pattern. Each mode needs
explicit advice -- there is no generic image display hook.

## Architecture

### Backend dispatch

Protocol-specific code is isolated behind an alist-based backend system:

- `kitty-gfx--backends` -- alist mapping `'kitty` / `'sixel` to operation alists
- `kitty-gfx--active-backend` -- symbol for the detected backend
- `kitty-gfx--backend-fn` -- dispatch helper: `(funcall (kitty-gfx--backend-fn 'place) ...)`
- `kitty-gfx--detect-protocol` -- tries Kitty (env check), then Sixel; sets active backend

Each backend implements: `detect`, `prepare`, `place`, `delete`, `cleanup`, `cleanup-all`.

### Image pipeline (shared)

1. **Prepare**: backend-specific -- Kitty transmits via APC `a=t`; Sixel encodes via ImageMagick to temp-file
2. **Reserve space**: `kitty-gfx--make-overlay` -- overlay with blank `display` property
3. **Place**: backend-specific -- Kitty emits `a=p` with `p=PID`; Sixel reads temp-file and emits DCS
4. **Refresh**: `kitty-gfx--refresh` -- debounced via `run-at-time`; walks windows,
   re-places moved overlays, deletes hidden ones
5. **Cache**: `kitty-gfx--image-cache` -- keyed by file path → image ID (integer).
   Dimensions are computed fresh each time. LRU eviction via `kitty-gfx--cache-lru`
   (max `kitty-gfx-cache-size` entries, default 64).
   Sixel also caches encoded data in temp-files under `/tmp/kitty-gfx-sixel-*.six`.

Overlay properties: `kitty-gfx` (bool marker), `kitty-gfx-id` (image ID),
`kitty-gfx-pid` (placement ID), `kitty-gfx-cols`/`kitty-gfx-rows` (cell size),
`kitty-gfx-last-row`/`kitty-gfx-last-col` (cached position, nil if hidden),
`kitty-gfx-file` (source file path, needed by Sixel for re-encoding).
All terminal output is wrapped in synchronized output (BSU/ESU, DEC mode
2026) to prevent flicker.

### Text sizing (OSC 66)

Unlike images, the text sizing protocol is **stateless** — there are no
image IDs or placement IDs.  The terminal renders scaled text inline
but any redraw clears it.

1. **Detect**: `kitty-gfx--query-text-sizing-support` — 3 CPR queries
   to probe width-only vs scale vs no support.  Cached in
   `kitty-gfx--text-sizing-support` (`scale`, `width`, or `none`).
2. **Scan**: `kitty-gfx--org-apply-heading-sizes` — walks org headings,
   looks up scale from `kitty-gfx-heading-scales` alist, creates overlays.
3. **Overlay**: `kitty-gfx--make-heading-overlay` — overlay **without**
   `display` property (Emacs shows the heading line normally; OSC 66 is
   painted on top by the refresh cycle).  No vertical space reservation.
4. **Place**: `kitty-gfx--place-heading` — emits `\e]66;s=SCALE;TEXT\a`
   at cursor position with SGR bold + 24-bit foreground color from
   `org-level-N` faces.
5. **Refresh**: `kitty-gfx--refresh-heading-overlay` — **always re-emits**
   OSC 66 when visible (stateless protocol).  Erases old position on move
   via `kitty-gfx--erase-heading` (writes spaces across all rows —
   per spec, overwriting any cell in the topmost row of a multicell
   character erases the entire block).

Heading overlay properties (in addition to the common ones above):
`kitty-gfx-heading` (bool), `kitty-gfx-heading-text`, `kitty-gfx-heading-scale`,
`kitty-gfx-heading-level`.  Heading overlays have `modification-hooks` so
editing the heading text removes the stale overlay for re-creation.
Re-scan after edits is debounced via `kitty-gfx--heading-rescan-timer`
(buffer-local, 0.2s) to prevent redundant scans from rapid typing.

Key design differences from images:

- Heading overlays **preserve their position cache** in
  `on-window-change` (images clear it).  This lets the refresh cycle
  compare old→new position and erase properly.  Images can afford to
  clear cache because re-placing with the same PID is idempotent.
- In `on-buffer-change`, heading overlays are **defensively erased**
  when their buffer becomes hidden (not visible in any window).  This
  prevents ghost multicell artifacts if the new buffer's content does
  not fully overwrite the heading's terminal cells.
- Overlap detection (`kitty-gfx--heading-occupied-rows`) is reset
  **per-window** inside `walk-windows`, not globally.  This ensures
  headings in one window don't block headings at different terminal
  rows in another window showing the same buffer.

## Known Issues & Planned Work

- **Fixed**: Overlays remain visible when org headings are collapsed (#1)
- **Limitation**: Does not work inside tmux (neither Kitty passthrough nor Sixel) (#2)
- **Limitation**: Each mode needs explicit `:around` advice integration
- **Limitation**: GIF files are not supported (multi-frame conversion issues,
  no animation support in terminal)
- **Limitation**: Sixel is 256 colors (vs truecolor on Kitty), stateless (re-emits on scroll)
- **Done**: LaTeX fragment preview in org-mode (#3)
- **Done**: doc-view / pdf-view-mode integration (#4)
- **Done**: Text sizing protocol for org heading sizes (OSC 66, Kitty >= 0.40.0)
- **Done**: Sixel backend with auto-detection (v0.3.0)
- **WIP**: Sixel image misplacement in org-mode (reported in foot terminal)
- **Planned**: comint-mime integration for shell buffer images (#5)
- **Planned**: Newsticker (RSS reader) integration (#6)

## Dependencies

- **Required**: Emacs >= 27.1, a supported terminal (Kitty/WezTerm/Ghostty
  for Kitty backend; foot/Konsole/xterm/mlterm/mintty for Sixel)
- **Required for Sixel**: ImageMagick (`magick`/`convert`) for encoding
- **Optional for Kitty**: ImageMagick for non-PNG formats and pixel-accurate sizing
- **No external Elisp deps** beyond built-in `cl-lib`

## Versioning

Version is declared in the file header (`Version: X.Y.Z` in
`kitty-graphics.el` line 6). This is the **single source of truth**.

- **Patch** (0.2.x): bug fixes, minor improvements
- **Minor** (0.x.0): new features, new mode integrations
- **Major** (x.0.0): breaking changes to public API (`kitty-gfx-` symbols)

Bump the version in the header when preparing a release.
