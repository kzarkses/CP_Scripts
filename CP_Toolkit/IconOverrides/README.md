# Icon overrides

Drop PNG files here to replace any CP_Toolkit procedural icon.

Contract:

- **Name** = the icon function name, exactly: `Play.png`, `StarFilled.png`,
  `TriangleDown.png`, `Folder.png`, … (see `Icons.lua` for the full list).
- **White shapes on a transparent background** — the file is tinted to the
  theme color at bake time (`gfx.muladdrect`), so one PNG works for every
  theme and every state (hover, dim, accent…).
- **64-128 px, square** recommended. Non-square files are aspect-fit
  centered.

Files are picked up on the next bake; call `UI.Icons.ReloadOverrides()` (or
restart the script) after adding or editing a file. A missing PNG simply
falls back to the built-in vector glyph.
