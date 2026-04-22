# Ready for work
- Ability to paste in images like pi and claude (ctl-v to paste a path to a temp file)
- Add in reasoning text (in a fait text, just like pi does) to the log

# Need refinement
- I really want a "code question" thing that doesn't interup flow / maybe doesn't even pollute history. these are just one off questions. li
- When a Review questions is fired off, the Chat is opened when it's answered, this should either hook into the code question flow above, or a t min, open the compose buffer as well.
- When a tool call hangs, we need a way to kick the model to move on

# Done
- If the "coding" pane is in use, don't "follow along" with tool use. and if that's too hard, maybe dont' follow along at all, and only do jump to locations for the review itself.
- The first review message in each file does not get the inlay help text
- :SherpaComment should pop up our multiline buffer
- status line needs cleanup, and maybe moving to "header" compse buffer, it should just be a single "Sherpa is" instead of a few in a row
- Markdown exceprts in review are getting rendered and it looks confusing
