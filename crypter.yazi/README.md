# crypter.yazi

Mount and unmount an encrypted [gocryptfs](https://github.com/rfjakob/gocryptfs) volume directly from Yazi. A single keybind toggles between locked and unlocked state, prompting for your password on unlock and retrying up to a configurable number of attempts.

Requires [`gocryptfs`](https://github.com/rfjakob/gocryptfs) and `fusermount`.

## Installation

```sh
ya pkg add deppes/yazi-plugins:crypter
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["c", "c"]
run  = "plugin crypter"
desc = "Toggle encrypted volume"
```

Note that, the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## Configuration

By default the plugin looks for an encrypted directory at `~/.local/share/crypter/locked` and mounts it to `~/.local/share/crypter/open`. Override these in `init.lua`:

```lua
require("crypter"):setup({
  locked_path = "~/path/to/encrypted/dir",
  open_path   = "~/path/to/mount/point",
  max_retries = 3,
})
```

- `locked_path` — path to the gocryptfs-encrypted directory (the ciphertext).
- `open_path` — mount point where the decrypted contents appear when unlocked.
- `max_retries` — number of password attempts allowed before giving up (default `3`).

## How it works

Pressing the bound key checks whether `open_path` is currently mounted. If it is, the volume is locked (unmounted via `fusermount`). If not, you're prompted for your password and the volume is unlocked via `gocryptfs`. The password is written to a short-lived, user-only temp file (under `$XDG_RUNTIME_DIR` when available) and passed to `gocryptfs` via `--passfile` rather than as a command-line argument, then deleted immediately after the mount attempt completes.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
