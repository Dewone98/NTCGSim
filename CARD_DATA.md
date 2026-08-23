# Card data & artwork

## Artwork

Card artwork **ships inside the app**, in `NTCGSimulator/Resources/CardArt/`. Every
install shows the same pictures; there is no per-device import and nothing for a player
to configure.

Files are named by collector number, so the art for card `N-004` is `N-004.AVIF`.
Matching is forgiving about case and separators — `n_004.avif` resolves the same card —
but the plain form is what the shipped set uses.

To replace or add art:

1. Drop the file into `NTCGSimulator/Resources/CardArt/`, named for its card.
2. Rebuild. The Xcode target uses synchronized folders, so nothing needs registering.

AVIF, PNG, JPEG, HEIC and WebP are all accepted. AVIF is what the shipped set uses
because it is what a modern iPhone exports and it is markedly smaller.

`BundledCardArtTests` fails the build if any card in the pool lacks artwork, so a
missing or misnamed file is caught rather than showing up as one odd-looking card.

### ⚠️ Rights

The artwork in this repository is **not ours**. It belongs to the game's publisher.

It is here so the app looks uniform, and the repository is private. Two consequences
worth being deliberate about:

- **Making the repository public would publish that artwork.** Deleting the files later
  would not undo it — git history keeps them until the history itself is rewritten.
- **Distributing the app with this artwork is redistribution.** App Store review is a
  hard no. Sideloading or TestFlight is lower-profile but no different in kind.

If the project is ever published or distributed, the artwork needs removing from both
the working tree and the history, and replacing with art there is a right to use.

---

## `cards.json`

The card pool lives in `NTCGSimulator/Resources/cards.json`: 35 cards carrying the
values printed on them, plus their abilities in structured form.

```json
{
  "id": "N-004",
  "name": "Naruto Uzumaki",
  "type": "character",
  "color": "red",
  "rarity": "R",
  "setCode": "01",
  "traits": ["Special", "Jinchuriki", "Hidden Leaf Village", "Team 7"],
  "cost": 2,
  "power": 5,
  "damage": 1,
  "health": 4,
  "canSetAsSupport": true,
  "abilities": [ /* see below */ ]
}
```

### Fields

| Field | Required | Type | Notes |
|---|---|---|---|
| `id` | ✅ | string | Collector number. **Must be unique** — it is the card's identity, and the name of its artwork file. |
| `name` | ✅ | string | |
| `type` | ✅ | enum | `leader`, `character`, `exCharacter`, `chakra`, `summon` |
| `color` | ✅ | enum | `red`, `blue`, `green` |
| `rarity` | ✅ | enum | `C`, `R`, `SR`, `L`, `SB` |
| `setCode` | ✅ | string | Drives the SET filter. |
| `traits` | | string[] | Drives the TRAIT filter. |
| `cost` | | int | Chakra to play as a jutsu, or to activate from a Support slot. Summoning is free. |
| `power` | | int | Damage dealt **to a character**. |
| `damage` | | int | Life removed **from a leader**. |
| `health` | | int | Damage absorbed before the character is knocked out. |
| `life` | | int | **Leaders only** — starting life. |
| `canSetAsSupport` | | bool | True only for cards printing a SUPPORT bar. Only these may be set face-down. |
| `abilities` | | array | The printed ability boxes — see `CardAbility.swift`. |

Anything omitted falls back to a sensible default: decoding is deliberately lenient so a
hand-authored file need not spell out what does not apply.

### What the app needs to stay playable

- A `leader` per colour you intend to use, each with `life`.
- At least one `chakra` card — its art is used for the five chakra on the board.
- Enough cards per colour to fill a legal deck: **13 distinct minimum** (13 × 4 = 52 ≥ 50).
- Some cards with a SUPPORT bar, or chakra has nothing to be spent on and no response
  window can ever be answered.
