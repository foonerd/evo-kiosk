#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
"""Generate the fully transparent cursor theme shipped in the kiosk layer.

Why a theme and not a compositor action:

  labwc's HideCursor suppresses a cursor that exists, and the cursor
  returns on the next pointer motion — its own manual says so. That is
  fine for a touch-only seat, where nothing ever moves a pointer, and
  useless the moment a mouse is attached. A theme whose every cursor is
  transparent has nothing to reveal: the pointer still moves, still
  hovers, still clicks, and draws no pixels. It also works on labwc
  0.8.3, which rejects HideCursor outright.

Output is committed under layer/share/icons/evo-blank so the shipped
bytes are reviewable and installed like any other layer file. Re-run
this script to regenerate; a fixture fails if the tree drifts from it.

Xcursor format: a header, a table of contents, then image chunks of
ARGB pixels. One 1x1 image with alpha 0 per nominal size is the whole
theme.
"""
import os
import struct
import sys

# Nominal sizes a compositor may ask for. A size absent from the theme
# resolves to the nearest present one, but carrying the common set
# keeps the lookup exact.
SIZES = [16, 24, 32, 48, 64]

CHUNK_TYPE_IMAGE = 0xFFFD0002

# Every cursor name a compositor or client is likely to request. A name
# the theme does not carry falls through to an inherited theme and comes
# back as a visible pointer, which would defeat the whole exercise, so
# this list is deliberately broad.
NAMES = [
    "default", "left_ptr", "arrow", "top_left_arrow", "pointer",
    "hand", "hand1", "hand2", "grab", "grabbing", "text", "xterm",
    "ibeam", "crosshair", "cross", "wait", "watch", "progress",
    "left_ptr_watch", "help", "question_arrow", "move", "all-scroll",
    "fleur", "not-allowed", "no-drop", "forbidden", "copy", "alias",
    "context-menu", "cell", "zoom-in", "zoom-out", "col-resize",
    "row-resize", "n-resize", "s-resize", "e-resize", "w-resize",
    "ne-resize", "nw-resize", "se-resize", "sw-resize", "ns-resize",
    "ew-resize", "nesw-resize", "nwse-resize", "sb_h_double_arrow",
    "sb_v_double_arrow", "top_side", "bottom_side", "left_side",
    "right_side", "top_left_corner", "top_right_corner",
    "bottom_left_corner", "bottom_right_corner", "dnd-move",
    "dnd-copy", "dnd-none", "vertical-text", "wayland-cursor",
    "X_cursor",
]

THEME_NAME = "evo-blank"


def transparent_cursor() -> bytes:
    """One Xcursor file carrying a 1x1 transparent image per size."""
    chunks = []
    for nominal in SIZES:
        chunks.append(
            struct.pack(
                "<IIIIIIIII",
                36,                 # chunk header size
                CHUNK_TYPE_IMAGE,   # type
                nominal,            # subtype: nominal size
                1,                  # version
                1,                  # width
                1,                  # height
                0,                  # xhot
                0,                  # yhot
                0,                  # delay
            )
            + struct.pack("<I", 0x00000000)  # a single fully transparent pixel
        )
    header = struct.pack("<4sIII", b"Xcur", 16, 0x00010000, len(SIZES))
    toc = b""
    pos = 16 + 12 * len(SIZES)
    for nominal, chunk in zip(SIZES, chunks):
        toc += struct.pack("<III", CHUNK_TYPE_IMAGE, nominal, pos)
        pos += len(chunk)
    return header + toc + b"".join(chunks)


def write_theme(root: str) -> int:
    cursors = os.path.join(root, "cursors")
    os.makedirs(cursors, exist_ok=True)
    # Drop anything stale so a removed name cannot survive a regenerate.
    for existing in os.listdir(cursors):
        os.remove(os.path.join(cursors, existing))
    with open(os.path.join(cursors, "default"), "wb") as handle:
        handle.write(transparent_cursor())
    for name in NAMES:
        if name == "default":
            continue
        os.symlink("default", os.path.join(cursors, name))
    with open(os.path.join(root, "index.theme"), "w") as handle:
        handle.write(
            "[Icon Theme]\n"
            f"Name={THEME_NAME}\n"
            "Comment=Fully transparent pointer for the kiosk seat\n"
        )
    return len(NAMES)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <theme-root>", file=sys.stderr)
        return 2
    count = write_theme(sys.argv[1])
    print(f"{sys.argv[1]}: {count} cursor names, sizes {SIZES}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
