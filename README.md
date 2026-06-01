# Obsidian Git Launcher

A tiny Windows launcher for syncing Obsidian vaults with GitHub.

Opens Obsidian, pulls before launch, pushes after exit.

---

## How it works

Instead of opening Obsidian directly, launch it through:

```bat
launch.bat
```

The launcher:

1. pulls the latest changes (`git pull --rebase`)
2. opens Obsidian
3. waits for Obsidian to close
4. commits local changes
5. pushes to GitHub

That’s it.

---

## Requirements

* Windows 10 / 11
* Git for Windows
  https://git-scm.com/download/win
* Obsidian
  https://obsidian.md/
* GitHub repository for your vault

During Git installation, keep **Git Credential Manager** enabled (default option).

---

## Installation

### Clone the repository

```bash
git clone https://github.com/yourusername/obsidian-git-launcher.git
cd obsidian-git-launcher
```

Or download the latest ZIP from Releases.

---

## Initial setup

Run:

```bat
launch.bat
```

If `config.ini` does not exist, the setup wizard will create it automatically.

You’ll be asked for:

* vault path
* GitHub repository URL
* branch name

Example:

```ini
[Personal]
Path=C:\Vaults\Personal
Remote=https://github.com/yourusername/personal-vault.git
Branch=main
ObsidianPath=C:\Users\YourName\AppData\Local\Obsidian\Obsidian.exe
```

---

## Preparing your vault

Your vault must already be a Git repository.

Example setup:

```bash
cd C:\Vaults\Personal

git init
git remote add origin https://github.com/yourusername/personal-vault.git

git branch -M main
git push -u origin main
```

Authentication is handled through Git Credential Manager.

On first push, GitHub login opens in your browser once and is then cached locally.

---

## Daily usage

Use `launch.bat` as your main Obsidian shortcut.

Recommended:

* pin it to the taskbar
* replace existing Obsidian shortcuts
* launch vaults through the launcher only

---

## Multi-vault support

Multiple vaults can be configured in `config.ini`.

Vaults sync sequentially in the order they appear.

```ini
[Personal]
Path=C:\Vaults\Personal
Remote=https://github.com/you/personal-vault.git
Branch=main
ObsidianPath=C:\Users\You\AppData\Local\Obsidian\Obsidian.exe

[Work]
Path=C:\Vaults\Work
Remote=https://github.com/you/work-vault.git
Branch=main
ObsidianPath=C:\Users\You\AppData\Local\Obsidian\Obsidian.exe
```

If one vault fails, the remaining vaults continue normally.

---

## Dry run mode

Enable dry-run mode in `[Settings]`:

```ini
[Settings]
DryRun=true
```

All actions are logged without modifying files or running Git operations.

Useful for initial verification and debugging.

---

## Merge conflicts

If a merge conflict is detected, the launcher stops immediately and prints the affected files.

Nothing is auto-resolved or force-pushed.

Resolve conflicts manually:

```bash
cd C:\Vaults\YourVault

git status
git add -A
git rebase --continue
```

Then run `launch.bat` again.

---

## Logs

Logs are written to:

```text
logs\
```

Generated files:

* `session_YYYY-MM-DD.log`
* `VaultName_YYYY-MM-DD.log`

---

## Task Scheduler (optional)

The launcher can run automatically at login using Windows Task Scheduler.

Basic setup:

1. Open `taskschd.msc`
2. Create a new task
3. Trigger: `At log on`
4. Action: start `launch.bat`
5. Set “Start in” to the launcher directory

---

## Configuration reference

```ini
[VaultName]
Path=
Remote=
Branch=main
ObsidianPath=

[Settings]
DryRun=false
CommitMessage=vault sync: %DATE% %TIME%
BackupEnabled=false
BackupDir=.\backups
```

---

## Note

This project is not:

* a background sync daemon
* a cloud sync platform
* a real-time collaboration tool
* an Obsidian plugin

Sync runs only when the launcher is started.

---
made w ❤ by manasvi
