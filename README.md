# borders-native

A small, native Swift alternative to [JankyBorders](https://github.com/FelixKratz/JankyBorders):
draws a colored (optionally glowing) border around the focused window on macOS.

One Swift file (~270 lines), no dependencies, ~100 KB binary, ~0% CPU when idle.

## Why

JankyBorders is great, but it is built almost entirely on private SkyLight (window server) APIs,
which tend to break between macOS releases. borders-native does the heavy lifting with public APIs:

- **Accessibility API** (`AXObserver`) to follow focus, moves, resizes, minimize, close and app switches
- **AppKit + Core Animation** (a click-through overlay `NSWindow` with a `CAShapeLayer`) to draw the border

Only two small private calls remain, both widely used (yabai, JankyBorders, AltTab) and both optional:

- `_AXUIElementGetWindow`: the window id of the focused window, for stacking the border right above it
- `SLSWindowIteratorGetCornerRadii`: the window's real corner radius, so the border hugs each window's
  corners (macOS 26+ uses different radii per window type). If it is unavailable, a radius of 9 is used.

## Features

- Border follows the focused window across apps, Spaces and multiple displays (mixed Retina/non-Retina)
- Per-window corner radius, or a fixed `radius=`
- Solid color or `glow(...)`
- Hides on minimize, close, hide (⌘H), quit and native fullscreen
- Survives sleep/wake, display changes and Low Power Mode switches
- Cheap while dragging: only the window frame is read, no restacking, glow uses a precomputed shadow path

## Requirements

- macOS 14 or later (developed on macOS 27)
- Xcode Command Line Tools (`xcode-select --install`)
- Accessibility permission for the binary

## Install

```bash
git clone https://github.com/krashnakant/borders-native.git
cd borders-native
make install            # builds, strips, ad-hoc signs, copies to ~/.local/bin/borders-native
```

`PREFIX` changes the install location: `make install PREFIX=/usr/local`.

## Usage

Options use the same `key=value` style as JankyBorders:

```bash
borders-native active_color="glow(0xffa855f7)" width=3.0 style=round
```

| Option         | Values                                  | Default        |
|----------------|-----------------------------------------|----------------|
| `active_color` | `0xAARRGGBB` or `glow(0xAARRGGBB)`      | `0xffffffff`   |
| `width`        | points                                  | `5`            |
| `style`        | `round`, `square`                       | `round`        |
| `radius`       | points, forces one radius for all windows | per window   |

Unsupported JankyBorders options (`inactive_color`, `hidpi`, `blacklist`, gradients, ...) are ignored with a message.

On first run macOS asks for Accessibility permission. The process waits until it is granted and then starts
drawing, no restart needed. Grant it in System Settings → Privacy & Security → Accessibility.

> The binary is ad-hoc signed, so every rebuild changes its signature and macOS asks for the permission again.

## Run at login

Save as `~/Library/LaunchAgents/local.borders-native.plist` (adjust the path and options):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.borders-native</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/YOU/.local/bin/borders-native</string>
		<string>active_color=glow(0xffa855f7)</string>
		<string>width=3.0</string>
		<string>style=round</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.borders-native.plist
```

After a rebuild: `make install && launchctl kickstart -k gui/$(id -u)/local.borders-native`.
After changing options in the plist: `bootout` and `bootstrap` it again.

### Migrating from JankyBorders (Homebrew)

```bash
brew services stop borders      # or: launchctl bootout gui/$(id -u)/homebrew.mxcl.borders
brew uninstall borders
```

Move the options from `~/.config/borders/bordersrc` into the plist above; borders-native does not read `bordersrc`.

## Limitations

- Only the focused window gets a border (`inactive_color` is not implemented)
- Rendered at 1x on every display (like JankyBorders' `hidpi=off`); slightly soft on Retina screens
- While a window is being dragged or resized the border can trail it by a frame
- No gradients, blur, app blacklist/whitelist or runtime reconfiguration

## How it works

1. One `AXObserver` per running app listens for activation, focus, move, resize, minimize and hide events.
2. On focus change the focused window is resolved (`AXFocusedWindow`), its window id and corner radius looked up,
   and the overlay is ordered directly above it.
3. The overlay is a borderless, transparent, mouse-transparent `NSWindow` on all Spaces whose layer-hosting
   view is a `CAShapeLayer` stroking a rounded rect just outside the window frame.
4. Moves and resizes only re-read the frame and update the path, with implicit animations disabled.
