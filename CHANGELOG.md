# Changelog

## 0.2.0 — 2026-11-08

- Click the menu bar reading to open a 12-hour glucose history graph.
- Highlight the target range returned by LibreLinkUp and show “Glucose In Range” for readings within its inclusive boundaries.
- Use a labeled 70–180 mg/dL default when API targets are missing or invalid; convert the range with the display units.
- Keep the history panel below the menu bar and inside the current screen, with close-button, Escape, toggle-click, and outside-click dismissal.
- Keep history in memory and show missing periods as gaps.
- Add checks for history filtering, screen placement, API targets, range boundaries, and fallback behavior.
