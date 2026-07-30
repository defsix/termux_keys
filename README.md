# conn

A small, dependency-light SSH connection and snippet manager for **Termux on
Android**. It replaces JuiceSSH (abandoned, pulled from the Play Store,
license servers dead) by reproducing its core workflow on top of maintained
standard tools — `ssh`, `tmux`, `fzf`, `age` — instead of a bespoke
terminal/SSH stack.

Two things matter here:

1. **Launch screen → tap a saved connection → connected**, no prompt.
2. **Inside a live session → summon a snippet → it types into the terminal.**

Everything else in this repo exists to make those two things work.

## Install

```
pkg install fzf openssh tmux mosh age sshpass git termux-api
./install.sh
```

`install.sh` symlinks `bin/conn` onto your `PATH` (`$PREFIX/bin` on Termux,
`~/.local/bin` elsewhere) and creates `~/.config/conn/{snippets,secrets,age}`.

Run `conn doctor` afterwards to confirm required tools are present.

First-time clone + install, one line:

```
git clone https://github.com/defsix/termux_keys && cd termux_keys && ./install.sh
```

### Updating

```
cd ~/termux_keys && git fetch origin && git reset --hard origin/main && ./install.sh
```

This force-syncs the repo (overwriting any local edits to `install.sh`/`conn`)
and re-runs the installer. Your snippets, secrets, age identity, and
`~/.ssh/config` are untouched either way — they live outside the repo, and
`install.sh` only creates them if missing, never overwrites.

## Quick start

```
conn keygen                 # generate a passphraseless ed25519 key
conn add                    # add a Host to ~/.ssh/config (prompts for alias/HostName/User/Port)
conn keygen myserver        # ssh-copy-id the key to that host
conn connect                # fzf-pick a host and connect (drops you into tmux)
conn bind-key               # install the prefix+s snippet-popup tmux keybinding
```

Then, inside any session started by `conn`:

```
conn snip add deploy        # write a snippet in $EDITOR
```

Press **prefix + s** in tmux → a numbered popup lists your snippets → type
the number, press enter → it's typed (and run) in the pane you were just in.

## Commands

```
conn [connect] [-m] [HOST|N]   connect (fzf-pick, or by number, if HOST omitted; -m = mosh)
conn list                      list hosts, numbered and grouped
conn add                       append a Host block to ~/.ssh/config
conn rm [HOST|N]               remove a Host (+ its secret/widget) from ~/.ssh/config
conn edit                      open ~/.ssh/config in $EDITOR
conn keygen [HOST...]          generate an ed25519 key, ssh-copy-id to HOSTs

conn snip add NAME             create/edit a snippet
conn snip ls                   list snippets
conn snip rm NAME              delete a snippet
conn snip [NAME]               pick a snippet, then copy / run local / run on host
conn bind-key [KEY]            install a tmux popup keybinding (default: s)

conn secret init               create an age identity for password holdouts
conn secret add HOST           encrypt a host password with age
conn secret rm HOST            remove a stored secret
conn secret ls                 list hosts with stored secrets

conn widgetize                 generate Termux:Widget launcher scripts
conn sync init                 create a git repo for snippets + secrets
conn sync remote URL           set the sync repo's remote
conn sync [push|pull]          commit + push/pull the sync repo

conn doctor                    check for required/optional dependencies
```

## How each piece works

### Connections live in `~/.ssh/config`

Nothing proprietary — `ssh` reads it natively, so `ProxyJump`, per-host keys,
`Port`, etc. all work for free. `conn add` appends a `Host` block; `conn edit`
opens the file in `$EDITOR` directly. `conn connect` (no args) fzf-picks from
the `Host` aliases in the file, skipping any wildcard (`*`/`?`) patterns.

`conn add` also asks, at the end, whether to store a password for the new
host — answering yes runs the same `age`-encrypted flow as `conn secret add`
(see below), so a password-only host can be fully set up in one pass instead
of two commands.

`conn rm [HOST|N]` removes a `Host` block (fzf-pick, or by number, if
omitted), along with any stored `age` secret and Termux:Widget shortcut for
that host.

### Numbering and groups

`conn list` prints every host as a numbered, grouped line:

```
 1) [work] web1
 2) [work] web2
 3) [personal] phone
 4) loose
```

The same numbers appear in the `conn connect` / `conn rm` fzf picker, and
`conn connect N` (or the shorthand `conn N`) connects straight to the Nth
host, skipping fzf entirely — handy for muscle-memory quick launches.
Numbers are just the current listing order, so they can shift as hosts are
added or removed; run `conn list` again if unsure.

`conn add` asks for an optional **Group** name. Groups are stored as a plain
`# Group: NAME` comment in `~/.ssh/config`, immediately before the `Host`
block(s) it covers — `ssh` ignores comments entirely, so this has zero effect
on how connections actually work. A group heading applies to every `Host`
that follows it until the next `# Group:` comment (or `# Group: ` with
nothing after the colon, which resets to ungrouped); `conn add` only writes
a new heading when the group actually changes from the previous entry, so
consecutive hosts in the same group don't repeat it. You can also add or
edit `# Group:` headings by hand via `conn edit`.

### Auth defaults to passphraseless ed25519 keys

`conn keygen` runs `ssh-keygen -t ed25519 -N "" -C "termux"` and, if given
hosts, `ssh-copy-id`s the public key to each. This makes `conn connect`
prompt-free. The accepted tradeoff: the private key is usable by anyone who
gets past your phone's lock screen / Termux's app sandbox — the lock screen
*is* the passphrase here. No ssh-agent, no passphrase machinery.

### tmux wrapper

`conn connect` puts you inside tmux automatically: if you're not already in
a tmux client, it runs `tmux new-session -A -s conn-<host> <ssh-or-mosh-cmd>`
— the `-A` means re-launching the same host's widget **attaches to the
already-running session** instead of spawning a duplicate. If you're already
inside tmux (e.g. jumping to another host from a snippet), it just execs the
connect command in the current pane.

### Snippets + injection (the part that matters most)

Snippets are plain shell scripts, one per file, in
`~/.config/conn/snippets/NAME.sh`. `conn snip add NAME` opens `$EDITOR` on
that file (creating it with a `# NAME` header if new).

`conn bind-key` (default key `s`) adds this to `~/.tmux.conf`:

```
bind-key s display-popup -E -w 80% -h 70% "conn snip-popup '#{pane_id}'"
```

`#{pane_id}` is expanded against the pane that was focused *when you pressed
the key* — before tmux switches you into the popup — so the popup script
knows exactly which live pane to inject into. Reload with
`tmux source-file ~/.tmux.conf` after installing (or start a new tmux
session).

The popup itself is a plain numbered menu, not fzf — it lists your snippets
as `1) name`, `2) name`, ... and you just type the number and press enter.
On an empty snippet list, or a bad number, it prints a message and waits for
a keypress instead of closing instantly (`display-popup -E` closes the
moment its command exits, so silent failures used to just flash and vanish).

Selecting a snippet runs `tmux send-keys -l` to type its literal contents
into that pane, followed by `Enter` — so multi-line snippets execute one line
at a time in the live shell, mirroring JuiceSSH's "pick a snippet, run it"
behavior. Snippets with side effects should be reviewed before you bind them.

From the CLI (outside a popup), `conn snip [NAME]` picks a snippet and offers
an action menu: **copy** (via `termux-clipboard-set`, if Termux:API is
installed), **run local** (`bash` the snippet on the phone), **run on host**
(`ssh HOST "$body"`, fzf-picking the host), and — if you're inside tmux —
**inject into pane** (send it to your current pane).

### Password holdouts via `age`

For hosts that force password auth:

```
conn secret init          # once per device: creates ~/.config/conn/age/identity.txt
conn secret add HOST      # prompts for the password, encrypts it to secrets/HOST.age
```

`conn connect HOST` automatically detects `secrets/HOST.age` and uses:

```
sshpass -f <(age -d -i <identity> secrets/HOST.age) ssh HOST
```

via process substitution — the decrypted password is only ever readable
through that anonymous pipe, so it never appears as a command-line argument
(no `ps` leak) and is never written to disk in plaintext. If no secret file
exists for a host, `conn` falls straight through to plain key-based `ssh`.
`-m`/mosh is ignored for password-only hosts (mosh needs a bootstrap over
ssh, which needs a key); `conn` warns and uses `ssh` instead.

#### Auto-installing a key so you stop needing the password

Both `conn add`'s "No key — password only?" prompt and standalone `conn
secret add HOST` follow up with: *"No key added — create one and use it
next time?"* (default yes). Answering yes generates the default key on this
device if it doesn't exist yet, and drops a `secrets/HOST.autokey` marker.

The next time `conn connect HOST` runs, it uses the stored password to run
`sshpass -f <(age -d ...) ssh-copy-id -i ~/.ssh/id_ed25519.pub HOST`
automatically, installing the key before the session starts. On success it
drops a `secrets/HOST.keyed` marker and that same connect proceeds over
plain `ssh` (or `mosh`, if you asked for it) instead of the password path —
every connect after that skips the stored password entirely. If the
install fails (host unreachable, etc.) `conn` falls back to the password
path for that session and retries the install next time.

The bootstrap uses `ssh-copy-id -o StrictHostKeyChecking=accept-new`, which
auto-accepts a host's key the first time it's seen (still refuses if a
known host's key later changes) so the install doesn't stall waiting for a
prompt you can't answer non-interactively.

### Termux:Widget launchers

`conn widgetize` writes one `~/.shortcuts/ssh-<host>.sh` per `Host` alias in
your ssh config, each just `exec conn connect <host>`, executable. Install
**Termux:Widget** from the **same source as Termux itself** (F-Droid or
GitHub — plugin apps must share Termux's signing key or Android refuses to
let them talk to each other), then long-press your home screen → Widgets →
Termux:Widget, and pick a shortcut. That's the "launch screen → tap → connect"
step JuiceSSH used to provide.

### Sync

`conn sync init` turns `~/.config/conn` into a git repo covering
`snippets/`, `secrets/*.age`, and the age `recipient.txt` (the *public* half
— safe to sync). Its `.gitignore` excludes `age/identity.txt` and any
`id_*` private key. `conn sync remote URL` sets the origin; `conn sync` (no
args) commits, pulls (rebase+autostash), and pushes.

**Golden rule of sync: only ciphertext travels.** The age identity (and any
private SSH key) must never go through the sync repo, GitHub, Drive,
Syncthing — wherever you point it. Move the identity file to a new device
by hand, once, over a channel you trust (e.g. `scp` between your own
devices, or physically).

## Security rules

- Passwords are **never** written to disk in plaintext — `age`-encrypted or
  nothing.
- Secrets are **never** passed via `sshpass -p` or any other command-line
  argument — always `-f <(...)`, so they never show up in `ps`.
- The age identity and any private SSH key **never** sync with the
  ciphertext they decrypt.
- `~/.ssh/config` and `~/.ssh/` are kept at `600`/`700`.

## Dependencies

Required: `bash`, `fzf`, `openssh`, `tmux`.
Optional: `mosh` (better mobile connections), `age` + `sshpass` (password
holdouts), `termux-api` (clipboard), `git` (sync), the Termux:Widget add-on
(home-screen launchers).

```
pkg install fzf openssh tmux mosh age sshpass git termux-api
```

## Non-goals

- No GUI / Android app / embedded terminal emulator — this is a CLI plus
  Termux:Widget launchers, on purpose.
- No password vault beyond one `age` file per secret — no daemon, no master
  database.
- No cloud account, license server, or telemetry. Everything is local files
  you can `cat`.
