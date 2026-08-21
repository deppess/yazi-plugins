# fs-usage-macos.yazi

A [Yazi](https://github.com/sxyazi/yazi) plugin to show the current partition's used space in the header or status.

macOS counterpart to [walldmtd/fs-usage](https://github.com/walldmtd/fs-usage), which only supports Linux — it shells out to GNU `df --output=source,pcent` and GNU `readlink --canonicalize`, neither of which exist on BSD/macOS `df`/`readlink`. This fork branches on `ya.target_os()` and uses `df -P` (fixed POSIX columns) and `readlink -f -n` on macOS, falling back to the original GNU behaviour everywhere else — so the same plugin works on both.

## Installation

```sh
ya pkg add deppess/yazi-plugins:fs-usage-macos
```

## Usage

To use the default setup, add this somewhere in `~/.config/yazi/init.lua`:

```lua
require("fs-usage-macos"):setup()
```

To customize it, add this instead and adjust/remove the options as needed:

```lua
require("fs-usage-macos"):setup({
    -- All values are optional

    -- Position of the component
    --   parent: Parent component ("Header" or "Status")
    --   align: Anchor point within parent object ("LEFT" or "RIGHT")
    --   order: Order relative to others in the same parent
    -- Default: { parent = "Header", align = "RIGHT", order = 2000 }
    position = { parent = "Header", align = "RIGHT", order = 2000 },

    -- Text format
    -- One of:
    --   "both": Partition name and percent used
    --   "name": Only partition name
    --   "usage": Only percent used
    -- Default: "both"
    format = "both",

    -- Option to enable or disable the usage bar
    -- Default: true
    bar = true,

    -- Percent usage to use the warning style (-1 to disable)
    -- Default: 90
    warning_threshold = 90,

    -- For style options, any unset options use the progress bar style
    --   from the Yazi flavor if available, otherwise it falls back to
    --   the default Yazi style.

    -- Label text style
    --   fg: Text colour (String like "white", or hex like "#ffffff")
    --      (Can also be "" to use the reverse of the bar colour)
    --   bold: Make the label bold (bool)
    --   italic: Make the label italic (bool)
    -- Example: style_label = { fg = "", bold = true, italic = false },
    -- Default: {}
    style_label = {},

    -- Usage bar style
    --   fg: Bar colour (String like "blue", or hex like "#0000ff")
    --   bg: Bar background colour (Same format as fg)
    -- Example: style_normal = { fg = "blue", bg = "black" },
    -- Default: {}
    style_normal = {},

    -- Usage bar style when the used space is above the warning threshold
    -- Options are the same as style_normal
    -- Default: {}
    style_warning = {},

    -- Bar padding
    --   open: Character on the left (string)
    --   close: Character on the right (string)
    -- Example: { open = "█", close = "█" } for square corners,
    --   or { open = "", close = "" } for no padding
    -- Default: { open = "", close = "" }
    padding = { open = "", close = "" }
})
```

## License

MIT-licensed, inherited from the upstream [walldmtd/fs-usage](https://github.com/walldmtd/fs-usage) — see [LICENSE](LICENSE).
