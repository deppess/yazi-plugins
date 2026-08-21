# crypter-macos.yazi

Mount and lock an encrypted macOS APFS volume directly from Yazi. A single keybind opens an unmounted volume at a configured mount point, or unmounts and locks it when already mounted there.

This is the macOS counterpart to [crypter.yazi](../crypter.yazi), which targets gocryptfs on Linux. It uses `diskutil`; no additional dependency is required.

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

By default the plugin looks for an APFS volume named `Media` and mounts it at `~/Media`. Override either value in `init.lua`:

```lua
require("crypter-macos"):setup({
  volume_name = "Media",
  mount_point = "~/Media",
  max_retries = 3,
})
```

- `volume_name` — the APFS volume's display name, as shown by `diskutil apfs list`.
- `mount_point` — where the volume is mounted. Defaults to `~/Media`.
- `max_retries` — number of password attempts allowed before giving up (default `3`).

## How it works

Pressing the bound key resolves the volume's APFS device and checks the live mount table. An unmounted volume is mounted at `mount_point`; if it is locked, the plugin prompts for its passphrase and passes it to `diskutil` over stdin. A volume mounted at `mount_point` is unmounted and then locked. The plugin refuses to remount a volume that is already mounted elsewhere. When unmounting is blocked, it reports non-Yazi processes and only force-unmounts when every reported blocker is Yazi itself.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
