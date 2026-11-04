# SyncTeX replacement experiment

This branch tests whether the upstream SyncTeX C library can replace TeXLocal's
Rust parser without losing navigation in compiled or live PDFs. The application
continues to use its existing parser while the experiment runs.

The probe builds unmodified [upstream source](https://github.com/jlaurens/synctex/tree/04cf8e3e8665ff203248d7af78ee1129afbc1b64)
at a fixed revision. It uses the strong-display-query build option
and rejects clamped results to respect TeXLocal's exact-line searches. It does
not introduce a library, subprocess, or download into the application.

The TeX check captures real compiled and TeXpresso snapshots before their
temporary projects disappear. Two checked-in fixture variants and a generated
400-page document supplement those snapshots. Both probes report inputs,
first forward hits, inverse hits at those boxes, parse duration, and mean
exact-line query duration over 20 passes. Coordinate or inverse differences
need interpretation; agreement with the old implementation alone is not a
correctness oracle.

To reproduce on macOS with the repository's TeX/TeXpresso prerequisites:

~~~sh
export TEXLOCAL_SYNCTEX_EXPERIMENT="$(mktemp -d)"
export TEXLOCAL_TEXPRESSO="/path/to/Helpers/texpresso"
cargo test --locked --no-fail-fast -p texlocal-core -- --ignored --nocapture
bash tools/synctex-experiment/run.sh "$TEXLOCAL_SYNCTEX_EXPERIMENT"
~~~

The experiment report is printed in the TeX check log and saved with all
captured PDFs and SyncTeX files in the workflow artifact. A failed native probe
is recorded as a result; missing fixtures or baseline failures stop the run.
The existing integration tests still have to pass.

Adoption requires usable live input mappings, acceptable navigation and cost,
a small safe adapter, and a maintainable static build. Vendoring would add
roughly 12,000 third-party C/header lines while removing about 1,200 first-party
Rust lines. It must not be presented as a reduction in total repository size.

The follow-up diagnostic also removes only TeXpresso's completed-input markers
from a temporary copy of each live SyncTeX file. This tests whether the simplest
normalization would resolve compatibility, without introducing a production
preprocessor. File tails and postamble presence are logged for rejected files.
Native timings exclude a production Rust adapter and synchronization; treat
them as an optimistic estimate. Parse timings are single samples.

The comparison still runs when an integration test fails, provided setup
completed and the required snapshots were captured. The job retains the test
failure. The C probe uses -O3; Rust uses the workspace release profile.
