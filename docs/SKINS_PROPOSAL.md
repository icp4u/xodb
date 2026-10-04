# Skins and look and feel sketch

Startup semantic colors and presets are now implemented; see
[the theme workflow](THEMES.md). Theme files load only at startup; the reload
interfaces in this older sketch are not adopted. The remaining skin, typography,
layout and plugin interfaces below remain proposals.

2026-10-02. Discussion proposal for review, alongside the
[Lua plugin sketch](LUA_PLUGIN_PROPOSAL.md). The configuration keys and interfaces
below are illustrative and **not implemented or adopted**. Current binaries
reject these new preferences fields.

Make the existing appearance a built-in preset, then let users change colors,
control styling, fonts, density and pane arrangements independently. Ordinary
skins should be data files that work without Lua. A plugin can contribute the
same data and add native panels that follow the user's chosen appearance.

## What users can customize

| Part | Owns | Examples |
| --- | --- | --- |
| Theme | Semantic colors and categorical palettes | Dark, light, high contrast, personal accent; breakpoint and selected-line colors |
| Skin | Control treatment and base spacing | Square or pill buttons, border widths, corner radii, shadows, row striping, focus treatment |
| Appearance preferences | Personal sizing and motion overrides | UI/code fonts and sizes, compact rows, UI scale, reduced motion |
| Input preferences | Interaction choices, configured separately | Scroll amount, tooltip delay, eventually command bindings |
| Layout | Pane placement and visibility | Source-heavy debugging, assembly/registers, flames/timeline, saved pane splits and tabs |

A shared skin supplies a visual preset. The user's input bindings, stepping
policy, capture settings and automation scope remain independently configured.
For example, a square skin with a light palette and larger code text should be a
normal combination. Changing skins must preserve current frame/thread selection,
watch expressions and profile filters.

## Example user configuration

Extend the existing explicitly loaded JSON preferences selected by
`--config FILE`. A proposed configuration could look like this:

```json
{
  "appearance": {
    "version": 1,
    "skin": "./skins/flat/skin.json",
    "theme": "./themes/ember.json",
    "density": "compact",
    "scale": 1.0,
    "fonts": {
      "ui": { "size": 15 },
      "code": { "size": 16 }
    },
    "motion": { "reduce": true }
  },
  "input": {
    "scroll_lines": 3,
    "tooltip_delay_ms": 500
  },
  "layout": {
    "version": 1,
    "preset": "debug",
    "splits": { "editor": 0.60, "profile": 0.70 }
  }
}
```

Font sizes and skin dimensions use logical UI units; `scale` is a user zoom
multiplier. Output scaling is a separate platform concern. Font entries may also
specify a `file`; omission uses the application's default font file. Keep
`--font FILE` as an explicit override for both roles. Start with file paths before
adding font-family discovery. Code text needs predictable column alignment.

Here, `editor` is the source share of the source/assembly area; `profile` is the
flame share above the timeline. Ratios apply to the available content area after
headers and separators. Layouts enforce minimum pane sizes and keep controls
reachable at small window sizes. The example illustrates a later phase too;
font sizing and general layout customization need more work than palette loading.

## A theme file

Themes expose named roles instead of pane-specific RGB literals:

```json
{
  "version": 1,
  "id": "user.ember",
  "base": "builtin:dark",
  "colors": {
    "background": "#121316",
    "surface": "#1A1C21",
    "text": "#E2E4E9",
    "text_muted": "#A0A6B2",
    "focus": "#E9AA68",
    "selection": "#E9AA6833",
    "breakpoint": "#F07878",
    "state_stopped": "#EDC477",
    "state_running": "#8ECCAA"
  },
  "palettes": {
    "threads": ["#E9AA68", "#70C8D0", "#BCA0E8", "#E992BA"]
  }
}
```

Allow `#RRGGBB` and `#RRGGBBAA` in sRGB notation, with renderer conversion handled
centrally. The built-in base supplies omitted roles. Initially bases must be
built-in themes, avoiding inheritance chains and cycles.

The complete vocabulary also needs headers, borders, selected text, hover,
pressed/disabled controls, errors/warnings, changed values, current instruction,
stale/unavailable evidence, and incomplete captures. Flame colors get a separate
palette; selection and missing-stack markers retain semantic roles. Thread and
frame identities determine palette indices consistently across panes. Colors do
not change sample weights, grouping or evidence labels.

Include readable light and high-contrast presets as coverage targets. A preview
should show actual debugger states, focus, selection and unavailable data, with
contrast diagnostics. State also needs text or a marker: a palette cannot make
stale data current, remove capture-loss indicators or erase the running/stopped
label. Reduced motion keeps the final state indicators visible.

## A skin file

A small skin can contain just one file:

```json
{
  "version": 1,
  "id": "user.flat",
  "theme": "builtin:dark",
  "controls": {
    "button_radius": 2,
    "panel_radius": 0,
    "border_width": 1,
    "shadows": false,
    "row_stripes": true
  },
  "metrics": {
    "row_padding_y": 3,
    "button_padding_x": 10,
    "pane_gap": 4
  }
}
```

These are a closed set of host-rendered treatments. The renderer already draws
rounded boxes, borders and shadows. Additional primitives can be added when a
concrete skin needs them. Existing font metrics determine row/control minima;
large text cannot be clipped by a small requested padding.

Later packages can include bounded font/icon resources and optional Lua panels.
Keep resource paths relative to their declaring file, with package resources
confined to their package. User-selected external files are explicit references.
A theme or skin never fetches assets or executes accompanying code on load.
User shaders, arbitrary drawing callbacks and CSS-style selectors can wait for a
specific need. They would substantially enlarge the implementation and API.

## Resolution, reload and persistence

Resolve each namespace deterministically:

1. Start with complete built-in defaults matching the current appearance.
2. Apply the selected skin's controls/metrics and recommended theme.
3. Apply an explicitly selected theme instead of the skin's recommendation.
4. Apply an explicitly selected density preset, then individual user appearance
   overrides. Density changes spacing; font sizes remain explicit.
5. Apply explicit CLI overrides, then any temporary preview edits.

Maps merge by known field; palette arrays replace in full. An omitted skin field
inherits its built-in value. `density: "skin"` uses the skin's spacing; `compact`
and `comfortable` select host-defined spacing presets. An inspector should show
where an effective setting came from. Relative paths stay anchored to the file
that declared them, even when configurations are combined.

Offer Reload, Preview, Apply, Revert, Reset and explicit Save/Export commands.
Applying changes affects the open GUI; saving writes only the chosen preferences
or layout destination. No automatic write-back or implicit project-file loading
in the first version. Export only data and portable references, with missing
resources identified. Persistence needs a complete-file replacement; no fsync
requirement, consistent with our durability preference.

Validate a complete candidate before applying it. Bound file/resource sizes,
reject unknown fields, unsupported versions, invalid colors, nonfinite dimensions
and invalid ratios, and report the filename plus field path. Startup can fall
back to the built-in appearance with a visible diagnostic; failed reload keeps
the last valid appearance. In a valid JSON document, a bad appearance section
should leave independently validated profile settings intact. Malformed JSON or
invalid profile settings still follow the existing configuration failure path.
Keep active preview data separate from the saved configuration.

Parsing/resource preparation runs outside drawing. Publish an immutable resolved
style at a frame boundary; swap fonts/atlases with safe GPU resource lifetimes.
A metrics change must recompute the geometry used for drawing, clipping, scrolling
and mouse hit tests together. Cancelling an active drag during that swap is safer
than applying an old drag offset to a new layout. Palette-only reload needs no
profile rebuild, target request or symbol reload. Invalidate the required frame,
then return to normal idle pacing; animations must have bounded lifetimes.

## Layout direction

Start with named presets for debugging, assembly and profiling, plus configurable
splits, pane visibility and column widths. The next step is a bounded tree of
horizontal/vertical splits and tab groups whose leaves are stable pane IDs such
as `source`, `assembly`, `threads`, `stack`, `locals`, `watches`, `flame` and
`timeline`. Plugin panes use namespaced IDs. Drag/drop docking edits that same data.

Save proportions and logical sizes independently of the current monitor. Layout
files do not contain target PIDs, live handles or stop generations. An unavailable
pane retains its slot with an explanation, so opening an offline capture or
unloading a plugin does not destroy the saved arrangement. Offer a reset-layout
command that stays accessible even with a bad arrangement. Multi-window docking
can follow after the single-window model is reliable.

Local, remote and imported/offline views should share appearance and layout
primitives, with available panes/actions determined by backend capabilities.
Remote appearance belongs to the desktop client; it requires no theme/font
uploads to Jetty or Android. A headless service accepts a shared configuration
without loading graphics assets and reports GUI operations as unavailable.

## Lua, MCP and agent touch surfaces

The [Lua proposal](LUA_PLUGIN_PROPOSAL.md) supplies the plugin registry and native
panel model. Data-only packages can register named themes/skins without a Lua
state. `theme.register` would accept the same validated representation. A plugin
may offer named layouts and publish tables/trees that inherit the user's fonts,
selection and spacing. Applying a preset requires an explicit UI action or UI
capability; registration alone does not change the active skin.

Expose native appearance commands through the same command registry used by Lua
and MCP: list presets, inspect effective settings, preview/apply, reset and export.
These commands belong to the GUI instance being customized; a connection to a
remote headless debugger cannot alter the desktop's preferences. UI permission is
separate from permission to observe or control a target. An agent's temporary
preview must not silently become a persistent setting.

Local or remote LLMs could propose a palette/layout from a description, explain
which override controls a setting, or inspect screenshots for clipping and poor
contrast. Their output should be ordinary validated config with a reviewable diff
and preview. Color conversion, contrast calculations and layout constraints stay
deterministic in the host. No embedded LLM is needed.

## Current findings and implementation touch points

| Current code | Finding and required change |
| --- | --- |
| `src/ui/style.zig` | Compile-time palette and hardcoded control effects; introduce an immutable runtime palette/controls/metrics object |
| `src/ui/workspace.zig`, `remote.zig`, `imported.zig` and their panes | Additional literal colors and fixed geometry; share resolved style and layout measurements across render/input |
| `src/render/font.zig` | One font face initialized at 16 pixels, bounded 1024-square atlas; add sizing/roles, measured line metrics and controlled atlas replacement |
| `src/render/vulkan.zig`, `ui.frag` | Existing shape machinery covers initial skins; centralize color handling and handle font/resource lifetimes |
| `src/platform/wayland.zig` | Explicit window dimensions/input coordinates; user zoom and output scaling need coordinated rendering/input work |
| `src/preferences.zig`, `src/main.zig` and remote startup | Strict, explicitly loaded JSON currently contains profile settings only; extend loading and route resolved appearance to every GUI entry path |
| Future plugin registry and native panels | Register resources by ID, inherit style and expose native appearance commands without Lua in drawing |

The local and remote toolbars already share some drawing/hit-test tables within
each view. They still use fixed coordinates and separate implementations; runtime
font changes need layout calculations across all affected controls. Existing
appearance attribution remains attached to the relevant source and notices.

## Delivery order and critical review

1. **Runtime colors:** current appearance as the default; explicit theme JSON,
   semantic colors across all GUI modes, reload with error retention. This can
   proceed independently of the Lua runtime.
2. **Useful skins:** square/rounded treatments, borders/shadows, compact spacing,
   reduced motion, measured controls and a small appearance preview. Verify every
   affected mouse target as metrics become configurable.
3. **Typography and layouts:** font sizes/roles, coordinated scaling, pane presets,
   saved splits/columns; then editable split/tab trees and docking.
4. **Extensions:** Lua-contributed panels/presets, MCP appearance commands and
   additional packaged assets as real uses emerge.

The immediate value is personalizing the debugger without a rebuild. The main
risk is treating this as a palette-only job: fonts and density expose hardcoded
geometry throughout separate local, remote and profile views. A setting that
changes drawing while leaving an old mouse rectangle is a correctness bug.
Verify small/wide windows, enlarged text, keyboard focus and breakpoint gutters,
and retain our hidden-window/idle responsiveness checks when changing animation
or resource lifetimes.

The scope risk is promising a full skin engine and docking editor before the
first useful customization ships. Keep the schema small and versioned, deliver
colors and a few control treatments first, and add fields when they have a working
consumer. Declarative data also gives agents a useful customization surface early.
The examples describe the direction; they do not require every knob in the first
implementation.
