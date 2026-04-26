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

# Tail the kitty-gfx debug log (set kitty-gfx-debug to t to populate)
log:
    tail -f /tmp/kitty-gfx.log
