# Sherpa tangent demo — :SherpaQ opens a tangent that branches off the
# active session tree, answers in the main chat surfaces, and on end
# drops from the active path so follow-up main-chat turns don't carry it
# as context.
# Run:   vhs recordings/vhs/tangent.tape

Output recordings/tangent.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh tangent app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/App.tsx`
Enter
Sleep 2500ms
Show

Sleep 2000ms

# Kick off a regular chat turn so there is a leaf to branch from.
Type ":SherpaChat add loading states to the lobby flow"
Sleep 2400ms
Enter
Sleep 3500ms

# Now the tangent — a question unrelated to the running thread that we
# do not want polluting the main session's history.
Type ":SherpaQ what does the App component even do here?"
Sleep 2600ms
Enter

# Wait for the tangent answer to stream in and the [Tangent] badge to
# appear in the compose winbar.
Sleep 3500ms

# End the tangent by re-invoking :SherpaQ with no args. This navigates
# pi's session tree back to the anchor captured at tangent start, so
# subsequent main-chat turns branch from before the tangent.
Type ":SherpaQ"
Sleep 2200ms
Enter
Sleep 2000ms

Type ":qall!"
Enter
Sleep 600ms
