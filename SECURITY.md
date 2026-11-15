# Security

MyMole moves and deletes files, and the direct edition can act as root. A flaw
that lets it remove the wrong thing, or lets another program use its
privileges, is a security issue. Please report it privately.

## Reporting a vulnerability

- Use GitHub's private reporting: open the repository's Security tab and
  choose Report a vulnerability.
- Do not open a public issue, pull request or discussion for a suspected
  vulnerability.
- Include the MyMole version and build, the edition (direct download or App
  Store), the macOS version and the steps that show the problem.
- Use synthetic files and folders in examples. Do not attach real user data,
  logs with personal paths, keys or signing material.
- You get an answer once the report has been read. Fixes go out in a release
  of the direct edition and, where it is affected, the App Store edition.
  The advisory names the fixed version.

## Supported versions

Only the latest release of each edition gets security fixes.

## In scope

- Removing, moving or overwriting anything the user did not choose, or
  anything a keep rule protects.
- Following a symbolic link, hard link or mount point to a place outside the
  chosen item.
- A race where a checked path is swapped before it moves or is deleted.
- Any way for another app, process or user to make the privileged helper act,
  or to widen what it does.
- The helper accepting a request, path or command that its own rules do not
  allow.
- App Store edition code that asks for root or leaves the App Sandbox.
- MyMole reaching the network, or sending data anywhere.

## Out of scope

- Something a user explicitly chose to remove, after the confirmation that
  names it.
- Attacks that already need root, or an administrator who disabled System
  Integrity Protection.
- Bugs in macOS, in other apps or in the developer tools MyMole lists.
- Wrong sizes or misleading text with no unsafe removal. Report those as
  normal issues.

## How privileges work

### App Store edition

- Runs in the App Sandbox and can only read the folders you give it access
  to.
- Contains no privileged helper and no code that asks for an administrator
  password.
- App removals that need an administrator password go through Finder, which
  asks for the password itself.

### Direct edition

- The app itself runs as you. Your own files go to the Trash, never straight
  to deletion.
- Work that needs root is done by a small helper program inside the app.
  macOS runs it in one of two ways:
  - as a background service, only after you approve it in macOS System
    Settings, or
  - once per action, after macOS asks for an administrator password.
- The service only accepts connections from a copy of MyMole signed with
  the same Developer ID, with no debugging entitlement, and only from the
  user logged in at the screen.
- One request runs at a time. A request from a different build of the app
  is refused.
- The helper can do only four kinds of work:
  - run maintenance tasks from a fixed list,
  - delete system caches and logs that its own rules allow,
  - delete what an uninstalled app left in system folders, matched by that
    app's exact identifiers,
  - move one verified app between Applications and your Trash.
- The helper checks every path against its own rules again before acting,
  and refuses links on the way. It never runs a command or path built from
  text the app sends.
- Nothing system-wide is chosen for you. System items are deleted for good
  only after you choose each one and confirm.

### Both editions

- MyMole uses no network and sends no data.
- What MyMole removes is listed in its history, and items moved to the Trash
  can be put back with Undo.
