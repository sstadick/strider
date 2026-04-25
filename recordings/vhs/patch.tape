# Strider patch demo — edits app.py via :StriderPatch on a visual-line selection.
#
# Run from the repo root:   vhs recordings/vhs/patch.tape

Output recordings/patch.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0

# Prep a clean workspace, launch nvim, and fully clear the screen — all hidden
# so the gif opens directly on the editor.
Hide
Type `WS=$(recordings/vhs/prep.sh patch python_app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" app.py`
Enter
Sleep 2500ms
Show

# Let the viewer read the file.
Sleep 2500ms

# Land on the greeting-return line so the target is obvious.
Type "gg"
Sleep 1200ms
Type "4j"
Sleep 1800ms

# Line-wise visual selection on just that line.
Type "V"
Sleep 2200ms

# Type the patch command so the viewer can read it on the cmdline.
Type ":StriderPatch change the greeting literal from hi to hello"
Sleep 2800ms
Enter

# Wait for the fake pi to apply the edit and the buffer to refresh.
Sleep 4500ms

# Leave nvim.
Type ":qall!"
Enter
Sleep 600ms
