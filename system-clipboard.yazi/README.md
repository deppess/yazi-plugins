# system-clipboard.yazi

Copies the selected/hovered file(s) onto the macOS system clipboard as real file references (via `NSPasteboard` through `osascript`), so pasting into Finder or any other app works — not just a text path.

macOS counterpart to [wl-clipboard.yazi](../wl-clipboard.yazi) (which targets the Wayland clipboard via `wl-copy` on Linux). No extra dependencies beyond macOS itself — `osascript` ships with the OS.

## Installation

```sh
ya pkg add deppess/yazi-plugins:system-clipboard
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on = "<C-y>"
run = "plugin system-clipboard"
desc = "Copy to clipboard"
```

Note that, the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
