# zoom.yazi

Enlarge or shrink the preview image of the hovered file, useful for magnifying small images for viewing.

Supported formats:

- Images — requires [ImageMagick](https://imagemagick.org/) (>= 7.1.1)

Note that, the maximum size of enlarged images is limited by the [`max_width`][max_width] and [`max_height`][max_height] configuration options, so you may need to increase them as needed.

[max_width]: https://yazi-rs.github.io/docs/configuration/yazi#preview.max_width
[max_height]: https://yazi-rs.github.io/docs/configuration/yazi#preview.max_height

Forked from [yazi-rs/plugins/zoom.yazi](https://github.com/yazi-rs/plugins/tree/main/zoom.yazi). Fixed and tuned to work on my setup (Arch, niri, Wayland).

## Installation

```sh
ya pkg add deppes/yazi-plugins:zoom
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = "+"
run  = "plugin zoom 1"
desc = "Zoom in hovered file"

[[mgr.prepend_keymap]]
on   = "-"
run  = "plugin zoom -1"
desc = "Zoom out hovered file"
```

Note that, the keybindings above are just examples, please tune them up as needed to ensure they don't conflict with your other actions/plugins.

## Advanced

If you want to apply a default zoom parameter to image previews, you can specify it while setting this plugin up as a custom previewer, for example:

```toml
[[plugin.prepend_previewers]]
mime = "image/{jpeg,png,webp}"
run  = "zoom 5"
```

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
