# SimpleTerminal

Popup terminal manager for Vim9 with multiple persistent sessions. A single UI
handles local shells and SimpleRemote SSH/Docker workspaces.

When `g:SimpleRemoteTerminalSpec()` reports a ready workspace, new terminals
start there (`ssh:host:project`); otherwise they use the local project root
(`local:project`). `:SimpleTerminalNew!` always opens a local shell. Existing
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
Malformed custom or SimpleRemote terminal providers are reported and fall back
to a local shell instead of aborting the command or `:SimpleTerminalHealth`.

See `:help simpleterminal`.
