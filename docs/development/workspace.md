# macOS Files and SSH workspace

Ordinary terminal windows have Files, SSH, and (when documents are open) Editor
controls above the terminal. The sidebar starts collapsed. Quick Terminal keeps
its existing layout.

## Use

- Open Files to browse the focused terminal's local filesystem. Double-click an
  item to open it. The context menu contains rename, download, and delete.
- The plus menu creates a file/folder or uploads one file. Transfers use new
  destination names and never replace an existing destination.
- Add an SSH connection in SSH. Host accepts either a hostname or an existing
  `~/.ssh/config` alias; leave user, port, and identity blank to use OpenSSH's
  settings. Connection profiles can be edited or removed with the context menu.
- Connect opens a new terminal tab. Enter passwords, key passphrases, and host-key
  confirmation there. Files loads after authentication. Passwords are not stored.
- Text files open above the terminal. Save or Command-S in the editor writes back
  to that document's original machine. Save Copy requires a full new path on the
  same machine. Documents remain associated with that machine when focus changes.
- Local directory following is opt-in. Remote directory following is unavailable:
  the existing terminal core only accepts local-host directory reports.
- Refresh reports disconnection/SFTP errors. Reconnect opens a new terminal tab
  and carries the selected connection's documents, including unsaved edits, over.

## Boundaries and failure behavior

The editor supports regular UTF-8 text files up to 5 MiB. It preserves UTF-8 BOM
and CRLF conventions; mixed newline files retain their existing text. Binary and
larger files can be downloaded. This is a text editor without language services.

Remote file access requires SFTP v3. Replacement saves require OpenSSH's
`posix-rename@openssh.com` extension; otherwise use Save Copy. Saved files retain
ordinary POSIX permission bits. Ownership, ACLs, hard-link relationships and
extended attributes are not promised across atomic replacement. Symlinks are
resolved before editing so saving updates their target.

Save compares the current contents with the opened version before replacing a
file. Conflicts keep the buffer and offer Reload or Overwrite. This detects
external changes but is not a distributed lock: another writer can still race
with the final replacement. A lost connection during commit can leave the result
uncertain; reconnect and reload/check the file before choosing Overwrite.

Local deletion uses Trash. Remote deletion is permanent and requires confirmation.
Only files and empty directories are deleted. Folder transfers, synchronization,
sudo editing, password persistence, manual/nested SSH detection and Quick Terminal
workspace UI are outside this version.

Cancellation stops at protocol/chunk boundaries. An in-flight network response
has a 15-second timeout. Temporary `.ghostty-<UUID>` files are removed when the
connection permits cleanup; a broken connection may leave a temporary file on the
server. No transfer or unsaved buffer is automatically resumed after app exit.

SSH profiles live in
`~/Library/Application Support/com.mitchellh.ghostty/workspace/ssh.json`.
Each managed connection has its own private `/tmp/gw-<UUID>/ssh` control socket.
The SSH terminal owns the master connection with `ControlPersist=no`; workspace
shutdown closes the file channel and requests master exit. Remote tabs are not
restored as local shells on app restart.

## Verification

Local verification is source inspection only. `Workspace macOS` in GitHub Actions
builds GhosttyKit, runs Swift lint and the macOS test target, checks a temporary
loopback sshd connection and SFTP subsystem reuse, and uploads an ad-hoc signed
ReleaseLocal preview app. It does not use upstream private runners or signing keys.
The added tests exercise real `/usr/libexec/sftp-server` protocol operations,
special filenames, binary transfer, symlink saves, permissions, conflicting edits,
nonempty-directory refusal, packet bounds, and BOM/CRLF preservation.

The preview is not notarized. Build/test/packaging results must be read from CI;
static inspection does not establish that they pass.

### Manual acceptance on the preview

1. Open Files locally, browse a directory with hidden files, create/rename a file
   and empty folder, edit/save text, download/upload a file, and delete to Trash.
2. Connect to test hosts using a config alias, agent, explicit identity,
   encrypted identity, password, and ProxyJump. Verify host-key confirmation and
   rejection of a changed key. Verify cancelling login does not enable Files.
3. Confirm SFTP-disabled hosts still have a working terminal and useful Files
   errors. Disconnect during browsing, upload, and save; retain editor buffers,
   reconnect, and verify the actual remote contents before continuing.
4. Open the same path on two hosts. Switch terminal splits/tabs and edit both;
   verify saves never cross connections. Close one connection and verify another
   remains usable. Hand-typed SSH does not acquire a remote Files binding.
5. Modify an opened file externally. Check Keep Editing, Reload, Overwrite, and
   Save Copy. Test permission denial and a server without atomic rename support.
6. Exercise Save/Find/Undo in the editor and terminal keybindings after focus
   changes. Resize/collapse sidebar/editor. Check non-native fullscreen and each
   supported titlebar style for layout regressions.
7. Attempt file-tab, terminal-tab, window-group, and app closure with dirty files.
   Cancel must preserve the buffers; discard must be explicit. Close during save
   must wait for completion.
8. Browse a large directory while typing in the terminal; rapidly change
   directories and toggle following. Old results must not replace the current
   directory. Transfer a large file, cancel, and check responsiveness and cleanup.
