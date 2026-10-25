# wallpaper.yazi

Set the currently hovered file as your wallpaper, applying it to both the `wallpaper` and `backdrop` namespaces. The last-used path is saved so it persists across restarts.

Requires Yazi 26.5.6 or newer, Linux/Wayland, and [`awww`](https://github.com/Decodetalkers/awww). The last path is saved below `$XDG_STATE_HOME/awww` (or `~/.local/state/awww`).

## Installation

```sh
ya pkg add deppess/yazi-plugins:wallpaper
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = "w"
run  = "plugin wallpaper"
desc = "Set hovered file as wallpaper"
```

Note that, the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
