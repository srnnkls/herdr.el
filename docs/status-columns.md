# The dashboard's columns

What a row is made of, and what can be changed from outside `herdr-status.el`.

## The shape of a row

```
  ● api-review     claude  alpha   ▣ %1   ▤ limen   ⎇ feat/hooks   󰍛 opus-5   󱉸 561k/1M   /projects/limen
  │ │              │       │       └──────────── trailing fields ────────────┘            └─ directory
  │ │              │       └─ session, drawn only when Emacs watches more than one server
  │ │              └─ harness, behind its vendor glyph
  │ └─ name, cut to `herdr-status-name-width'
  └─ state glyph, behind the attachment marker
```

`herdr-status--row` concatenates the attachment marker, the state glyph and the three fixed cells, then joins whatever `herdr-status--trailing-columns` returns with two spaces. A nil cell drops out, so a column no row has a value for takes no room at all.

## One cell

```elisp
(herdr-status--field-column FIELD VALUE WIDTH &optional FACE)
```

FIELD is a symbol — `pane`, `workspace`, `branch`, `model`, `context`, `directory`. The call looks up the field's glyph, cuts VALUE to WIDTH, pads it back to WIDTH, and propertizes the result.

A nil VALUE becomes blanks of the same width, so the rows below and above stay aligned. A WIDTH of zero answers nil, which is how a column whose every row is empty disappears rather than drawing a run of spaces.

## Widths

`herdr-status--widths` measures one redraw's entries and answers a positional list: label, harness, session, pane, workspace, branch, model, context. `herdr-status--trailing-columns` reads it back with `nth`.

Each measurement is `herdr-status--width ENTRIES ACCESSOR MINIMUM FIELD`: the widest value any row carries, never below MINIMUM, then capped by `herdr-status-column-widths`.

## What can be changed from outside

| Concern | Where |
|---|---|
| Cap a column | `herdr-status-column-widths`, an alist of `(FIELD . COLUMNS)`; a field left out takes the widest value its rows carry |
| Change a glyph | `herdr-status-field-glyphs`, candidates in order of preference — the first the display can draw wins, and an empty candidate draws the field bare |
| Rename a reported token | `herdr-status-context-token`, `herdr-status-model-token` |
| Read what was cut | a cut cell carries the whole value under `herdr-status-full` and `help-echo`; `herdr-status-echo-cut-fields` says whether the echo area shows it as point crosses the cell |
| Draw a row of your own | `herdr-status-agent-row` takes an entry and the widths, so a section inserted through `herdr-status-sections-functions` draws on the same columns |
| Act on a finished redraw | `herdr-status-refresh-hook` runs in the dashboard buffer; `herdr-status-cached-agents` answers with the entries it was drawn from, and `herdr-status-visible-agents` with those the filters leave |

## Where a value comes from

Three kinds, and the difference decides who can extend what.

- `pane` and `workspace` are fields of the entry herdr reports.
- `branch` and `directory` are computed from the entry's working directory.
- `model` and `context` are read from the entry's `tokens`, the metadata another package reported to that pane through `pane.report_metadata`. Limen reports both; anything else may report its own.

So the *values* are open to any package that can reach the herdr socket. The *set of columns* is not.

## The set of columns is closed

Adding one means editing `herdr-status.el` in four places: an accessor, an entry in `herdr-status-field-glyphs`, a measurement in `herdr-status--widths`, and a cell in `herdr-status--trailing-columns`. The positional `nth` indexing between the last two means inserting a column anywhere but the end renumbers every column after it.

Opening it is a contained change: a `herdr-status-columns` alist of `(FIELD . ACCESSOR)` that both `--widths` and `--trailing-columns` walk, which replaces the positional list with lookup by field and removes the renumbering hazard.
