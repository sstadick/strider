# Strider review-selection demo — inside a review, ask about a visual range.
# Run:   vhs recordings/vhs/review-selection.tape

Output recordings/review-selection.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh review_selection app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/main.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Start a file review so the review panel is visible.
Type ":StriderReview file"
Sleep 2200ms
Enter
Sleep 3500ms

# Navigate to the block we want to ask about.
Type "gg"
Sleep 900ms
Type "j"
Sleep 700ms

# Line-wise visual selection on the block.
Type "Vj"
Sleep 2000ms

# Ask a focused question about just that range.
Type ":StriderReview why does this block matter?"
Sleep 2800ms
Enter

# Wait for the explanation to stream in.
Sleep 4500ms

Type ":qall!"
Enter
Sleep 600ms
