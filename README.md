# Obsidian Git Launcher

A lightweight Windows utility that syncs your Obsidian vault with GitHub automatically — on every open and close.

> "A safer, smarter doorway into Obsidian."

---

## How It Works

When you run `launch.bat`:

1. Pulls latest changes from GitHub (`git pull --rebase`)
2. Launches Obsidian and waits for you to close it
3. Commits all your changes (`git add -A && git commit`)
4. Pushes to GitHub
5. Exits

That's it. No background processes. No daemons. No magic.

---

## Requirements

- Windows 10/11
- [Git for Windows](https://git-scm.com/download/win) (with Git Credential Manager)
- [Obsidian](https://obsidian.md/)
- Your vault already initialized as a GitHub repo

---

## Setup

### 1. Clone or download this tool

```
git clone https://github.com/yourusername/obsidian-git-launcher.git
```

### 2. Create your config

```
copy config.ini.example config.ini
```

Edit `config.ini` with your vault's details:

```ini
[MyVault]
Path=C:\Vaults\Personal
Remote=https://github.com/yourusername/my-vault.git
Branch=main
ObsidianPath=C:\Users\YourName\AppData\Local\Obsidian\Obsidian.exe
```

### 3. Make sure your vault is a git repo

```
cd C:\Vaults\Personal
git init
git remote add origin https://github.com/yourusername/my-vault.git
git branch -M main
```

### 4. Authenticate with GitHub (once)

```
git push -u origin main
```

Git Credential Manager will open a browser prompt. Log in once. Credentials are cached securely.

### 5. Double-click `launch.bat`

Use it as your default way to open Obsidian.

---

## Options (config.ini)

| Key | Default | Description |
|-----|---------|-------------|
| `Path` | *(required)* | Absolute path to your vault |
| `Remote` | *(required)* | GitHub HTTPS URL |
| `Branch` | `main` | Branch to sync |
| `ObsidianPath` | *(required)* | Path to `Obsidian.exe` |
| `DryRun` | `false` | Log actions without pushing |
| `BackupEnabled` | `false` | Zip snapshots before push |
| `BackupDir` | `.\backups` | Where snapshots are saved |
| `CommitMessage` | `vault sync: %DATE% %TIME%` | Commit message template |

---

## Multi-Vault

Add multiple `[SectionName]` blocks in `config.ini`. Each vault syncs independently, in order.

```ini
[Personal]
Path=C:\Vaults\Personal
...

[Work]
Path=C:\Vaults\Work
...
```

---

## Conflict Handling

If a merge conflict is detected, the launcher **stops immediately** and tells you which files are affected. It will never auto-resolve or force-push.

Manual resolution:
```
cd C:\Vaults\YourVault
git status
# fix the conflicted files
git add -A
git rebase --continue
```

---

## Logs

Every run writes a log to `logs\sync_YYYY-MM-DD.log`.

---

## Dry Run

Set `DryRun=true` in `[Settings]` to test the flow without committing or pushing. Useful before first use.

---

## Task Scheduler (Optional)

To auto-launch on login instead of double-clicking, create a Task Scheduler entry pointing to `launch.bat`.

---

## What This Is NOT

- Not a background sync daemon (no FileSystemWatcher)
- Not a cloud service
- Not an Electron app
- Not real-time collaboration

It runs once, on-demand, when you open Obsidian.

---

## License

MIT
