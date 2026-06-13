<#
.SYNOPSIS
    Obsidian Git Launcher - Core Sync Script
    All business logic lives here. launch.bat is a thin wrapper only.

.DESCRIPTION
    Launch flow:
      1. Read config.ini
      2. Pull latest changes (git fetch + pull --rebase)
      3. Launch Obsidian and wait for it to close
      4. Commit all changes (git add -A + commit)
      5. Push to remote
      6. Exit

    On any error: log it clearly, stop execution, exit non-zero.
    Never silently continue past a failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------
# PATHS
# -----------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path $ScriptDir "config.ini"
$LogDir = Join-Path $ScriptDir "logs"

# Session-level log: one per day, captures the full run across all vaults.
# Each vault also gets its own log file (see Get-VaultLogFile).
$LogFile = Join-Path $LogDir ("session_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))

# -----------------------------------------
# LOGGING SETUP
# -----------------------------------------
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

# Session start time - used in the summary footer.
$script:SessionStart = Get-Date

# Written to log once at startup; also tells the user where their log lives.
Start-Transcript -Path $LogFile -Append | Out-Null

# -- Write-Log ----------------------------------------------------------------
# Central log function. All output goes through here so the transcript captures
# everything, and color keeps the terminal readable at a glance.
#
#   INFO    - white     normal progress
#   OK      - green     step succeeded
#   WARN    - yellow    non-fatal issue, user should know
#   ERROR   - red       fatal, script will stop after this
#   DRYRUN  - cyan      action skipped because dry-run is on
#
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $label = $Level.PadRight(6)          # fixed-width so columns align in the log
    $line = "[$ts] [$label] $Message"

    $color = switch ($Level) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "DRYRUN" { "Cyan" }
        default { "White" }
    }

    Write-Host $line -ForegroundColor $color
}

# -- Write-VaultLog ------------------------------------------------------------
# Appends a timestamped line to the per-vault log file AND calls Write-Log so
# the session transcript captures it too. No nested Start-Transcript needed.
# $script:CurrentVaultLog is set by Sync-Vault at the start of each vault sync.
$script:CurrentVaultLog = $null

function Write-VaultLog {
    param([string]$Message, [string]$Level = "INFO")

    Write-Log $Message $Level

    if ($script:CurrentVaultLog) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $label = $Level.PadRight(6)
        $line = "[$ts] [$label] $Message"
        Add-Content -Path $script:CurrentVaultLog -Value $line -Encoding UTF8
    }
}

# -- Fail ---------------------------------------------------------------------
# Hard stop. Prints the error, tells the user where the log is, exits non-zero.
function Fail {
    param([string]$Message, [string]$VaultName = "")

    Write-Host "" # blank line for breathing room
    if ($VaultName) { Write-Log "Vault: $VaultName" "ERROR" }
    Write-Log $Message "ERROR"
    Write-Log "Log file: $LogFile" "ERROR"
    Write-Log "Exiting." "ERROR"
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

# -- Session header ------------------------------------------------------------
# Written once at the top of every run so logs are easy to scan by date.
function Write-SessionHeader {
    param([bool]$IsDryRun)

    $mode = if ($IsDryRun) { "DRY RUN - no changes will be written" } else { "LIVE" }
    Write-Log "=================================================="
    Write-Log "  Obsidian Git Launcher"
    Write-Log "  Mode    : $mode"
    Write-Log "  Log     : $LogFile"
    Write-Log "  Started : $($script:SessionStart.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "=================================================="
}

# -- Session summary -----------------------------------------------------------
# Printed at normal exit so the user gets a one-glance confirmation.
function Write-SessionSummary {
    param(
        [string[]]$VaultsSynced,
        [hashtable[]]$VaultsFailed,
        [bool]$IsDryRun
    )

    $elapsed = [math]::Round(((Get-Date) - $script:SessionStart).TotalSeconds, 1)
    $mode = if ($IsDryRun) { " (dry run - nothing was pushed)" } else { "" }

    Write-Log "=================================================="
    Write-Log "  Done in ${elapsed}s$mode"

    foreach ($v in $VaultsSynced) {
        Write-Log "  OK $v" "OK"
    }
    foreach ($f in $VaultsFailed) {
        Write-Log "  FAIL $($f.Name) - $($f.Reason)" "ERROR"
    }

    Write-Log "  Log     : $LogFile"
    Write-Log "=================================================="
}

# -----------------------------------------
# CONFIG PARSER
# -----------------------------------------

# Returns a hashtable of [SectionName => @{key=value}] AND an ordered list of
# vault section names. Hashtable keys have no guaranteed order in PowerShell;
# we need insertion order so vaults sync in the same sequence as the file.
function Read-IniFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        # First run - hand off to the interactive setup wizard instead of failing.
        Invoke-SetupWizard -OutputPath $Path
    }

    $ini = @{}
    $sectionOrder = [System.Collections.Generic.List[string]]::new()  # preserves INI file order
    $currentSection = "_root"

    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -match '^\s*[;#]' -or $line -eq "") { continue }

        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1].Trim()
            $ini[$currentSection] = @{}
            # Track non-root sections in order; duplicates are silently last-write-wins.
            if ($currentSection -ne "_root" -and $sectionOrder -notcontains $currentSection) {
                $sectionOrder.Add($currentSection)
            }
        }
        elseif ($line -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            if (-not $ini.ContainsKey($currentSection)) { $ini[$currentSection] = @{} }
            $ini[$currentSection][$key] = $value
        }
    }

    # Attach the ordered section list as a synthetic key so callers don't need
    # a second return value. The leading underscore keeps it out of vault loops.
    $ini["_sectionOrder"] = $sectionOrder

    return $ini
}

# Validate that a vault section has all required keys.
# Returns a list of missing key names. Empty list = valid.
function Get-MissingVaultKeys {
    param([hashtable]$VaultConfig)

    $required = @("Path", "Branch", "ObsidianPath")
    return ($required | Where-Object { -not $VaultConfig.ContainsKey($_) -or -not $VaultConfig[$_] })
}

# Return the per-vault log file path for a given vault name.
# Vault name is sanitised so it is safe as a filename.
function Get-VaultLogFile {
    param([string]$VaultName)

    $safe = $VaultName -replace '[\\/:*?"<>|]', '_'
    return Join-Path $LogDir ("${safe}_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
}

# -----------------------------------------
# FIRST-RUN SETUP WIZARD
# -----------------------------------------
function Invoke-SetupWizard {
    param([string]$OutputPath)

    # -- Banner -------------------------------
    Write-Host ""
    Write-Host "  +==========================================+"
    Write-Host "  |     Obsidian Git Launcher - First Run    |"
    Write-Host "  |  Let's set up your vault sync in 1 min.  |"
    Write-Host "  +==========================================+"
    Write-Host ""
    Write-Host "  No config.ini found. This wizard will create one."
    Write-Host "  Press Ctrl+C at any time to cancel."
    Write-Host ""

    # -- Locate Obsidian.exe (once, shared across all vaults) --
    $obsidianPath = Find-ObsidianExe

    # -- Vault collection loop -----------------
    $vaults = [System.Collections.Generic.List[hashtable]]::new()
    $addMore = $true
    $vaultNum = 1

    while ($addMore) {
        Write-Host "  -- Vault $vaultNum -----------------------------"
        $vault = Read-VaultConfig -VaultNumber $vaultNum -ObsidianPath $obsidianPath
        $vaults.Add($vault)

        Write-Host ""
        $another = Read-PromptValue `
            -Prompt "  Add another vault? (y/N)" `
            -Default "N" `
            -AllowEmpty $true

        $addMore = ($another -match '^[Yy]$')
        $vaultNum++
        Write-Host ""
    }

    # -- Global settings -----------------------
    Write-Host "  -- Global Settings -------------------------"
    $dryRun = Read-PromptValue `
        -Prompt "  Enable dry-run mode? Logs actions without pushing. (y/N)" `
        -Default "N" `
        -AllowEmpty $true
    $dryRunValue = if ($dryRun -match '^[Yy]$') { "true" } else { "false" }

    # -- Write config.ini ----------------------
    Write-IniConfig -OutputPath $OutputPath -Vaults $vaults -DryRun $dryRunValue

    Write-Host ""
    Write-Host "  [OK] config.ini created at: $OutputPath"
    Write-Host "  Starting sync now..."
    Write-Host ""
}

# Prompt for one vault's settings and return a hashtable.
function Read-VaultConfig {
    param([int]$VaultNumber, [string]$ObsidianPath)

    # -- Section name --------------------------
    $defaultName = "Vault$VaultNumber"
    $sectionName = Read-PromptValue `
        -Prompt "  Vault name (used in logs) [$defaultName]" `
        -Default $defaultName `
        -AllowEmpty $true
    # Strip characters that would break INI section syntax
    $sectionName = $sectionName -replace '[\[\]=;#]', '' | ForEach-Object { $_.Trim() }
    if (-not $sectionName) { $sectionName = $defaultName }

    # -- Vault path ----------------------------
    $vaultPath = ""
    do {
        $vaultPath = Read-PromptValue `
            -Prompt "  Vault folder path (e.g. C:\Vaults\Personal)" `
            -Default "" `
            -AllowEmpty $false

        if (-not (Test-Path $vaultPath)) {
            Write-Host "  [WARN] Path does not exist. Check the path and try again." -ForegroundColor Yellow
            $vaultPath = ""
        }
    } while (-not $vaultPath)

    # -- Git repo check / offer to init --------
    $gitDir = Join-Path $vaultPath ".git"
    if (-not (Test-Path $gitDir)) {
        Write-Host ""
        Write-Host "  [WARN] This folder is not a git repo yet." -ForegroundColor Yellow
        $doInit = Read-PromptValue `
            -Prompt "  Initialise git repo here now? (Y/n)" `
            -Default "Y" `
            -AllowEmpty $true

        if ($doInit -notmatch '^[Nn]$') {
            & git -C $vaultPath init 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [ERROR] git init failed. Is Git installed?" -ForegroundColor Red
                exit 1
            }
            Write-Host "  [OK] git repo initialised."
        }
        else {
            # User declined - warn but continue. Sync-Vault will catch it later.
            Write-Host "  [WARN] Skipping git init. Sync will fail unless the folder is a git repo." -ForegroundColor Yellow
        }
    }

    # -- Remote URL ----------------------------
    $remote = ""
    do {
        $remote = Read-PromptValue `
            -Prompt "  GitHub repo URL (e.g. https://github.com/you/vault.git or git@github.com:you/vault.git)" `
            -Default "" `
            -AllowEmpty $false

        if ($remote -match '[\r\n]') {
            Write-Host "  [WARN] URL should contain no line breaks. Try again." -ForegroundColor Yellow
            $remote = ""
        }
    } while (-not $remote)

    # -- Branch --------------------------------
    $branch = Read-PromptValue `
        -Prompt "  Branch name [main]" `
        -Default "main" `
        -AllowEmpty $true
    if (-not $branch) { $branch = "main" }

    # -- Wire up remote (if repo was just init'd or has no remote) --
    $existingRemote = & git -C $vaultPath remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $existingRemote) {
        & git -C $vaultPath remote add origin $remote 2>&1 | Out-Null
        Write-Host "  [OK] Remote 'origin' set to $remote"
    }
    else {
        Write-Host "  [INFO] Remote 'origin' already exists: $existingRemote"
    }

    return @{
        SectionName  = $sectionName
        Path         = $vaultPath
        Remote       = $remote
        Branch       = $branch
        ObsidianPath = $ObsidianPath
    }
}

# Locate Obsidian.exe - check common install paths, then ask the user.
function Find-ObsidianExe {
    $candidates = @(
        "$env:LOCALAPPDATA\Obsidian\Obsidian.exe",
        "$env:PROGRAMFILES\Obsidian\Obsidian.exe",
        "${env:PROGRAMFILES(x86)}\Obsidian\Obsidian.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            Write-Host "  [OK] Obsidian found at: $candidate"
            $confirm = Read-PromptValue `
                -Prompt "  Use this path? (Y/n)" `
                -Default "Y" `
                -AllowEmpty $true
            if ($confirm -notmatch '^[Nn]$') {
                return $candidate
            }
        }
    }

    # Manual entry fallback
    $obsidianPath = ""
    do {
        $obsidianPath = Read-PromptValue `
            -Prompt "  Path to Obsidian.exe" `
            -Default "" `
            -AllowEmpty $false

        if (-not (Test-Path $obsidianPath)) {
            Write-Host "  [WARN] File not found at that path. Try again." -ForegroundColor Yellow
            $obsidianPath = ""
        }
    } while (-not $obsidianPath)

    return $obsidianPath
}

# Generic prompt helper - shows default, returns trimmed input or default if empty.
function Read-PromptValue {
    param(
        [string]$Prompt,
        [string]$Default,
        [bool]$AllowEmpty = $false
    )

    while ($true) {
        Write-Host -NoNewline "$Prompt : "
        $raw = $Host.UI.ReadLine()
        $value = $raw.Trim()

        if ($value -eq "" -and $Default -ne "") {
            return $Default
        }
        if ($value -ne "" -or $AllowEmpty) {
            return $value
        }
        Write-Host "  [WARN] This field is required." -ForegroundColor Yellow
    }
}

# Serialise collected vault data to a clean config.ini file.
function Write-IniConfig {
    param(
        [string]$OutputPath,
        [System.Collections.Generic.List[hashtable]]$Vaults,
        [string]$DryRun
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("; Obsidian Git Launcher - config.ini")
    $lines.Add("; Generated by setup wizard on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("; Edit this file any time to update your settings.")
    $lines.Add("")

    foreach ($vault in $Vaults) {
        # Strip CR/LF and block INI metacharacters (= ; #) from all written values.
        $safeSectionName = $vault.SectionName -replace '[\r\n=;#]', ''
        $safePath = $vault.Path -replace '[\r\n]', ''
        $safeRemote = $vault.Remote -replace '[\r\n]', ''
        $safeBranch = $vault.Branch -replace '[\r\n=;#]', ''
        $safeObsidianPath = $vault.ObsidianPath -replace '[\r\n]', ''

        $lines.Add("[$safeSectionName]")
        $lines.Add("Path=$safePath")
        $lines.Add("Remote=$safeRemote")
        $lines.Add("Branch=$safeBranch")
        $lines.Add("ObsidianPath=$safeObsidianPath")
        $lines.Add("")
    }

    $lines.Add("[Settings]")
    $lines.Add("DryRun=$DryRun")
    $lines.Add("BackupEnabled=false")
    $lines.Add("BackupDir=.\backups")
    $lines.Add("CommitMessage=vault sync: %DATE% %TIME%")

    # Write atomically - build in memory, write once.
    $lines | Set-Content -Path $OutputPath -Encoding UTF8
}

# -----------------------------------------
# GIT HELPERS
# -----------------------------------------
function Test-GitIdentity {
    param([string]$VaultPath)

    $name = & git -C $VaultPath config user.name 2>&1
    $email = & git -C $VaultPath config user.email 2>&1

    if (-not $name -or -not $email -or $LASTEXITCODE -ne 0) {
        Write-Log "Git identity is not configured. Setting a repository-local fallback..." "WARN"
        & git -C $VaultPath config local user.name "Obsidian Launcher" 2>&1 | Out-Null
        & git -C $VaultPath config local user.email "launcher@obsidian.local" 2>&1 | Out-Null
        Write-Log "Configured local user: 'Obsidian Launcher <launcher@obsidian.local>'" "OK"
    }
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [string]$WorkDir,
        # When true: log the command but do not execute it.
        # Used for write operations (add, commit, push) in dry-run mode.
        # Read-only commands (fetch, pull --rebase) are also skipped in dry-run
        # because they hit the network and could change local state.
        [bool]$SkipInDryRun = $false,
        [bool]$IsDryRun = $false
    )

    $cmdStr = "git $($Arguments -join ' ')"

    if ($SkipInDryRun -and $IsDryRun) {
        Write-Log "[would run] $cmdStr" "DRYRUN"
        return @()   # return empty so callers that use the result don't break
    }

    Write-Log "$cmdStr"

    # Capture stdout and stderr separately so real error text surfaces cleanly.
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $stdout = & git -C $WorkDir @Arguments 2>$stderrFile
    $exitCode = $LASTEXITCODE
    $stderrContent = Get-Content $stderrFile -ErrorAction SilentlyContinue
    Remove-Item $stderrFile -ErrorAction SilentlyContinue

    # Echo both streams so the transcript captures them.
    if ($stdout) { $stdout        | ForEach-Object { Write-Log "  $_" } }
    if ($stderrContent) { $stderrContent | ForEach-Object { Write-Log "  $_" "WARN" } }

    if ($exitCode -ne 0) {
        $detail = if ($stderrContent) { $stderrContent -join "`n" } else { $stdout -join "`n" }
        # throw instead of Fail - lets the per-vault catch in MAIN record this
        # failure and continue to the next vault rather than exiting the process.
        throw "$cmdStr failed (exit $exitCode)`n$detail"
    }

    return $stdout
}

# Check porcelain status for conflict markers (UU, AA, DD, AU, UA, DU, UD).
function Test-Conflicts {
    param([string]$VaultPath)

    $status = & git -C $VaultPath status --porcelain 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git status --porcelain failed (exit $LASTEXITCODE) in: $VaultPath"
    }
    $conflicts = $status | Where-Object { $_ -match '^(UU|AA|DD|AU|UA|DU|UD)' }

    if ($conflicts) {
        Write-Log "Merge conflicts detected - manual resolution required:" "ERROR"
        $conflicts | ForEach-Object { Write-Log "  conflict: $_" "ERROR" }
        Write-Log "  To resolve:" "ERROR"
        Write-Log "    1. Open the conflicted files and fix the markers" "ERROR"
        Write-Log "    2. git add -A" "ERROR"
        Write-Log "    3. git rebase --continue" "ERROR"
        Write-Log "    4. Re-run launch.bat" "ERROR"
        throw "Merge conflict in: $VaultPath"
    }
}

# Detect a stuck mid-rebase state (REBASE_HEAD exists in the git dir).
# This can happen if the user Ctrl+C'd a previous run during pull --rebase.
function Test-RebaseInProgress {
    param([string]$VaultPath)

    $rawGitDir = & git -C $VaultPath rev-parse --git-dir 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse --git-dir failed (exit $LASTEXITCODE) in: $VaultPath"
    }
    # rev-parse --git-dir returns a path relative to $VaultPath when called
    # via -C (e.g. ".git"). Resolve it to absolute before Join-Path so
    # Test-Path works regardless of the script's working directory.
    $gitDir = if ([System.IO.Path]::IsPathRooted($rawGitDir)) {
        $rawGitDir
    }
    else {
        Join-Path $VaultPath $rawGitDir
    }

    $rebaseHead = Join-Path $gitDir "REBASE_HEAD"
    $rebaseMerge = Join-Path $gitDir "rebase-merge"
    $rebaseApply = Join-Path $gitDir "rebase-apply"

    if ((Test-Path $rebaseHead) -or (Test-Path $rebaseMerge) -or (Test-Path $rebaseApply)) {
        throw "Rebase already in progress in: $VaultPath`nRun: git rebase --continue  (after fixing conflicts)`n  or: git rebase --abort     (to reset to pre-pull state)`nThen re-run launch.bat."
    }
}

# -----------------------------------------
# VAULT SYNC
# -----------------------------------------
function Sync-Vault {
    param(
        [string]$VaultName,
        [hashtable]$VaultConfig,
        [hashtable]$Settings,
        # Path to this vault's dedicated log file.
        # Written alongside the session transcript for isolated debugging.
        [string]$VaultLog
    )

    $vaultPath = $VaultConfig["Path"]
    $branch = $VaultConfig["Branch"]
    $obsidianPath = $VaultConfig["ObsidianPath"]
    $dryRun = ($Settings -and $Settings["DryRun"] -eq "true")
    $commitMsg = if ($Settings -and $Settings["CommitMessage"]) {
        $Settings["CommitMessage"] `
            -replace "%DATE%", (Get-Date -Format "yyyy-MM-dd") `
            -replace "%TIME%", (Get-Date -Format "HH:mm:ss")
    }
    else {
        "vault sync: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }

    # Track whether we committed this session; gates the push step.
    $committed = $false

    # -- Per-vault log ---------------------------------------------------------
    # Set the script-scoped vault log path so Write-VaultLog appends to it.
    # We do NOT open a nested Start-Transcript - PowerShell 5.1 (the Windows
    # default) supports only one active transcript; a second call silently
    # stops the session transcript, breaking the cross-vault session log.
    # Instead, Write-VaultLog calls Write-Log (captured by session transcript)
    # AND appends the same line directly to the per-vault file via Add-Content.
    $script:CurrentVaultLog = $VaultLog

    Write-Log "---------------------------------------------------"
    Write-Log "Vault : $VaultName"
    Write-Log "Path  : $vaultPath"
    Write-Log "Branch: $branch"
    Write-Log "Log   : $VaultLog"
    if ($dryRun) { Write-Log "Mode  : DRY RUN - no changes will be written" "DRYRUN" }
    Write-Log "---------------------------------------------------"

    # -- Pre-flight validation -------------------------------------------------
    # throw - caught by the per-vault try/catch in MAIN, recorded, then moves on.
    if (-not (Test-Path $vaultPath)) {
        throw "Vault path does not exist: $vaultPath"
    }
    if (-not (Test-Path (Join-Path $vaultPath ".git"))) {
        throw "Not a git repository: $vaultPath"
    }
    # Validate ObsidianPath: must resolve to an absolute path, leaf must be
    # Obsidian.exe (case-insensitive), and must contain no newlines or shell
    # metacharacters that could escape Start-Process argument handling.
    if ($obsidianPath -match '[\r\n&|;`$<>]') {
        throw "ObsidianPath contains disallowed characters: $obsidianPath"
    }
    $obsidianResolved = [System.IO.Path]::GetFullPath($obsidianPath)
    $obsidianLeaf = [System.IO.Path]::GetFileName($obsidianResolved)
    if ($obsidianLeaf -ne 'Obsidian.exe') {
        throw "ObsidianPath leaf must be 'Obsidian.exe' (got '$obsidianLeaf'): $obsidianResolved"
    }
    if (-not (Test-Path $obsidianResolved)) {
        throw "Obsidian.exe not found: $obsidianResolved"
    }
    $obsidianPath = $obsidianResolved

    # Verify Git Identity so commit doesn't fail later
    Test-GitIdentity -VaultPath $vaultPath

    # Check for changes before fetching/pulling (pre-sync commit)
    # This avoids "Cannot pull with rebase: You have unstaged changes"
    $preSyncStatus = & git -C $vaultPath status --porcelain 2>&1
    if ($preSyncStatus) {
        Write-Log "Local changes detected. Committing before pulling..." "INFO"
        Invoke-Git @("add", "-A") -WorkDir $vaultPath -SkipInDryRun $true -IsDryRun $dryRun
        $preCommitMsg = "pre-launch: $commitMsg"
        Invoke-Git @("commit", "-m", $preCommitMsg) `
            -WorkDir $vaultPath -SkipInDryRun $true -IsDryRun $dryRun
    }

    # Catch a stuck rebase from a previous crashed run before we try to pull.
    Test-RebaseInProgress -VaultPath $vaultPath

    $remote = $VaultConfig["Remote"]
    if ($remote) {
        $existingRemote = & git -C $vaultPath remote get-url origin 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $existingRemote) {
            & git -C $vaultPath remote add origin $remote 2>&1 | Out-Null
            Write-Log "Remote 'origin' added as $remote" "OK"
        }
        elseif ($existingRemote.Trim() -ne $remote) {
            & git -C $vaultPath remote set-url origin $remote 2>&1 | Out-Null
            Write-Log "Remote 'origin' updated to $remote" "OK"
        }
    }

    # -- STEP 1: git fetch (with Offline Resiliency) ---------------------------
    $offline = $false
    try {
        Write-Log "[1/5] Fetching remote..."
        Invoke-Git @("fetch", "origin") `
            -WorkDir $vaultPath `
            -SkipInDryRun $true `
            -IsDryRun $dryRun
    }
    catch {
        Write-Log "Network fetch failed. Proceeding in OFFLINE mode." "WARN"
        $offline = $true
    }

    # -- STEP 2: git pull --rebase ---------------------------------------------
    if (-not $offline) {
        try {
            Write-Log "[2/5] Rebasing onto origin/$branch..."
            Invoke-Git @("pull", "--rebase", "origin", $branch) `
                -WorkDir $vaultPath `
                -SkipInDryRun $true `
                -IsDryRun $dryRun
            
            # -- STEP 3: conflict detection ------------------------------------
            if (-not $dryRun) {
                Test-RebaseInProgress -VaultPath $vaultPath
                Test-Conflicts -VaultPath $vaultPath
            }
        }
        catch {
            # If a merge conflict occurred, we must stop and let the user resolve it.
            if ($_ -match "conflict" -or (Test-Path (Join-Path $vaultPath ".git/REBASE_HEAD"))) {
                throw $_
            }
            Write-Log "Rebase/pull failed. Proceeding with caution..." "WARN"
        }
    }
    Write-Log "[3/5] Launching Obsidian..." "OK"

    # -- STEP 4: Launch Obsidian, wait for exit --------------------------------
    # -PassThru : gives us the Process object to read the exit code.
    # -Wait     : blocks until Obsidian AND all its Electron child processes exit.
    #             .WaitForExit() alone only waits on the root PID.
    if ($dryRun) {
        Write-Log "Skipping Obsidian launch - simulating 2s session." "DRYRUN"
        Start-Sleep -Seconds 2
        Write-Log "Simulated session complete." "DRYRUN"
    }
    else {
        try {
            $obsidianProc = Start-Process `
                -FilePath $obsidianPath `
                -ArgumentList ("obsidian://open?path={0}" -f [uri]::EscapeDataString($vaultPath.Replace('\', '/'))) `
                -PassThru

            Write-Log "Obsidian launched (PID $($obsidianProc.Id)). Waiting for exit..." "INFO"
            Start-Sleep -Milliseconds 800
            
            if ($obsidianProc.HasExited) {
                Write-Log "Obsidian process exited immediately (delegated to running instance)." "WARN"
                Write-Log "Waiting for all Obsidian windows to close, OR press ENTER in this terminal to sync now..." "INFO"
                while ($true) {
                    if (-not (Get-Process obsidian -ErrorAction SilentlyContinue)) {
                        Write-Log "All Obsidian windows closed." "OK"
                        break
                    }
                    if ([Environment]::UserInteractive) {
                        try {
                            if ([System.Console]::KeyAvailable) {
                                $key = [System.Console]::ReadKey($true)
                                if ($key.Key -eq [System.ConsoleKey]::Enter) {
                                    Write-Log "Sync triggered manually by user." "INFO"
                                    break
                                }
                            }
                        } catch {}
                    }
                    Start-Sleep -Seconds 2
                }
            }
            else {
                # Wait for the specific process we started
                $obsidianProc.WaitForExit()
                Write-Log "Obsidian exited (PID $($obsidianProc.Id))." "OK"
                if ($obsidianProc.ExitCode -ne 0) {
                    Write-Log "Obsidian exited with non-zero code $($obsidianProc.ExitCode). Continuing sync." "WARN"
                }
            }
        }
        catch {
            throw "Failed to launch Obsidian: $_"
        }
    }

    # -- STEP 5: stage + commit ------------------------------------------------
    Write-Log "[4/5] Checking for changes..."

    # Check status BEFORE staging so we don't run add/commit on a clean tree.
    $preStageStatus = & git -C $vaultPath status --porcelain 2>&1

    if (-not $preStageStatus) {
        Write-Log "No changes - vault is clean."
    }
    else {
        Write-Log "Changes detected:"
        $preStageStatus | ForEach-Object { Write-Log "  $_" }

        # Stage all changes (new, modified, deleted).
        Invoke-Git @("add", "-A") `
            -WorkDir $vaultPath `
            -SkipInDryRun $true `
            -IsDryRun $dryRun

        Invoke-Git @("commit", "-m", $commitMsg) `
            -WorkDir $vaultPath `
            -SkipInDryRun $true `
            -IsDryRun $dryRun

        if (-not $dryRun) {
            $committed = $true
            Write-Log "Committed: $commitMsg" "OK"
        }
    }

    # -- STEP 6: push ----------------------------------------------------------
    # Only push if we actually committed something - avoids a pointless network
    # round-trip (and possible auth prompt) when the vault is already in sync.
    Write-Log "[5/5] Push..."

    if ($committed) {
        $pushNeeded = $true
    }
    else {
        $aheadCount = & git -C $vaultPath rev-list --count "origin/$branch..HEAD" 2>&1
        if ($LASTEXITCODE -eq 0 -and [int]$aheadCount -gt 0) {
            $pushNeeded = $true
        }
        elseif ($LASTEXITCODE -ne 0) {
            # rev-list failed - likely because origin/$branch doesn't exist yet.
            # Check whether the remote has the branch at all before deciding to push.
            $lsRemote = & git -C $vaultPath ls-remote --heads origin $branch 2>&1
            if ($LASTEXITCODE -eq 0 -and -not $lsRemote) {
                Write-Log "Branch '$branch' not found on remote - will push to create it." "WARN"
            }
            $pushNeeded = $true
        }
        else {
            $pushNeeded = $false
        }
    }

    if ($pushNeeded) {
        try {
            Invoke-Git @("push", "origin", $branch) `
                -WorkDir $vaultPath `
                -SkipInDryRun $true `
                -IsDryRun $dryRun
            Write-Log "Pushed to origin/$branch." "OK"
        }
        catch {
            if ($offline -or $_ -match "unreachable" -or $_ -match "could not resolve host") {
                Write-Log "Push failed (offline/network error). Your changes are saved locally and will push next time you are online." "WARN"
            }
            else {
                throw $_
            }
        }
    }
    elseif ($dryRun) {
        Write-Log "Would push to origin/$branch (skipped)." "DRYRUN"
    }
    else {
        Write-Log "Nothing to push."
    }

    Write-Log "Vault sync complete: $VaultName" "OK"

    # Clear vault log path so stray Write-VaultLog calls after this point
    # (there shouldn't be any) don't append to a finished vault's file.
    $script:CurrentVaultLog = $null
}

# -----------------------------------------
# MAIN
# -----------------------------------------
$config = Read-IniFile -Path $ConfigFile
$settings = if ($config.ContainsKey("Settings")) { $config["Settings"] } else { @{} }
$isDryRun = ($settings["DryRun"] -eq "true")

Write-SessionHeader -IsDryRun $isDryRun

# Vault sections in INI file order (stored by parser as _sectionOrder).
# Excludes [Settings] and internal parser keys.
$vaultSections = $config["_sectionOrder"] | Where-Object { $_ -ne "Settings" }

if (-not $vaultSections) {
    Fail "No vault sections found in config.ini. Add at least one [VaultName] section."
}

Write-Log "Vaults to sync: $($vaultSections -join ', ')"

$synced = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[hashtable]]::new()

foreach ($vaultName in $vaultSections) {
    # Validate required keys before handing off to Sync-Vault.
    # A bad config entry shouldn't block other vaults.
    $vaultConfig = $config[$vaultName]
    $missing = Get-MissingVaultKeys -VaultConfig $vaultConfig

    if ($missing) {
        $reason = "Missing required keys in config.ini: $($missing -join ', ')"
        Write-Log "Skipping '$vaultName': $reason" "WARN"
        $failed.Add(@{ Name = $vaultName; Reason = $reason })
        continue
    }

    # Per-vault log file - written in addition to the session log.
    # The session transcript (Start-Transcript) already captures everything;
    # per-vault logs give a clean isolated view for debugging a single vault.
    $vaultLogFile = Get-VaultLogFile -VaultName $vaultName

    try {
        # Run the vault sync. Any unhandled terminating error is caught below.
        Sync-Vault `
            -VaultName   $vaultName `
            -VaultConfig $vaultConfig `
            -Settings    $settings `
            -VaultLog    $vaultLogFile

        $synced.Add($vaultName)

    }
    catch {
        # Catch-all for unexpected PowerShell terminating errors (not from Fail).
        # Fail already calls exit 1, so this catches things like null refs, etc.
        $reason = $_.Exception.Message
        Write-Log "" "ERROR"
        Write-Log "Unexpected error in vault '$vaultName': $reason" "ERROR"
        Write-Log "Vault log: $vaultLogFile" "ERROR"
        Write-Log "Continuing to next vault..." "WARN"
        $failed.Add(@{ Name = $vaultName; Reason = $reason })
    }
}

Write-SessionSummary -VaultsSynced $synced -VaultsFailed $failed -IsDryRun $isDryRun

try { Stop-Transcript | Out-Null } catch { }

# Exit non-zero if any vault failed, so Task Scheduler / callers can detect partial failure.
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
