# PathBar

**A Windows-style address bar for macOS Save/Open dialogs and Finder windows.**

macOS file dialogs only show the current folder's name. PathBar adds a bar that shows the
**full path** of where you are. Click it, type or paste any path, press Return, and the
dialog (or Finder window) jumps straight there. It's handy when your browser asks where to
save a download.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ↑   /Users/you/Documents/Projects/Client/Exports          ⧉   ⟲   │
└──────────────────────────────────────────────────────────────────────┘
```

## Features

- **Works in every app's Save and Open dialogs**: Chrome, Brave, Safari, Firefox downloads,
  "Save As…", "Open…", upload pickers.
- **Works in Finder windows**: the bar sits in the toolbar where the title is, and stretches
  out while you type.
- **Type or paste a path** and press Return to jump. `~`, quoted paths, `file://` URLs and
  paths copied from Terminal (`My\ Folder`) all work. **Tab** completes folder names.
- **↑** goes up one folder. **Copy** copies the full path.
- **Recent folders and open Finder windows** in one click (the clock button).
- **Drag a folder from Finder** onto the bar to jump there.
- Lives in the menu bar (folder icon), where you can turn it off for dialogs or for Finder.
- No network access, no tracking. Everything stays on your Mac.

## Requirements

- macOS 13 Ventura or newer (developed and tested on macOS 26 Tahoe)
- Apple's free Command Line Tools for the Swift compiler. The installer offers to install
  them if they're missing (or run `xcode-select --install`).

## Install

**With git:**

```bash
git clone https://github.com/<user>/PathBar.git
cd PathBar
bash install.sh
```

**Without git:** click **Code → Download ZIP** on GitHub and unzip it. Open **Terminal**,
type `cd ` (with a space), drag the unzipped `PathBar` folder into the Terminal window,
press Return, then run:

```bash
bash install.sh
```

The installer builds PathBar on your Mac, puts it in `~/Applications/PathBar.app` and
starts it at login. It needs no admin password. On a first install, macOS asks two things:

1. **Keychain:** "codesign wants to use the key PathBar Local Signing". Enter your Mac
   password and click **Always Allow**. (See *Why a signing certificate?* below.)
2. **Accessibility:** "PathBar would like to control this computer". Click
   **Open System Settings** and switch **PathBar** on.

That's it. Open any Save dialog to try it.

> **Double-click install:** `Install PathBar.command` does the same thing. macOS may block
> it the first time because it came from the internet. If so, use the Terminal steps above,
> or allow it under System Settings → Privacy & Security → "Open Anyway".

## Using it

| Where | What happens |
| --- | --- |
| Save / Open dialog | The bar floats just above the dialog, showing the full path. |
| Finder window | The bar sits in the toolbar. Click it and it widens up to the search field. |

- **Click the path.** It's all selected, so just type or paste a new one.
- **Return** jumps there. **Esc** cancels. **Tab** completes a folder name.
- **↑** goes up a folder. In Finder this is Finder's own ⌘↑, so Back still works.
- **⧉** copies the path. **⟲** lists recent folders and your open Finder windows.
  The first time, macOS asks to let PathBar read your Finder windows.

**Menu bar folder icon:** turn the bar on or off for dialogs, or just for Finder windows.
You can also open the log or quit.

## Update

```bash
cd PathBar
git pull
bash install.sh
```

Updates keep the Accessibility permission, so there's no need to allow it again.

## Uninstall

```bash
bash uninstall.sh          # removes the app and login item
bash uninstall.sh --all    # also deletes its settings and signing certificate
```

Then remove PathBar from System Settings → Privacy & Security → Accessibility (select it, click −).

## Why Accessibility permission?

PathBar has to see the dialog or Finder window that's open, read which folder it shows and
press its "Go to Folder" shortcut for you. On macOS that's what the Accessibility permission
is for. PathBar uses it only for that. It has no network code, and you can read every line
in `Sources/`.

## Why a signing certificate?

macOS remembers the Accessibility permission per app *signature*. An app built without a
certificate gets a new signature every time it's built, so every update would look like a
new app and the permission would have to be given again. Toggling the switch in System
Settings doesn't fix that.

So on first install, `setup-signing.sh` creates a personal certificate called
**PathBar Local Signing** in your login keychain. It's made on your Mac, used only by
Apple's `codesign` tool to sign PathBar, and isn't trusted system-wide. Every build is signed
with it, so macOS sees the same app and keeps the permission.
`bash uninstall.sh --all` deletes it.

## Troubleshooting

- **It keeps asking for Accessibility, or switching it on does nothing.** Quit System
  Settings (⌘Q) and run `bash install.sh` again. If an old entry is stuck, run
  `sudo tccutil reset Accessibility local.pathbar.helper`, then reinstall and allow it once.
- **The bar doesn't appear.** Check the menu bar icon. A ⚠️ means the permission is missing.
  "Open Log" shows what PathBar sees (`~/Library/Logs/PathBar.log`).
- **Typing a path doesn't jump.** PathBar drives the dialog with ⌘⇧G and types the path, so
  that app must be in front. Keyboard layouts that move the G key (e.g. Dvorak) aren't
  supported yet.
- **Finder already has a path bar from another tool.** Turn off "Show Path Bar in Finder
  Windows" in PathBar's menu.

## How it works

PathBar is a small menu-bar app in Swift/AppKit with no dependencies. It polls the front
app through the Accessibility API and looks for windows whose identifier is `save-panel` or
`open-panel`, or for Finder's front browser window. It reads the folder from the file list
(each row carries its file URL) and the folder pop-up or window title. To jump, it opens the
window's own **Go to Folder** sheet and enters the path, the same thing you'd do by hand.

```
Sources/
  main.swift       app, watch loop, menu bar icon, settings
  AX.swift         Accessibility helpers; finding dialogs and Finder windows; reading the folder
  Navigator.swift  jumping (Go to Folder), path parsing, Tab completion
  Bar.swift        the floating bar UI
install.sh         build + install (+ login item)
setup-signing.sh   one-time personal signing certificate
uninstall.sh       remove
```

### Developing

- `bash install.sh --no-login` builds and opens PathBar without the login item.
- Every build runs `PathBar --selftest` (path parsing, Tab completion, folder detection).
- Debug mode: `defaults write local.pathbar.helper debug -bool true`, then restart PathBar.
  It then accepts the distributed notification `local.pathbar.cmd` with `state`, `dump`,
  `snap`, `up`, `go:<path>`, `pid:<n>`, `dumpapp:<bundle id>`, `focus` or `blur`. Leave it
  off in normal use, because any program could send these.

## License

[MIT](LICENSE). Use it, change it, share it.
