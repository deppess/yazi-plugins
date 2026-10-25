# localsend-cli-ui.yazi

Send and receive files over the local network directly from Yazi — backed by [localsend-cli](https://github.com/deppess/localsend-cli), a headless [LocalSend](https://localsend.org) v2.1 client.

Requires Yazi 26.8.15 or newer and [localsend-cli](https://github.com/deppess/localsend-cli) installed and configured at `~/.config/localsend-cli/config.toml`. The plugin reads favorites from that configuration automatically. Notifications use `notify-send` on Linux and macOS notifications through `osascript`.

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

**Receive (`md`)** runs `localsend-cli receive --headless` directly from the async plugin. Once a sender connects and finishes transferring, the process exits and a desktop notification reports the result. On cancel or connection drop, partial `.tmp` files are cleaned up automatically and the process exits silently.

**Send (`mp`)** reads configured favorites from `~/.config/localsend-cli/config.toml` and presents a numbered picker without a network scan. Select a device, and `localsend-cli send` receives every path as a direct command argument. A desktop notification reports success or failure.

Receive dir is always the `dir` value from your localsend-cli config (defaults to `~/Downloads`).

## License

MIT — see [LICENSE](LICENSE).
