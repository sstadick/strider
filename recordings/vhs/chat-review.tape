# Strider chat+review demo — send a message via :StriderChat, then review the
# resulting diff.
# Run:   vhs recordings/vhs/chat-review.tape

Output recordings/chat-review.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh chat_review app --git)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/App.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Send a broader request through the chat command.
Type ":StriderChat add loading states to the lobby flow"
Sleep 2800ms
Enter

# Let the chat pass complete.
Sleep 3500ms

# Review the resulting working-tree diff.
Type ":StriderReview walk me through the diff on this branch"
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
Type ":StriderComment this branch needs a clearer empty state"
Sleep 2600ms
Enter
Sleep 2500ms

# Advance past the remaining review items to trigger the summary.
Type ":StriderNext"
Sleep 1800ms
Enter
Sleep 3500ms

Type ":qall!"
Enter
Sleep 600ms
