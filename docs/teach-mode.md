# Teach mode (historical note)

Sherpa no longer exposes `:SherpaTeach` as a primary command.
The user-facing walkthrough surface is now:

- `:SherpaReview`

The old teach idea evolved into a broader review model that includes:
- explicit review scopes (`file`, `diff`, `last`, `searches`)
- a dedicated review pane
- selection questions during review
- local review comments
- end-of-review agent follow-up

See:
- `docs/review-mode.md`
- `docs/architecture.md`
- `README.md`
