# Strider chat read-only demo — toggle chat-only read-only mode, then send a
# prompt that is guarded against file changes.
# Run:   vhs recordings/vhs/chat-readonly.tape

Output recordings/chat-readonly.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh chat_readonly app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/App.tsx`
Enter
Sleep 2500ms
Show

Sleep 1800ms

# Open chat, then enable the chat-only read-only guard. The compose winbar shows RO.
Type ":StriderChat"
Sleep 1200ms
Enter
Sleep 1000ms
Type ":StriderChatReadOnly on"
Sleep 1700ms
Enter
Sleep 1200ms

# Ask for an explanation while preserving the working tree.
Type "explain this component without changing files"
Sleep 1800ms
Ctrl+S
Sleep 4500ms

Type ":qall!"
Enter
Sleep 600ms
