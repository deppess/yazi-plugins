# yazi-plugins

A collection of Yazi plugins for macOS and Linux. Install an individual plugin with:

```sh
ya pkg add deppess/yazi-plugins:<name>
```

Each plugin README and its top-level `@since` annotation document the authoritative minimum Yazi version, platform, dependencies, configuration, and suggested keybindings. This collection is validated against Yazi 26.9.1.

Source: [Codeberg](https://codeberg.org/deppes/yazi-plugins) (primary) · [GitHub](https://github.com/deppess/yazi-plugins) (mirror)

## Plugins

| Plugin | Platform | Description |
|---|---|---|
| [archive-info.yazi](archive-info.yazi) | Linux, macOS | Previews an archive's stats and tests its integrity, including encrypted archives and multi-volume sets. |
| [crypter-macos.yazi](crypter-macos.yazi) | macOS | Mounts and locks an encrypted APFS volume at a configured path. |
| [fs-usage-macos.yazi](fs-usage-macos.yazi) | Linux, macOS | Shows the current filesystem's used space; includes BSD-compatible macOS handling. |
| [media-search.yazi](media-search.yazi) | Linux, macOS | Searches folders under a configured media-library root. |
| [metaclean.yazi](metaclean.yazi) | macOS | Removes identity metadata from photos, video and audio without re-encoding. |
| [sfync.yazi](sfync.yazi) | Linux, macOS | Syncs, compares, transfers, and mounts sfync profiles. |
| [sudo.yazi](sudo.yazi) | Linux | Runs supported file operations through `sudo`. |
| [system-clipboard.yazi](system-clipboard.yazi) | macOS | Copies files as native macOS clipboard file references. |
| [trash-empty-macos.yazi](trash-empty-macos.yazi) | macOS | Clears native macOS trash locations. |
| [translate-macos.yazi](translate-macos.yazi) | macOS | Writes translated subtitles for videos with on-device Apple speech and translation models. |
| [wallpaper-macos.yazi](wallpaper-macos.yazi) | macOS | Sets the hovered file through `desktoppr`. |
| [zoom.yazi](zoom.yazi) | Linux, macOS | Enlarges or shrinks the hovered image preview. |

## Build and test

Requires [StyLua](https://github.com/JohnnyMorganz/StyLua).

```sh
stylua --check .
```

translate-macos.yazi also has a Swift helper, which needs the Xcode Command Line Tools:

```sh
translate-macos.yazi/build.sh /tmp/translate
```

## License

PolyForm Strict License 1.0.0 (`SPDX-License-Identifier: PolyForm-Strict-1.0.0`), except for the directories below. See [LICENSE](LICENSE).

Forks and adaptations keep their upstream licenses, shown in each directory's LICENSE file: fs-usage-macos.yazi, system-clipboard.yazi and zoom.yazi.

I ask that this code not be used to train AI models. This is a request, not a license term.
