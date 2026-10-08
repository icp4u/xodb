# Startup themes

Choose colors without rebuilding xodb:

```sh
./zig-out/bin/xodb --theme builtin:light -- path/to/program
./zig-out/bin/xodb --theme builtin:contrast -- path/to/program
./zig-out/bin/xodb --theme config/themes/ember.json -- path/to/program
```

`builtin:dark` preserves the original palette and remains the default.
`builtin:light` and `builtin:contrast` include matching text, status, flame and
thread colors. State names, unavailable values, loss indicators, breakpoint
markers and evidence remain unchanged by theme selection.

The theme is loaded once during startup and applies to local, core,
saved-capture, imported-profile and remote GUI views. Successful loading is
silent. There are no theme hotkeys, popups, file watchers or live reload.
Restart xodb to apply edits or choose a different theme.

`xodb --overview` is the exception: it has its own palettes, which `t` cycles
(see [OVERVIEW.md](OVERVIEW.md)).

An invalid theme falls back to built-in dark with a diagnostic on stderr.
The bounded regular-file reader rejects FIFOs, devices, directories and
oversized files. Theme loading completes before the GUI starts.

## Preferences

An explicitly loaded preferences file can select the theme:

```json
{
  "appearance": { "theme": "themes/ember.json" },
  "profile": { "frequency_hz": 99 }
}
```

Theme file paths here are relative to the preferences file. A `--theme` argument
wins and resolves relative paths from the working directory. Built-in names
resolve without filesystem access. Both theme and preferences files are read
at startup.

An invalid theme file leaves valid profile/allocation settings intact. Invalid
preferences JSON, unknown preference keys or a malformed `appearance.theme`
value still fail configuration loading, like other malformed preferences.
There is no implicit project configuration, script execution or preference
write-back. A remote GUI loads themes on the desktop client. A headless service
accepts appearance settings but never opens the selected theme file.

## Theme format, version 1

```json
{
  "version": 1,
  "id": "user.ember",
  "base": "builtin:dark",
  "colors": {
    "background": "#121316",
    "surface": "#1A1C21",
    "text": "#E2E4E9",
    "weak": "#A0A6B2",
    "focus": "#E9AA68",
    "breakpoint": "#F07878"
  },
  "palettes": {
    "threads": ["#E9AA68", "#70C8D0", "#BCA0E8", "#E992BA"]
  }
}
```

Only `version` is required. The default base is `builtin:dark`; bases must be
one of the four built-in presets. File inheritance is unsupported. Optional
`id` is 1–64 printable ASCII characters without spaces. The file is limited to
64 KiB; duplicate/unknown keys, unsupported versions and invalid values are
rejected. Diagnostics identify the selected file and offending field.

Colors use `#RRGGBB` or `#RRGGBBAA`. Components map directly to the renderer's
existing normalized color channels; alpha keeps the existing blending behavior.
No new color-management or HDR behavior is implied. Omitted roles inherit from
the base. Custom palettes can have poor contrast; xodb does not silently rewrite
user colors. The built-in light and contrast palettes have text-contrast tests;
the original dark palette retains its existing appearance and contrast limits.

| Roles | Use |
| --- | --- |
| `background`, `surface`, `header`, `border` | Window, pane and control surfaces |
| `text`, `weak` | Primary and secondary labels |
| `good`, `neutral`, `warm` | Success/running, ordinary activity and warnings/stopped state |
| `focus`, `breakpoint` | Focus/selection overlays and breakpoint markers |
| `thread_main`, `thread_other` | First two default thread colors |
| `pop`, `good_pop`, `bad_pop`, `fresh` | Status and changed-value emphasis |
| `shadow`, `stripe`, `overlay` | Shadows, row stripes and modal backdrop |
| `highlight`, `chip_fill`, `chip_border`, `status_border` | Button effects, key labels and status separators |
| `flame_low`, `flame_high` | Name-stable flame color ramp |
| `flame_root`, `flame_unknown`, `flame_import_unknown`, `flame_text` | Root/thread frames, unavailable frames and flame labels |

`palettes.threads` replaces the complete thread palette with 1–16 colors. When
present it takes precedence over `thread_main`/`thread_other`. Thread identity
keeps a stable palette index across views. Colors do not alter sample
weights, grouping, symbol resolution or any evidence identity.

The [Ember example](../config/themes/ember.json) ships with the source and local
packages (under the package's documentation/config directory). Layout persistence,
font scaling, skin geometry, a theme editor, MCP appearance commands and Lua
registration remain separate roadmap work.

## Validation

`./scripts/build test` covers parser ownership, strict schema/color validation,
bounded input, built-in text contrast and preference precedence/path resolution.
`python3 tests/themes.py` exercises actual private-Sway rendering, startup
selection and fallback, quiet successful loading, unchanged colors after file
edits or the former hotkey, small windows, imported and remote views, and
headless operation. The GUI
release tier includes this test. Existing debugger/profile/remote and renderer
fault checks continue to cover their controls and evidence behavior.

## VGA look and pixel fonts

`builtin:vga` opts into a DOS-style blue background, light-grey text, cyan and
yellow emphasis, square selections and a block expression cursor. It keeps
breakpoints, unavailable values, stale evidence and loss labels visible. The
original dark theme remains the default.

For the matching 8×16 font, download the Linux pack from the
[Oldschool PC Font Resource](https://int10h.org/oldschool-pc-fonts/download/),
by [VileR](https://int10h.org/oldschool-pc-fonts/). The font remakes are licensed
under [CC BY-SA 4.0](https://int10h.org/oldschool-pc-fonts/readme/#legal_stuff).
Extract `ttf - Px (pixel outline)/Px437_IBM_VGA_8x16.ttf` into a directory of
your choice; no font files are bundled with xodb.

```sh
xodb --theme builtin:vga --font './fonts/Px437_IBM_VGA_8x16.ttf' -- path/to/program
```

Use **Space** to continue, **B** for breakpoints and **E** for the expression
entry with its block cursor. `PxPlus_IBM_VGA_8x16.ttf` from the same pack provides
more Unicode glyphs. The 437 variant uses a missing-glyph box for characters it
does not contain.

The theme selects monochrome FreeType rendering at **16 physical pixels**, the
VGA 8×16 font's native height. Glyph coverage is binary and shaped positions
snap to integer pixels. Scalable pixel-outline fonts and matching monochrome 16-pixel
bitmap strikes work; other bitmap strike sizes fall back if FreeType cannot
select 16 pixels. Embedded grayscale/color bitmaps are unsupported in pixel mode
and use the existing missing-glyph fallback (or default-font retry if initialization
fails). There is no fractional font scaling or change to pane sizes.
With no `--font`, VGA uses the normal installed font in monochrome mode. A missing
or invalid selected font prints a diagnostic and retries the configured default
font. If that font also fails, startup reports the error.

[config/themes/vga.json](../config/themes/vga.json) is an editable example. A
version-1 theme can set `"font": { "pixel": true }` independently of its colors;
`false` restores smooth glyphs. The default is inherited from its built-in base
(VGA uses `true`, the other presets use `false`). The only font field is `pixel`,
a boolean. Fonts and themes are selected once at startup, including remote GUI
clients; there are no theme hotkeys or live reload.
