# sfync.yazi

Sync directories, push/pull individual files, diff remote state, and live-mount SFTP/FTP remotes directly from Yazi — all backed by [sfync](https://github.com/deppess/sfync).

Zero config: the plugin reads your sfync profiles from `~/.config/sfync/config.json` automatically.

Requires [sfync](https://github.com/deppess/sfync) installed and configured with at least one profile that has a `context` field set. Push and pull use [fish](https://fishshell.com) shell syntax, so fish must be set as your Yazi shell for those actions to work.

## Installation

```sh
ya pkg add deppess/yazi-plugins:sfync
```

## Usage

Add to `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = ["v", "u"]
run  = "plugin sfync -- up"
desc = "sfync: sync up"

[[mgr.prepend_keymap]]
on   = ["v", "d"]
run  = "plugin sfync -- down"
desc = "sfync: sync down"

[[mgr.prepend_keymap]]
on   = ["v", "D", "u"]
run  = "plugin sfync -- du"
desc = "sfync: diff up"

[[mgr.prepend_keymap]]
on   = ["v", "D", "d"]
run  = "plugin sfync -- dd"
desc = "sfync: diff down"

[[mgr.prepend_keymap]]
on   = ["v", "p"]
run  = "plugin sfync -- push"
desc = "sfync: push file(s)"

[[mgr.prepend_keymap]]
on   = ["v", "l"]
run  = "plugin sfync -- pull"
desc = "sfync: pull file(s)"

[[mgr.prepend_keymap]]
on   = ["v", "m"]
run  = "plugin sfync -- mount"
desc = "sfync: live mount"

[[mgr.prepend_keymap]]
on   = ["v", "M"]
run  = "plugin sfync -- unmount"
desc = "sfync: unmount"
```

Adjust keys to avoid conflicts with your other plugins.

## Actions

| Key | Action | Where it works |
|-----|--------|----------------|
| `vu` | Sync full project up to remote | Hovered on a profile's context directory |
| `vd` | Sync full project down from remote | Hovered on a profile's context directory |
| `vDu` | Dry-run diff (what would be uploaded) | Hovered on a profile's context directory |
| `vDd` | Dry-run diff (what would be downloaded) | Hovered on a profile's context directory |
| `vp` | Push selected file(s) and/or folder(s) | File or folder under any profile context |
| `vl` | Pull selected file(s) and/or folder(s) | File or folder under any profile context |
| `vm` | Mount remote via FUSE, navigate there | Hovered on a profile's context directory |
| `vM` | Unmount | Anywhere |

Sync and diff open an interactive terminal and wait for Enter before returning to Yazi. Push, pull, and mount run in the background; desktop notifications report success or failure (including per-file errors).

`vp` and `vl` operate on the hovered item when nothing is selected, or on all selected items. Selections spanning multiple profile context directories are grouped per profile and transferred concurrently.

`vM` works from anywhere in Yazi. If Yazi was restarted since mounting, the plugin recovers by scanning all profile contexts with `mountpoint` automatically.

## How it works

The plugin parses `~/.config/sfync/config.json` in Lua using balanced-brace pattern matching — no external dependencies beyond sfync itself. Only profiles with a `context` field are recognised; `context` is the local directory that maps to the remote root.

- **`vu` / `vd`** call `sfync up <profile>` / `sfync down <profile>` — a full bidirectional mirror sync.
- **`vDu` / `vDd`** call `sfync diff up <profile>` / `sfync diff down <profile>` — dry-run preview with no changes made.
- **`vp` / `vl`** call `sfync push <profile> <file>` / `sfync pull <profile> <file>` for each target. Directories are expanded with `find -type f` so every contained file is transferred individually, with failures reported by name.
- **`vm`** calls `sfync mount <profile>` to FUSE-mount the remote at the profile's context path, then navigates your current Yazi pane there. Only one profile can be mounted at a time.
- **`vM`** calls `sfync unmount <profile>` and navigates back to the local context directory.

## License

MIT — see [LICENSE](LICENSE).
