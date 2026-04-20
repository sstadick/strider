# Sherpa search demo — :SherpaSearch jumps to the entrypoint.
# Run:   vhs recordings/vhs/search.tape

Output recordings/search.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh search app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" index.html`
Enter
Sleep 2500ms
Show

# Let the viewer read the file.
Sleep 2500ms

# Ask Sherpa where the entrypoint is.
Type ":SherpaSearch where is the main entrypoint?"
Sleep 2800ms
Enter

# Wait for the jump and settle on the result.
Sleep 4500ms

Type ":qall!"
Enter
Sleep 600ms
