# trash-empty-macos.yazi

Instantly clear the macOS trash — `~/.Trash` plus every mounted volume's per-user `.Trashes/<uid>` directory — without confirmation prompts. Reports how many items were removed, how much space was freed, and how many locations were cleaned.

Volumes are discovered generically under `/Volumes`, so anything currently mounted is covered automatically, including encrypted APFS volumes (e.g. `/Volumes/Media`, see [crypter-macos.yazi](../crypter-macos.yazi)) only while they're unlocked and mounted — locked, they're simply not there to scan. The boot volume shows up under `/Volumes` as a symlink rather than a real directory, so it's skipped without any special-casing.

macOS counterpart to [trash-empty.yazi](../trash-empty.yazi), which targets XDG trash + `.Trash-*` dirs via `trash-cli` on Linux.

## Installation

```sh
ya pkg add deppess/yazi-plugins:trash-empty-macos
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["d", "T"]
run  = "plugin trash-empty-macos"
desc = "Empty trash across all mounted volumes"
```

Note that the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
