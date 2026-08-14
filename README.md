# SimpleTerminal

Popup terminal manager for Vim9 with multiple persistent sessions. A single UI
handles local shells and SimpleRemote SSH/Docker workspaces.

When `g:SimpleRemoteTerminalSpec()` reports an active workspace, new terminals
start there; otherwise they use the local project root. Existing sessions stay
attached to the workspace in which they were created.

Commands include `:SimpleTerminalNew`, `:SimpleTerminalToggle`,
`:SimpleTerminalNext`, `:SimpleTerminalPrev`, `:SimpleTerminalKill` and
`:SimpleTerminalSend`.
