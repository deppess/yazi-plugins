# ts-note.yazi

Timestamps notes in a notes directory. Any file created there gets a lowercase timestamp prefix, and extensionless names get `.md` appended, so typing `idea` produces `2610261432-idea.md`.

- Extensionless names → `.md` is appended, then the name is stamped.
- `.md` files → stamped.
- Other extensions (`.png`, `.pdf`, …), hidden files, and directories → left alone.
- Already-stamped names are not stamped again. A colliding name gets a `_1`, `_2`, … suffix.

## Installation

```sh
ya pkg add deppess/yazi-plugins:ts-note
```

## Configuration

```lua
-- init.lua
require("ts-note"):setup {
	dir = "/Users/you/Documents/Notes",
	format = "%y%m%d%H%M",
}
```

- `dir` (required): absolute path to the notes directory.
- `format`: `os.date` format for the prefix. The default is `%y%m%d%H%M` (`2610261432`): unique per minute and sorts by date and time.
- `pattern`: Lua pattern that recognizes an already-stamped name. The default, `^(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)%-`, matches the default `format` and checks that month, day, hour and minute are valid. If you change `format`, change this too, because it is not derived automatically. A pattern with three captures checks only the date; one without captures is used as a plain shape match.

Register the preloader for automatic stamping. Use the same directory as `dir`:

```toml
# yazi.toml
[plugin]
prepend_preloaders = [
  { url = "/Users/you/Documents/Notes/*", run = "ts-note" },
]
```

## Usage

To stamp the hovered file manually, bind a key:

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = "N"
run  = "plugin ts-note"
desc = "Timestamp hovered note"
```

Note that, the keybindings above are just an example, please tune them up as needed to ensure they don't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
