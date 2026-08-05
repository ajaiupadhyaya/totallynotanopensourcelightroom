# Develop Grammar — The Interaction Layer

**Date:** 2026-08-05
**Status:** Approved design, awaiting implementation plan (sequenced **after** the Minilab engine sub-project, `2026-08-05-minilab-engine-design.md`)

## Problem

The app's design system is real and codified (Theme.swift's three laws, the numbered spine, the delta-from-neutral fader) — but it is deep-narrow. What separates the daily *feel* from Lightroom Classic's develop module is interaction grammar, not features: the judgment loop (zoom, before/after, histogram) and direct manipulation (edit the image by touching the image). Research on LR's develop module decomposes the "professional feel" into pillars, and this app already has two of them (achromatic chrome discipline; slider micro-interactions). This sub-project adds the missing ones.

## Goals

- Close the interaction-grammar gap: free zoom + navigator, split/side-by-side before-after, an interactive histogram, free-point curve with targeted adjustment, color wheels, preset hover-preview, scoped copy/paste, solo mode, lights-out.
- Everything drawn in the existing Theme language. The design system is the identity; nothing here changes it.

## Non-goals

- Library grid/collections/keywords (Phase 4). Soft proofing, mask-panel breadth (thumbnails/amount/rename), visualize-spots, auto-tone for positives, dual-window, tethering. FilmPanel's new engine controls (owned by the Minilab spec).

## Design

### Canvas: free zoom + navigator

- Scroll-wheel and pinch zoom, anchored at the pointer (zoom-to-point), continuous between 25% and 400%, with the existing four stops (Fit/50/100/200) as snap detents and unchanged keyboard/TabStrip/double-click behavior. Fit still never enlarges. The viewport-sized Metal drawable makes this a transform change, not a render-cost change; the existing zoom ≥ 100% full-res source trigger keys off effective scale.
- Zoom no longer resets pan to center when the change is gesture-driven (anchor math preserves the point under the pointer); stop-jumps keep today's center-reset.
- **Navigator**: a drawn floating card, bottom-left of the canvas, visible only when zoomed past Fit (and while hovering it): fit-view thumbnail, pan rectangle, click/drag to pan. Machined-edge chrome, achromatic, no shadow. It reuses the preview image — no extra render path.

### Before/after modes

- `\` stays: momentary full-canvas Before.
- **Y**: side-by-side (before left, after right, shared zoom/pan). **Shift+Y**: split-screen on one image with a draggable divider. Esc or repeat key exits. All transitions instant — no animation (motion law).
- Renders reuse the pipeline's ability to replay two stacks from one source; before = the unedited stack (or the film-converted base for negatives — the "before" of a negative is the positive conversion, matching today's `\` semantics).

### Interactive histogram

- The Inspector histogram gains five hover-highlighted regions — Blacks / Shadows / Exposure / Highlights / Whites — draggable left/right, wired to the Light panel's sliders; the slider visibly co-moves (single source of truth: the drag writes the same editStack field the slider does).
- Clipping triangles in the top corners light per-channel and toggle the existing clipping overlays on click (same state the ClippingDiagnostics toggles drive today; J stays the keyboard route).
- RGB% / Luma readout under the histogram while the cursor is over the canvas (the 2.0 reference-mock feature, finally built). Monospace, measured-value voice.

### Tone curve: free points + targeted adjustment

- Free point placement: click the curve to add a point, drag to shape, right-click to delete; Catmull-Rom interpolation retained; per-channel tabs retained; the four parametric region sliders retained beneath. Input/output readout while dragging (monospace).
- The 5-fixed-point storage becomes a variable-length point list with lenient decoding: absent → today's 5 points; existing photos unchanged. (Render-stage change is engine-adjacent; it ships behind the same lenient-decode discipline as everything else.)
- **Targeted Adjustment Tool (TAT)**: a tool-rail entry arming drag-on-the-image via the existing `CanvasPicker` pattern — vertical drag edits the curve at the luminance under the cursor (adds/moves a point). The same gesture serves the **Color Mixer**: with the mixer TAT armed, dragging on the image moves the hue-band sliders weighted by the actual colors under the cursor. Tool-switch side effects integrate through `WorkspaceModel.activate()` like every tool.

### Color grading wheels

- The Color Grade panel's three zones (+ a Global zone) become drawn hue/saturation wheels: puck at angle=hue, radius=saturation; luminance micro-slider beneath each; Blending and Balance sliders governing zone overlap. Option-drag = fine; double-click puck = reset. Values map onto the existing three-zone grading model (no render change) with Global as a new zone summed in the LUT builder.
- Drawn in Theme language: hairline ring, achromatic chrome, the wheel interior is the one place color legitimately appears (it is data — a color-selection surface).

### Presets

- Hover-preview on the real image: hovering a preset row renders the candidate stack to the canvas (debounced through the existing RenderScheduler; mouse-out reverts). Click applies (undoable).
- Amount slider scaling a preset's deltas from the current stack; folders (nested groups); import/export as JSON files sharing the EditStack coding.
- The stock naming alert is replaced by a drawn naming field (InstrumentField in a sheet) — removing the recorded design-language break.

### Slider unification

- `MiniContextFader` adopts `AdjustmentSlider`'s full behavior set (delta bar, scrubby readout, option-precision, keyboard, double-click reset) — one fader grammar everywhere.

### Workflow

- **Copy/Paste Settings scoping**: ⇧⌘C opens a drawn checkbox dialog organized by the numbered pipeline sections (01 Film … 14 Effects, plus Geometry/Masks), with All / None / Modified. Paste (⇧⌘V) applies the scoped set; targeting rules unchanged (selection-or-all-visible). **Previous** command applies the last-edited photo's (scoped-remembered) settings in one step.
- **Solo mode**: Option-click a section header opens it and closes the rest; the disclosure affordance changes state to say so; persisted like existing expansion state.
- **Lights-out**: L cycles two dim stages over all chrome (canvas untouched), Esc restores. Achromatic dimming only.
- Every new command lands in the menu bar with its shortcut (house rule); bare-key tool additions (TAT) go through ToolKeyMonitor, never SwiftUI keyboardShortcuts.

## Testing

- Conformance: new scalar controls (wheel values map to existing grading fields; curve points; preset amount) — covered by the completeness suite where they are EditStack fields.
- Unit: zoom anchor math (point-under-pointer invariance, detent snapping, clamping); curve point-list model (add/delete/sort/decode-fallback); copy/paste scoping (field-set algebra); preset amount scaling.
- The histogram-drag ↔ slider binding and TAT weighting get model-level tests (pure functions from gesture deltas to field writes).
- Interaction feel (gesture friction, navigator behavior, hover-preview latency) is verified in-app by the user — the same human-gate honesty as the engine's taste pass.

## Sequencing note

Engine first (its FilmPanel controls land in the panel this spec polishes around). Within this sub-project, the implementation plan should order: zoom/navigator + before-after + histogram (the judgment loop) → curve/TAT + wheels (editing depth) → presets + copy/paste + solo + lights-out (workflow).
