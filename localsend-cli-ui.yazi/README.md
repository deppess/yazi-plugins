# localsend-cli-ui.yazi

Send and receive files over the local network directly from Yazi — backed by [localsend-cli](https://github.com/deppess/localsend-cli), a headless [LocalSend](https://localsend.org) v2.1 client.

Requires [localsend-cli](https://github.com/deppess/localsend-cli) installed and configured at `~/.config/localsend-cli/config.toml`. The plugin reads your favorites from that config automatically — no extra setup needed. Notifications use `notify-send` (libnotify).

## Installation

```sh
ya pkg add deppess/yazi-plugins:localsend-cli-ui
```

## Usage

Add to `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = ["m", "d"]
run  = "plugin localsend-cli-ui -- receive"
desc = "LocalSend: receive a file"

[[mgr.prepend_keymap]]
on   = ["m", "p"]
run  = "plugin localsend-cli-ui -- send"
desc = "LocalSend: send selected files"
```

## Actions

| Key | Action |
|-----|--------|
| `md` | Wait for an incoming transfer from any device. Runs in the background (visible in task panel), exits automatically after one complete session. |
| `mp` | Pick a device from your favorites, then send the selected files (or hovered file if nothing is selected). |

## How it works

**Receive (`md`)** spawns `localsend-cli receive --headless` as a background shell task. The task stays visible in Yazi's task panel while waiting. Once a sender connects and finishes transferring, the process exits and `notify-send` fires with the received filenames. On cancel or connection drop, partial `.tmp` files are cleaned up automatically and the process exits silently.

**Send (`mp`)** reads your configured favorites from `~/.config/localsend-cli/config.toml` and presents a numbered picker instantly (no network scan delay). Select a device, and `localsend-cli send` runs as a background task in the task panel. A `notify-send` notification fires on success or failure.

Receive dir is always the `dir` value from your localsend-cli config (defaults to `~/Downloads`).

## License

MIT — see [LICENSE](LICENSE).
