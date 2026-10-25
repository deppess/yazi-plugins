# yazi-plugins

A collection of Yazi plugins and flavors for Linux, macOS, and Wayland. Install an individual plugin or flavor with:

```sh
ya pkg add deppess/yazi-plugins:<name>
```

Each plugin README and its top-level `@since` annotation document the authoritative minimum Yazi version, platform, dependencies, configuration, and suggested keybindings. This collection is validated against Yazi 26.9.1.

## Plugins

| Plugin | Platform | Description |
|---|---|---|
| [crypter.yazi](crypter.yazi) | Linux | Mounts and unmounts a gocryptfs volume. |
| [crypter-macos.yazi](crypter-macos.yazi) | macOS | Mounts and locks an encrypted APFS volume at a configured path. |
| [fs-usage-macos.yazi](fs-usage-macos.yazi) | Linux, macOS | Shows the current filesystem's used space; includes BSD-compatible macOS handling. |
| [localsend-cli-ui.yazi](localsend-cli-ui.yazi) | Linux, macOS | Sends and receives files through `localsend-cli`. |
| [media-search.yazi](media-search.yazi) | Linux, macOS | Searches folders under a configured media-library root. |
| [restore.yazi](restore.yazi) | Linux | Restores files managed by `trash-cli`. |
| [sfync.yazi](sfync.yazi) | Linux, macOS | Syncs, compares, transfers, and mounts sfync profiles. |
| [sudo.yazi](sudo.yazi) | Linux | Runs supported file operations through `sudo`. |
| [system-clipboard.yazi](system-clipboard.yazi) | macOS | Copies files as native macOS clipboard file references. |
| [trash-empty.yazi](trash-empty.yazi) | Linux | Clears XDG trash and mounted-drive trash locations. |
| [trash-empty-macos.yazi](trash-empty-macos.yazi) | macOS | Clears native macOS trash locations. |
| [trash-restore-macos.yazi](trash-restore-macos.yazi) | macOS | Trashes files and restores manifest-backed native macOS trash entries. |
| [wallpaper.yazi](wallpaper.yazi) | Linux/Wayland | Sets the hovered file through `awww`. |
| [wallpaper-macos.yazi](wallpaper-macos.yazi) | macOS | Sets the hovered file through `desktoppr`. |
| [wl-clipboard.yazi](wl-clipboard.yazi) | Linux/Wayland | Copies files to the Wayland clipboard as URI-list data. |
| [zoom.yazi](zoom.yazi) | Linux, macOS | Enlarges or shrinks the hovered image preview. |

## Origins And Licenses

Several directories are maintained forks or adaptations. Their individual READMEs and LICENSE files retain upstream attribution and identify modifications. Most plugins are MIT-licensed; [restore.yazi](restore.yazi) is licensed under AGPL-3.0-or-later.
