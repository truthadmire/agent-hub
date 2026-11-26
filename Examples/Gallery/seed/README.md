# Field Notes

A text-only photography index with a local preview and JSON API. Five invented photo entries keep these tests independent of external assets and private photo libraries.

Run `python3 -B -m unittest discover -s tests` for the baseline. Start the local preview using `python3 -B server.py --port 8765` and visit the printed loopback URL.

## Example task

Add a category filter, paginated API and empty state. Preserve the catalogue typography. Share the following contract across the page, data and test workers.

- `GET /api/photos?category=Coast&page=2` returns `items`, `page`, `pages`, and `total`. Pages start at one with two entries per page. Category filtering happens before pagination, in catalogue order.
- Unknown categories and pages beyond the end return an empty list. Non-numeric or non-positive pages return HTTP 400.
- The page supports category selection, empty results and pagination links that retain the selection. The form must work with JavaScript disabled.
- Run the Python test suite on the integrated worktree and open the local preview.
