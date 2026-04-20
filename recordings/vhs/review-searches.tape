# Sherpa review-searches demo — kick off a search, then review the results.
# Run:   vhs recordings/vhs/review-searches.tape

Output recordings/review-searches.gif

Set Shell "bash"
Set FontSize 14
Set Width 1200
Set Height 700
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `WS=$(recordings/vhs/prep.sh review_searches app)`
Enter
Sleep 400ms
Type `clear && recordings/vhs/run-nvim.sh "$WS" src/main.tsx`
Enter
Sleep 2500ms
Show

Sleep 2500ms

# Run a search that returns multiple roots.
Type ":SherpaSearch show all entry roots"
Sleep 2500ms
Enter

# Wait for telescope to open with the results.
Sleep 3000ms

# Accept the first result.
Enter
Sleep 2000ms

# Start a review over the search results.
Type ":SherpaReview searches"
Sleep 2200ms
Enter

Sleep 4500ms

Type ":qall!"
Enter
Sleep 600ms
