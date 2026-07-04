# Menubar Native Control

Native macOS/AppKit menu bar controller for a MOTU 828ES or another AVB mixer with HTTP-accessible control endpoints.

## What It Does

- Adds a menu bar item named `828`.
- Shows the sections and controls you add in the Menu Layout editor.
- Provides a settings window for:
  - mixer IP/host,
  - scanning available mixer inputs and outputs from the configured IP,
  - scanning available control sources from the MOTU datastore,
  - building the menu manually from sections and source-backed elements,
  - auto-start through macOS login items.

## Build And Run

This project is a Swift Package so it can build without an Xcode project:

```sh
swift run MenubarNativeControl
```

If SwiftPM tries to write caches outside the workspace, use:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift run MenubarNativeControl
```

## Package As An App

Create a menu-bar-only `.app` bundle:

```sh
./build archive
```

The app is written to:

```text
.build/Menubar Native Control.app
```

Install the archived app into `/Applications`:

```sh
./build archive install
```

Set `INSTALL_DIR` to install somewhere else:

```sh
INSTALL_DIR="$HOME/Applications" ./build archive install
```

Auto-start works best from the packaged app, because macOS login item registration expects an application bundle.

## Endpoint Configuration

Endpoint fields accept either relative paths against the mixer host or full URLs.

For write operations:

- If the endpoint contains `{value}`, the app substitutes the value and sends a `GET`.
- MOTU `/datastore/...` writes are sent like the web app sends them: `POST /datastore?client=...` with a `json` form payload.
- Other endpoints are sent with `PUT` and a `text/plain` body.

Examples:

```text
/datastore/ext/some/path?value={value}
http://192.168.1.100/datastore/ext/some/path?value={value}
```

For reads, the app sends `GET` and accepts plain text or JSON with common fields such as `value`, `val`, `data`, `current`, or `name`.

MOTU datastore paths vary by firmware and mixer configuration, so the defaults intentionally leave endpoint paths empty. Fill them from the MOTU web app/API paths you want to control.

## Scanning Mixer I/O

After entering the mixer IP in Settings, click `Scan Mixer I/O`.

The app queries common MOTU datastore roots and opens a results window grouped into inputs, outputs, and other named endpoints. Each entry shows the discovered base path plus likely name, volume, level, and mute paths when those keys are present in the returned datastore.

Use `Scan Control Sources` to read `/datastore` and populate the source/control pickers in the Menu Layout editor. Scanning only updates the available picker catalog; it does not add anything to the menu.

Fader rows in the Menu Layout editor include `Min` and `Max` fields. Scanned controls are prefilled with their discovered range, and manual faders default to `0` and `1`.

In Menu Layout, add your own sections and elements. For each element, choose a scanned source first, then choose what that element controls for that source. The menu supports:

- input trims, pad, and +48V where the mixer exposes them,
- phones and monitor output trims,
- monitor level and mute,
- mixer channel faders, main sends, aux sends, group sends, mutes, compressor toggles, and four EQ-band toggles,
- mixer group faders, mutes, and main sends.

Each element keeps an editable endpoint field for advanced manual overrides. The menu is built from this layout; there are no separate fixed channel or special sections.

Datastore writes use the same protocol as the MOTU web app: `POST /datastore?client=...` with a `json` payload. Direct `PUT /datastore/...` is rejected by the tested firmware.

On current MOTU AVB firmware, live meters are exposed through HTTP polling rather than websocket. The web app polls:

```text
/meters?meters=mix/gate:mix/comp:mix/level:mix/leveler:ext/input
```

The app supports scalar meter endpoint paths in channel `Level` fields:

```text
meters/ext/input/14
meters/mix/level/5/14
```

Meter values are normalized from MOTU's `0...1000` response scale to the app's `0...1` level indicator scale.
