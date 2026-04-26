// Test fixture for kitty-graphics.el typst inline equation preview.
//
// Usage:
//   TERM=xterm-256color emacs -nw -Q -l kitty-graphics.el \
//     --eval "(kitty-graphics-mode 1)" tests/test-typst.typ
//   M-x kitty-gfx-typst-preview
//   M-x kitty-gfx-typst-clear-preview
//
// Inline math fragments below should each be replaced by a rendered
// PNG overlay.  Escaped dollar signs (\$ ... \$) must be ignored.

= Inline samples

Pythagoras: $a^2 + b^2 = c^2$, classic.

Euler: $e^(i pi) + 1 = 0$ -- the famous identity.

Display style with surrounding spaces:
$ integral_(-oo)^(+oo) e^(-x^2) dif x = sqrt(pi) $

Mixed line: $x = 1$ and $y = 2$ on the same line.

Escaped dollar signs should be skipped: \$not math\$ here.

= Edge cases

Sum: $sum_(k=0)^n binom(n, k) = 2^n$.

Matrix: $mat(1, 2; 3, 4)$.

Greek: $alpha + beta = gamma$.
