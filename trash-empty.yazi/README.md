# trash-empty.yazi

Instantly clear XDG trash, plus any `.Trash-*` folders found across mounted drives, without confirmation prompts. Reports how many items were removed, how much space was freed, and which locations were cleaned.

Requires [`trash-cli`](https://github.com/andreafrancia/trash-cli).

## Installation

```sh
ya pkg add deppes/yazi-plugins:trash-empty
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["d", "T"]
run  = "plugin trash-empty"
desc = "Empty trash across all mounted drives"
```

Note that, the keybinding above is just an example, please tune it up as needed to ensure it doesn't conflict with your other actions/plugins.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
