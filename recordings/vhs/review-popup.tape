# Sherpa review-popup demo — :SherpaReview with no args opens a floating
# editor whose ghost text explains that the first word picks the scope.
# Run:   vhs recordings/vhs/review-popup.tape

Output recordings/review-popup.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh review_popup app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/main.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Open the review popup with no args. The ghost text shows the scope menu.
Type ":SherpaReview"
Sleep 1500ms
Enter
Sleep 2200ms

# First word picks the scope. Submit with Ctrl-s to start the file review.
Type "file"
Sleep 1500ms
Ctrl+S

# Wait for the file review to start and the explanation to settle.
Sleep 3500ms

# With a review active, :SherpaReview opens a question editor instead.
Type ":SherpaReview"
Sleep 1500ms
Enter
Sleep 1800ms

Type "why does this mount App?"
Sleep 1200ms
Ctrl+S

Sleep 3000ms

Type ":qall!"
Enter
Sleep 600ms
