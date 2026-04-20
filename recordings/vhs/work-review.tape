# Sherpa work+review demo — run :SherpaWork, then review the resulting diff.
# Run:   vhs recordings/vhs/work-review.tape

Output recordings/work-review.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh work_review app --git)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/App.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Kick off a broader work request.
Type ":SherpaWork add loading states to the lobby flow"
Sleep 2800ms
Enter

# Let the work pass complete.
Sleep 3500ms

# Review the resulting working-tree diff.
Type ":SherpaReview diff"
Sleep 2200ms
Enter
Sleep 3500ms

# Leave a comment on a chunk of the diff.
Type "gg"
Sleep 800ms
Type "j"
Sleep 700ms
Type "Vj"
Sleep 1600ms
Type ":SherpaComment this branch needs a clearer empty state"
Sleep 2600ms
Enter
Sleep 2500ms

# Advance past the remaining review items to trigger the summary.
Type ":SherpaNext"
Sleep 1800ms
Enter
Sleep 3500ms

Type ":qall!"
Enter
Sleep 600ms
