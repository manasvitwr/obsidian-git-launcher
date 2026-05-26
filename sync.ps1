<#
.SYNOPSIS
    Obsidian Git Launcher — Core Sync Script
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

# ─────────────────────────────────────────
# PATHS
# ─────────────────────────────────────────
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile  = Join-Path $ScriptDir "config.ini"
$LogDir      = Join-Path $ScriptDir "logs"
$LogFile     = Join-Path $LogDir ("sync_{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))

# ─────────────────────────────────────────
# LOGGING SETUP
# ─────────────────────────────────────────
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [$Level] $Message"
}

function Fail {
    param([string]$Message)
    Write-Log $Message "ERROR"
    Stop-Transcript | Out-Null
    exit 1
}

# ─────────────────────────────────────────
# CONFIG PARSER
# ─────────────────────────────────────────
function Read-IniFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        # First run — hand off to the interactive setup wizard instead of failing.
        Invoke-SetupWizard -OutputPath $Path
    }

    $ini = @{}
    $currentSection = "_root"

    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -match '^\s*[;#]' -or $line -eq "") { continue }

        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1].Trim()
            $ini[$currentSection] = @{}
        }
        elseif ($line -match '^([^=]+)=(.*)$') {
            $key   = $matches[1].Trim()
            $value = $matches[2].Trim()
            if (-not $ini.ContainsKey($currentSection)) { $ini[$currentSection] = @{} }
            $ini[$currentSection][$key] = $value
        }
    }

    return $ini
}

# ─────────────────────────────────────────
# FIRST-RUN SETUP WIZARD
# ─────────────────────────────────────────
function Invoke-SetupWizard {
    param([string]$OutputPath)

    # ── Banner ───────────────────────────────
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗"
    Write-Host "  ║     Obsidian Git Launcher — First Run    ║"
    Write-Host "  ║  Let's set up your vault sync in 1 min.  ║"
    Write-Host "  ╚══════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "  No config.ini found. This wizard will create one."
    Write-Host "  Press Ctrl+C at any time to cancel."
    Write-Host ""

    # ── Locate Obsidian.exe (once, shared across all vaults) ──
    $obsidianPath = Find-ObsidianExe

    # ── Vault collection loop ─────────────────
    $vaults   = [System.Collections.Generic.List[hashtable]]::new()
    $addMore  = $true
    $vaultNum = 1

    while ($addMore) {
        Write-Host "  ── Vault $vaultNum ─────────────────────────────"
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

    # ── Global settings ───────────────────────
    Write-Host "  ── Global Settings ─────────────────────────"
    $dryRun = Read-PromptValue `
        -Prompt "  Enable dry-run mode? Logs actions without pushing. (y/N)" `
        -Default "N" `
        -AllowEmpty $true
    $dryRunValue = if ($dryRun -match '^[Yy]$') { "true" } else { "false" }

    # ── Write config.ini ──────────────────────
    Write-IniConfig -OutputPath $OutputPath -Vaults $vaults -DryRun $dryRunValue

    Write-Host ""
    Write-Host "  [OK] config.ini created at: $OutputPath"
    Write-Host "  Starting sync now..."
    Write-Host ""
}

# Prompt for one vault's settings and return a hashtable.
function Read-VaultConfig {
    param([int]$VaultNumber, [string]$ObsidianPath)

    # ── Section name ──────────────────────────
    $defaultName = "Vault$VaultNumber"
    $sectionName = Read-PromptValue `
        -Prompt "  Vault name (used in logs) [$defaultName]" `
        -Default $defaultName `
        -AllowEmpty $true
    # Strip characters that would break INI section syntax
    $sectionName = $sectionName -replace '[\[\]=;#]', '' | ForEach-Object { $_.Trim() }
    if (-not $sectionName) { $sectionName = $defaultName }

    # ── Vault path ────────────────────────────
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

    # ── Git repo check / offer to init ────────
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
        } else {
            # User declined — warn but continue. Sync-Vault will catch it later.
            Write-Host "  [WARN] Skipping git init. Sync will fail unless the folder is a git repo." -ForegroundColor Yellow
        }
    }

    # ── Remote URL ────────────────────────────
    $remote = ""
    do {
        $remote = Read-PromptValue `
            -Prompt "  GitHub repo URL (HTTPS, e.g. https://github.com/you/vault.git)" `
            -Default "" `
            -AllowEmpty $false

        if ($remote -notmatch '^https?://.+') {
            Write-Host "  [WARN] URL should start with https://. Try again." -ForegroundColor Yellow
            $remote = ""
        }
    } while (-not $remote)

    # ── Branch ────────────────────────────────
    $branch = Read-PromptValue `
        -Prompt "  Branch name [main]" `
        -Default "main" `
        -AllowEmpty $true
    if (-not $branch) { $branch = "main" }

    # ── Wire up remote (if repo was just init'd or has no remote) ──
    $existingRemote = & git -C $vaultPath remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $existingRemote) {
        & git -C $vaultPath remote add origin $remote 2>&1 | Out-Null
        Write-Host "  [OK] Remote 'origin' set to $remote"
    } else {
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

# Locate Obsidian.exe — check common install paths, then ask the user.
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

# Generic prompt helper — shows default, returns trimmed input or default if empty.
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

    $lines.Add("; Obsidian Git Launcher — config.ini")
    $lines.Add("; Generated by setup wizard on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("; Edit this file any time to update your settings.")
    $lines.Add("")

    foreach ($vault in $Vaults) {
        $lines.Add("[$($vault.SectionName)]")
        $lines.Add("Path=$($vault.Path)")
        $lines.Add("Remote=$($vault.Remote)")
        $lines.Add("Branch=$($vault.Branch)")
        $lines.Add("ObsidianPath=$($vault.ObsidianPath)")
        $lines.Add("")
    }

    $lines.Add("[Settings]")
    $lines.Add("DryRun=$DryRun")
    $lines.Add("BackupEnabled=false")
    $lines.Add("BackupDir=.\backups")
    $lines.Add("CommitMessage=vault sync: %DATE% %TIME%")

    # Write atomically — build in memory, write once.
    $lines | Set-Content -Path $OutputPath -Encoding UTF8
}

# ─────────────────────────────────────────
# GIT HELPERS
# ─────────────────────────────────────────
function Invoke-Git {
    param([string[]]$Arguments, [string]$WorkDir)

    Write-Log "git $($Arguments -join ' ')"
    $result = & git -C $WorkDir @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($result) { Write-Host $result }

    if ($exitCode -ne 0) {
        Fail "git $($Arguments -join ' ') failed (exit $exitCode)`n$result"
    }
    return $result
}

function Test-Conflicts {
    param([string]$VaultPath)

    $status = & git -C $VaultPath status --porcelain 2>&1
    $conflicts = $status | Where-Object { $_ -match '^(UU|AA|DD|AU|UA|DU|UD)' }

    if ($conflicts) {
        Write-Log "Merge conflicts detected — manual resolution required:" "ERROR"
        $conflicts | ForEach-Object { Write-Log "  $_" "ERROR" }
        Fail "Resolve conflicts manually in: $VaultPath`nDo NOT force-push. Fix the files, then run: git add -A && git rebase --continue"
    }
}

# ─────────────────────────────────────────
# VAULT SYNC
# ─────────────────────────────────────────
function Sync-Vault {
    param(
        [string]$VaultName,
        [hashtable]$VaultConfig,
        [hashtable]$Settings
    )

    $vaultPath     = $VaultConfig["Path"]
    $branch        = $VaultConfig["Branch"]
    $obsidianPath  = $VaultConfig["ObsidianPath"]
    $dryRun        = ($Settings -and $Settings["DryRun"] -eq "true")
    $commitMsg     = if ($Settings -and $Settings["CommitMessage"]) {
        $Settings["CommitMessage"] `
            -replace "%DATE%", (Get-Date -Format "yyyy-MM-dd") `
            -replace "%TIME%", (Get-Date -Format "HH:mm:ss")
    } else {
        "vault sync: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }

    Write-Log "─── Starting sync for vault: $VaultName ───"

    # Validate vault path
    if (-not (Test-Path $vaultPath)) {
        Fail "Vault path does not exist: $vaultPath"
    }
    if (-not (Test-Path (Join-Path $vaultPath ".git"))) {
        Fail "Vault path is not a git repository: $vaultPath"
    }

    # Validate Obsidian executable
    if (-not (Test-Path $obsidianPath)) {
        Fail "Obsidian.exe not found at: $obsidianPath"
    }

    # ── STEP 1: Pull latest ──────────────────
    Write-Log "Fetching remote changes..."
    Invoke-Git @("fetch", "origin") -WorkDir $vaultPath
    Invoke-Git @("pull", "--rebase", "origin", $branch) -WorkDir $vaultPath
    Test-Conflicts -VaultPath $vaultPath

    # ── STEP 2: Launch Obsidian ──────────────
    Write-Log "Launching Obsidian: $obsidianPath"

    if ($dryRun) {
        Write-Log "[DRY RUN] Would launch Obsidian. Skipping." "INFO"
        Write-Log "[DRY RUN] Simulating 3 second wait..." "INFO"
        Start-Sleep -Seconds 3
    } else {
        try {
            # -PassThru gives us the process object. -Wait isn't used here because
            # Obsidian (Electron) spawns child processes — we wait on the parent.
            $obsidianProc = Start-Process -FilePath $obsidianPath -PassThru
            Write-Log "Obsidian launched (PID $($obsidianProc.Id)). Waiting for it to close..."
            $obsidianProc.WaitForExit()
            Write-Log "Obsidian closed."
        } catch {
            Fail "Failed to launch Obsidian: $_"
        }
    }

    # ── STEP 3: Commit changes ───────────────
    Write-Log "Staging all changes..."
    Invoke-Git @("add", "-A") -WorkDir $vaultPath

    # Check if there's anything to commit
    $statusOutput = & git -C $vaultPath status --porcelain 2>&1
    if (-not $statusOutput) {
        Write-Log "No changes to commit. Vault is already up to date."
    } else {
        if ($dryRun) {
            Write-Log "[DRY RUN] Would commit: $commitMsg" "INFO"
        } else {
            Invoke-Git @("commit", "-m", $commitMsg) -WorkDir $vaultPath
        }
    }

    # ── STEP 4: Push ─────────────────────────
    if ($dryRun) {
        Write-Log "[DRY RUN] Would push to origin/$branch. Skipping." "INFO"
    } else {
        Write-Log "Pushing to origin/$branch..."
        Invoke-Git @("push", "origin", $branch) -WorkDir $vaultPath
    }

    Write-Log "─── Vault sync complete: $VaultName ───"
}

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
Write-Log "Obsidian Git Launcher starting"

$config   = Read-IniFile -Path $ConfigFile
$settings = if ($config.ContainsKey("Settings")) { $config["Settings"] } else { @{} }

# Collect vault sections (anything that isn't [Settings])
$vaultSections = $config.Keys | Where-Object { $_ -ne "Settings" -and $_ -ne "_root" }

if (-not $vaultSections) {
    Fail "No vault sections found in config.ini. Add at least one [VaultName] section."
}

foreach ($vaultName in $vaultSections) {
    Sync-Vault -VaultName $vaultName -VaultConfig $config[$vaultName] -Settings $settings
}

Write-Log "All vaults synced successfully."
Stop-Transcript | Out-Null
exit 0
