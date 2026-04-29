# Strider review-comment demo — leave a multi-line comment on a review range.
# Run:   vhs recordings/vhs/review-comment.tape

Output recordings/review-comment.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh review_comment app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/main.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Start a file review.
Type ":StriderReview file"
Sleep 2200ms
Enter
Sleep 900ms
Ctrl+S
Sleep 3500ms

# Select a block to comment on.
Type "gg"
Sleep 800ms
Type "j"
Sleep 700ms
Type "Vj"
Sleep 1800ms

# Open the multi-line comment editor on the selection.
Type ":StriderComment"
Sleep 2200ms
Enter

# Let the comment buffer open.
Sleep 1800ms

# Type the multi-line comment.
Type "This branch needs a clearer name"
Sleep 900ms
Enter
Type "Maybe mention root rendering too"
Sleep 1500ms

# Submit with Ctrl-s (the bound submit key for the comment buffer).
Ctrl+S
Sleep 3500ms

Type ":qall!"
Enter
Sleep 600ms
