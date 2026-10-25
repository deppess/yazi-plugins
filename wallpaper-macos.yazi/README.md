# wallpaper-macos.yazi

Sets the hovered file as the wallpaper on every connected macOS display.

Requires Yazi 26.5.6 or newer and [desktoppr](https://github.com/scriptingosx/desktoppr). The plugin checks `PATH`, `/opt/homebrew/bin/desktoppr`, then `/usr/local/bin/desktoppr`.

## Installation

```sh
ya pkg add deppess/yazi-plugins:wallpaper-macos
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on = ["n", "w"]
run = "plugin wallpaper-macos"
desc = "Set wallpaper"
```

This is the macOS counterpart to [wallpaper.yazi](../wallpaper.yazi), which uses `awww` on Linux/Wayland.

## License

This plugin is MIT-licensed. See [LICENSE](LICENSE).
