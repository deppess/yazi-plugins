# crypter-macos.yazi

Lock and unlock an encrypted macOS APFS volume directly from Yazi. A single keybind toggles between locked and unlocked state, prompting for your password on unlock and retrying up to a configurable number of attempts.

macOS counterpart to [crypter.yazi](../crypter.yazi) (which targets gocryptfs on Linux). Uses `diskutil apfs lockVolume`/`unlockVolume` — no extra dependencies beyond macOS itself. Mirrors the `lock`/`unlock` fish functions (`~/.config/fish/functions/{lock,unlock}.fish`), so the same named APFS volume works from either the shell or Yazi.

## Installation

```sh
ya pkg add deppess/yazi-plugins:crypter-macos
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["n", "u"]
run  = "plugin crypter-macos"
desc = "Toggle encrypted volume"
```

Note that, the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## Configuration

By default the plugin looks for an APFS volume named `Media`. Override this in `init.lua`:

```lua
require("crypter-macos"):setup({
  volume_name = "Media",
  max_retries = 3,
})
```

- `volume_name` — the APFS volume's display name, as shown by `diskutil apfs list`.
- `max_retries` — number of password attempts allowed before giving up (default `3`).

## How it works

Pressing the bound key looks up the named volume's disk identifier via `diskutil apfs list`, then checks `diskutil info <dev>` for its `Locked:` state. If unlocked, the volume is locked via `diskutil apfs lockVolume`. If locked, you're prompted for your password and the volume is unlocked via `diskutil apfs unlockVolume <dev> -stdinpassphrase` — the password is piped directly to `diskutil`'s stdin, never written to disk or passed as a CLI argument.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
