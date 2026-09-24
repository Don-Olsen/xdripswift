Watch-reading durability draft — transfer package
================================================

Classification: Skal overføres (preserved draft, not release-ready)

This package preserves the existing local four-Swift-file draft exactly as it
was found in worktrees/watch-reading-durability. No code was recreated from
documentation, and no development, tests, commit, push, build or upload were
performed while making this package.

Basis and relationship
----------------------

- Branch: fix/watch-reading-durability-4260
- Full basis commit: e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21
- Later Mac source: d09bac575d9622d1368cbba0dc3039862d997ed3
- d09bac57 is a linear descendant, 25 commits after e11a6f4.
- Stable patch-id: eb1be6714fea885a77cac99ac53a3c6b8e8f9e37

What the draft changes
----------------------

The draft moves durable Watch reading queue preparation ahead of local
display/alarm publication, records whether the queue write was confirmed,
repairs the display-cache/outbox relationship after restart, and surfaces a
storage warning. It adds eight testSubmission... XCTest methods. The four
Swift files total 370 insertions and 27 deletions.

Contents
--------

- watch-reading-durability.patch
  Exact full-index Git patch for the four Swift files, relative to e11a6f4.
- GIT-STATUS.txt
  Full basis commit, branch, remote, short status and porcelain-v2 status as
  observed when the package was made.
- COMPARISON-D09BAC57.txt
  Concrete evidence that the draft is absent from and not replaced in d09bac57.

Transfer caution
----------------

The patch reverse-checks cleanly against the preserved dirty worktree, but it
does not apply directly to d09bac57 because later commits changed overlapping
WatchStateModel code. Transfer therefore requires a reviewed manual integration
onto d09bac57 or its chosen descendant. This is an uncommitted and unverified
draft. A preserved review also notes a restore/read-failure edge case that must
be assessed before treating the fix as release-ready.

There are no new/untracked source or test files in the draft. All code needed
to reproduce the four modified tracked Swift files is contained in the patch.
Complete e11-era file copies are deliberately not included because replacing
d09bac57 files wholesale would discard later committed work.

Excluded deliberately
----------------------

The separate README.md +2 release-guide link and untracked AGENTS.md/docs/
items shown by Git status are not part of the four-Swift-file correction and
are not included. No keys, certificates, provisioning material, personal
settings or health logs are included.
