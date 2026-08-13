# yazi-plugins

A small collection of [Yazi](https://github.com/sxyazi/yazi) plugins and flavors — a couple of my own, plus a few forks fixed up for my Linux and macOS setups.

Install any of them individually with `ya pkg`:

```sh
ya pkg add deppess/yazi-plugins:<name>
```

Check each plugin's own README for setup, keymaps, platform notes, and requirements.

## Plugins

| Plugin | Description |
|---|---|
| [fs-usage-macos.yazi](fs-usage-macos.yazi) | Shows the current partition's used space in the header. Fork of [walldmtd/fs-usage](https://github.com/walldmtd/fs-usage), ported off GNU-only `df`/`readlink` flags to work on macOS. |
| [wallpaper.yazi](wallpaper.yazi) | Sets the hovered file as your wallpaper via `awww`. |
| [trash-empty.yazi](trash-empty.yazi) | Instantly clears XDG trash and `.Trash-*` folders across mounted drives. |
| [trash-empty-macos.yazi](trash-empty-macos.yazi) | Instantly clears `~/.Trash` and every mounted volume's `.Trashes/<uid>`, including encrypted volumes like `/Volumes/Media` while unlocked. macOS counterpart to trash-empty.yazi. |
| [trash-restore-macos.yazi](trash-restore-macos.yazi) | Trash and restore files via native macOS `~/.Trash`/`.Trashes/<uid>`, with a small manifest for exact original-path restore. No custom picker — restore works on whatever's selected while browsing the trash dir itself. |
| [localsend-cli-ui.yazi](localsend-cli-ui.yazi) | Send and receive files over the local network via [localsend-cli](https://github.com/deppess/localsend-cli). |
| [system-clipboard.yazi](system-clipboard.yazi) | Copies file(s) onto the macOS system clipboard as real file references, so pasting works in Finder/other apps. macOS counterpart to [wl-clipboard.yazi](wl-clipboard.yazi). |
| [sfync.yazi](sfync.yazi) | Sync, diff, push/pull, and live-mount SFTP/FTP remotes from Yazi via [sfync](https://github.com/deppess/sfync). |
| [crypter.yazi](crypter.yazi) | Mount/unmount an encrypted gocryptfs volume from Yazi. |
| [sudo.yazi](sudo.yazi) | Run sudo file operations and open hovered/selected files in Helix with sudo. All-Lua fork of sudo.yazi. |
| [zoom.yazi](zoom.yazi) | Zoom in/out of the preview image. Fork of [yazi-rs/plugins](https://github.com/yazi-rs/plugins/tree/main/zoom.yazi). |
| [restore.yazi](restore.yazi) | Restore deleted files/folders with quick recovery or a native picker. Fork of [boydaihungst/restore.yazi](https://github.com/boydaihungst/restore.yazi). |
| [wl-clipboard.yazi](wl-clipboard.yazi) | Wayland system clipboard support. Fork of [grappas/wl-clipboard.yazi](https://github.com/grappas/wl-clipboard.yazi). |

## Flavors

| Flavor | Description |
|---|---|
| [tokyo-night.yazi](tokyo-night.yazi) | Tokyo Night colorscheme. Fork of [BennyOe/tokyo-night](https://github.com/BennyOe/tokyo-night), with tweaked indicator and status bar colors. |

## License

Each plugin and flavor is MIT-licensed individually — see the `LICENSE` file inside its folder.
