# Teach mode (historical note)

Sherpa no longer exposes `:SherpaTeach` as a primary command.
The user-facing walkthrough surface is now:

- `:SherpaReview`

The old teach idea evolved into a pre-planned review model that includes:
- a model-produced plan (via the `sherpa_plan` tool) driving a fixed list of stops
- self-labeled review scopes (`selection`, `diff`, `free`)
- a dedicated review pane with a plan TOC
- selection questions during review
- local review comments
- end-of-review agent follow-up

See:
- `docs/review-mode.md`
- `docs/architecture.md`
- `README.md`
