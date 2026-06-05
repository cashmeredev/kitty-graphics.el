# kitty-graphics.el -- developer task runner
#
# Requires: just, emacs, typst (for typst tests), imagemagick (for sixel).
# Run `just` to list recipes.

set shell := ["bash", "-cu"]

EMACS  := env_var_or_default("EMACS", "emacs")
TERM_  := env_var_or_default("KGFX_TERM", "xterm-256color")
SRC    := "kitty-graphics.el"

# Default: list recipes
default:
    @just --list --unsorted

# --- Build / lint -----------------------------------------------------------

# Byte-compile (primary lint check)
compile:
    rm -f {{SRC}}c
    {{EMACS}} -Q -batch -f batch-byte-compile {{SRC}}

# Byte-compile, treat warnings as errors
lint:
    rm -f {{SRC}}c
    {{EMACS}} -Q -batch --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile {{SRC}}

# Load-test: file evaluates without error
load:
    {{EMACS}} -Q -batch -l {{SRC}} -f kill-emacs

# Remove generated artifacts
clean:
    rm -f {{SRC}}c
    rm -rf /tmp/kitty-gfx-typst /tmp/kitty-gfx-sixel-*.six /tmp/kitty-gfx.log

# --- Interactive tests (open terminal Emacs) --------------------------------

# Test typst inline equations (M-x kitty-gfx-typst-preview after open)
test-typst:
    @echo ">> M-x kitty-gfx-typst-preview     to render"
    @echo ">> M-x kitty-gfx-typst-clear-preview to clear"
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(kitty-graphics-mode 1)" \
        --eval "(setq kitty-gfx-debug t)" \
        tests/test-typst.typ

# Test org-mode inline images -- C-c C-x C-v after open
test-org:
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-kitty-gfx.org

# Test text sizing protocol (OSC 66) on org headings
test-headings:
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(setq kitty-gfx-heading-sizes-auto t)" \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-kitty-gfx.org

# Test image-mode rendering
test-image:
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-image.png

# Test doc-view / PDF rendering
test-pdf:
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-document.pdf

# Test markdown-overlays integration
test-markdown:
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-markdown.md

# Test LaTeX fragment preview in org-mode (C-c C-x C-l on a fragment)
test-latex:
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-kitty-gfx.org

# Start (or attach to) a tmux session pre-configured for the kitty
# graphics + sixel features in this package:
#   - `allow-passthrough on'   so Kitty APC escapes survive the mux
#   - `*:sixel' terminal-feature so tmux 3.4+ forwards Sixel
#   - default-terminal screen-256color (closest to xterm)
# Then drops into an emacs -nw with kitty-graphics-mode + video enabled.
# Outer terminal should be Kitty (or any kitty-protocol capable term).
tmux:
    #!/usr/bin/env bash
    set -eu
    if [ -n "${TMUX:-}" ]; then
        echo ">> Already inside tmux -- re-applying the kitty-graphics options here."
        tmux set-option -g allow-passthrough on
        tmux set-option -as terminal-features "*:sixel"
        exec env TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
            --eval "(kitty-graphics-mode 1)"
    fi
    SESSION=kgfx
    SOCKET=/tmp/kgfx-tmux.sock
    # Fresh session every time so old options don't linger.
    tmux -S "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
    tmux -S "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 \
        env TERM={{TERM_}} {{EMACS}} -nw -Q -l "$(pwd)/{{SRC}}" \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
            --eval "(kitty-graphics-mode 1)"
    tmux -S "$SOCKET" set-option -t "$SESSION" -g allow-passthrough on
    tmux -S "$SOCKET" set-option -t "$SESSION" -as terminal-features "*:sixel"
    tmux -S "$SOCKET" set-option -t "$SESSION" -g default-terminal "screen-256color"
    exec tmux -S "$SOCKET" attach -t "$SESSION"

# Test dirvish with kitty-graphics: image + video thumbnail previews.
# Bootstraps a throwaway init dir under /tmp/kgfx-dirvish-init/ so
# `package-install dirvish' doesn't touch ~/.emacs.d.  Requires network
# on first run for MELPA refresh.
#   just test-dirvish                        # default: open ~/
#   just test-dirvish dir=/path/to/folder    # open given folder
test-dirvish dir="~":
    #!/usr/bin/env bash
    set -eu
    dir={{dir}}
    # Tolerate `just test-dirvish dir=PATH' (just treats it as a
    # positional value that starts with `dir=', so strip the prefix).
    dir=${dir#dir=}
    dir=$(eval echo "$dir")
    [ -d "$dir" ] || { echo "ERROR: not a directory: $dir" >&2; exit 1; }
    dir=$(realpath "$dir")
    INIT_DIR=/tmp/kgfx-dirvish-init
    mkdir -p "$INIT_DIR"
    echo ">> Kitty terminal required.  Init dir: $INIT_DIR"
    echo ">> Auto-preview enabled: arrow over images / videos -- side window shows the thumbnail."
    echo ">> Manual full playback: M-x kitty-gfx-dired-play-video"
    exec env TERM={{TERM_}} {{EMACS}} -nw -Q \
        --init-directory "$INIT_DIR" \
        --eval "(progn \
                  (require 'package) \
                  (setq package-archives \
                        '((\"gnu\"   . \"https://elpa.gnu.org/packages/\") \
                          (\"melpa\" . \"https://melpa.org/packages/\"))) \
                  (package-initialize) \
                  (unless (package-installed-p 'dirvish) \
                    (package-refresh-contents) \
                    (package-install 'dirvish)))" \
        -L "$(pwd)" \
        -l "{{SRC}}" \
        --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
        --eval "(kitty-graphics-mode 1)" \
        --eval "(add-hook 'dired-mode-hook #'kitty-gfx-dired-auto-preview-mode)" \
        --eval "(require 'dirvish)" \
        --eval "(dirvish-override-dired-mode 1)" \
        --eval "(dirvish \"$dir\")"

# TEMP: dirvish + kitty-gfx loaded against the user's REAL ~/.emacs.d
# config (config.org) instead of the throwaway init dir.  Useful for
# iterating on the kitty-media dispatcher without restarting the
# main Emacs.  Forces the local kitty-graphics.el over the elpaca build
# via -L + (load ...) so edits in this repo take effect immediately.
#   just test-dirvish-myconfig                  # default: open ~/
#   just test-dirvish-myconfig dir=/path        # open given folder
test-dirvish-myconfig dir="~":
    #!/usr/bin/env bash
    set -eu
    dir={{dir}}
    dir=${dir#dir=}
    dir=$(eval echo "$dir")
    [ -d "$dir" ] || { echo "ERROR: not a directory: $dir" >&2; exit 1; }
    dir=$(realpath "$dir")
    echo ">> Loading ~/.emacs.d/config.org (your real config)."
    echo ">> Local $(pwd)/{{SRC}} overrides the elpaca build."
    exec env TERM={{TERM_}} {{EMACS}} -nw \
        -L "$(pwd)" \
        --eval "(load \"$(pwd)/{{SRC}}\")" \
        --eval "(setq kitty-gfx-debug t)" \
        --eval "(dirvish \"$dir\")"

# Test inline mpv video playback (Kitty terminal only, requires mpv).
# Opens terminal Emacs with video integration enabled, then auto-plays
# the file given as positional arg (or drops into scratch buffer when
# omitted, ready for `M-x kitty-gfx-play-video').
#   just test-mpv                       # manual: M-x kitty-gfx-play-video
#   just test-mpv ~/Untitled.mp4        # auto-play (tilde expanded)
test-mpv video="":
    #!/usr/bin/env bash
    set -eu
    echo ">> Requires Kitty terminal + mpv on PATH."
    echo ">> Stop: M-x kitty-gfx-stop-video     Pause: M-x kitty-gfx-toggle-video"
    video={{video}}
    # Tolerate `just test-mpv video=PATH' (just treats it as a positional
    # value that happens to start with `video=', so strip the prefix).
    video=${video#video=}
    # Expand ~ and resolve relative paths so Emacs gets an absolute path.
    if [ -n "$video" ]; then
        video=$(eval echo "$video")
        if [ ! -f "$video" ]; then
            echo "ERROR: file not found: $video" >&2
            exit 1
        fi
        video=$(realpath "$video")
    fi
    exec env TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
        --eval "(kitty-graphics-mode 1)" \
        --eval "(when (> (length \"$video\") 0) (kitty-gfx-play-video \"$video\"))"

# Launch terminal Emacs with the inline casty browser (Kitty only).
# casty is auto-resolved to ../casty/bin/casty.js; a Chromium-based browser
# (Helium, Chromium, Chrome) is auto-detected on PATH.  Override either with
# KGFX_CASTY=/path/to/casty and CASTY_CHROME=/path/to/browser.
#   just test-browser                                   # opens example.com
#   just test-browser url=https://news.ycombinator.com
test-browser url="https://example.com":
    #!/usr/bin/env bash
    set -eu
    echo ">> Requires the Kitty terminal."
    echo ">> Navigate: j/k scroll  C-f/C-b page  H/L back/forward  r reload  o open  q quit"
    url={{url}}
    url=${url#url=}
    # Resolve the casty launcher: env override, else the sibling repo, else PATH.
    casty="${KGFX_CASTY:-{{justfile_directory()}}/../casty/bin/casty.js}"
    if [ ! -x "$casty" ]; then
        command -v casty >/dev/null && casty=casty || {
            echo "ERROR: casty not found at $casty (set KGFX_CASTY=/path/to/casty)" >&2; exit 1; }
    fi
    # Reuse an installed Chromium-based browser so casty skips the download.
    chrome="${CASTY_CHROME:-}"
    if [ -z "$chrome" ]; then
        for c in helium-browser chromium chromium-browser google-chrome-stable google-chrome; do
            p=$(command -v "$c" 2>/dev/null) && { chrome="$p"; break; }
        done
    fi
    echo ">> casty:  $casty"
    echo ">> chrome: ${chrome:-<casty default / auto-install Chrome Headless Shell>}"
    exec env TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(setq kitty-gfx-debug t kitty-gfx-enable-browser t)" \
        --eval "(setq kitty-gfx-casty-program \"$casty\")" \
        --eval "(when (> (length \"$chrome\") 0) (setq kitty-gfx-casty-chrome \"$chrome\"))" \
        --eval "(kitty-graphics-mode 1)" \
        --eval "(kitty-gfx-browse \"$url\")"

# --- Headless typst checks --------------------------------------------------

# Compile a typst fragment headlessly, print the PNG path
typst-render fragment="$x^2 + y^2 = z^2$":
    {{EMACS}} -Q -batch -L . -l {{SRC}} --eval '(progn \
        (setq kitty-gfx-debug t) \
        (let ((png (kitty-gfx--typst-render "{{fragment}}"))) \
          (princ (format "png=%s exists=%s\n" png (and png (file-exists-p png))))))'

# Render fragment and open PNG with xdg-open
typst-show fragment="$integral_(-oo)^(+oo) e^(-x^2) dif x = sqrt(pi)$":
    @png=$({{EMACS}} -Q -batch -L . -l {{SRC}} --eval '(princ (kitty-gfx--typst-render "{{fragment}}"))' 2>/dev/null); \
        echo "png=$png"; \
        [ -n "$png" ] && xdg-open "$png"

# --- Headless sixel checks --------------------------------------------------

# Show resolved sixel encoder (auto-detect: img2sixel > magick > convert)
sixel-encoder:
    {{EMACS}} -Q -batch -L . -l {{SRC}} --eval '(princ (format "%S\n" (kitty-gfx--sixel-resolve-encoder)))'

# Encode tests/test-image.png to sixel headlessly, report payload size.
# Override encoder with: just sixel-encode "img2sixel"
sixel-encode encoder="":
    {{EMACS}} -Q -batch -L . -l {{SRC}} --eval '(progn \
        (setq kitty-gfx-debug t) \
        (when (> (length "{{encoder}}") 0) \
          (setq kitty-gfx-sixel-encoder-program "{{encoder}}")) \
        (princ (format "encoder=%S\n" (kitty-gfx--sixel-resolve-encoder))) \
        (let ((d (kitty-gfx--sixel-encode "tests/test-image.png" 20 10))) \
          (princ (format "bytes=%s\n" (and d (length d))))))'
    @echo "--- log tail ---"
    @tail -3 /tmp/kitty-gfx.log 2>/dev/null || true

# Verify timeout watchdog kills a hung encoder within `kitty-gfx-sixel-encoder-timeout'
sixel-timeout-test:
    @printf '#!/usr/bin/env bash\nsleep 60\n' > /tmp/kgfx-fake-encoder.sh
    @chmod +x /tmp/kgfx-fake-encoder.sh
    time {{EMACS}} -Q -batch -L . -l {{SRC}} --eval '(progn \
        (setq kitty-gfx-debug t \
              kitty-gfx-sixel-encoder-program "/tmp/kgfx-fake-encoder.sh" \
              kitty-gfx-sixel-encoder-timeout 1.0) \
        (with-temp-buffer \
          (set-buffer-multibyte nil) \
          (princ (format "ok=%S\n" (kitty-gfx--sixel-run-encoder \
                                    "/tmp/kgfx-fake-encoder.sh" 1.0 \
                                    (current-buffer) nil)))))'
    @echo "--- log tail ---"
    @tail -3 /tmp/kitty-gfx.log 2>/dev/null || true
    @rm -f /tmp/kgfx-fake-encoder.sh

# --- Interactive sixel tests (run inside a sixel-capable terminal) ----------

# Open test-image.png with sixel backend forced (foot/Konsole/mintty/WezTerm)
test-sixel-image encoder="":
    @echo ">> Run inside foot, Konsole, mintty, mlterm, or WezTerm."
    TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
        --eval "(setq kitty-gfx-debug t kitty-gfx-preferred-protocol 'sixel)" \
        --eval '(when (> (length "{{encoder}}") 0) (setq kitty-gfx-sixel-encoder-program "{{encoder}}"))' \
        --eval "(kitty-graphics-mode 1)" \
        tests/test-image.png

# Open test-image.png inside tmux with sixel backend forced.
# Outer terminal must be sixel-capable (foot, Konsole, mintty, mlterm, WezTerm).
# Requires tmux >= 3.4 built with --enable-sixel.
# When already inside tmux, runs emacs directly (no nesting).
test-sixel-tmux encoder="":
    #!/usr/bin/env bash
    set -eu
    if [ -n "${TMUX:-}" ]; then
        echo ">> Already inside tmux -- running emacs directly in this pane."
        exec env TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
            --eval '(setq kitty-gfx-debug t kitty-gfx-preferred-protocol (quote sixel))' \
            --eval '(when (> (length "{{encoder}}") 0) (setq kitty-gfx-sixel-encoder-program "{{encoder}}"))' \
            --eval '(kitty-graphics-mode 1)' \
            tests/test-image.png
    else
        echo ">> Outer terminal must be sixel-capable; spawning fresh tmux session."
        exec tmux new-session -As kgfx-sixel-test \
            "TERM={{TERM_}} {{EMACS}} -nw -Q -l {{SRC}} \
                --eval '(setq kitty-gfx-debug t kitty-gfx-preferred-protocol (quote sixel))' \
                --eval '(when (> (length \"{{encoder}}\") 0) (setq kitty-gfx-sixel-encoder-program \"{{encoder}}\"))' \
                --eval '(kitty-graphics-mode 1)' tests/test-image.png"
    fi

# --- Logs -------------------------------------------------------------------

# Tail the kitty-gfx debug log (set kitty-gfx-debug to t to populate)
log:
    tail -f /tmp/kitty-gfx.log
