# Sherpa reasoning-log demo — show faint reasoning text landing in the log
# before tool output and the final assistant summary.
# Run:   vhs recordings/vhs/reasoning-log.tape

Output recordings/reasoning-log.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh reasoning_log app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/main.tsx`
Enter
Sleep 2500ms
Show

Sleep 1500ms

# Run a chat turn that emits reasoning, tool activity, and a final answer.
Type ":SherpaChat add a banner"
Sleep 1600ms
Enter
Sleep 5000ms

Type ":qall!"
Enter
Sleep 600ms
