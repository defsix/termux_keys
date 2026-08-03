# conn.ps1 — Windows companion to `conn`

A PowerShell script that reads and writes the **same** git-synced
`~/.config/conn` repo as the Termux `conn` tool (see the [main
README](../README.md)) — connections, snippets, and encrypted passwords
created on your phone are usable here, and vice versa, after `conn sync`.

This is a companion, not a port. Two things don't carry over from Termux,
because there's nothing equivalent on Windows to build them on:

- **No tmux**, so no live-pane snippet injection. Clipboard copy is the way
  snippets get used here — which is already the *reliable* path on Termux
  too, so you're not missing much.
- **No `sshpass` equivalent** for a full interactive password-auth session.
  Password-holdout hosts get a one-time auto-key install via
  [Posh-SSH](https://github.com/darkoperator/Posh-SSH) (see below); after
  that, or if you skip it, the actual connection always goes through native
  `ssh.exe`, which prompts for the password itself if no key is installed —
  a normal, honest fallback rather than something half-working.

## Install

1. **OpenSSH Client** (if not already present): Settings → Apps → Optional
   Features → Add a feature → OpenSSH Client. Or:
   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
   ```
2. **fzf, age, git:**
   ```powershell
   winget install fzf
   winget install FiloSottile.age
   winget install Git.Git
   ```
3. **Posh-SSH** (optional — only needed for the password-holdout auto-key
   path):
   ```powershell
   Install-Module -Name Posh-SSH -Scope CurrentUser
   ```
4. **PowerShell 7.3+** is required (for correct empty-string argument
   passing to native commands, used by `ssh-keygen -N ''`). Check with
   `$PSVersionTable.PSVersion`.

Then clone this repo and set up a `conn` function in your PowerShell
profile (`notepad $PROFILE`):

```powershell
function conn { & "C:\path\to\termux_keys\windows\conn.ps1" @args }
```

Reload your profile (`. $PROFILE`) or open a new terminal, then:

```powershell
conn doctor
```

## Getting your existing hosts/snippets/secrets here

On the Termux side, you've already run `conn sync init` + `conn sync remote
<url>` + `conn sync`, which pushed `~/.config/conn` (hosts, snippets,
`age`-encrypted secrets — **never** the age identity or private keys) to a
git remote. On Windows:

```powershell
git clone <url> $HOME\.config\conn
conn doctor
```

Then copy over, **by hand, once** — the same golden rule as the Termux
side, the decryption keys never travel through the sync repo:

- Your `age` identity: from the Termux device (`~/.config/conn/age/identity.txt`)
  to `$HOME\.config\conn\age\identity.txt` here.
- Any private SSH keys referenced by your hosts' `IdentityFile` lines, to
  the matching path here (typically `$HOME\.ssh\id_ed25519`).

Once both are in place, `conn connect HOST` should log you in without a
prompt, same as on Termux.

## Commands

Same surface as the Termux tool, minus tmux-specific things
(`bind-key`/`snip-popup`) and `widgetize` (Termux:Widget is Android-only):

```
conn connect [-m] [HOST|N]  connect (fzf-pick, or by number, if omitted)
conn list                   list hosts, numbered and grouped
conn add                    append a Host block to ssh_config
conn rm [HOST|N]            remove a Host (+ its secret) from ssh_config
conn edit                   open ssh_config in $env:EDITOR (default notepad)
conn keygen [HOST]          generate an ed25519 key, ssh-copy-id to HOST

conn snip add NAME          create/edit a snippet
conn snip ls                list snippets
conn snip rm NAME           delete a snippet
conn snip [NAME]            pick a snippet: copy to clipboard / run local / run on host

conn secret init             create an age identity for password holdouts
conn secret add HOST         encrypt a host password with age (offers to
                              auto-install a key via Posh-SSH on next connect)
conn secret rm HOST          remove a stored secret
conn secret ls               list hosts with stored secrets

conn sync init                create/verify the git repo for ssh_config + snippets + secrets
conn sync remote URL          set the sync repo's remote
conn sync [push|pull]         commit + push/pull the sync repo

conn doctor                   check for required/optional dependencies
conn help                     show the full command list
```

## How the shared config works

Exactly like the Termux side: your actual `Host` blocks live in
`~/.config/conn/ssh_config` (git-synced), and `~/.ssh/config` is kept to a
single line:

```
Include C:\Users\you\.config\conn\ssh_config
```

so plain `ssh.exe HOST` / `git` outside of `conn` see the same hosts
without knowing anything about `conn`. The first time `conn.ps1` runs, if
`~/.ssh/config` already has real content that isn't already `Include`d,
it's moved into `ssh_config` (merged with, not overwriting, anything
already there from a sync pull), the original is backed up to
`~/.ssh/config.bak.<timestamp>`, and `~/.ssh/config` is rewritten to just
the `Include` line. Always prints what happened — never a silent
structural change to a config you already had working.

## Password holdouts

`conn secret add HOST` prompts for the password (via `Read-Host
-AsSecureString` — needs a real interactive console, not piped input) and
encrypts it to `secrets/HOST.age`, same as Termux. It then asks: *"No key
added — create one and use it next time?"* Answering yes means the next
`conn connect HOST` uses the stored password, through Posh-SSH, to append
your public key to that host's `~/.ssh/authorized_keys` — a one-time
operation, never a persistent interactive session. After that (or if the
install fails, or you skip it), the connection proceeds through ordinary
`ssh.exe`, prompting for the password itself if no key ended up installed.

If `Posh-SSH` isn't installed, this step is skipped with a message —
`conn connect` still works normally via `ssh.exe`'s own password prompt.

## Security notes

- Passwords are never written to disk in plaintext — `age`-encrypted or
  nothing, same as Termux.
- The password only ever reaches Posh-SSH as a `SecureString`/`PSCredential`,
  never as a plain command-line argument.
- The `age` identity and any private SSH key **never** sync — same golden
  rule as Termux: only ciphertext travels through the repo.

## Known limitations

- `Read-Host -AsSecureString` needs a real console — it won't work if you
  try to script `conn secret add`/`conn add`'s password prompt via piped
  input (this is a PowerShell/Windows constraint, not something `conn.ps1`
  can work around).
- "run local" for a snippet needs `bash` on `PATH` (Git for Windows or
  WSL both provide one) since snippets are plain `.sh` scripts shared
  cross-platform via the same repo — if it's not found, the snippet body
  just gets printed instead.
- `mosh` isn't commonly available on Windows; `conn connect -m` will error
  clearly if it's missing rather than silently falling back.
