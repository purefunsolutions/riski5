<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Pinned RISC-V specifications

Reference material for the riski5 core. Pinned by filename to a
specific upstream release so edits to the spec don't silently
invalidate what we've designed against.

| File | Upstream release | Downloaded |
|---|---|---|
| `riscv-spec-2026-04-16.pdf` | `riscv-isa-release-ea0f0fc-2026-04-16` from [riscv/riscv-isa-manual](https://github.com/riscv/riscv-isa-manual/releases/tag/riscv-isa-release-ea0f0fc-2026-04-16) | 2026-04-19 |

The current upstream release publishes a single unified PDF
(`riscv-spec.pdf`) covering the Unprivileged ISA, the Privileged
Architecture, and the extensions that have been ratified to date.
Older releases split these into two volumes ("Unprivileged" and
"Privileged") — keep that in mind when following cross-references
from older papers.

Licensing of the PDF follows the upstream manual: **CC-BY-4.0**,
RISC-V International. We redistribute it here for local use only;
the authoritative copy is the release asset linked above.

## How to re-pin

```sh
# From the repo root:
tag=$(gh api repos/riscv/riscv-isa-manual/releases/latest --jq .tag_name)
date=$(gh api repos/riscv/riscv-isa-manual/releases/latest --jq .published_at | cut -d'T' -f1)
curl -sSL -o "docs/riscv/riscv-spec-$date.pdf" \
  "https://github.com/riscv/riscv-isa-manual/releases/download/$tag/riscv-spec.pdf"
# Then update the table above with the new tag + date.
```

Old pinned PDFs get deleted in the same commit that updates the pin —
we don't accumulate unused specs under `docs/`.
