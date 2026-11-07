# inkmud

A multi-user dungeon whose world is written as players explore it. Rooms,
items and pictures are generated the first time anyone goes somewhere, saved,
and from then on everyone sees the same thing.

Setting: **Vellmoor**, a fog-bound city of lanterns built on a drowned older
city. Art style: ink and watercolor.

## Run it locally

Needs Gleam ≥ 1.18, Erlang/OTP, Node (for bundling the client), `uv`, and
Ollama running **natively** (not in Docker: on a Mac, containers can't use the
GPU).

```sh
ollama pull llama3.2:3b
scripts/dev.sh            # → http://localhost:4300
```

`dev.sh` starts the image service if it isn't running (first start downloads
SDXL-Turbo, ~7 GB, into `~/.cache/huggingface`), builds the client, and runs
the server. The world lives in `data/` — delete it to start a fresh world.

Tests: `cd server && gleam test`.

**Feedback.** The ✎ button in the top bar (on phones, in the ⋯ menu) lets
anyone leave a note about something that felt off. It's saved with the
place and their last few chronicle entries, and kept across world resets.
Read them with `scripts/feedback.sh` (`scripts/feedback.sh 5 short` for the
newest five, one line each).

**Reset world (dev only).** With `DEV_TOOLS=1` (which `dev.sh` sets), the
room panel shows *Developer → Reset world*. After a confirm step it deletes
every room, picture, item and player position, writes the seed again, and
moves everyone online back to the first room. The server refuses the request
unless `DEV_TOOLS` is on, so production — which leaves it unset — can't be
reset from a browser.

## How it fits together

```
browser (Lustre) ──websocket──▶ Gleam server
                                ├─ session        one process per player
                                ├─ room           one process per room in use (its mailbox orders actions)
                                ├─ world          registry: starts rooms, single-flight room building, prefetch
                                ├─ builder        model proposes a room as JSON → checked → saved
                                ├─ art            one-at-a-time drawing queue, urgent first
                                └─ SQLite         the source of truth
                                       │
                         Ollama (text) · imagegen/ (pictures), both over HTTP
```

- **Saved once, permanent.** A generated room is never regenerated.
- **A real grid.** Every room has fixed `(x, y, z)` coordinates, set when it's
  built: the room beyond an exit is always one step away, one room per cell
  (a unique index enforces it). An exit into a cell that's already built
  joins that room, so walking around a block brings you back — loops form on
  their own. A new room is also joined to any neighbour whose exits point
  into its cell. Worlds from before coordinates are placed once at startup.
- **Phones are first-class.** On a narrow screen the panels stack: the
  picture (its ways out labelled on it; tap one to go), the chronicle,
  what's here and your satchel, with the command box and Story / Satchel /
  Map tabs at the bottom. Moving keeps the new room's picture in view rather
  than jumping to its text. The map pans with one finger and pinches to zoom.
- **Same browser, same player.** Each browser keeps a random device key. A
  reconnect with your name from the same browser (a refresh, a phone waking
  up while its old connection lingers, a second tab) takes over and the old
  connection is told to stand down; another browser using a name in play is
  refused.
- **Items have a job.** Only items whose role the game implements can be
  picked up or examined (`types.takeable_roles`: just keys for now). The
  builder doesn't invent items; objects it mentions are scenery. Some new
  rooms get a locked way out; its key is promised to an unbuilt place
  reachable without that lock (beyond another of the room's ways out, or
  the previous room's), and whichever way that place is built, it contains
  the key. A key opens its lock for everyone and stays in it.
- **Tools and obstacles.** Three tools (iron crowbar, coil of rope,
  lamplighter's hooked pole), each getting you past its kind of obstacle (a
  rusted grate, a sheer drop, a ladder pulled up out of reach). A tool is
  kept and works on every obstacle of its kind; a cleared obstacle stays
  cleared for everyone. If no tool of a kind is to be had, one is promised
  to a reachable unbuilt place. The crossroads starts with the hooked pole.
- **Treasure maps.** Beyond the gentle area, a new room sometimes holds a
  stained treasure map, with a treasure buried at an unbuilt place someone
  could walk to. Examining the map says roughly where ("about 2 west, 2
  levels above here") and marks a ✕ on your map; `dig` there with a spade
  (or crowbar) to unearth it. If nothing to dig with is lying around, a
  spade is left beside the map. The spade also clears rubble and cave-ins.
- **Difficulty grows with distance** from the crossroads (each level up or
  down counts double): gentle (0-2) has no dark, locks or obstacles and
  more helpful finds; wary (3-5) and perilous (6+) bring them in. See
  `builder.odds`.
- **Light and dark.** Some places below the streets are pitch dark: without
  a lit lantern you see no description, picture or items, and the only way
  out you can find is the way you came in. A lantern burns one unit of oil per step
  into a dark place, warns as it runs low, and goes out; `fill lantern` pours
  in a tin of oil (which turns up in rooms once lanterns exist). Whenever a
  dark place is built and no lantern is free, one is promised to an unbuilt
  street-level place, which is never dark.
- **Danger.** Away from the gentle streets, walking into a place may
  bring something out of the fog: rats underground, stray dogs and
  footpads on the streets, and further out drowned things, Warrens gangs
  and rooftop prowlers (`world/danger.gleam`; 10% of entries in wary places,
  20% in perilous ones, +10% in the dark). Everyone in the room faces it.
  `fight` (a die plus your best tool: crowbar +2, pole or spade +1),
  `flee` back the way you came (it may get a blow in), or `raise lantern`
  at the creatures that fear light. Three wounds and you collapse: you wake
  at the crossroads with one wound, and what you carried lies where you
  fell. Wounds heal one per 20 minutes, or all at once with `rest` at the
  crossroads. `ENCOUNTER_CHANCE=100` forces encounters, for testing.
- **Three levels.** The streets; below them one connected underground
  (sewers, tunnels, cellars, crypts), with no way further down; and
  upstairs, a single room you climb to and come back down from. The engine
  drops any way out a level doesn't allow, and each picture prompt says
  where the place is.
- **Outdoors, indoors, below.** The engine decides what kind of place each
  room is; the top bar shows it. Streets are always out under the sky, and
  you go into a building only through a door (a door icon on the picture's
  label; "You go inside."). Some streets have one (`builder.door_chance`).
  A building has up to three rooms on its floor (`builder.building_rooms`),
  maybe stairs up to a loft (`stairs_chance`) or steps down to a cellar.
  Up from a street (a fire escape, a belfry ladder) is a rooftop. Doors
  belong to the passage, like locks, and are never locked or blocked by the
  builder. Nothing attacks you indoors.
- **Your map** (the Map button) shows the rooms you've visited at their grid
  positions, each floor a tilted plane stacked above the one below.
- **Engine owns the truth.** The model proposes rooms in a fixed JSON shape;
  `builder.gleam` checks every field, guarantees the way back, and caps sizes.
  Player actions only change the world through the fixed command set.
- **Single flight.** Each unbuilt exit has at most one build; everyone walking
  into it waits on the same one.
- **Prefetch.** Entering a room queues its unbuilt exits for building, and
  every built room is queued for drawing, so the next room and its picture are
  usually ready before anyone arrives. A build a player is waiting on always
  gets a slot immediately.
- **Free-form input** is translated by the fast model into one command from
  the fixed set (`go`, `look`, `examine`, `take`, `drop`, `inventory`, `say`,
  `help`), or refused. Typed commands skip the model entirely.
- **Art prompts come from stored room facts, never player text.** A room's
  picture is an establishing shot of the place. Examining something you could
  pick up (or carry) draws a close-up of just that thing (from the item's
  plain physical "look"), shown in the story and kept for next time.

## Configuration

| Variable | Default | |
|---|---|---|
| `PORT` | `4300` | |
| `DB_PATH` / `ART_DIR` | `data/inkmud.db` / `data/art` | via `dev.sh` |
| `OLLAMA_BASE_URL` | `http://localhost:11434` | |
| `FAST_MODEL` / `BUILDER_MODEL` | `llama3.2:3b` / `llama3.2:3b` | builder could be an 8B for care over speed |
| `MODEL_API_BASE_URL` | — | set → OpenAI-compatible endpoint instead of Ollama |
| `MODEL_API_KEY`, `MODEL_API_FAST_MODEL`, `MODEL_API_BUILDER_MODEL` | — | for that endpoint |
| `IMAGE_API_BASE_URL` | `http://localhost:7860` | the image service |
| `DEV_TOOLS` | off | `1` enables developer actions (Reset world). Never in production. |

Image service (`imagegen/server.py`):

| Variable | Default | |
|---|---|---|
| `IMAGE_BACKEND` | `local` | `local` = SDXL-Turbo on this GPU; `fal` = FLUX.1 schnell on fal.ai |
| `FAL_KEY` | — | for `fal` |
| `IMAGE_STEPS`, `IMAGE_SIZE` | `2`, `512` | local backend |

## Production (DigitalOcean droplet, no GPU)

Same code, hosted models: point `MODEL_API_BASE_URL` at a hosted
OpenAI-compatible provider, and run `imagegen/` with `IMAGE_BACKEND=fal`
(install without the `local` extra: `uv sync`). The droplet then only runs the
Gleam server, SQLite and a thin image proxy.

The `fal` backend and the OpenAI-compatible path are written but **not yet
tested** against real accounts.

## Not done yet

Deployment files (Dockerfile/compose), chat moderation, accounts/auth (names
are first-come, per server run), the fixed state-change vocabulary
(`burned`, `barricaded`…), characters with memory, and combat.
