# yazi-plugins

A small collection of [Yazi](https://github.com/sxyazi/yazi) plugins — a couple of my own, plus a few forks fixed up to run on my setup (Arch Linux, Niri WM).

Install any of them individually with `ya pkg`:

```sh
ya pkg add deppes/yazi-plugins:<plugin-name>
```

Check each plugin's own README for setup, keymaps, and requirements.

## Plugins

| Plugin | Description |
|---|---|
| [wallpaper.yazi](wallpaper.yazi) | Sets the hovered file as your wallpaper via `awww`. |
| [trash-empty.yazi](trash-empty.yazi) | Instantly clears XDG trash and `.Trash-*` folders across mounted drives. |
| [crypter.yazi](crypter.yazi) | Mount/unmount an encrypted gocryptfs volume from Yazi. |
| [zoom.yazi](zoom.yazi) | Zoom in/out of the preview image. Fork of [yazi-rs/plugins](https://github.com/yazi-rs/plugins/tree/main/zoom.yazi). |
| [restore.yazi](restore.yazi) | Restore the most recently deleted files/folders. Fork of [boydaihungst/restore.yazi](https://github.com/boydaihungst/restore.yazi). |
| [wl-clipboard.yazi](wl-clipboard.yazi) | Wayland system clipboard support. Fork of [grappas/wl-clipboard.yazi](https://github.com/grappas/wl-clipboard.yazi). |

## License

Each plugin is MIT-licensed individually — see the `LICENSE` file inside its folder.
