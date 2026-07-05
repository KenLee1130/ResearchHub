# ResearchHub

A local-first research workspace for macOS — notes, daily journal, calendar,
and a pomodoro timer, built around plain text files and designed from day one
to collaborate with AI agents.

**Everything is a file.** Notes and journals are Markdown on your disk;
events, tasks, and focus history are human-readable JSON. No account, no
server, no telemetry — and any external tool (Claude, scripts, automations)
can integrate by just reading and writing the same files.

## Features

- **Notes** — folder-based Markdown library with `[[wikilinks]]`,
  KaTeX math (`$…$`, `$$…$$`, LaTeX environments), Overleaf-style
  autocomplete for LaTeX commands, Zotero `\cite{…}` resolution,
  footnotes/`\eqref` cross-references, image paste, and one-click PDF export.
- **Block editor** — a Notion-style editor (Tiptap in a WKWebView) for
  journals and notes: slash menu, markdown shortcuts, click-to-edit math
  blocks, drag-to-reorder, collapsible toggle blocks. Markdown stays the
  single source of truth. Fully offline — all web dependencies are bundled.
- **Journal + calendar** — one Markdown file per day, month calendar with
  event lanes, tagged events with rich descriptions, `.ics` export.
- **Tasks** — checkboxes in any note or journal are aggregated on the home
  screen, with `!high` / `!low` priority and `@due(7/10)` due-date markers.
  Tasks that keep reappearing in journals without getting done are surfaced
  ("added 3 times, never finished — let it go or do it today") with a
  one-click trash-and-strikethrough flow.
- **Pomodoro** — plan/done notes per session, streak stats, and productivity
  analytics: peak focus hours, best weekday, plan-adherence rate, average
  first-session time.
- **Evening planning ritual** — a dedicated view for writing tomorrow's
  journal next to your productivity rhythm, with one-click carry-over of
  today's unfinished tasks.
- **AI bridge** — the app auto-generates a machine-readable data contract
  (`.hub/README.md`) inside your library folder. An AI agent can analyze
  your journals, write encouragement and a time-blocked schedule suggestion
  into `.hub/claude/insights.json`, and the app renders it on the home
  screen — with one click to turn the suggested schedule into calendar
  events.
- **Bilingual** — full Traditional Chinese / English UI with live switching.

## Integrations

| Bridge | How |
|---|---|
| AI agents / scripts | Read & write the files described in `.hub/README.md` (auto-generated in your library folder) |
| Zotero | Local API (`localhost:23119`, port configurable in Settings) for citation picking and PDF attachments |
| Calendar apps | Export all events as standard `.ics` |
| Anything else | `researchhub://note?path=…` and `researchhub://journal?date=YYYY-MM-DD` URL scheme |
| Other editors | Notes are plain Markdown with `[[wikilinks]]` — open the same folder in Obsidian or any editor |

## Build

Requirements: macOS 26+, Xcode 26+.

```bash
git clone https://github.com/KenLee1130/ResearchHub.git
open ResearchHub/ResearchHub.xcodeproj   # ⌘R
```

On first launch, pick (or create) a library folder — the app scaffolds
`Notes/`, `Journal/`, and `.hub/` inside it. Put the folder in iCloud Drive
if you want it synced across machines.

Web editor dependencies (Tiptap, KaTeX, marked) are pre-bundled in
`ResearchHub/Resources/EditorWeb/`. To rebuild them from pinned npm
versions: `scripts/build-web-resources.sh`.

## Architecture notes

- SwiftUI app, no third-party Swift dependencies.
- The block editor is Tiptap/ProseMirror inside a persistent `WKWebView`
  (single instance, preloaded at launch); Swift ↔ JS talk over script
  messages, and the JS bundle is injected as a `WKUserScript` so the editor
  works fully offline.
- Markdown is canonical everywhere: the block editor converts markdown →
  blocks on load and blocks → markdown on every edit.
- Language switching swaps `Bundle.main` for a subclass that redirects
  string lookups at runtime — instant UI language change without restart.
- All state lives in the user's folder; deleting the app leaves your data
  as ordinary Markdown and JSON.

## License

MIT
