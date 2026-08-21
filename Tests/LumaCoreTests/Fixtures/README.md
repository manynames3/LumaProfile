# Synthetic fixture manifest

Every file in this directory is authored, recorded-looking **synthetic test data**. None was captured from ArgyllCMS, a display, an ICC installation, or measurement hardware. Names, serials, values, paths, timings, and warnings are fictitious and exist only to exercise deterministic parser behavior.

- `version.synthetic.txt`: representative version banner with mixed stdout/stderr-style context.
- `instrument-list.synthetic.txt`: two numbered instrument entries and a display section boundary.
- `instrument-list-argyll35-i1display.synthetic.txt`: the pinned tool's numbered HID/serial-port usage shape with a synthetic i1Display entry.
- `instrument-none.synthetic.txt`: explicit no-device result.
- `instrument-malformed.synthetic.txt`: nonempty unknown format that must fail closed.
- `spotread-success.synthetic.txt`: XYZ, Yxy, CCT, and a retained warning.
- `spotread-yxy-only.synthetic.txt`: Yxy-only reconstruction path.
- `spotread-truncated.synthetic.txt`: incomplete numeric triplet.
- `spotread-malformed.synthetic.txt`: invalid negative/non-finite-style measurement.
- `dispcal-console.synthetic.txt`, `dispread-console.synthetic.txt`, `colprof-console.synthetic.txt`, `dispwin-console.synthetic.txt`, and `profcheck-console.synthetic.txt`: tool-specific progress/message/warning shapes.
- `console-truncated.synthetic.txt`: interrupted line that must not become invented progress.
- `unknown-version.synthetic.txt`: future major-version output that compatibility checks reject.
- `prompt-known.synthetic.txt`: a recognized placement request.
- `prompt-unknown.synthetic.txt`: an unfamiliar input request that must fail closed.
- `correction-sample-id.synthetic.ccss`: minimal valid spectral correction with a numeric `SAMPLE_ID` column.
- `profcheck-patches.synthetic.txt` and `profcheck-summary.synthetic.txt`: patch-detail and summary-only verification shapes.
- `verification.synthetic.ti3`: minimal RGB/XYZ verification table with a synthetic gamma 2.2 gray ramp.

When a real transcript reveals a new structure, sanitize it and author a minimal synthetic analogue instead of committing the transcript itself.
