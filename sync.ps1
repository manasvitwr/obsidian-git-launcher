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
        Fail "config.ini not found at: $Path`nCopy config.ini.example to config.ini and fill in your vault details."
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
