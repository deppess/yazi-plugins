# Isolated Yazi integration configuration

This directory is intentionally separate from `~/.config/yazi`.

For a manual integration test, create a disposable configuration root, copy
this `keymap.toml` into it, and make `plugins/metaclean.yazi` point at this
project directory. Start Yazi in a directory under `metaclean.yazi/tests/working/`
only. Never use this configuration with personal media.

The automated suite drives the production transaction through an adapter for
Yazi's APIs. Running the plugin inside Yazi itself stays a manual check,
because Yazi needs a terminal session.
