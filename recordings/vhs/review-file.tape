# Strider review-file demo — start a file walkthrough, accept a stop, and step back.
# Run:   vhs recordings/vhs/review-file.tape

Output recordings/review-file.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh review_file app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/main.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Start a file-scoped review.
Type ":StriderReview file"
Sleep 2200ms
Enter

# Let the review panel render the first explanation.
Sleep 4000ms

# Accept the current stop and advance to the next review item.
Type ":StriderNext!"
Sleep 1800ms
Enter
Sleep 3500ms

# Check the compact lane/status surface.
Type ":StriderStatus"
Sleep 1800ms
Enter
Sleep 3000ms

# Step back to the previous item.
Type ":StriderPrev"
Sleep 1800ms
Enter
Sleep 3500ms

Type ":qall!"
Enter
Sleep 600ms
