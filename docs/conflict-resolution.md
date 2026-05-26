# Conflict Resolution

When the launcher detects a merge conflict, it stops immediately and logs the affected files. It will not auto-resolve, force-push, or silently skip files.

The terminal will show something like:

```
[ERROR] Merge conflicts detected — manual resolution required:
[ERROR]   conflict: UU Notes/daily/2026-05-26.md
[ERROR]   To resolve:
[ERROR]     1. Open the conflicted files and fix the markers
[ERROR]     2. git add -A
[ERROR]     3. git rebase --continue
[ERROR]     4. Re-run launch.bat
```

## How to fix it

Open the conflicted file(s) in any text editor. Git marks the conflicts like this:

```
<<<<<<< HEAD
Your local version of the line
=======
The remote version of the line
>>>>>>> origin/main
```

Edit the file to keep whichever version is correct (or combine them). Remove the `<<<<<<<`, `=======`, and `>>>>>>>` markers entirely.

Then:

```
cd C:\Vaults\YourVault
git add -A
git rebase --continue
```

If Git asks for a commit message during `rebase --continue`, save and close the editor.

Then run `launch.bat` again — it'll pick up where it left off.

## If you want to abort

If the rebase is too tangled and you just want to go back to before the pull:

```
cd C:\Vaults\YourVault
git rebase --abort
```

This resets to the state before the pull started. Your local changes are safe. You'll need to manually reconcile with the remote at some point, but nothing is lost.

## Why does this happen?

Conflicts happen when the same file was changed both locally and on the remote since your last sync — typically because you edited a note on another device (phone, other computer) and that change was pushed, while you also edited the same note locally.

The cleanest way to avoid it: always open Obsidian through the launcher rather than directly, so every session starts with a pull and ends with a push. Conflicts become very rare when the sync is consistently used.
