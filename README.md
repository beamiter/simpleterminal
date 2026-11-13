# SimpleTerminal

Popup terminal manager for Vim9 with multiple persistent sessions. A single UI
handles local shells and SimpleRemote SSH/Docker workspaces.

When `g:SimpleRemoteTerminalSpec()` reports a ready workspace, new terminals
start there (`ssh:host:project`). With no active or connecting workspace they
use the local project root (`local:project`). Pending workspaces and provider
errors refuse to start rather than executing a remote-intended command locally. `:SimpleTerminalNew!` always opens a local shell. Existing
sessions stay attached to the workspace in which they were created: when
SimpleRemote disconnects, that workspace's shells keep running and are labelled
`(detached)` (or are stopped with `g:simpleterminal_remote_on_disconnect =
'kill'`); reconnecting to the same workspace adopts them back, switching to
another one labels the old shells.

Commands: `:SimpleTerminalNew[!] [cmd]`, `:SimpleTerminalToggle`,
`:SimpleTerminalNext`, `:SimpleTerminalPrev`, `:SimpleTerminalSelect {name}`,
`:SimpleTerminalKill`, `:[range]SimpleTerminalSend [text]`,
`:SimpleTerminalList`, `:SimpleTerminalHealth`.

For siblings: `simpleterminal#Run(cmd)` opens a terminal in the workspace and
returns its buffer number; `simpleterminal#Select(name)`,
`simpleterminal#SendRange(...)`, `simpleterminal#State()`; terminal buffers
carry `b:simpleterminal_remote` and `b:simpleterminal_workspace`.

Configuration is normalized at load and rechecked where it is consumed.
Malformed or throwing terminal providers are reported and terminal creation is
refused (`simpleterminal#Run()` returns `-1`); existing sessions stay unchanged.
Use `:SimpleTerminalNew!` to explicitly run locally. `:SimpleTerminalHealth`
continues to report provider errors without aborting.

See `:help simpleterminal`.
