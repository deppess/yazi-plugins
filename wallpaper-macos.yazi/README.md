# wallpaper-macos.yazi

Sets the hovered file as the wallpaper on every connected macOS display.

Requires [desktoppr](https://github.com/scriptingosx/desktoppr).

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
