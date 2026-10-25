# system-clipboard.yazi

Copies the selected/hovered file(s) onto the macOS system clipboard as real file references (via `NSPasteboard` through `osascript`), so pasting into Finder or any other app works — not just a text path.

macOS counterpart to [wl-clipboard.yazi](../wl-clipboard.yazi), which targets the Wayland clipboard via `wl-copy` on Linux. It preserves the selection behavior of [orhnk/system-clipboard.yazi](https://github.com/orhnk/system-clipboard.yazi) while using macOS's built-in `osascript` backend.

Requires Yazi 26.8.15 or newer.

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

The keybinding is an example; adjust it to avoid conflicts with other actions.

## License

This plugin is MIT-licensed. It retains attribution to [orhnk/system-clipboard.yazi](https://github.com/orhnk/system-clipboard.yazi); see [LICENSE](LICENSE).
