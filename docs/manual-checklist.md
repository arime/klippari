# Manual checklist

Checks that need a person at the Mac, because they involve other apps,
system permissions or what is on screen. Walk the list after a change
to the app layer, using a build installed with `Scripts/build-app.sh`.
Expected behaviour is defined in `specification.md`.

## Capturing

- [ ] Copying text, an image and a file each adds a row, with no
      prompt from macOS about clipboard access.
- [ ] A password copied from the password manager does not appear.
- [ ] Copying the same thing twice leaves one row, moved to the top.
- [ ] Capture keeps working after the Mac has been idle for a while.

## Panel

- [ ] Shift+Cmd+V opens the panel over the current app, which stays
      frontmost.
- [ ] The filter field has focus on every open, not just the first.
- [ ] Arrows, Ctrl+N / Ctrl+P and repeated Shift+Cmd+V move the
      selection.
- [ ] Typing filters; Esc clears the filter, then closes.
- [ ] Cmd+Backspace deletes the selected row.
- [ ] The panel looks right in light and dark mode, over light and
      dark windows, including its corners and blur.
- [ ] An image row shows a thumbnail.
- [ ] The panel can be dragged by its search row and footer, reopens
      where it was left, and still does after a relaunch.
- [ ] Reset Panel Position in the menu puts it back in the middle.
- [ ] With more than nine items, scrolling the list with the trackpad
      and reopening shows the first row selected and in view.

## Pasting

- [ ] Without the Accessibility permission, Return copies the item and
      the panel shows the notice; the system prompt appears once and
      does not hide the notice.
- [ ] With the permission, Return pastes into a text editor, a browser
      field and a terminal.
- [ ] Shift+Return pastes styled text as plain; an image pastes as-is.
- [ ] Cmd+1 to Cmd+9 paste that row.
- [ ] A copied file pastes into a Finder window.
- [ ] The pasted item is first on the next open.
- [ ] Paste lands reliably in slow and in full-screen apps.
- [ ] Holding Return or Cmd+digit does not repeat into the target app.

## Menu bar and settings

- [ ] The menu bar icon shows in light and dark menu bars and dims
      while capture is paused.
- [ ] Pause stops capture, and resume does not record what was copied
      while paused.
- [ ] Clear History asks first, then empties the panel and the storage
      folder.
- [ ] Lowering the history size trims the list at once.
- [ ] Shortcut field: Return arms it, Esc cancels, Cmd+V and Cmd+Q are
      refused, and a failed registration keeps the previous shortcut.
- [ ] A changed shortcut takes effect at once and survives a relaunch.
- [ ] Settings can be operated with the keyboard alone.

## Installation

- [ ] Rebuilding with the script keeps the Accessibility permission.
- [ ] The app is listed and enabled under Login Items after first
      launch, and the Settings toggle turns it off and on.
- [ ] After logout and login the app is running with its history.
- [ ] The app icon shows in Finder.
