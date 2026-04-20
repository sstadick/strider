# Sherpa demos

These asciinema demos mirror the flows shown in the main README.

## Generate all demos

```bash
python3 recordings/make_recordings.py
```

## Generate one demo

```bash
python3 recordings/make_recordings.py search
```

## Play demos

```bash
./recordings/show_demos.sh
./recordings/show_demos.sh search
```

## Demos

- `search.cast`
- `review-file.cast`
- `review-diff.cast`
- `review-searches.cast`
- `review-selection.cast`
- `review-comment.cast`
- `patch.cast`
- `work-review.cast`

All demos use the bundled fake pi backend and fixture projects so they stay fast and reproducible.
