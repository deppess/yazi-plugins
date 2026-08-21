# media-search.yazi

Recursive folder search scoped to a media library root. Type a query in a native input box; a small read-only panel below it shows the top-ranked matching folders live, updating on every settled keystroke. Press Enter to jump straight to the best match — native `cd`, no custom picker, no terminal takeover.

Folders only (`fd -t d`) — this is built for navigating a deep, heavily-nested media library by name, not general-purpose file search.

Requires [`fd`](https://github.com/sharkdp/fd).

## Installation

```sh
ya pkg add deppess/yazi-plugins:media-search
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["b", "f"]
run  = "plugin media-search"
desc = "Search media library"

[[mgr.prepend_keymap]]
on   = ["b", "i"]
run  = "plugin media-search -- reindex"
desc = "Rebuild media search index"
```

Note that, the keybindings above are just an example, please tune them up as needed to ensure they don't conflict with your other actions/plugins.

## Configuration

By default the plugin searches `~/Media`. Override this in `init.lua`:

```lua
require("media-search"):setup({
  root = "~/path/to/media/library",
})
```

- `root` — absolute or `~`-relative path to the media library to search. Must exist and be a directory; a missing/misspelled path is rejected up front with a notification.

## How it works

**Search** runs against a manually-built index when one exists, or falls back to a live `fd` walk otherwise — so it works out of the box, just faster once indexed. Matching is smart-case (case-sensitive only if your query contains an uppercase letter, matching `fd`'s own convention), and a folder whose name exactly matches the query beats a mere substring match at any depth. Among remaining candidates, the shallowest (closest to root) wins; ties are broken using your live `yazi.toml` sort settings (`sort_by`/`sort_sensitive`/`sort_reverse`/`sort_fallback`), applied at the first path segment where the tied candidates diverge — so results always land where you'd expect if you'd browsed there natively.

**The index** (`b i`) is a flat, plain-text list of every folder under `root`, rebuilt in full on each press — no incremental/partial updates. It is stored as a hidden file inside the media root rather than in a regular cache directory. Each rebuild reports how many folders changed since the last one (`+added, -removed`); the first build reports the total.

**The live panel** truncates long paths shell-prompt style: every ancestor folder collapses to its first character, the matched folder's own name always stays spelled out in full — e.g. `Projects/-Dots/config/fish/themes` renders as `P/-/c/f/themes`.

## License

This plugin is MIT-licensed. For more information check the [LICENSE](LICENSE) file.
