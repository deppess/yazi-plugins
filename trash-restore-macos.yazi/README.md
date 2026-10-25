# trash-restore-macos.yazi

Trash and restore files using macOS's native per-volume trash — `~/.Trash` for your boot volume, `.Trashes/<uid>` on every other mounted volume (same discovery as [trash-empty-macos.yazi](../trash-empty-macos.yazi)). One plugin, one `sh` subprocess per action regardless of how many files are targeted.

## Why not the native `~/.Trash`/Finder restore, or `trash-cli`?

macOS's native trash keeps no scriptable record of a file's original path (no xattr, no sidecar), so nothing can restore it correctly. `trash-cli` sidesteps that by using its own `~/.local/share/Trash`, ignoring native `~/.Trash` entirely. This plugin instead writes a tiny per-trash-dir manifest (`.restore-manifest.tsv`: trashed-name, original path, timestamp) at trash time, so restore is exact — and native `~/.Trash`/`.Trashes` stay the single source of truth. The manifest lives and dies with its trash dir's contents, so [trash-empty-macos.yazi](../trash-empty-macos.yazi) clearing a dir clears its manifest for free.

## Restore

`restore` opens an in-Yazi picker (ported from [restore.yazi](../restore.yazi)'s Modal) over the newest 100 manifest entries across every native trash location: `~/.Trash`, APFS Data, and mounted external, encrypted, network, or FUSE volumes — no need to `cd` into a trash dir first. `Space` multi-selects, `Enter` restores (falls back to the item under the cursor if nothing's selected), `j`/`k` or arrow keys move, `q`/`Esc` cancels. A `!` marker means something already exists at that item's original path — restoring it lands as `name (1)`, `name (2)`, etc. (capped at 100) instead of overwriting. Anything without a manifest record (trashed outside this plugin) never shows up, so nothing is guessed at.

## Installation

```sh
ya pkg add deppess/yazi-plugins:trash-restore-macos
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = "d"
run  = "plugin trash-restore-macos"
desc = "Trash selected files"

[[mgr.prepend_keymap]]
on   = ["b", "r"]
run  = "plugin trash-restore-macos -- restore"
desc = "Pick trashed files to restore"
```

Binding straight onto `d` (yazi's default trash key) is intentional: it ensures every delete goes through the manifest, so everything you trash is later restorable. `D` (permanent delete) is untouched.

## Confirmation

Trashing opens Yazi's native confirmation popup with the selected paths and their configured icons. Press `Enter` or `y` to trash, or use Yazi's standard cancel keys. Cancelling leaves every file and manifest unchanged.

This plugin requires Yazi `26.8.15` or later.

Note that the keybindings above are just an example, please tune them up as needed to ensure they don't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
