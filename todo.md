# Ready for work
- Still need a way to queue up follow up messages
- Generally speed up the review process. Unsure how to do this. But for small reviews maybe steal some context from... somewhere?
- we need to do a round of tidy up on the flow related logs and such to make sure we have commands to see everything
- Sometimes the Chat/Log uis get weird if I open a file in them


# Need refinement
- When a tool call hangs, we need a way to kick the model to move on
- Buffer per question? seems like it could be useful to get multiple streams going at once... but we do already have two
- Some pi TUI commands (/session, /copy, /share, /hotkeys, /changelog, /settings) have no RPC equivalent

# Done
- When we run commands like /compact - show something to indicate that things are happening
    - raw RPC commands now set a pending command request and show `Working` in the compose/log winbars until their response arrives.
- Guard same-lane sends while pi is busy so extension commands do not trigger:
    ```
    Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.
    ```
    - Lua rejects new prompt-style work when that lane has a pending request.
    - The pi extension also refuses `sendUserMessage` while its process is busy.
- The "strider_clarify" blocks so I can't see the plan that I'm asked to provide a response on
    - fixed: force vim.cmd("redraw") before vim.ui.select in plan proposal picker
- Add a way to hard reset the agent
    - /new sends the new_session RPC type; /fork, /compact, /export also route as raw RPC commands
    - session changes render a visual separator in the log
- Running /compact does nothing - are we stripping commands or something?
    - fixed: /compact is a dedicated RPC type, not a prompt-routed extension command
- multi-tool call ordering: results now insert next to their headers via extmark tracking
- diffs use inline custom rendering with Strider extmark coloring
- Stream all text back, but especially thinking
- Make use of vim.notify for when Patch and Q are done so the user can open the chat
    - bonus, notify if chat is not open and the model hits the end of a turn.
- If the "coding" pane is in use, don't "follow along" with tool use. and if that's too hard, maybe dont' follow along at all, and only do jump to locations for the review itself.
- The first review message in each file does not get the inlay help text
- :StriderComment should pop up our multiline buffer
- status line needs cleanup, and maybe moving to "header" compse buffer, it should just be a single "Strider is" instead of a few in a row
- Markdown exceprts in review are getting rendered and it looks confusing
- Ability to paste in images like pi and claude (ctl-v to paste a path to a temp file)
- Add in reasoning text (in a fait text, just like pi does) to the log
- I really want a "code question" thing that doesn't interup flow / maybe doesn't even pollute history. these are just one off questions. li
- When a Review questions is fired off, the Chat is opened when it's answered, this should either hook into the code question flow above, or a t min, open the compose buffer as well.
- Add a second (and third) pi process
    - StriderQ, StriderSearch, StriderPatch can use it to do stuff while the main one is running
    - I think this second process could still have a log / that's where answers would show up, but the only way Q can talk to it is via the pop-up. the goal is stay in flow with Qs, Patches, etc.
    - Nice to have: send to primary chat, so that we could lift some subset of the /tree to the main chat to share context better
    - I think StriderReview should actually get it's own dedicated pi process as well. Any follow up questions in the review hit that specific process, kill it on review end, have a review summary (with comments) forwarded to the main chat.
    - This second log buffer, let's just call it StriderLogFlow (for the Q, Search, Patch) and StriderLogReview (for the review tool), open and close it when that command is called.
    - the goal is to make the flow easier for programmers to stay in the zone, by moving Q/Prompt/Search to pop ups and non-interactable (easily) chat, and no default window pops, that lets the programmer stay programming longer. By moving these to their own processes, it gives us something to do while larger prompts are running in StriderChat
- Don't markdown render the compose buffer
- Don't do .5s second ticks
    - move the timer to the right side of the bar so it isn't jumping around
- Running /compact does nothing - are we stripping commands or something?
    - fixed: dedicated RPC type, not a prompt-routed command
- Render reads nicely / fence them even when they are given back as line ranges
    - read/write use code fences for syntax highlighting.
    - bash/grep/find/ls use compact gutter rows so mixed command output
      does not get fake syntax highlighting or accidental markdown rendering.
    - multi-tool call ordering fixed via extmark tracking
    - (don't act on this yet, needs more invstigatin) there's something annoying happening "thinking" where some code-looking elements are getting highlighting
    - diffs use inline custom rendering with Strider extmark coloring
- UX status/acceptance pass
    - `:StriderStatus` summarizes lane state, pending controls, review progress, and last errors.
    - `:StriderNext!` accepts the current review stop and advances without adding another top-level command.
    - compose ghost text/winbar says whether `<C-s>` will send, steer, or answer clarify.
- something is wrong with the log header bar, it is showing the lat assistant message or something, but then I can't see amount of context used, which is very important
- show the args to the tools like grep and such
- take a pass at simplifying / speeding up each turn, I think we have quite a bit of tooling between each request, and the model, and each reply and the user
- for the StriderLogFlow, need some indicator that it's working. Probably need to refactor and unify the StriderCompose header to not be ont eh compose buffer or something.
    - kind of does this when in normal mode
- Replace the visible diff fence with custom diff rendering; edit headers now carry `(+N -M)` stats.
- are we actually diong "steering" prompts and such?
- move the timer to the left side  next to Working like: `Working (<time>)`
- Paste clipboard images at the cursor instead of the end of the compose
  buffer; insert a newline after the `@image <path>` marker.
- Don't open the review log on review start
    - Or on review end
    - The flow at the end of the review could still use a bit of work / messaging, it's not clear what is about to happen when you ht the end / how the end works, and that comments and a summary.
    - I don't think we need to put that in the side bar, but maybe we need a "final buffer" or something that says review end, and shows the summary in-buffer. Give the user a shot to edit that in the buffer, and then send it to the main flow?
- I think we lost the "Search/Patch/Q" done green dot in the bottom left, open to other ways to indicate doneness though.
    - at a minimum the message is getting burried, or not showing for some reason?
okay first, updat my ~/aihome/dotfiles with
- Update Strider’s prompt rendering so steering prompts and follow-up prompts each have their own distinct colored line-start indicator, separate from normal user prompts. Include tests/docs if the rendering behavior is user-visible.
