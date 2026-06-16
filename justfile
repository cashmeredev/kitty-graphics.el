# kitty-graphics.el -- developer task runner
#
# Requires: just, emacs, typst (for typst tests), imagemagick (for sixel).
# Run `just` to list recipes.

set shell := ["bash", "-cu"]

export KITTY_GFX_DEBUG := "1"

# Interactive tests load YOUR ~/.emacs.d by default (the local kitty-graphics.el
# is loaded after init and overrides any installed copy).  Set KGFX_VANILLA=1
# for the old isolated `-Q` behaviour when bisecting config interference.
QFLAG  := if env_var_or_default("KGFX_VANILLA", "0") == "1" { "-Q" } else { "" }

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

# Batch self-tests + dry-run heading rendering scenarios
test-batch:
    {{EMACS}} -Q -batch -l {{SRC}} --eval "(kitty-gfx-run-self-tests)"
    {{EMACS}} -Q -batch -l {{SRC}} -l tests/test-heading-scenarios.el

# Remove generated artifacts
clean:
    rm -f {{SRC}}c
    rm -rf /tmp/kitty-gfx-typst /tmp/kitty-gfx-sixel-*.six /tmp/kitty-gfx.log

# --- Interactive tests (open terminal Emacs) --------------------------------

# Test typst inline equations (M-x kitty-gfx-typst-preview after open)
test-typst:
    @echo ">> M-x kitty-gfx-typst-preview     to render"
    @echo ">> M-x kitty-gfx-typst-clear-preview to clear"
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        --eval "(setq kitty-gfx-debug t)" \
        tests/test-typst.typ

# Test org-mode inline images -- C-c C-x C-v after open
test-org:
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        tests/test-kitty-gfx.org

# Test text sizing protocol (OSC 66) on org headings
test-headings file="tests/test-kitty-gfx.org":
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(setq kitty-gfx-heading-sizes-auto t)" \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        {{file}}

# Test image-mode rendering
test-image:
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        tests/test-image.png

# Test doc-view / PDF rendering
test-pdf:
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        tests/test-document.pdf

# Test markdown-overlays integration
test-markdown:
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        tests/test-markdown.md

# Test shr image scaling in eww (kitty-gfx-shr-scale 'fit); pass a different url=...
test-shr url="https://en.wikipedia.org/wiki/Cat":
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(setq kitty-gfx-shr-scale 'fit)" \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        --eval "(eww \"{{url}}\")"

# Test LaTeX fragment preview in org-mode (C-c C-x C-l on a fragment)
test-latex:
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        tests/test-kitty-gfx.org

# One-shot daemon test.  Starts an ISOLATED daemon on socket `kgfx-test'
# (your real daemon is untouched) with the LOCAL kitty-graphics.el, connects
# a client IN THIS TERMINAL, and stops the daemon when the client exits.
# Just type `M-x kill-emacs' (or close the client) and everything shuts down.
# Reuses an already-running kgfx-test daemon, so a SECOND terminal running
# `just test-daemon' attaches a second client for multi-tty testing.
#   just test-daemon                            # opens tests/test-kitty-gfx.org
#   just test-daemon file=tests/test-image.png  # open a different file
#   just test-daemon browser=1                  # also enable the casty browser
test-daemon file="tests/test-kitty-gfx.org" browser="0":
    #!/usr/bin/env bash
    set -u
    SOCK=kgfx-test
    file={{file}}; file=${file#file=}
    browser={{browser}}; browser=${browser#browser=}
    enable_browser=$([ "$browser" = "1" ] && echo t || echo nil)
    # Start the daemon only if it is not already up (so a 2nd terminal just attaches).
    if ! emacsclient -s "$SOCK" -e t >/dev/null 2>&1; then
        echo ">> starting daemon '$SOCK' (local {{SRC}}, debug log: just log)"
        {{EMACS}} -Q --daemon=$SOCK \
            -L "$(pwd)" -l "{{SRC}}" \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t kitty-gfx-enable-browser $enable_browser)" \
            --eval "(add-hook 'server-after-make-frame-hook (lambda () (when (and (not kitty-graphics-mode) (not (display-graphic-p))) (kitty-graphics-mode 1))))"
        STARTED=1
    else
        echo ">> attaching to running daemon '$SOCK'"
        STARTED=0
    fi
    echo ">> M-x kill-emacs stops the daemon AND the client."
    TERM=xterm-256color emacsclient -s "$SOCK" -t "$file" || true
    # Only the invocation that STARTED the daemon tears it down on exit, so a
    # second terminal that merely attached can detach (C-x C-c) without
    # killing the daemon — handy for the lifecycle test.
    if [ "$STARTED" = "1" ]; then
        emacsclient -s "$SOCK" -e '(kill-emacs)' >/dev/null 2>&1 || true
        pkill -f "emacs.*--daemon=$SOCK" 2>/dev/null || true
        echo ">> daemon '$SOCK' stopped."
    else
        echo ">> detached (daemon '$SOCK' left running for the first client)."
    fi

# Stop the isolated test daemon (only needed if a client was detached with
# C-x C-c instead of M-x kill-emacs, leaving the daemon running).
test-daemon-kill:
    -emacsclient -s kgfx-test -e '(kill-emacs)' >/dev/null 2>&1
    -pkill -f "emacs.*--daemon=kgfx-test" 2>/dev/null
    @echo ">> kgfx-test daemon stopped."

# Inline mpv video playback THROUGH the isolated test daemon (socket
# `kgfx-test').  Starts the daemon if needed (local kitty-graphics.el, video
# enabled), attaches a client IN THIS TERMINAL, and auto-plays the video once
# the client frame is up.  Reuses an already-running kgfx-test daemon, so a
# SECOND terminal running this attaches a second client for multi-tty playback.
#   just test-daemon-mpv                       # plays tests/casty-demo.mp4
#   just test-daemon-mpv video=~/clip.mp4      # tilde expanded
test-daemon-mpv video="tests/casty-demo.mp4":
    #!/usr/bin/env bash
    set -u
    SOCK=kgfx-test
    video={{video}}; video=${video#video=}
    video=$(eval echo "$video")
    [ -f "$video" ] || { echo "ERROR: file not found: $video" >&2; exit 1; }
    video=$(realpath "$video")
    if ! emacsclient -s "$SOCK" -e t >/dev/null 2>&1; then
        echo ">> starting daemon '$SOCK' (local {{SRC}}, debug log: just log)"
        {{EMACS}} -Q --daemon=$SOCK \
            -L "$(pwd)" -l "{{SRC}}" \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t kitty-gfx-enable-browser t)" \
            --eval "(add-hook 'server-after-make-frame-hook (lambda () (when (and (not kitty-graphics-mode) (not (display-graphic-p))) (kitty-graphics-mode 1))))"
        STARTED=1
    else
        echo ">> attaching to running daemon '$SOCK'"
        STARTED=0
    fi
    echo ">> Stop: M-x kitty-gfx-stop-video   Pause: M-x kitty-gfx-toggle-video"
    echo ">> M-x kill-emacs stops the daemon AND the client."
    # Defer the play call by a tick so the client frame is fully up and the
    # server-after-make-frame-hook has detected the backend on this terminal.
    TERM=xterm-256color emacsclient -s "$SOCK" -t \
        --eval "(run-with-timer 0.5 nil (lambda () (unless kitty-graphics-mode (kitty-graphics-mode 1)) (kitty-gfx-play-video \"$video\")))" || true
    if [ "$STARTED" = "1" ]; then
        emacsclient -s "$SOCK" -e '(kill-emacs)' >/dev/null 2>&1 || true
        pkill -f "emacs.*--daemon=$SOCK" 2>/dev/null || true
        echo ">> daemon '$SOCK' stopped."
    else
        echo ">> detached (daemon '$SOCK' left running for the first client)."
    fi

# Inline casty browser THROUGH the isolated test daemon (socket `kgfx-test').
# Like test-daemon-mpv but opens the browser; casty is resolved from
# ../casty/bin/casty.js (override KGFX_CASTY) and a Chromium-based browser is
# auto-detected on PATH (override CASTY_CHROME).  A SECOND terminal running
# this attaches another client for multi-tty browsing.
#   just test-daemon-browser                                 # example.com
#   just test-daemon-browser url=https://news.ycombinator.com
test-daemon-browser url="https://example.com":
    #!/usr/bin/env bash
    set -u
    SOCK=kgfx-test
    url={{url}}; url=${url#url=}
    casty="${KGFX_CASTY:-{{justfile_directory()}}/../casty/bin/casty.js}"
    if [ ! -x "$casty" ]; then
        command -v casty >/dev/null && casty=casty || {
            echo "ERROR: casty not found at $casty (set KGFX_CASTY=/path/to/casty)" >&2; exit 1; }
    fi
    chrome="${CASTY_CHROME:-}"
    if [ -z "$chrome" ]; then
        for c in helium-browser chromium chromium-browser google-chrome-stable google-chrome; do
            p=$(command -v "$c" 2>/dev/null) && { chrome="$p"; break; }
        done
    fi
    echo ">> casty:  $casty"
    echo ">> chrome: ${chrome:-<casty default / auto-install Chrome Headless Shell>}"
    if ! emacsclient -s "$SOCK" -e t >/dev/null 2>&1; then
        echo ">> starting daemon '$SOCK' (local {{SRC}}, debug log: just log)"
        {{EMACS}} -Q --daemon=$SOCK \
            -L "$(pwd)" -l "{{SRC}}" \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t kitty-gfx-enable-browser t)" \
            --eval "(add-hook 'server-after-make-frame-hook (lambda () (when (and (not kitty-graphics-mode) (not (display-graphic-p))) (kitty-graphics-mode 1))))"
        STARTED=1
    else
        echo ">> attaching to running daemon '$SOCK'"
        STARTED=0
    fi
    # Point the daemon at the resolved casty/browser (covers the attach case,
    # where the daemon was started without these set).
    emacsclient -s "$SOCK" -e "(setq kitty-gfx-enable-browser t kitty-gfx-casty-program \"$casty\")" >/dev/null 2>&1 || true
    [ -n "$chrome" ] && emacsclient -s "$SOCK" -e "(setq kitty-gfx-casty-chrome \"$chrome\")" >/dev/null 2>&1 || true
    echo ">> Navigate: j/k scroll  C-f/C-b page  H/L back/forward  r reload  o open  q quit"
    echo ">> M-x kill-emacs stops the daemon AND the client."
    TERM=xterm-256color emacsclient -s "$SOCK" -t \
        --eval "(run-with-timer 0.5 nil (lambda () (unless kitty-graphics-mode (kitty-graphics-mode 1)) (kitty-gfx-browse \"$url\")))" || true
    if [ "$STARTED" = "1" ]; then
        emacsclient -s "$SOCK" -e '(kill-emacs)' >/dev/null 2>&1 || true
        pkill -f "emacs.*--daemon=$SOCK" 2>/dev/null || true
        echo ">> daemon '$SOCK' stopped."
    else
        echo ">> detached (daemon '$SOCK' left running for the first client)."
    fi

# Final integration test: boot a daemon with your REAL ~/.emacs.d config (elpaca
# etc.), then force the LOCAL kitty-graphics.el over the installed build and turn
# on video + the casty browser, and attach a client IN THIS TERMINAL.  Use to
# confirm the whole stack (browser/mpv/pdf) works inside your personal config.
# The local file is (re)loaded from the client frame hook, so it wins over the
# elpaca build regardless of elpaca's async load order.  Socket is `kgfx-myconfig'
# so it never collides with your real daemon.
#   just test-daemon-myconfig                              # opens an org file
#   just test-daemon-myconfig file=tests/test-document.pdf # then it is doc-view
#   then:  M-x kitty-gfx-browse   /   M-x kitty-gfx-play-video
test-daemon-myconfig file="tests/test-kitty-gfx.org":
    #!/usr/bin/env bash
    set -u
    SOCK=kgfx-myconfig
    file={{file}}; file=${file#file=}
    here="$(pwd)"
    casty="${KGFX_CASTY:-{{justfile_directory()}}/../casty/bin/casty.js}"
    [ -x "$casty" ] || casty=$(command -v casty || echo "$casty")
    chrome="${CASTY_CHROME:-}"
    if [ -z "$chrome" ]; then
        for c in helium-browser chromium chromium-browser google-chrome-stable google-chrome; do
            p=$(command -v "$c" 2>/dev/null) && { chrome="$p"; break; }
        done
    fi
    if ! emacsclient -s "$SOCK" -e t >/dev/null 2>&1; then
        echo ">> starting daemon '$SOCK' with YOUR ~/.emacs.d config + LOCAL {{SRC}}"
        echo ">> casty: $casty   chrome: ${chrome:-<auto>}"
        {{EMACS}} --daemon=$SOCK \
            --eval "(add-hook 'server-after-make-frame-hook (lambda () (unless (display-graphic-p) (load \"$here/{{SRC}}\") (setq kitty-gfx-debug t kitty-gfx-enable-video t kitty-gfx-enable-browser t kitty-gfx-casty-program \"$casty\") (when (> (length \"$chrome\") 0) (setq kitty-gfx-casty-chrome \"$chrome\")) (unless kitty-graphics-mode (kitty-graphics-mode 1)))) t)"
        STARTED=1
    else
        echo ">> attaching to running daemon '$SOCK'"
        STARTED=0
    fi
    echo ">> M-x kitty-gfx-browse  /  M-x kitty-gfx-play-video  to test."
    echo ">> M-x kill-emacs stops the daemon AND the client; casty log: C-x b *kitty-casty-log*"
    TERM=xterm-256color emacsclient -s "$SOCK" -t "$file" || true
    if [ "$STARTED" = "1" ]; then
        emacsclient -s "$SOCK" -e '(kill-emacs)' >/dev/null 2>&1 || true
        pkill -f "emacs.*--daemon=$SOCK" 2>/dev/null || true
        echo ">> daemon '$SOCK' stopped."
    else
        echo ">> detached (daemon '$SOCK' left running for the first client)."
    fi

# Stop the personal-config integration-test daemon.
test-daemon-myconfig-kill:
    -emacsclient -s kgfx-myconfig -e '(kill-emacs)' >/dev/null 2>&1
    -pkill -f "emacs.*--daemon=kgfx-myconfig" 2>/dev/null
    @echo ">> kgfx-myconfig daemon stopped."

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
        exec env TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
            --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)"
    fi
    SESSION=kgfx
    SOCKET=/tmp/kgfx-tmux.sock
    # Fresh session every time so old options don't linger.
    tmux -S "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
    tmux -S "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 \
        env TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l "$(pwd)/{{SRC}}" \
            --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
            --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)"
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
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
        --eval "(add-hook 'dired-mode-hook #'kitty-gfx-dired-auto-preview-mode)" \
        --eval "(require 'dirvish)" \
        --eval "(dirvish-override-dired-mode 1)" \
        --eval "(dirvish \"$dir\")"

# TEMP: dirvish + kitty-gfx loaded against the user's REAL ~/.emacs.d
# config (config.org) instead of the throwaway init dir.  Useful for
# iterating on the kitty-media dispatcher without restarting the
# main Emacs.  Forces the local kitty-graphics.el over the elpaca build
# via `with-eval-after-load' so the repo copy is (re)loaded right after
# elpaca's build, winning regardless of elpaca's async load order.
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
        --eval "(with-eval-after-load 'kitty-graphics (load \"$(pwd)/{{SRC}}\") (setq kitty-gfx-debug t))" \
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
    echo ">> Sixel terminals work too (experimental) when mpv is built with libsixel (--vo=sixel)."
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
    exec env TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(setq kitty-gfx-debug t kitty-gfx-enable-video t)" \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
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
    exec env TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(setq kitty-gfx-debug t kitty-gfx-enable-browser t)" \
        --eval "(setq kitty-gfx-casty-program \"$casty\")" \
        --eval "(when (> (length \"$chrome\") 0) (setq kitty-gfx-casty-chrome \"$chrome\"))" \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
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
    TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
        --eval "(setq kitty-gfx-debug t kitty-gfx-preferred-protocol 'sixel)" \
        --eval '(when (> (length "{{encoder}}") 0) (setq kitty-gfx-sixel-encoder-program "{{encoder}}"))' \
        --eval "(when (bound-and-true-p kitty-graphics-mode) (kitty-graphics-mode -1))" --eval "(kitty-graphics-mode 1)" \
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
        exec env TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
            --eval '(setq kitty-gfx-debug t kitty-gfx-preferred-protocol (quote sixel))' \
            --eval '(when (> (length "{{encoder}}") 0) (setq kitty-gfx-sixel-encoder-program "{{encoder}}"))' \
            --eval '(kitty-graphics-mode 1)' \
            tests/test-image.png
    else
        echo ">> Outer terminal must be sixel-capable; spawning fresh tmux session."
        exec tmux new-session -As kgfx-sixel-test \
            "TERM={{TERM_}} {{EMACS}} -nw {{QFLAG}} -l {{SRC}} \
                --eval '(setq kitty-gfx-debug t kitty-gfx-preferred-protocol (quote sixel))' \
                --eval '(when (> (length \"{{encoder}}\") 0) (setq kitty-gfx-sixel-encoder-program \"{{encoder}}\"))' \
                --eval '(kitty-graphics-mode 1)' tests/test-image.png"
    fi

# --- SSH latency test (issue #19) -------------------------------------------

# Push source to a remote host and open it in terminal Emacs over SSH so you
# can feel the keystroke latency for real.  Defaults to `moneyspread`; pass
# any host:  `just test-ssh somehost`.  Emacs comes from `nix shell nixpkgs#emacs`
# on the remote (NixOS) — no system install needed.
#
# Profiler is pre-armed — once Emacs is open:
#   1. switch to *scratch*  (C-x b RET)
#   2. mash keys for ~10s
#   3. M-x profiler-report  — look for kitty-gfx--on-redisplay et al.
#   4. M-x profiler-stop
test-ssh host="moneyspread":
    #!/usr/bin/env bash
    set -eu
    REMOTE_DIR="/tmp/kitty-graphics-ssh-test"
    echo ">> rsync source + tests to {{host}}:$REMOTE_DIR"
    ssh {{host}} "mkdir -p $REMOTE_DIR/tests"
    rsync -az {{SRC}} {{host}}:$REMOTE_DIR/
    rsync -az tests/ {{host}}:$REMOTE_DIR/tests/
    echo ">> launching emacs via nix shell on {{host}} (TERM={{TERM_}})"
    echo ">> profiler is pre-armed; M-x profiler-report after typing test"
    ssh -t {{host}} "cd $REMOTE_DIR && nix shell nixpkgs#emacs nixpkgs#imagemagick nixpkgs#libsixel --command \
        env TERM={{TERM_}} TERM_PROGRAM=kitty KITTY_PID=ssh emacs -nw -Q \
        -l $REMOTE_DIR/{{SRC}} \
        --eval '(setq kitty-gfx-debug t kitty-gfx-preferred-protocol (quote kitty))' \
        --eval '(kitty-graphics-mode 1)' \
        --eval '(profiler-start (quote cpu))'"

# Same as test-ssh but baseline: checks out origin/master into a worktree,
# pushes THAT version to the remote.  Use to A/B against the fix branch.
test-ssh-baseline host="moneyspread":
    #!/usr/bin/env bash
    set -eu
    WT=$(mktemp -d /tmp/kgfx-baseline.XXXXXX)
    trap "git worktree remove --force $WT >/dev/null 2>&1 || true" EXIT
    git worktree add --detach $WT origin/master >/dev/null
    REMOTE_DIR="/tmp/kitty-graphics-ssh-baseline"
    echo ">> rsync ORIGIN/MASTER source to {{host}}:$REMOTE_DIR"
    ssh {{host}} "mkdir -p $REMOTE_DIR/tests"
    rsync -az $WT/{{SRC}} {{host}}:$REMOTE_DIR/
    rsync -az $WT/tests/ {{host}}:$REMOTE_DIR/tests/
    echo ">> launching emacs via nix shell on {{host}} with BASELINE code"
    ssh -t {{host}} "cd $REMOTE_DIR && nix shell nixpkgs#emacs nixpkgs#imagemagick nixpkgs#libsixel --command \
        env TERM={{TERM_}} TERM_PROGRAM=kitty KITTY_PID=ssh emacs -nw -Q \
        -l $REMOTE_DIR/{{SRC}} \
        --eval '(setq kitty-gfx-debug t kitty-gfx-preferred-protocol (quote kitty))' \
        --eval '(kitty-graphics-mode 1)' \
        --eval '(profiler-start (quote cpu))'"

# --- Logs -------------------------------------------------------------------

# Tail the kitty-gfx debug log (set kitty-gfx-debug to t to populate)
log:
    tail -f /tmp/kitty-gfx.log
