# Git & Credential Setup

This covers the one-time setup you need before the launcher can talk to GitHub.

## Install Git for Windows

Download from [git-scm.com/download/win](https://git-scm.com/download/win).

During installation, the defaults are fine. The only thing to confirm: on the "Credential helper" screen, make sure **Git Credential Manager** is selected. It's the default — just don't uncheck it.

To verify Git is installed after:

```
git --version
```

If that prints a version number, you're good.

## Authenticate with GitHub (once)

The first time you push to a private repo, Git Credential Manager opens a browser window and asks you to log into GitHub. Do that once, and it stores the token securely in Windows Credential Manager. You won't be asked again.

To trigger this manually before your first launcher run:

```
cd C:\Vaults\YourVault
git push -u origin main
```

That's it. Future pushes from the launcher will be silent.

## If authentication breaks

GitHub tokens can expire or be revoked. If you see a push failure in the logs mentioning authentication or 401, clear the stored credential and re-authenticate:

```
git credential-manager-core erase
```

Then run the launcher (or `git push` manually) and the browser login will appear again.

On newer Git versions the command is:

```
git credential-manager erase
```

Type `protocol=https`, `host=github.com`, then press Enter twice.

Alternatively, open Windows Credential Manager (`control keymgr.dll`), find the `git:https://github.com` entry, and delete it. The next push will prompt for login again.

## Personal Access Tokens (alternative to browser login)

If you're on a machine where the browser flow doesn't work (e.g. a headless server, though this tool is Windows-desktop-first), you can use a PAT:

1. Go to GitHub → Settings → Developer Settings → Personal Access Tokens → Tokens (classic)
2. Generate a token with `repo` scope
3. When Git asks for a password, paste the token

Git Credential Manager stores it after the first use.

## HTTPS vs SSH

This tool is built around HTTPS + GCM. SSH works too but you're on your own for key management — the launcher doesn't care which transport you use as long as `git push` works from the vault folder.
