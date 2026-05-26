# Task Scheduler Setup

This is optional. If you're happy double-clicking `launch.bat`, skip this.

If you want the launcher to fire automatically when you log in to Windows — so Obsidian just opens synced without you thinking about it — Task Scheduler is the way to do it natively, no third-party software required.

## Create the task

Open Task Scheduler. The fastest way: press `Win+R`, type `taskschd.msc`, hit Enter.

In the right panel, click **Create Basic Task**.

Walk through the wizard:

- **Name**: something like `Obsidian Git Launcher`
- **Trigger**: When I log on
- **Action**: Start a program
- **Program/script**: browse to your `launch.bat` file (e.g. `C:\Tools\obsidian-git-launcher\launch.bat`)
- **Start in**: the folder containing `launch.bat` (e.g. `C:\Tools\obsidian-git-launcher`) — this is required so the script can find `config.ini` and `sync.ps1`

Finish the wizard, then right-click your new task and choose **Properties**.

Under the **General** tab:
- Check "Run only when user is logged on" (default, leave it)
- Optionally check "Run with highest privileges" if you hit UAC prompts (unlikely)

Under the **Conditions** tab:
- Uncheck "Start the task only if the computer is on AC power" if you're on a laptop and want it to run on battery too

## How it behaves

When you log in, a terminal window appears briefly, does the pull, launches Obsidian, and disappears when Obsidian closes. The whole pre-launch sync takes a few seconds.

If you don't want the terminal window visible at all, change the **Action** to run `powershell.exe` with these arguments:

```
-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Tools\obsidian-git-launcher\sync.ps1"
```

Note: hidden mode means you won't see errors. Check `logs\session_YYYY-MM-DD.log` if something seems off.

## Disable or remove

In Task Scheduler, right-click your task and choose Disable (to pause it) or Delete (to remove it entirely). Your vault and config are untouched either way.
