# NNN. <Feature title> — tasks

Each task is one pull request (≤ ~600 changed lines of non-generated code, tests included) of one or more commits:
failing test first, then code; the build is green after each commit. Small adjacent tasks may share one PR: the later
task is marked `(same PR as Tn)`. A task split later becomes `T7.1`, `T7.2` (no renumbering). Each task updates the
living docs its behavior change affects. The last task sets `status: Implemented`.

- [ ] T1 (AC-1) …
- [ ] T2 (AC-2, AC-3) …
