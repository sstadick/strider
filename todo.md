# Ready for work
- Stream all text back, but especially thinking
- Render reads nicely / fence them even when they are given back as line ranges
    - just codeblock fece them.
    - I think every tool call needs a codeblock fence actually, otherwise the markdown tries to render all kinds of weird stuff
    - there is also something sus happening with multi-tool call turns, like the ordering is getting messsed up
    - there's something annoying happening "thinking" where some code-looking elements are getting highlighting
    - diffs are getting rendered really weird. I think they need code block fencing, it's weird that they have the `tool edit` and then a ---[diff] marker
        - also it's the background that should be green / red, not the text
- Running /compact does nothing - are we stripping commands or something?
- Add a way to hard reset the agent
- something is wrong with the log header bar, it is showing the lat assistant message or something, but then I can't see amount of context used, which is very important
- take a pass at simplifying / speeding up each turn, I think we have quite a bit of tooling between each request, and the model, and each reply and the user
- for the SherpaLogFlow, need some indicator that it's working. Probably need to refactor and unify the SherpaCompose header to not be ont eh compose buffer or something.
- How do I expose notifications / "SherpaQ running" even when in insert mode and such?
    - Looks like it shows up after leaving insert mode, cool

# Need refinement
- When a tool call hangs, we need a way to kick the model to move on

# Done
- Make use of vim.notify for when Patch and Q are done so the user can open the chat
    - bonus, notify if chat is not open and the model hits the end of a turn.
- If the "coding" pane is in use, don't "follow along" with tool use. and if that's too hard, maybe dont' follow along at all, and only do jump to locations for the review itself.
- The first review message in each file does not get the inlay help text
- :SherpaComment should pop up our multiline buffer
- status line needs cleanup, and maybe moving to "header" compse buffer, it should just be a single "Sherpa is" instead of a few in a row
- Markdown exceprts in review are getting rendered and it looks confusing
- Ability to paste in images like pi and claude (ctl-v to paste a path to a temp file)
- Add in reasoning text (in a fait text, just like pi does) to the log
- I really want a "code question" thing that doesn't interup flow / maybe doesn't even pollute history. these are just one off questions. li
- When a Review questions is fired off, the Chat is opened when it's answered, this should either hook into the code question flow above, or a t min, open the compose buffer as well.
- Add a second (and third) pi process
    - SherapQ, SherpaSearch, SherpaPatch can use it to do stuff while the main one is running
    - I think this second process could still have a log / that's where answers would show up, but the only way Q can talk to it is via the pop-up. the goal is stay in flow with Qs, Patches, etc.
    - Nice to have: send to primary chat, so that we could lift some subset of the /tree to the main chat to share context better
    - I think SherpaReview should actually get it's own dedicated pi process as well. Any follow up questions in the review hit that specific process, kill it on review end, have a review summary (with comments) forwarded to the main chat.
    - This second log buffer, let's just call it SherpaLogFlow (for the Q, Search, Patch) and SherpaLogReview (for the review tool), open and close it when that command is called. 
    - the goal is to make the flow easier for programmers to stay in the zone, by moving Q/Prompt/Search to pop ups and non-interactable (easily) chat, and no default window pops, that lets the programmer stay programming longer. By moving these to their own processes, it gives us something to do while larger prompts are running in SherpaChat
- Don't markdown render the compose buffer
- Don't do .5s second ticks
    - move the timer to the right side of the bar so it isn't jumping around
