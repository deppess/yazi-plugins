# sudo.yazi

Run common root file operations directly from Yazi using `sudo`. This fork is all Lua: no Python, Ruby, Nushell, or helper scripts.

It supports sudo paste, rename, create, permanent delete, chmod, and opening the hovered or selected files in Helix with sudo.

Requires `sudo` and standard GNU/coreutils commands. The Helix action requires `hx`.

## Installation

```sh
ya pkg add deppes/yazi-plugins:sudo
```

## Usage

Add the actions you want to your `keymap.toml`:

```toml
# sudo cp/mv
[[mgr.prepend_keymap]]
on = ["z", "p", "p"]
run = "plugin sudo -- paste"
desc = "sudo paste"

# sudo cp/mv --force
[[mgr.prepend_keymap]]
on = ["z", "P"]
run = "plugin sudo -- paste --force"
desc = "sudo paste"

# sudo mv
[[mgr.prepend_keymap]]
on = ["z", "r"]
run = "plugin sudo -- rename"
desc = "sudo rename"

# sudo touch/mkdir
[[mgr.prepend_keymap]]
on = ["z", "a"]
run = "plugin sudo -- create"
desc = "sudo create"

# sudo delete
[[mgr.prepend_keymap]]
on = ["z", "D"]
run = "plugin sudo -- remove --permanently"
desc = "sudo delete"

# sudo chmod
[[mgr.prepend_keymap]]
on = ["c", "H"]
run = "plugin sudo -- chmod"
desc = "sudo chmod"

# sudo helix
[[mgr.prepend_keymap]]
on = ["z", "e"]
run = "plugin sudo -- hx"
desc = "sudo helix"
```

The keybindings above are examples. Tune them as needed to avoid conflicts with your existing Yazi actions and plugins.

## Commands

* `paste` — paste yanked files into the current directory using `sudo cp -a` or `sudo mv`.
* `paste --force` — force paste using `sudo cp -af` or `sudo mv -f`.
* `rename` — rename the hovered file using `sudo mv`.
* `create` — create a file with `sudo touch`, or a directory with `sudo mkdir -p` when the name ends in `/`.
* `remove --permanently` — permanently delete the hovered or selected files using `sudo rm -rf`.
* `chmod` — change permissions on the hovered or selected files using `sudo chmod`.
* `hx` — open the hovered file, or all selected files, in one sudo Helix session.

## Configuration

The plugin works without setup.

The `hx` action uses your normal Helix config by default:

```text
~/.config/helix/config.toml
```

If `$XDG_CONFIG_HOME` is set, it uses:

```text
$XDG_CONFIG_HOME/helix/config.toml
```

Optional environment overrides:

```sh
YAZI_SUDO_HX
YAZI_SUDO_HX_CONFIG
YAZI_SUDO_HX_XDG_CONFIG_HOME
YAZI_SUDO_HELIX_RUNTIME
```

Example with fish:

```fish
set -Ux YAZI_SUDO_HX hx
set -Ux YAZI_SUDO_HX_CONFIG ~/.config/helix/config.toml
set -Ux YAZI_SUDO_HX_XDG_CONFIG_HOME ~/.config
set -Ux YAZI_SUDO_HELIX_RUNTIME $HELIX_RUNTIME
```

## How it works

The plugin collects either the selected files or, when nothing is selected, the hovered file. It then builds a sudo command and runs it through Yazi's blocking shell action.

Password handling is left entirely to `sudo`. The plugin does not ask for, store, pass, cache, or write your password. When authentication is needed, `sudo` prompts normally in the terminal.

For Helix, the plugin runs one `hx` process with all selected files passed as arguments, so Helix opens them in the same session and buffer list.

## Notes

This plugin only supports permanent deletion. Trash support was intentionally removed.

This plugin is designed for Linux systems with `sudo`, coreutils, and Yazi 26.5.6 or newer.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.

