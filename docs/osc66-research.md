# OSC 66 Text Sizing — Research Notes

## User Observations (v0.4.0-dev, 2026-03-29)

### What works
- Heading rendering at scale: ✅ (2x, 1.5x, 1.2x all working)
- Protocol detection (CPR-based): ✅ (`KittyGfx[K+T]` modeline)
- Folding (TAB/S-TAB): ✅ works
- Color extraction from org-level faces: ✅

### Known issues
- **Scroll artifacts**: small visual artifacts when scrolling
- **Heading horizontal drift**: headings shift left/right during
  scroll — likely a column calculation issue in `posn-at-point`
  or the cursor positioning escape (`\e[row;colH`)

---

## Existing Implementations (Deep Dive)

### 1. mdfried — Terminal Markdown Viewer (Rust + ratatui)
- **URL**: https://github.com/benjajaja/mdfried
- **Status**: Most mature real-world OSC 66 consumer (v0.12.0+)
- **Language**: Rust

#### Architecture
Two rendering paths for headings:
1. **With OSC 66**: Direct escape sequences via `BigText` widget
2. **Without OSC 66**: Falls back to rendering heading text into
   images via `cosmic-text` font shaping, displayed via Kitty/Sixel

#### The Erase-Character Dance (KEY FINDING)
Before emitting OSC 66, mdfried **erases the target area** using ECH:
```
\x1b[{width}X\x1B[?7l    -- erase current line + disable DECAWM
\x1b[1B                   -- move down 1 row
\x1b[{width}X\x1B[?7l    -- erase next line
\x1b[1A                   -- move back up
```
This prevents ghost artifacts. Uses ECH (`\x1b[NX`) which is more
efficient than writing spaces. **We should consider adopting this
for `kitty-gfx--erase-heading`.**

#### Fractional Scaling for Size Tiers (KEY FINDING)
All tiers use `s=2` as base, then `n:d` for fine-grained sizing:
```
Tier 1: s=2, n=7, d=7  (full 2x)
Tier 2: s=2, n=5, d=6
Tier 3: s=2, n=3, d=4
Tier 4: s=2, n=2, d=3
Tier 5: s=2, n=3, d=5
Tier 6: s=2, n=1, d=3
```
Gives 6 distinct sizes that are smoother than integer `s=` alone.
All headings occupy exactly 2 terminal rows regardless of tier.

#### Unicode Chunking (BUG FIX v0.18.1)
Wide characters (emoji, CJK) in headings broke rendering.
Fix: emit each wide character in its own OSC 66 escape sequence.
Width for partial chunks: `(chunk_width * n).div_ceil(d)` — round up.
Comment in code says uncertain if Kitty bug or expected behavior.

#### Ratatui Buffer Integration
Puts entire escape sequence in a single cell, marks all other
cells as "skip". **Equivalent to our overlay `display` property
approach** — first cell gets the payload, rest is reserved space.

#### Bug History
- v0.12.0: Initial text sizing
- v0.15.0: "All tiers above #1 had letter spacing too wide"
  (wrong `w` calculation for partial chunks)
- v0.18.1: Emoji/wide grapheme rendering bugs (unicode_chunks fix)

### 2. neovim/neovim#32539 — Variable Font Sizes
- **URL**: https://github.com/neovim/neovim/issues/32539
- **Status**: Open, labeled `gsoc`. No implementation.

#### justinmk (Neovim core):
Variable line-height is feasible, could allow markdown headings
at different heights. 54 hearts on this comment — massive demand.

#### fredizzimo's Architecture Analysis (KEY FINDING)
Identified fundamental challenges for any terminal editor:
1. **j/k navigation**: scaled text breaks column mapping
2. **Line height**: UI must tell editor the rendered height
3. **Variable-width fonts**: UI must handle wrapping
4. **Grid protocol**: can't send more cols/rows than grid allows

His proposed approach (matches ours exactly):
- Variable text is non-navigable (like virtual text / our overlays)
- Plugin switches to normal rendering when cursor is on those lines
- UI tells box height/width before drawing (avoid flicker)
- Text attached to buffer with extmarks, space reserved with vtext

#### algmyr's Use Case
LSP inlay hints at smaller font — makes them visually distinct
AND saves horizontal space. 20 thumbs up.

#### CWood-sdf's Rendering Approaches
1. Uniform row height: entire line height = tallest char (simpler)
2. Push-aside: large chars push aside text below (drop-cap style)

### 3. render-markdown.nvim#560 — Figlet Headings Request
- **URL**: https://github.com/MeanderingProgrammer/render-markdown.nvim/issues/560
- **Status**: Closed, deferred to OSC 66

MeanderingProgrammer (owner): waiting for kitty text sizing to
mature, get adoption, and get integrated in neovim first.

**Key insight**: Neovim ecosystem is blocked on core UI changes.
Emacs has advantage — `send-string-to-terminal` bypasses framework.

### 4. opentui commit c246044 — TypeScript+Zig TUI Framework
- **URL**: https://github.com/melMass/opentui/commit/c246044
- **Language**: TypeScript + Zig
- **Status**: AI-generated implementation (Nov 2025)

#### Separator Convention (confirmed)
- Within parameter group: colon `:` (e.g., `s=2:n=1:d=2`)
- Between params and text: semicolon `;`
- Format: `\x1b]66;PARAMS;TEXT\x1b\\`

#### Terminator Choice
Uses `ESC \` (ST) not BEL — "seems safer". Our code uses BEL (`\a`).
Both are valid per spec. BEL is shorter (1 byte vs 2).

#### Performance Note
~10% terminal throughput overhead from multicell bookkeeping.
"Use text sizing judiciously."

### 5. foot!1927 — Width-Only OSC 66 Implementation
- **URL**: https://codeberg.org/dnkl/foot/pulls/1927
- **Language**: C (terminal emulator internals)
- **Status**: Merged Feb 2025

#### Scope
Width parameter (`w=`) only. No font scaling, no multi-line characters.
This is the `'width` tier our detection reports.

#### w=0 Semantics
Process each codepoint normally, as if printed directly to terminal.

#### w!=0 Semantics
Entire text string becomes a single combining character stored in
first cell, followed by SPACER cells. Treats "foobar" with `w=6`
as a single 6-column wide "character".

#### Variation Selector Bug (krobelus)
Splitting `⚠\ufe0f` across two OSC 66 sequences breaks rendering.
Fix: always emit codepoint + variation selector in same sequence.

#### Cursor on Multi-Width Characters
Foot doesn't render cursor in the middle of a forced-width character.
"Mostly doesn't make sense to place cursor on filler cell."

#### Minimum Terminal Width
Changed from 2 to 7 cells. Reflow logic breaks when a character
(via `w=`) is wider than the terminal itself.

#### Glyph Bleeding
When glyph is wider than allocated cells, pixels bleed into adjacent
cells. Visual-only, doesn't affect grid state.

---

## Actionable Findings for kitty-graphics.el

### HIGH PRIORITY

1. **Erase via ECH instead of spaces** (from mdfried)
   Our `kitty-gfx--erase-heading` writes spaces. ECH (`\x1b[NX`)
   is more efficient and what mdfried uses. Also consider disabling
   DECAWM during erase to prevent wrapping artifacts.

2. **Fractional scaling with s=2 base** (from mdfried)
   Instead of our current s=1/2/3 integer scales, use s=2 for ALL
   heading tiers with n:d ratios for fine-grained sizing. This means
   all headings are exactly 2 rows tall, simplifying space reservation.

3. **Unicode chunking for wide chars** (from mdfried v0.18.1)
   If heading text contains emoji or CJK, emit each wide character
   in its own OSC 66 sequence. We don't do this yet.

### MEDIUM PRIORITY

4. **Horizontal drift investigation**
   The heading left/right shift during scroll could be related to:
   - posn-at-point returning inconsistent col values
   - body-left offset not being stable across redraws
   - org-indent-mode or line-number-mode changing column offsets
   fredizzimo's analysis confirms this is a fundamental challenge.

5. **Pre-erase before OSC 66 emission** (from mdfried)
   mdfried erases BEFORE emitting, not just when moving. We could
   adopt this pattern in `kitty-gfx--place-heading`: erase area first,
   then emit OSC 66. Prevents artifacts from partial overwrites.

### LOW PRIORITY

6. **ST vs BEL terminator**
   Our code uses BEL (`\a`). Both valid. Consider ST (`\x1b\\`) for
   consistency with other implementations, but BEL is 1 byte shorter.

7. **w= parameter for heading text**
   We currently use `w=0` (auto). This is fine for ASCII headings.
   If we want exact column control (which could fix the drift), we
   could calculate and emit explicit `w=` per character/chunk.

---

## Terminal Support Matrix

| Terminal | Width (w=) | Scale (s=) | Fractional (n:d) | Notes |
|----------|-----------|-----------|-----------------|-------|
| Kitty ≥0.40.0 | ✅ | ✅ | ✅ | Full support |
| Foot | ✅ | ❌ | ❌ | Width only (merged Feb 2025) |
| Ghostty | 🔄 | ❌ | ❌ | Parsing added, rendering WIP |
| tmux | ❌ | ❌ | ❌ | Breaks OSC 66 entirely |
| WezTerm | ❌ | ❌ | ❌ | No support |
| Neovide | ❌ | ❌ | ❌ | Feature requested |

## Competitive Landscape

| Project | Type | OSC 66 | Scroll Strategy |
|---------|------|--------|----------------|
| **kitty-graphics.el** | Editor overlay | ✅ | Two-phase re-emission |
| mdfried | Full-screen TUI | ✅ | Full redraw per frame |
| presenterm | Full-screen TUI | ✅ | Full redraw per frame |
| opentui | TUI framework | ✅ | Double-buffered |
| libvaxis | TUI framework | w= only | Double-buffered |
| render-markdown.nvim | Neovim plugin | ❌ | Blocked on neovim core |
| Neovim core | Editor | ❌ | GSoC project, no impl |

**We are the only editor-overlay implementation.** All others
are full-screen TUIs that own the viewport, or are waiting
for framework support.
