# ShowMyVaults

**The Great Vault knows exactly one character: the one standing in front of it.**

You have alts, and the vault window says nothing about them. ShowMyVaults
writes their progress straight onto it:

```
Gandalfred 1/1
  Leegolas 1/1
           0/1
```

Each reward slot already shows your own progress in its corner, the unnamed
line. Your other characters stack above it in their class colours, counted
against that slot's own threshold, so six dungeons reads 1/1, 4/4, 6/8 across
the Dungeons row. Green means the slot is earned. A character with nothing
toward a row stays off that row.

## Who still has a vault to open

A gold line under the rows:

```
Vault waiting: Holycowbell
```

This covers characters you have not logged in since the reset. Filling slots
one week means a chest to open the next. So when the week rolls over, earned
progress becomes a "vault waiting" entry instead of vanishing, and it stays
until you log that character in and deal with it.

## This week only

The fractions come from each character recording itself while you play it. A
character you have not logged in since the weekly reset shows none. The game
gives no way to read an offline character's vault, and a stale row would be a
guess dressed up as a fact. The gold line is the one exception, because the
only thing it needs to remember is "there is a chest".

## Options

Interface options, under *Show My Vaults*:

| Setting | Default | |
|---------|---------|---|
| Force server name | off | Always show realms, not only when names collide. |
| Characters | all on | One checkbox per stored character. Uncheck to hide one everywhere. |
| Clear saved variables | — | Forget every stored character. Rebuilds as you play them. |

Hidden characters stay hidden, even when they get recorded again later.

## Commands

- `/smv` toggles everything. `/smv show` and `/smv hide` to be explicit.
- `/smv clear` empties the stored characters.

## Honest limitations

Text is English only. The addon works on any client, but its labels stay
English.

While you are picking this week's reward, the stacks get out of the way. They
come back once the choice is made.

There is no minimap button and no standalone window, on purpose. The addon
exists only inside the vault window.

## Installation

- **CurseForge:** search for *ShowMyVaults* in the CurseForge app.
- **Manual:** download the latest zip from [Releases](../../releases/latest)
  and extract the `ShowMyVaults` folder into
  `World of Warcraft\_retail_\Interface\AddOns\`, then restart the game.

Requires World of Warcraft Retail (Midnight, 12.x).

## License

MIT license, see [LICENSE](LICENSE).
