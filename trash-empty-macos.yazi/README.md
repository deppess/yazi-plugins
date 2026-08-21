# trash-empty-macos.yazi

Instantly clear the current user's macOS trash system-wide from Yazi — `~/.Trash`, `/System/Volumes/Data/.Trashes/<uid>`, and every mounted volume's per-user `.Trashes/<uid>` directory — without confirmation prompts. Reports how many top-level trash items were removed, how much space was freed, and how many locations were cleaned.

Trash locations are discovered from macOS mount data instead of only scanning `/Volumes`, so the APFS Data volume (`/System/Volumes/Data/.Trashes`) and currently mounted external, encrypted, network, or FUSE volumes are covered when their trash directory exists. Locked or unmounted volumes are naturally skipped.

Results are reported through a Yazi notification.

macOS counterpart to [trash-empty.yazi](../trash-empty.yazi), which targets XDG trash + `.Trash-*` dirs via `trash-cli` on Linux.

## Installation

```sh
ya pkg add deppess/yazi-plugins:trash-empty-macos
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["b", "t"]
run  = "plugin trash-empty-macos"
desc = "Empty my macOS trash"
```

Note that the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
