<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Pinned Terasic DE2 board reference

Hardware reference for the Altera DE2 (Cyclone II EP2C35F672C6) we
target. Pinned by filename so edits to the upstream document don't
silently invalidate the pin assignments and timing numbers we
derive from it.

| File | Upstream release | Downloaded |
|---|---|---|
| `DE2_UserManual_v1.6_2012-10-08.pdf` | DE2 User Manual v1.6 (2012-10-08), from the [Terasic DE2 board archive page](https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&CategoryNo=53&No=30&PartNo=4) | 2026-04-20 |
| `DE2_Pin_Table_2006-02-15.pdf` | DE2 Pin Table (2006-02-15), same archive page | 2026-04-20 |
| `DE2_Schematic.pdf` | DE2 board schematic — Terasic's CD-ROM hosts the original but the download is gated behind a member login. Mirrored from [Columbia CS course materials](https://www.cs.columbia.edu/~sedwards/classes/2008/4840/DE2_schematics.pdf) (also mirrored on Georgia Tech and Tufts course pages). Page count + content match the version distributed on Terasic's DE2 System CD-ROM. | 2026-04-20 |

This is the canonical document for:

- DE2 schematic and pin assignments — Chapter 4 ("Using the DE2
  Board") and Appendix A list every connector and pin name we
  reference from `pkgs/riski5-core/Riski5.qsf`.
- HD44780 16×2 LCD wiring (`LCD_DATA[7..0]`, `LCD_RS`, `LCD_RW`,
  `LCD_EN`, `LCD_ON`, `LCD_BLON`).
- Push-buttons (`KEY[3..0]`), slide switches (`SW[17..0]`), red
  LEDs (`LEDR[17..0]`), green LEDs (`LEDG[8..0]`), 7-segment
  displays (`HEX[7..0]`).
- External memory chip part numbers and connections — 512 KB SRAM
  (IS61LV25616), 8 MB SDR SDRAM (IS42S16400), 4 MB NOR flash —
  feeding our phase-1C (T26+) and phase-1D (T32+) work.
- USB-Blaster JTAG path and EPCS configuration flow.

Copyright remains with **Terasic Inc.**; we redistribute the PDF
here only as a build-time reference. The authoritative copy lives
at the upstream archive page linked above.

## How to re-pin

The Terasic archive page lists the current revision; download
preserving the version + release date in the filename:

```sh
# From the repo root, with the FID and date taken from the archive page:
curl -sSL -o "docs/de2/DE2_UserManual_v<ver>_<YYYY-MM-DD>.pdf" \
  "https://www.terasic.com.tw/cgi-bin/page/archive_download.pl?Language=English&No=30&FID=<fid>"
# Then update the table above with the new version + date and delete
# the old pinned PDF in the same commit.
```

Old pinned PDFs get deleted in the same commit that updates the
pin — we don't accumulate unused references under `docs/`.
