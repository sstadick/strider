# Strider chat plan proposal demo — plan approval happens in chat compose,
# without a native Neovim select dialog blocking the scrollback.
# Run:   vhs recordings/vhs/chat-plan.tape

Output recordings/chat-plan.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh chat_plan app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/App.tsx`
Enter
Sleep 2500ms
Show

Sleep 1500ms

# The fake pi backend emits a plan proposal through extension_ui_request.
# Strider renders it in the chat log and seeds compose for approval.
Type ":StriderChat"
Sleep 1200ms
Enter
Sleep 900ms
Type "propose a plan before changing files"
Sleep 1500ms
Ctrl+S
Sleep 2800ms

# Accept the compose-seeded plan as-is.
Ctrl+S
Sleep 3500ms

Type ":qall!"
Enter
Sleep 600ms
