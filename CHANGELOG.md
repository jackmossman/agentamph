# Changelog

Each release gets an entry here and a matching tag. Versions follow [Semantic Versioning](https://semver.org/).

## 1.0.0 - 2026-10-16

The first public release.

- A tray app that lists the Claude Code sessions running on this machine, from the CLI and the VS Code extension, and keeps Windows awake for the ones you choose.
- Critical marks per session, set from the tray menu or, with the optional Claude Code plugin, by starting a prompt with a trigger phrase.
- **Sessions** (All or Critical) and **Keep awake** (Until closed or While busy, with a grace period) selectors, and an option to keep the display on.
- The update guard: while a session holds, Windows Update's Active Hours follow the clock so Windows doesn't restart for updates, and your own Active Hours come back afterwards.
- A per-user install with no administrator rights, by one command or from the release zip, with a Start Menu shortcut, start at login and an Apps & Features entry that uninstalls it.
