# StriderQ demo — :StriderQ opens a side-question card and keeps the main chat
# surfaces out of the way.
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
Type ":StriderChat add loading states to the lobby flow"
Sleep 2400ms
Enter
Sleep 900ms
Ctrl+S
Sleep 3500ms

# Now the side question — unrelated to the running thread and isolated from the
# main session's history.
Type ":StriderQ what does the App component even do here?"
Sleep 2600ms
Enter
Sleep 900ms
Ctrl+S

# Wait for the Q answer to stream into its card.
Sleep 3500ms

# Hide the Q card by re-invoking :StriderQ with no args.
Type ":StriderQ"
Sleep 2200ms
Enter
Sleep 2000ms

Type ":qall!"
Enter
Sleep 600ms
