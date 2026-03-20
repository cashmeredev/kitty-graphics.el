# PLAN: Sixel Backend Expansion — terminal-graphics.el

## Meta
- **Date**: 2026-03-20
- **Mode**: SCOPE EXPANSION
- **Version**: 0.2.1 → 0.3.0
- **Estimated Effort**: 28-41 hours (~3-5 days)
- **LOC Delta**: +300-400 lines (1948 → ~2300)
- **Risk**: MEDIUM (terminal quirks)
- **Confidence**: HIGH (clean abstraction perimeter)

---

## Motivation

kitty-graphics.el is the first-ever native Emacs Lisp package for terminal
image display. Currently supports Kitty/WezTerm/Ghostty (~3 terminals).
Sixel support unlocks ~20 additional terminals including foot, Konsole,
xterm, mlterm, mintty, VS Code Terminal, **and tmux**.

tmux is the killer use case — it's the only way to get images in tmux
from Emacs, since Kitty protocol doesn't work through tmux.

## Key Architecture Decisions

### 1. Backend Dispatch: Alist (Decision A)

A backend is an alist of functions:
```elisp
((prepare . kitty-gfx--kitty-prepare)
 (place   . kitty-gfx--kitty-place)
 (delete  . kitty-gfx--kitty-delete)
 (cleanup . kitty-gfx--kitty-cleanup))
```

`kitty-gfx--backends` is an alist of `(SYMBOL . BACKEND-ALIST)`.
`kitty-gfx--active-backend` holds the active key ('kitty or 'sixel).
Dispatch: `(funcall (alist-get 'place (alist-get backend kitty-gfx--backends)) ...)`

**Why**: ~2h more than if/else, but every future protocol (iTerm2, etc.)
is a 5-line alist entry instead of branches everywhere.

### 2. Sixel Cache: Temp-Files (Decision B)

Sixel-encoded data is stored in temp-files under `/tmp/kitty-gfx-sixel-*.six`.
Cache lookup: file-exists-p → insert-file-contents → send-string-to-terminal.

**Why**: Eliminates GC pressure from multi-100KB Emacs strings. Disk I/O
is negligible vs. the ImageMagick shell-out that already happens.
Cache-size can stay at 64 entries. Cleanup via kill-emacs-hook.

### 3. Refresh Strategy: Dirty-Flag (Decision A)

Sixel overlays are only re-emitted when `last-row`/`last-col` has changed
OR an explicit dirty flag is set (resize, buffer-switch). Standing images
on a static screen = zero cost.

**Why**: Minimal-invasive. One bool per overlay. The existing position
tracking provides the dirty signal for free.

### 4. Encoding: Synchronous with Debounce (Decision B)

Window resize triggers synchronous re-encode with 500ms debounce for
Sixel backend. User sees 1-2s freeze for 5+ visible images on resize.
Accepted tradeoff — resize is infrequent.

**Why**: Async encoding (make-process + sentinel) adds race conditions
and ~6h complexity for a rare interaction. Ship first, optimize if
anyone complains.

---

## Protocol Comparison

```
                   KITTY PROTOCOL                    SIXEL PROTOCOL
  Statefulness:    STATEFUL (transmit once,          STATELESS (emit all data
                    place many times)                  every time)
  Image Storage:   TERMINAL-SIDE                     CLIENT-SIDE (temp-files)
  Placement:       NAMED (PID) — atomic replace      ANONYMOUS — erase + re-emit
  Delete:          EXPLICIT (APC a=d)                 IMPLICIT (overwrite spaces)
  Encoding:        BASE64 PNG (lossless)              6-bit palette + RLE
  Wire Format:     APC (\e_G...\e\\)                  DCS (ESC P q ... ESC \)
  Max Colors:      Full RGBA (truecolor + alpha)      256 colors (no alpha)
```

---

## System Architecture — Target State

```
  ┌─────────────────────────────────────────────────────────────┐
  │                    INTEGRATION LAYER                         │
  │  org-mode │ image-mode │ shr │ doc-view │ dired │ eshell   │
  │  (20+ :around advice functions — ALL UNCHANGED)             │
  │           ALL call: kitty-gfx-display-image                 │
  └──────────────────────────┬──────────────────────────────────┘
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │                    ORCHESTRATION LAYER                       │
  │  kitty-gfx-display-image                                    │
  │    1. convert-to-png  (ImageMagick — shared)                │
  │    2. compute-cell-dims (shared)                            │
  │    3. DISPATCH to active backend:                           │
  │       (funcall (kitty-gfx--backend-fn 'prepare) ...)        │
  │    4. make-overlay (shared)                                 │
  │    5. schedule-refresh                                      │
  └──────────────────────────┬──────────────────────────────────┘
                             │
  ┌──────────────────────────▼──────────────────────────────────┐
  │                    BACKEND DISPATCH                          │
  │                                                             │
  │  kitty-gfx--active-backend ──▶ 'kitty / 'sixel             │
  │                                                             │
  │  ┌─────────────────┐    ┌──────────────────────────┐       │
  │  │  KITTY BACKEND   │    │  SIXEL BACKEND            │       │
  │  │                  │    │                           │       │
  │  │  prepare:        │    │  prepare:                 │       │
  │  │   transmit APC   │    │   png→sixel encode        │       │
  │  │   cache: id only │    │   cache: temp-file path   │       │
  │  │                  │    │                           │       │
  │  │  place:          │    │  place:                   │       │
  │  │   APC a=p (50B)  │    │   read tmpfile → DCS Pq   │       │
  │  │                  │    │   (50-500KB)              │       │
  │  │                  │    │                           │       │
  │  │  delete:         │    │  delete:                  │       │
  │  │   APC a=d (30B)  │    │   overwrite with spaces   │       │
  │  │                  │    │                           │       │
  │  │  cleanup:        │    │  cleanup:                 │       │
  │  │   delete-by-id   │    │   delete temp-files       │       │
  │  └─────────────────┘    └──────────────────────────┘       │
  └─────────────────────────────────────────────────────────────┘
```

---

## Protocol-Specific Functions — Refactor Map

Only 6 functions emit terminal-specific escape sequences today.
These become backend dispatch points:

| Current Function              | Backend Method | Kitty                | Sixel                     |
|-------------------------------|---------------|----------------------|---------------------------|
| `kitty-gfx--transmit-image`   | `prepare`     | APC a=t chunked      | magick → sixel tmpfile    |
| `kitty-gfx--place-image`      | `place`       | APC a=p (50 bytes)   | read tmpfile → DCS emit   |
| `kitty-gfx--delete-placement` | `delete`      | APC a=d,d=i          | overwrite with spaces     |
| `kitty-gfx--delete-by-id`     | `cleanup`     | APC a=d,d=I          | delete temp-file          |
| `kitty-gfx--delete-all-images`| `cleanup-all` | APC a=d,d=A          | delete all temp-files     |
| `kitty-gfx--supported-p`      | (detection)   | KITTY_PID/TERM check | DA1 query + env check     |

Everything else (~70% of codebase) is protocol-agnostic.

---

## Performance Model

```
  OPERATION                  | KITTY            | SIXEL              | RATIO
  ---------------------------|------------------|--------------------|--------
  First display (cold)       | ~200ms           | ~300ms             | 1.5x
  Placement (warm cache)     | ~0.1ms (50B)     | ~5-50ms (50-500KB) | 50-500x
  Refresh (no change)        | ~0ms (skip)      | ~0ms (dirty-flag)  | 1x
  Refresh (position change)  | ~0.1ms           | ~10-100ms          | 100-1000x
  Window resize (5 images)   | ~0.5ms           | ~1500ms            | 3000x
  Delete                     | ~0.1ms           | ~1-5ms             | 10-50x
```

Dirty-flag eliminates steady-state cost. Resize is debounced (500ms).

---

## Error & Rescue Registry

| Method                    | Error                 | Rescued | Action                | User Sees           |
|---------------------------|-----------------------|---------|-----------------------|---------------------|
| detect-protocol (DA1)     | timeout               | Y       | env-var fallback      | Transparent         |
| detect-protocol (DA1)     | parse-error           | Y       | env-var fallback      | Transparent         |
| sixel-encode              | missing ImageMagick   | Y       | user-error            | "Install ImageMagick"|
| sixel-encode              | process-error         | Y       | skip image, log       | Image missing       |
| sixel-encode              | empty output          | Y       | skip image, log       | Image missing       |
| sixel-place (DCS emit)    | io-error              | Y       | ignore-errors         | Image missing       |
| sixel-cache-put           | disk full             | Y       | condition-case        | Fallback in-memory  |
| backend-dispatch          | missing backend key   | Y       | error with message    | Clear error msg     |
| sixel-delete (erase)      | position stale        | PARTIAL | sync-begin/end        | Brief flicker       |

CRITICAL GAPS: 0

---

## Failure Modes Registry

| Codepath         | Failure Mode        | Rescued? | Test? | User Sees?  | Logged? |
|------------------|---------------------|----------|-------|-------------|---------|
| sixel-encode     | magick not found    | Y        | #2    | user-error  | Y       |
| sixel-encode     | corrupt PNG input   | Y        | —     | skip image  | Y       |
| sixel-encode     | huge output (>1MB)  | Y        | #16   | downscaled  | Y       |
| sixel-place      | terminal overflow   | PARTIAL  | #6    | slow/hang   | Y       |
| sixel-cache      | disk full           | Y        | —     | fallback    | Y       |
| detect-protocol  | DA1 timeout         | Y        | #5    | fallback    | Y       |
| detect-protocol  | terminal lies       | N        | —     | wrong proto | N       |
| refresh (sixel)  | rapid scroll 5 imgs | Y (flag) | #6    | skip re-emit| Y       |
| resize (sixel)   | 5 imgs re-encode    | Y (dbnc) | #7    | 1-2s freeze | Y       |

---

## Rollout Phases

### Phase 1: Backend Refactor (in-place)
- Introduce alist dispatch
- Extract existing Kitty code into 'kitty backend
- NO new functionality, only restructuring
- Byte-compile + load-test
- Commit: "refactor: extract protocol backend dispatch"

### Phase 2: Sixel Backend
- kitty-gfx--sixel-encode, -place, -delete, -cleanup
- Temp-file cache system
- Dirty-flag in refresh cycle
- Commit: "feat: add Sixel graphics protocol backend"

### Phase 3: Auto-Detection
- DA1 query + env-var fallback chain
- kitty-gfx-preferred-protocol defcustom ('auto / 'kitty / 'sixel)
- Commit: "feat: auto-detect terminal graphics protocol"

### Phase 4: Polish
- Repo rename: kitty-graphics → terminal-graphics.el
- README update
- Version bump: 0.3.0
- MELPA recipe submission

---

## Test Matrix

| # | What                          | Type   | Spec                                    |
|---|-------------------------------|--------|-----------------------------------------|
| 1 | Sixel encode happy path       | Manual | PNG in org-buffer, foot terminal        |
| 2 | Sixel encode failure          | Manual | Remove ImageMagick, attempt display     |
| 3 | Backend auto-detect Kitty     | Manual | In Kitty: mode on → backend = 'kitty   |
| 4 | Backend auto-detect Sixel     | Manual | In foot: mode on → backend = 'sixel    |
| 5 | Fallback when DA1 fails       | Manual | Set TERM_PROGRAM manually, block stdin  |
| 6 | Scroll performance (5 images) | Manual | Org file with 5 images, rapid scroll    |
| 7 | Window resize                 | Manual | Display image, C-x 3 split → re-encode |
| 8 | Cache hit                     | Manual | Toggle images off/on → faster 2nd time  |
| 9 | Cache cleanup on kill-emacs   | Manual | Exit Emacs, check /tmp → files gone     |
| 10| tmux + Sixel                  | Manual | tmux (--enable-sixel) + foot            |
| 11| Kitty regression              | Manual | Kitty: +/-/0 zoom still works           |
| 12| Sixel image-mode zoom         | Manual | foot: +/-/0 zoom → re-encodes          |
| 13| doc-view in Sixel             | Manual | foot: open PDF → pages render           |
| 14| shr/eww in Sixel              | Manual | foot: eww with images                   |
| 15| defcustom override            | Manual | Force 'sixel in Kitty → uses Sixel      |
| 16| Large image DoS protection    | Manual | 4K image → capped, no terminal hang     |

---

## NOT in Scope

| Item                         | Rationale                                        |
|------------------------------|--------------------------------------------------|
| iTerm2 Protocol Backend      | Trivial after Sixel (~2h), separate PR           |
| tmux Kitty Passthrough       | Separate feature, separate PR                    |
| Async Sixel Encoding         | Only if users complain about resize freeze       |
| OSC 66 Text Sizing Ship      | Already designed in AGENTS.md, separate feature  |
| GIF/Animation Support        | Out of scope for this iteration                  |
| In-Emacs Sixel Encoder       | Would eliminate ImageMagick dep, ~40h, not now   |
| comint-mime Integration      | Issue #5, separate feature                       |

---

## Delight Opportunities (post-ship)

1. **tmux Kitty passthrough** — DCS wrapper, ~1h after backend abstraction
2. **Auto-detect with modeline indicator** — `[K]` or `[S]` in lighter
3. **kitty-gfx-preferred-protocol defcustom** — user override for power users
4. **Sixel color palette size defcustom** — 256 vs 1024, speed vs quality
5. **iTerm2 backend** — ~2h, covers macOS iTerm2 users

---

## Naming Strategy

- Emacs symbol prefix: keep `kitty-gfx-` (breaking change otherwise)
- Repository name: rename `kitty-graphics` → `terminal-graphics.el`
- GitHub rename preserves all stars, forks, issues, redirects old URLs
- MELPA package name: `terminal-graphics` (or keep `kitty-graphics`)
- Explain in Commentary section why prefix differs from repo name

---

## GitHub Rename Notes

- Stars, forks, issues ALL preserved on rename
- Old URLs auto-redirect to new name
- git clone/fetch/push from old URL continues to work
- CAVEAT: "do not reuse the original name" — if you create a NEW repo
  called `kitty-graphics` after renaming, redirects break
- Recommendation: simple rename, no new-repo trick needed
