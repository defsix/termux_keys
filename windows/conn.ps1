#!/usr/bin/env pwsh
# conn.ps1 - Windows/PowerShell companion to the Termux `conn` tool.
# Reads/writes the SAME git-synced ~/.config/conn repo (ssh_config,
# snippets, secrets) so hosts/snippets/passwords created on either
# platform are usable on both after `conn sync`.
#
# No tmux on Windows, so there is no snippet-injection-into-a-live-pane
# feature here -- clipboard copy is the (already-primary, on Termux too)
# way snippets get used. Password-holdout hosts get a one-time auto-key
# bootstrap via Posh-SSH (see Invoke-KeyBootstrap); the actual interactive
# session always goes through native ssh.exe/mosh, which will prompt for a
# password itself if no key ended up installed -- there's no Windows
# equivalent of sshpass for a full interactive PTY session, so this is the
# honest fallback rather than something half-working.

$ErrorActionPreference = 'Stop'

# --- paths -------------------------------------------------------------

$script:ConnHome = if ($env:CONN_HOME) { $env:CONN_HOME } else { Join-Path $HOME '.config/conn' }
$script:SnipDir = Join-Path $ConnHome 'snippets'
$script:SecretDir = Join-Path $ConnHome 'secrets'
$script:AgeDir = Join-Path $ConnHome 'age'
$script:AgeIdentity = if ($env:CONN_AGE_IDENTITY) { $env:CONN_AGE_IDENTITY } else { Join-Path $AgeDir 'identity.txt' }
$script:AgeRecipientFile = Join-Path $AgeDir 'recipient.txt'
# Canonical, git-synced Host-block file -- same file bin/conn (Termux) reads.
$script:SshConfig = if ($env:CONN_SSH_CONFIG) { $env:CONN_SSH_CONFIG } else { Join-Path $ConnHome 'ssh_config' }
# What ssh.exe/git/mosh actually read by default -- kept as just an
# `Include` pointer at SshConfig, mirroring bin/conn's approach exactly.
$script:RealSshConfig = if ($env:CONN_REAL_SSH_CONFIG) { $env:CONN_REAL_SSH_CONFIG } else { Join-Path $HOME '.ssh/config' }

function Write-ConnDie {
    param([string]$Message)
    Write-Host "conn: $Message" -ForegroundColor Red
    exit 1
}

function Test-ConnCommand {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-ConnDie "missing dependency: $Name ($InstallHint)"
    }
}

# --- ssh_config setup / migration (mirrors bin/conn's ensure_ssh_config_include) ---

function Initialize-ConnDirs {
    New-Item -ItemType Directory -Force -Path $SnipDir, $SecretDir, $AgeDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $SshConfig -Parent) | Out-Null
    Initialize-SshConfigInclude
}

function Initialize-SshConfigInclude {
    if (-not (Test-Path $SshConfig)) {
        New-Item -ItemType File -Path $SshConfig -Force | Out-Null
    }

    $includeLine = "Include $SshConfig"
    $realDir = Split-Path $RealSshConfig -Parent
    New-Item -ItemType Directory -Force -Path $realDir | Out-Null

    if ((Test-Path $RealSshConfig) -and (Select-String -Path $RealSshConfig -SimpleMatch $includeLine -Quiet)) {
        return
    }

    $existing = if (Test-Path $RealSshConfig) { Get-Content $RealSshConfig -Raw } else { $null }

    if ([string]::IsNullOrWhiteSpace($existing)) {
        Set-Content -Path $RealSshConfig -Value "# conn: hosts live in $SshConfig, included below`n$includeLine"
        return
    }

    # RealSshConfig has real content that isn't Include'd yet - migrate it,
    # merging with (not clobbering) anything already in SshConfig from a
    # sync pull, and always backing up the original first.
    $backup = "$RealSshConfig.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item -Path $RealSshConfig -Destination $backup

    $current = if (Test-Path $SshConfig) { Get-Content $SshConfig -Raw } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        Add-Content -Path $SshConfig -Value "`n# conn: merged in from $RealSshConfig during migration on $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')`n$existing"
    } else {
        Set-Content -Path $SshConfig -Value $existing
    }

    Set-Content -Path $RealSshConfig -Value "# conn: hosts live in $SshConfig, included below`n$includeLine"

    Write-Host "conn: moved your existing hosts from $RealSshConfig into $SshConfig (now tracked by conn sync)"
    Write-Host "conn: original backed up to $backup"
}

# --- ssh_config parsing (mirrors list_hosts_meta_raw / list_hosts_meta / load_host_index) ---

function Get-ConnHostsRaw {
    if (-not (Test-Path $SshConfig)) { return @() }
    $group = ''
    $results = @()
    foreach ($line in Get-Content $SshConfig) {
        if ($line -match '(?i)^\s*#\s*group\s*:\s*(.*)$') {
            $group = $matches[1].Trim()
            continue
        }
        if ($line -match '(?i)^\s*host\s+(.+)$') {
            $tokens = $matches[1].Trim() -split '\s+'
            foreach ($t in $tokens) {
                if ($t -notmatch '[*?]') {
                    $results += [PSCustomObject]@{ Alias = $t; Group = $group }
                }
            }
        }
    }
    return $results
}

function Get-ConnHosts {
    $raw = Get-ConnHostsRaw
    $results = @()
    foreach ($h in $raw) {
        $resolved = & ssh -G $h.Alias 2>$null
        $user = ($resolved | Where-Object { $_ -match '^user\s' } | Select-Object -First 1) -replace '^user\s+', ''
        $hostname = ($resolved | Where-Object { $_ -match '^hostname\s' } | Select-Object -First 1) -replace '^hostname\s+', ''
        $port = ($resolved | Where-Object { $_ -match '^port\s' } | Select-Object -First 1) -replace '^port\s+', ''
        $results += [PSCustomObject]@{ Alias = $h.Alias; Group = $h.Group; User = $user; HostName = $hostname; Port = $port }
    }
    return $results
}

function Get-ConnHostIndex {
    $meta = @(Get-ConnHosts)
    $lines = @()
    for ($i = 0; $i -lt $meta.Count; $i++) {
        $h = $meta[$i]
        $n = $i + 1
        $target = ''
        if ($h.User -and $h.HostName) { $target = " ($($h.User)@$($h.HostName))" }
        elseif ($h.HostName) { $target = " ($($h.HostName))" }
        if ($h.Group) {
            $lines += ('{0,2}) [{1}] {2}{3}' -f $n, $h.Group, $h.Alias, $target)
        } else {
            $lines += ('{0,2}) {1}{2}' -f $n, $h.Alias, $target)
        }
    }
    return [PSCustomObject]@{ Meta = $meta; Lines = $lines }
}

function Resolve-ConnHostByNumber {
    param([int]$Number)
    $idx = Get-ConnHostIndex
    if ($Number -lt 1 -or $Number -gt $idx.Meta.Count) {
        Write-ConnDie "no host numbered $Number (run: conn list)"
    }
    return $idx.Meta[$Number - 1].Alias
}

function Select-ConnHost {
    Test-ConnCommand fzf 'winget install fzf'
    $idx = Get-ConnHostIndex
    if ($idx.Meta.Count -eq 0) { Write-ConnDie "no hosts in $SshConfig yet - run: conn add" }
    $selection = $idx.Lines | & fzf --prompt='connect> ' --height='~40%' --reverse
    if (-not $selection) { return $null }
    if ($selection -match '^\s*(\d+)\)') {
        $n = [int]$matches[1]
        return $idx.Meta[$n - 1].Alias
    }
    return $null
}

# --- doctor --------------------------------------------------------------

function Invoke-ConnDoctor {
    $ok = $true
    function Test-Dep {
        param([string]$Name, [string]$Hint, [switch]$Required)
        if (Get-Command $Name -ErrorAction SilentlyContinue) {
            Write-Host ('  [x] {0,-24} found' -f $Name)
        } else {
            Write-Host ('  [ ] {0,-24} missing{1}' -f $Name, $(if ($Hint) { " ($Hint)" } else { '' }))
            if ($Required) { $script:ok = $false }
        }
    }
    Write-Host 'Required:'
    Test-Dep -Name 'ssh' -Hint 'Settings > Apps > Optional Features > OpenSSH Client' -Required
    Test-Dep -Name 'fzf' -Hint 'winget install fzf' -Required
    Write-Host 'Optional:'
    Test-Dep -Name 'mosh' -Hint 'not commonly available on Windows'
    Test-Dep -Name 'age' -Hint 'winget install FiloSottile.age'
    Test-Dep -Name 'git' -Hint 'winget install Git.Git'
    if (Get-Module -ListAvailable -Name Posh-SSH) {
        Write-Host ('  [x] {0,-24} found' -f 'Posh-SSH module')
    } else {
        Write-Host ('  [ ] {0,-24} missing (Install-Module Posh-SSH) - needed for password-holdout auto key install' -f 'Posh-SSH module')
    }
    if (Test-Path $SshConfig) { Write-Host "  [x] $SshConfig exists" } else { Write-Host "  [ ] $SshConfig missing (run: conn add)" }
    if (-not $ok) { Write-ConnDie 'missing required dependencies' }
    Write-Host 'conn: all required dependencies present'
}

# --- quick help ------------------------------------------------------------

function Show-ConnQuickHelp {
    Write-Host ''
    Write-Host 'conn quick reference:' -ForegroundColor Cyan
    Write-Host '  conn connect [HOST|N]   connect (fzf-pick, or by number, if omitted)'
    Write-Host '  conn add / edit / rm    manage the shared ssh_config'
    Write-Host '  conn snip               pick a snippet and copy it to the clipboard'
    Write-Host '  conn secret add HOST    store an age-encrypted password for it'
    Write-Host '  conn sync               push/pull hosts + snippets + secrets'
    Write-Host '  conn help               full command list'
}

# --- add / edit / rm / keygen ---------------------------------------------

function Invoke-ConnAdd {
    Initialize-ConnDirs
    $Alias = Read-Host 'Alias (Host name, e.g. myserver)'
    if (-not $Alias) { Write-ConnDie 'alias is required' }
    $HostName = Read-Host 'HostName (IP or DNS name)'
    if (-not $HostName) { Write-ConnDie 'HostName is required' }
    $User = Read-Host "User [$env:USERNAME]"
    if (-not $User) { $User = $env:USERNAME }
    $Port = Read-Host 'Port [22]'
    if (-not $Port) { $Port = 22 }
    $DefaultIdentity = Join-Path $HOME '.ssh/id_ed25519'
    $Identity = Read-Host "IdentityFile [$DefaultIdentity]"
    if (-not $Identity) { $Identity = $DefaultIdentity }
    $Group = Read-Host 'Group (optional, e.g. work)'

    $lastGroupRaw = (Get-ConnHostsRaw | Select-Object -Last 1).Group
    $lastGroup = if ($lastGroupRaw) { $lastGroupRaw } else { '' }
    $groupNorm = if ($Group) { $Group } else { '' }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    if ($groupNorm -ne $lastGroup) {
        $lines.Add("# Group: $Group")
    }
    $lines.Add("Host $Alias")
    $lines.Add("    HostName $HostName")
    $lines.Add("    User $User")
    $lines.Add("    Port $Port")
    $lines.Add("    IdentityFile $Identity")
    Add-Content -Path $SshConfig -Value ($lines -join "`n")
    Write-Host "conn: added Host '$Alias' to $SshConfig"

    $UsePw = Read-Host 'No key - password only? [y/N]'
    if ($UsePw -match '^[Yy]') {
        Invoke-ConnSecretAdd -HostAlias $Alias
    }
}

function Invoke-ConnEdit {
    Initialize-ConnDirs
    $Editor = if ($env:EDITOR) { $env:EDITOR } else { 'notepad' }
    & $Editor $SshConfig
}

# Mirrors bin/conn's cmd_rm awk logic exactly: drops just the target alias
# from a multi-alias Host line (keeping the others), or the whole block
# (Host line + its indented/blank body) when it's the only alias on that line.
function Remove-ConnHostFromConfig {
    param([string]$Target)
    $lines = @(Get-Content $SshConfig)
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*[Hh]ost\s+(.+)$') {
            $skip = $false
            $toks = $matches[1].Trim() -split '\s+'
            $matched = $false
            $rest = @()
            foreach ($t in $toks) {
                if ($t -eq $Target) { $matched = $true } else { $rest += $t }
            }
            if ($matched -and $rest.Count -eq 0) { $skip = $true; continue }
            if ($matched) { $out.Add('Host ' + ($rest -join ' ')); continue }
        } elseif ($skip) {
            if ($line -match '^\s*$' -or $line -match '^\s') { continue }
            $skip = $false
        }
        $out.Add($line)
    }
    Set-Content -Path $SshConfig -Value ($out -join "`n")
}

function Invoke-ConnRm {
    param([string]$HostArg)
    Initialize-ConnDirs
    if (-not $HostArg) { $HostArg = Select-ConnHost }
    if (-not $HostArg) { return }
    if ($HostArg -match '^\d+$') { $HostArg = Resolve-ConnHostByNumber -Number ([int]$HostArg) }

    $aliases = (Get-ConnHostsRaw).Alias
    if ($aliases -notcontains $HostArg) { Write-ConnDie "no such host: $HostArg" }

    Remove-ConnHostFromConfig -Target $HostArg
    Write-Host "conn: removed Host '$HostArg' from $SshConfig"

    $secretFile = Join-Path $SecretDir "$HostArg.age"
    if (Test-Path $secretFile) {
        Remove-Item $secretFile -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $SecretDir "$HostArg.keyed") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $SecretDir "$HostArg.autokey") -ErrorAction SilentlyContinue
        Write-Host "conn: removed stored secret for '$HostArg'"
    }
}

function Get-ConnDefaultKey {
    $key = Join-Path $HOME '.ssh/id_ed25519'
    New-Item -ItemType Directory -Force -Path (Split-Path $key -Parent) | Out-Null
    if (-not (Test-Path $key)) {
        Test-ConnCommand ssh-keygen 'part of the Windows OpenSSH Client feature'
        & ssh-keygen -t ed25519 -N '' -C 'windows' -f $key
    }
    return $key
}

function Invoke-ConnKeygen {
    param([string]$TargetHost)
    $key = Join-Path $HOME '.ssh/id_ed25519'
    $existed = Test-Path $key
    Get-ConnDefaultKey | Out-Null
    if ($existed) { Write-Host "conn: key already exists at $key" }
    if ($TargetHost) {
        Test-ConnCommand ssh-copy-id 'not bundled with Windows OpenSSH - install via Git for Windows, or copy the .pub manually'
        & ssh-copy-id -i "$key.pub" $TargetHost
    } else {
        Write-Host "conn: no host given - copy the key manually, e.g. by appending $key.pub to the remote's ~/.ssh/authorized_keys"
    }
}

# --- connect ---------------------------------------------------------------

# Uses the stored age-encrypted password (via Posh-SSH, never as a plaintext
# CLI arg) to install this device's public key on HOST, mirroring bin/conn's
# maybe_bootstrap_key -- but unlike Termux, that's ALL Posh-SSH is used for.
# The actual interactive session always goes through native ssh.exe/mosh
# below, which will prompt for the password itself if no key ended up
# installed -- there's no Windows equivalent of `sshpass -f <(...)` for a
# full interactive PTY session, so this is the honest fallback.
function Invoke-ConnKeyBootstrap {
    param([string]$HostAlias, [string]$SecretFile, [string]$KeyedMarker)
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Host "conn: Posh-SSH module not installed; skipping auto key-install for '$HostAlias' (Install-Module Posh-SSH)" -ForegroundColor Yellow
        return
    }
    Import-Module Posh-SSH -ErrorAction Stop

    if (-not (Test-Path $AgeIdentity)) {
        Write-Host "conn: no age identity at $AgeIdentity - run: conn secret init, or copy one from another device" -ForegroundColor Yellow
        return
    }
    Test-ConnCommand age 'winget install FiloSottile.age'

    $key = Get-ConnDefaultKey
    $pubKey = (Get-Content "$key.pub" -Raw).Trim()

    $password = & age -d -i $AgeIdentity $SecretFile
    if (-not $password) {
        Write-Host "conn: could not decrypt stored password for '$HostAlias'" -ForegroundColor Red
        return
    }

    $resolved = & ssh -G $HostAlias 2>$null
    $rHost = ($resolved | Where-Object { $_ -match '^hostname\s' } | Select-Object -First 1) -replace '^hostname\s+', ''
    $rUser = ($resolved | Where-Object { $_ -match '^user\s' } | Select-Object -First 1) -replace '^user\s+', ''
    $rPort = ($resolved | Where-Object { $_ -match '^port\s' } | Select-Object -First 1) -replace '^port\s+', ''
    if (-not $rPort) { $rPort = 22 }

    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($rUser, $secure)
    $password = $null

    Write-Host "conn: installing your SSH key on '$HostAlias' so you won't need the password next time..."
    $session = $null
    try {
        $session = New-SSHSession -ComputerName $rHost -Port $rPort -Credential $cred -AcceptKey -ErrorAction Stop
        $escapedKey = $pubKey.Replace("'", "'\''")
        $remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$escapedKey' ~/.ssh/authorized_keys || echo '$escapedKey' >> ~/.ssh/authorized_keys"
        $result = Invoke-SSHCommand -SSHSession $session -Command $remoteCmd
        if ($result.ExitStatus -eq 0) {
            New-Item -ItemType File -Path $KeyedMarker -Force | Out-Null
            Write-Host "conn: key installed on '$HostAlias' - future connects will skip the password"
        } else {
            Write-Host "conn: could not install the key automatically this time (remote command failed); continuing with a normal password prompt" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "conn: could not install the key automatically this time; continuing with a normal password prompt" -ForegroundColor Yellow
    } finally {
        if ($session) { Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue | Out-Null }
    }
}

function Invoke-ConnConnect {
    param([string[]]$Rest)
    Initialize-ConnDirs
    $UseMosh = $false
    $HostArg = $null
    foreach ($a in $Rest) {
        if ($a -eq '-m' -or $a -eq '--mosh') { $UseMosh = $true }
        elseif ($a -notmatch '^-') { $HostArg = $a }
    }
    if (-not $HostArg) { $HostArg = Select-ConnHost }
    if (-not $HostArg) { return }
    if ($HostArg -match '^\d+$') { $HostArg = Resolve-ConnHostByNumber -Number ([int]$HostArg) }

    $secretFile = Join-Path $SecretDir "$HostArg.age"
    $keyedMarker = Join-Path $SecretDir "$HostArg.keyed"
    $autokeyMarker = Join-Path $SecretDir "$HostArg.autokey"

    if ((Test-Path $secretFile) -and -not (Test-Path $keyedMarker) -and (Test-Path $autokeyMarker)) {
        Invoke-ConnKeyBootstrap -HostAlias $HostArg -SecretFile $secretFile -KeyedMarker $keyedMarker
    }

    if ($UseMosh) {
        Test-ConnCommand mosh 'not commonly available on Windows; consider WSL for this host instead'
        & mosh $HostArg
    } else {
        Test-ConnCommand ssh 'Settings > Apps > Optional Features > OpenSSH Client'
        & ssh $HostArg
    }
    Show-ConnQuickHelp
}

function Invoke-ConnList {
    $idx = Get-ConnHostIndex
    if ($idx.Meta.Count -eq 0) {
        Write-Host "conn: no hosts in $SshConfig yet - run: conn add"
        return
    }
    $idx.Lines | ForEach-Object { Write-Host $_ }
}

# --- snippets ---------------------------------------------------------------
# No tmux on Windows, so there's no live-pane injection here -- clipboard
# copy is the primary (and on Termux, already the *reliable*) way snippets
# get used. "run local" needs bash on PATH (Git for Windows/WSL) since
# snippets are plain .sh scripts shared cross-platform via the same repo.

function Get-ConnSnipFile {
    param([string]$Name)
    return Join-Path $SnipDir "$Name.sh"
}

function Invoke-ConnSnipAdd {
    param([string]$Name)
    if (-not $Name) { Write-ConnDie 'usage: conn snip add NAME' }
    Initialize-ConnDirs
    $file = Get-ConnSnipFile -Name $Name
    if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file -Force | Out-Null }
    $Editor = if ($env:EDITOR) { $env:EDITOR } else { 'notepad' }
    & $Editor $file
    Write-Host "conn: saved snippet '$Name' -> $file"
}

function Invoke-ConnSnipLs {
    Initialize-ConnDirs
    Get-ChildItem -Path $SnipDir -Filter '*.sh' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
}

function Invoke-ConnSnipRm {
    param([string]$Name)
    if (-not $Name) { Write-ConnDie 'usage: conn snip rm NAME' }
    $file = Get-ConnSnipFile -Name $Name
    if (-not (Test-Path $file)) { Write-ConnDie "no such snippet: $Name" }
    Remove-Item $file
    Write-Host "conn: removed snippet '$Name'"
}

function Select-ConnSnippet {
    Test-ConnCommand fzf 'winget install fzf'
    $names = @(Invoke-ConnSnipLs)
    if ($names.Count -eq 0) { Write-ConnDie 'no snippets yet - run: conn snip add NAME' }
    return $names | & fzf --prompt='snippet> ' --height='~40%' --reverse
}

function Invoke-ConnSnipAction {
    param([string]$Name)
    if (-not $Name) { $Name = Select-ConnSnippet }
    if (-not $Name) { return }
    $file = Get-ConnSnipFile -Name $Name
    if (-not (Test-Path $file)) { Write-ConnDie "no such snippet: $Name" }
    $body = (Get-Content $file -Raw)
    if ($null -eq $body) { $body = '' }

    Test-ConnCommand fzf 'winget install fzf'
    $choice = @('copy', 'run local', 'run on host') | & fzf --prompt="$Name> " --height='~30%' --reverse

    switch ($choice) {
        'copy' {
            Set-Clipboard -Value $body
            Write-Host "conn: copied '$Name' to clipboard"
        }
        'run local' {
            if (Get-Command bash -ErrorAction SilentlyContinue) {
                & bash $file
            } else {
                Write-Host 'conn: no bash found to run this locally (install Git for Windows or WSL) - printing it instead:' -ForegroundColor Yellow
                Write-Host $body
            }
        }
        'run on host' {
            $h = Select-ConnHost
            if (-not $h) { return }
            Test-ConnCommand ssh 'Settings > Apps > Optional Features > OpenSSH Client'
            & ssh $h $body
        }
        default { return }
    }
    Show-ConnQuickHelp
}

function Invoke-ConnSnip {
    param([string[]]$Rest)
    if ($Rest.Count -eq 0) { Invoke-ConnSnipAction; return }
    switch ($Rest[0]) {
        'add' { Invoke-ConnSnipAdd -Name $Rest[1] }
        'ls' { Invoke-ConnSnipLs }
        'rm' { Invoke-ConnSnipRm -Name $Rest[1] }
        default { Invoke-ConnSnipAction -Name $Rest[0] }
    }
}

# --- secrets (age password holdouts) ----------------------------------------

function ConvertFrom-ConnSecureString {
    param([securestring]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-ConnSecretInit {
    Test-ConnCommand age-keygen 'winget install FiloSottile.age'
    Initialize-ConnDirs
    if (Test-Path $AgeIdentity) { Write-ConnDie "identity already exists: $AgeIdentity" }
    & age-keygen -o $AgeIdentity 2>$null
    $pubLine = Get-Content $AgeIdentity | Where-Object { $_ -match '^# public key:' } | Select-Object -First 1
    $recipient = ($pubLine -split '\s+')[-1]
    Set-Content -Path $AgeRecipientFile -Value $recipient
    Write-Host "conn: created age identity at $AgeIdentity (never sync this file)"
    Write-Host "conn: recipient (public, safe to sync) saved to $AgeRecipientFile"
}

function Get-ConnAgeRecipient {
    if (-not (Test-Path $AgeRecipientFile)) { Write-ConnDie "no age recipient at $AgeRecipientFile - run: conn secret init" }
    return (Get-Content $AgeRecipientFile -Raw).Trim()
}

# Mirrors bin/conn's offer_autokey: on the next connect, the stored password
# is used once (via Posh-SSH) to install this device's key, after which
# ordinary key-based ssh/mosh takes over.
function Invoke-ConnOfferAutokey {
    param([string]$HostAlias)
    $autoKey = Read-Host 'No key added - create one and use it next time? [Y/n]'
    if ($autoKey -notmatch '^[Nn]') {
        Get-ConnDefaultKey | Out-Null
        New-Item -ItemType File -Path (Join-Path $SecretDir "$HostAlias.autokey") -Force | Out-Null
        Write-Host "conn: will install your key on '$HostAlias' automatically on your next connect"
    }
}

function Invoke-ConnSecretAdd {
    param([string]$HostAlias)
    if (-not $HostAlias) { Write-ConnDie 'usage: conn secret add HOST' }
    Test-ConnCommand age 'winget install FiloSottile.age'
    Initialize-ConnDirs

    $secretFile = Join-Path $SecretDir "$HostAlias.age"
    if (Test-Path $secretFile) {
        $overwrite = Read-Host "A password is already stored for '$HostAlias' - overwrite it? [y/N]"
        if ($overwrite -notmatch '^[Yy]') {
            Write-Host "conn: kept the existing password for '$HostAlias'"
            return
        }
    }

    if (-not (Test-Path $AgeRecipientFile)) { Invoke-ConnSecretInit }
    $recipient = Get-ConnAgeRecipient

    $secure = Read-Host "Password for $HostAlias" -AsSecureString
    $plain = ConvertFrom-ConnSecureString -Secure $secure
    if (-not $plain) { Write-ConnDie 'empty password, aborting' }
    $plain | & age -r $recipient -o $secretFile
    $plain = $null

    Write-Host "conn: stored encrypted password for '$HostAlias' -> $secretFile"
    Invoke-ConnOfferAutokey -HostAlias $HostAlias
}

function Invoke-ConnSecretRm {
    param([string]$HostAlias)
    if (-not $HostAlias) { Write-ConnDie 'usage: conn secret rm HOST' }
    Remove-Item (Join-Path $SecretDir "$HostAlias.age") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $SecretDir "$HostAlias.keyed") -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $SecretDir "$HostAlias.autokey") -ErrorAction SilentlyContinue
    Write-Host "conn: removed stored secret for '$HostAlias'"
}

function Invoke-ConnSecretLs {
    Initialize-ConnDirs
    Get-ChildItem -Path $SecretDir -Filter '*.age' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
}

function Invoke-ConnSecret {
    param([string[]]$Rest)
    switch ($Rest[0]) {
        'init' { Invoke-ConnSecretInit }
        'add' { Invoke-ConnSecretAdd -HostAlias $Rest[1] }
        'rm' { Invoke-ConnSecretRm -HostAlias $Rest[1] }
        'ls' { Invoke-ConnSecretLs }
        default { Write-ConnDie 'usage: conn secret {init|add HOST|rm HOST|ls}' }
    }
}

# --- sync --------------------------------------------------------------

function Invoke-ConnSyncInit {
    Test-ConnCommand git 'winget install Git.Git'
    Initialize-ConnDirs
    & git -C $ConnHome rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "conn: $ConnHome is already a git repo"
        return
    }
    & git -C $ConnHome init | Out-Null
    $gitignore = "# never sync the decryption key`nage/identity.txt`n# never sync private keys, only public halves`nid_*`n!id_*.pub`n*.pem`n"
    Set-Content -Path (Join-Path $ConnHome '.gitignore') -Value $gitignore -NoNewline
    & git -C $ConnHome add snippets secrets ssh_config .gitignore 2>$null
    if (Test-Path $AgeRecipientFile) { & git -C $ConnHome add $AgeRecipientFile }
    & git -C $ConnHome commit -m 'conn: initial sync repo' 2>$null | Out-Null
    Write-Host "conn: initialized sync repo at $ConnHome"
    Write-Host 'conn: set a remote with: conn sync remote <url>'
}

function Invoke-ConnSyncRemote {
    param([string]$Url)
    Test-ConnCommand git 'winget install Git.Git'
    if (-not $Url) { Write-ConnDie 'usage: conn sync remote URL' }
    & git -C $ConnHome remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & git -C $ConnHome remote set-url origin $Url
    } else {
        & git -C $ConnHome remote add origin $Url
    }
    Write-Host "conn: sync remote set to $Url"
}

function Invoke-ConnSyncDefault {
    Test-ConnCommand git 'winget install Git.Git'
    & git -C $ConnHome add -A
    $status = & git -C $ConnHome status --porcelain
    if ($status) {
        & git -C $ConnHome commit -m "conn sync $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-ConnDie "commit failed (see the git error above - first time here? run: git -C $ConnHome config user.email you@example.com ; git -C $ConnHome config user.name 'Your Name')"
        }
    } else {
        Write-Host 'conn: nothing to commit'
    }
    & git -C $ConnHome remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & git -C $ConnHome rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & git -C $ConnHome pull --rebase --autostash
        }
        & git -C $ConnHome push -u origin HEAD
    } else {
        Write-Host 'conn: no remote configured; run: conn sync remote <url>'
    }
}

function Invoke-ConnSync {
    param([string[]]$Rest)
    switch ($Rest[0]) {
        'init' { Invoke-ConnSyncInit }
        'remote' { Invoke-ConnSyncRemote -Url $Rest[1] }
        'push' { Test-ConnCommand git 'winget install Git.Git'; & git -C $ConnHome push -u origin HEAD }
        'pull' { Test-ConnCommand git 'winget install Git.Git'; & git -C $ConnHome pull --rebase --autostash }
        default { Invoke-ConnSyncDefault }
    }
}

# --- help / dispatch ---------------------------------------------------

function Show-ConnUsage {
    @'
conn.ps1 - Windows companion to the Termux `conn` tool
Shares the same git-synced ~/.config/conn (ssh_config, snippets, secrets).

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

  conn secret init            create an age identity for password holdouts
  conn secret add HOST        encrypt a host password with age (offers to
                               auto-install a key via Posh-SSH on next connect)
  conn secret rm HOST         remove a stored secret
  conn secret ls              list hosts with stored secrets

  conn sync init               create/verify the git repo for ssh_config + snippets + secrets
  conn sync remote URL         set the sync repo's remote
  conn sync [push|pull]        commit + push/pull the sync repo

  conn doctor                  check for required/optional dependencies
  conn help                    show this message
'@ | Write-Host
}

function Invoke-Conn {
    param([Parameter(Position = 0)][string]$Command, [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not $Rest) { $Rest = @() }
    Initialize-ConnDirs
    if (-not $Command) { $Command = 'connect' }
    switch ($Command) {
        'connect' { Invoke-ConnConnect -Rest $Rest }
        'list' { Invoke-ConnList }
        'add' { Invoke-ConnAdd }
        { $_ -in @('rm', 'delete') } { Invoke-ConnRm -HostArg $Rest[0] }
        'edit' { Invoke-ConnEdit }
        'keygen' { Invoke-ConnKeygen -TargetHost $Rest[0] }
        'snip' { Invoke-ConnSnip -Rest $Rest }
        'secret' { Invoke-ConnSecret -Rest $Rest }
        'sync' { Invoke-ConnSync -Rest $Rest }
        'doctor' { Invoke-ConnDoctor }
        { $_ -in @('help', '-h', '--help') } { Show-ConnUsage }
        '-m' { Invoke-ConnConnect -Rest (@('-m') + $Rest) }
        default {
            if ($Command -like '-*') { Write-ConnDie "unknown flag: $Command (see: conn help)" }
            # allow `conn HOST` as shorthand for `conn connect HOST`
            Invoke-ConnConnect -Rest (@($Command) + $Rest)
        }
    }
}

# Only auto-dispatch when the script is actually run (`conn.ps1 connect host`
# or via a wrapper function calling `& $path @args`), not when dot-sourced --
# dot-sourcing (`. ./conn.ps1`) just defines the functions above, which is
# how this file's own test suite exercises individual functions directly.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Conn @args
}
