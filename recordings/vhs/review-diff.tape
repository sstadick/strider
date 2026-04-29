# Strider review-diff demo — walk the current working-tree diff.
# Run:   vhs recordings/vhs/review-diff.tape

Output recordings/review-diff.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh review_diff app --diff)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/App.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Start a diff-scoped review of the uncommitted change.
Type ":StriderReview diff"
Sleep 2200ms
Enter
Sleep 900ms
Ctrl+S

# Let the review panel pick up the hunk and explain it.
Sleep 4500ms

Type ":qall!"
Enter
Sleep 600ms
