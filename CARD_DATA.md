# Card data & artwork

The app ships with a **demo card pool** (`NTCGSimulator/Resources/cards.json`) whose
stats and rules text were written for this project as placeholders. Every card is drawn
with generated art, so the app is fully playable with no assets installed.

To replace it with real data, import your own `cards.json` from **Settings → Card data**.

---

## `cards.json` format

A single JSON array of card objects.

```json
[
  {
    "id": "N-004",
    "name": "Naruto Uzumaki",
    "type": "character",
    "color": "red",
    "rarity": "R",
    "setCode": "01",
    "traits": ["Team 7", "Jinchuriki"],
    "cost": 2,
    "power": 4,
    "damage": 1,
    "health": 4,
    "effect": "When this Character is summoned, it gains +2 power until the end of the turn.",
    "supportText": "Support: instead of summoning, draw a card.",
    "artist": "Artist name",
    "artFilename": "N-004.png"
  }
]
```

### Fields

| Field | Required | Type | Notes |
|---|---|---|---|
| `id` | ✅ | string | Collector number. **Must be unique** — it is the card's identity everywhere in the app. |
| `name` | ✅ | string | |
| `type` | ✅ | enum | `leader`, `character`, `exCharacter`, `support`, `chakra`, `summon` |
| `color` | ✅ | enum | `red`, `blue`, `green` |
| `rarity` | ✅ | enum | `C`, `R`, `SR`, `L`, `SB` |
| `setCode` | ✅ | string | e.g. `"01"`. Drives the SET filter. |
| `traits` | | string[] | Drives the TRAIT filter. Omit or `[]` for none. |
| `cost` | | int | Chakra required **to play as a jutsu, or to play a Support card**. Summoning is always free. Omit for Leaders and Chakra cards. |
| `power` | | int | Attack value. |
| `damage` | | int | Life removed from a Leader on an unblocked hit. |
| `health` | | int | Power absorbed before going to the Trash. |
| `life` | | int | **Leaders only** — starting life. |
| `effect` | | string | Rules text. Defaults to `""`. |
| `supportText` | | string | Present only on cards that can be played as a jutsu. |
| `artist` | | string | Credit shown on the card detail screen. |
| `artFilename` | | string | Filename inside the art folder. When absent, art is generated. |
| `leaderAbility` | | object | **Leaders only.** The effect the player activates once per turn — see below. |

Any card missing a required field causes the **whole import to fail** with an error
shown in Settings — this is deliberate, so a malformed file cannot half-load.

### `leaderAbility`

A Leader may carry one activated ability. It is encoded as a single-key object:

```json
"leaderAbility": { "drawCard": {} }
"leaderAbility": { "restoreLife": { "_0": 2 } }
"leaderAbility": { "empowerCharacter": { "power": 1 } }
"leaderAbility": { "weakenCharacter": { "power": 2 } }
```

| Ability | Effect | Target |
|---|---|---|
| `drawCard` | Draw one card | none |
| `restoreLife` | Restore life to your Leader | none |
| `empowerCharacter` | Give one of **your** characters +power until end of turn | friendly |
| `weakenCharacter` | Remove power from an **opposing** character until end of turn | enemy |

Abilities are free, usable once per turn during the main phase.

### A note on `cost`

Summoning a Character costs **nothing**. A card's `cost` is charged only when it is
played as a jutsu (via `supportText`) or when it is a `support` card. A deck with no
Support cards and no Support lines has nothing to spend chakra on.

### What the app needs to be playable

- At least one card with `type: "leader"` per colour you intend to use, each with `life`.
- At least one `chakra` card (its art is used for the five Chakra on the board).
- Enough `character` / `exCharacter` / `support` cards per colour to fill a legal deck:
  **13 distinct cards minimum** (13 × 4 copies = 52 ≥ 50).
- Some `support` cards, or characters with a `supportText` line — otherwise chakra has
  no use and the game plays flat.

---

## Artwork

Illustrations are **not** bundled with the app. Put image files in the app's card-art
folder and reference them by `artFilename`.

The exact path for this install is shown in **Settings → Card data** (it is
`Application Support/CardArt/` inside the app's container).

- Supported: anything `UIImage` reads — PNG, JPEG, HEIC.
- Recommended: a 5:7 portrait ratio, around 500 × 700 px.
- A card whose `artFilename` is missing or unreadable silently falls back to generated
  art, so a partial art set is fine.

### Getting files there

- **Simulator:** drag the folder into the container, or
  `xcrun simctl get_app_container booted <bundle-id> data` to find the path.
- **Device:** enable file sharing on the target and copy via the Files app, or import
  through Settings.

---

## ⚠️ Rights

The demo pool's stats and rules text were written for this project. Card artwork for the
real game is owned by its publisher — **do not ship it inside the app**. Importing art
you have the rights to, on your own device, is the intended workflow; bundling
third-party art into a distributed build is not.
