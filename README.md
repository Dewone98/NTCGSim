# NTCG Simulator

A native iOS trading-card-game simulator, built in SwiftUI. Offline-first: build decks,
browse the card pool, and play full games against an AI opponent or both sides yourself.

> **Unofficial.** This is a fan project and is not affiliated with, endorsed by, or
> connected to any card game publisher. The card pool that ships with the app is demo
> data written for this project — see [CARD_DATA.md](CARD_DATA.md) to import your own.

---

## Building

Xcode is required. If `xcodebuild` is not on your path, either point the developer
directory at Xcode once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

…or skip that and use the bundled script, which sets `DEVELOPER_DIR` itself:

```bash
./build.sh          # build for the simulator
./build.sh run      # build, install and launch on the booted simulator
./build.sh test     # run the unit tests
```

**Target:** iOS 18.0 · iPhone and iPad · SwiftUI · Swift 5 language mode.

---

## Project layout

The Xcode target uses **synchronized folders** — any `.swift` file added under
`NTCGSimulator/` is compiled automatically. There is no need to edit `project.pbxproj`,
and doing so by hand will usually make things worse.

```
NTCGSimulator/
├─ App/              NTCGSimulatorApp, RootView, Navigation (routes + Router)
├─ DesignSystem/     Theme (tokens), Shapes (notched panels), Components, CardFaceView
├─ Models/           Card, Deck (+ legality rules, share codes), CardDatabase
├─ Engine/           The rules engine — pure, deterministic, no SwiftUI
│  └─ AI/            SimpleAI, the heuristic opponent
├─ Features/
│  ├─ Home/          The main menu
│  ├─ Play/          Mode → format → deck selection
│  ├─ Board/         The game board
│  ├─ DeckBuilder/   Deck list and editor
│  ├─ Collection/    Card browser and detail
│  ├─ Settings/      Preferences and card-data import
│  └─ Placeholder/   "Coming soon" screens
├─ Persistence/      SettingsStore, DeckStore
└─ Resources/        cards.json (demo pool)
```

### Where to change things

| To change… | Edit |
|---|---|
| Any colour, font size or spacing | `DesignSystem/Theme.swift` |
| The angular panel silhouette | `DesignSystem/Shapes.swift` |
| How a card is drawn | `DesignSystem/CardFaceView.swift` |
| Deck size / copy limits | `DeckRules` in `Models/Deck.swift` |
| Game rules | `Engine/` — start with `GameEngine.swift` |
| AI behaviour | `Engine/AI/SimpleAI.swift` |
| A new screen | Add a `Route` case in `App/Navigation.swift`, then resolve it in `RootView` |

---

## What works

- **Deck Builder** — Leader selection, colour-locked card pool, copy limits, live
  legality checking, save/duplicate/delete, and export/import via share codes.
- **Collection** — the full card pool with search and filters for set, colour, type,
  rarity and trait, plus a card detail inspector.
- **Play** — Solo v Self and vs AI, in Classic (30-card fixed decks) and Vanilla
  (50-card, your own decks) formats.
- **Settings** — theme, chakra card art, turn/target confirmation behaviour, sound, and
  card-data import.

## What does not

**Online play, accounts, the leaderboard and tournaments are not in this build.** They
need a server, and those screens intentionally show a "coming soon" panel. Networking is
kept behind the `Route` layer so it can be added without disturbing the rest of the app.

**Most card effect text is displayed, not executed.** The engine implements the core
rules — chakra, summoning, combat, damage and life — and it resolves **Leader abilities**
concretely, because those are pressed every turn. Individual Character and Support card
effects are printed but not scripted. That is the natural next step, and the engine's
single `apply(_:)` entry point is the place to hook it.

---

## The chakra economy

This is the rule most likely to be misread, so it is worth stating plainly:

- **Summoning a Character or EX Character is free.** It costs no chakra.
- **Chakra is spent on exactly two things:**
  1. Playing a **Support card** (costs its printed value, occupies a Support slot).
  2. Playing a card **as a jutsu** through its Support line (costs its printed value,
     then goes to the Trash).

A card's printed cost is therefore a *jutsu/support* cost, never a summoning cost. The
single source of truth is `ChakraCost.toPlay(_:asJutsu:)` in `Models/CardModels.swift` —
change it there and the whole app follows.

**Leader abilities** activate once per turn during the main phase and are free. They are
modelled as `LeaderAbility` and resolved by the engine.

---

## Rules accuracy

This game's official rulebook is not public. The engine implements a coherent ruleset
based on what has been shown publicly, and it is deliberately isolated in `Engine/` so
corrections land in one place rather than being spread through the UI.
