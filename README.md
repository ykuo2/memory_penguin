# Memory Penguin

Memory Penguin is a native macOS menu bar app that shows current memory pressure with a small Adelie-inspired penguin icon. Click the icon to inspect detailed memory information.

## Language Choice

This project uses Swift + AppKit because it is the best fit for a lightweight macOS utility:

- Swift can call macOS APIs such as `host_statistics64`, `sysctl`, and `NSStatusBar` directly.
- AppKit provides stable menu bar behavior, and the app bundle uses `LSUIElement` to stay out of the Dock.
- The app does not require an extra runtime such as Electron.
- The penguin icon is drawn with `NSImage`, so the pressure state can update without maintaining separate image files.

## Features

- Updates lightweight menu bar memory data every 2 seconds, then every second while the menu is open.
- Shows or hides the percentage in the menu bar with the `Show Percentage` menu item.
- Enables or disables opening at login with the `Launch at Login` menu item.
- Displays total, used, available, app memory, cache, file-backed cache, anonymous, free, active, inactive, wired, compressed, purgeable, speculative, page-out rate, swap traffic rate, swap memory values, plus separate top memory and top CPU process lists.
- Shows or hides detailed memory sections with the `Show Detailed Memory Info` menu item.
- Uses three minimalist Adelie-inspired icon states:
  - Green short mark: calm pressure.
  - Yellow medium mark: elevated pressure.
  - Red long mark: high pressure.
- Uses `Resources/icon.png` as the app icon.
- Uses `Resources/memory_icon.png` as the three-state menu bar icon sheet.

## Pressure Model

Activity Monitor's exact memory pressure formula is not public. Apple documents it as being determined by free memory, swap rate, wired memory, and file cached memory.

Memory Penguin now follows the same broad model used by `exelban/stats`:

- Used memory: active + inactive + speculative + wired + compressed - purgeable - file-backed cache.
- App memory: used - wired - compressed.
- Cache: purgeable + file-backed cache.
- Pressure state: `kern.memorystatus_vm_pressure_level`, mapped to normal, warning, or critical.

The menu bar percentage is memory usage, not a private Activity Monitor pressure percentage.

## Resource Use

Memory counters and pressure state are read through macOS VM and sysctl APIs. Process lists are read from a lightweight `ps` snapshot, then sorted in the app.

When the menu is closed, Memory Penguin refreshes lightweight status data every 2 seconds and does not read the process list. When the menu is open, it refreshes every second and reads process data in the background to update the five visible memory processes and five visible CPU processes without blocking the menu.

## Build

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
```

The app bundle is created at:

```text
dist/MemoryPenguin.app
```

Open it with:

```bash
open dist/MemoryPenguin.app
```

## Development

```bash
swift run
```

For regular use, prefer the `.app` bundle so `LSUIElement` is applied and the app runs as a Dockless menu bar utility.

For `Launch at Login`, move `dist/MemoryPenguin.app` into `/Applications` first. The build script ad-hoc signs the local bundle so macOS can register it as a login item.

Each release build automatically increments the patch component of `CFBundleShortVersionString` and updates `CFBundleVersion` to a timestamp build number.
