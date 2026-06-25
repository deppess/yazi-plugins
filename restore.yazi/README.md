# restore.yazi

Restore or recover the most recently deleted files and folders.

Note that, Yazi deletes files in batches of roughly 1000-2000, so a single large deletion may not all share the same timestamp. If you deleted a very large selection, you may need to run the restore command more than once to recover everything.

Requires [`trash-cli`](https://github.com/andreafrancia/trash-cli).

Forked from [boydaihungst/restore.yazi](https://github.com/boydaihungst/restore.yazi). Fixed and tuned to work on my setup (Arch, niri, Wayland).

## Installation

```sh
ya pkg add deppes/yazi-plugins:restore
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["d", "u"]
run  = "plugin restore"
desc = "Restore last deleted files/folders"

[[mgr.prepend_keymap]]
on   = ["d", "U"]
run  = "plugin restore --interactive"
desc = "Pick deleted files/folders to restore"
```

`plugin restore` restores the latest deleted batch. `plugin restore --interactive` opens a native picker for the newest 100 trash entries on the current volume.

Note that, the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
