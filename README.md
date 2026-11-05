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
- **Phones are first-class.** On a narrow screen the picture becomes a banner
  (shrinking while you type), the story fills the middle, and a sideways row
  of actions plus the command box sit at the bottom. Hold a way out to
  glimpse it; tap to go. The map pans with one finger and pinches to zoom.
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
- **Levels mean something.** Below street level is always underground
  (sewers, tunnels, cellars, crypts); above is rooftops, towers, bridges.
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
