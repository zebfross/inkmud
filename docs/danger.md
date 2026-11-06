# Design: danger

Status: **draft**, nothing built yet. Related: [politics](politics.md).

## Why

- **Pacing.** The city is currently safe everywhere, so the fastest way to
  play is to sprint through rooms. Danger makes the deep and far places
  something to prepare for rather than run through.
- **Texture.** "The sewers are dangerous" says something about Vellmoor that
  description alone doesn't.
- **Shared stakes.** Creatures too strong to face alone give players a
  reason to gather, which leads to hunts, bounties and stories to tell.

This is deliberately **danger, not a combat system**. There are no levels,
experience points, armour, stats to build or player-versus-player fighting.

## Principles

- **The engine owns the numbers.** Creature types, their strength and every
  outcome come from fixed tables and engine rolls. The model writes
  descriptions and pictures only; it never decides who wins.
- **Built from what exists.** Difficulty tiers decide where danger appears.
  Tools double as weapons, light matters, and fleeing uses the
  way-you-came rule from dark rooms.
- **Safe near home.** The gentle streets around the crossroads stay safe,
  so new players can find their feet.
- **Losing costs time, not progress.** You lose ground and what you were
  carrying, never your character.

## Wounds

- You can take **three wounds**. The third puts you down (see
  [Losing](#losing)).
- Wounds **heal over time**, one per 20 minutes of play, or **at once** by
  resting at your faction's hall or an inn (`rest`).
- Being wounded shows in the room text and the top bar ("your side aches")
  but doesn't weaken you. One rule is easier to read than many.
- The top bar shows wounds where the Stitch design had its health meter.

## Where danger is

Encounters use the existing difficulty tiers:

| Tier | Encounter chance on entering a place | Creatures |
|---|---|---|
| Gentle (0–2) | none | — |
| Wary (3–5) | low (about 10%) | sewer rats, a stray dog, a footpad |
| Perilous (6+) | higher (about 20%) | drowned things, a Warrens gang, a rooftop prowler |

- **Level matters:**
  - Underground: rats, drowned things.
  - Streets: footpads, dogs, gangs.
  - Rooftops: prowlers.
- **Darkness:** a dark place raises the chance.
- **Control:** a district held by your faction (once politics exists) lowers
  it for you, because its lamps are lit and its patrols keep things down.
- **Rooms are never permanently dangerous.** An encounter is rolled on
  entering, so a place is risky rather than blocked.

## The bestiary

A fixed table. The model gives each encounter its description and picture,
never its numbers.

| Creature | Where | Strength | Light drives it off | Notes |
|---|---|---|---|---|
| sewer rats | underground | 1 | yes | a swarm; easy to flee |
| stray dog | streets | 1 | no | can be calmed (later: food) |
| footpad | streets | 2 | no | after your things: wins = takes one item and runs |
| drowned thing | underground, perilous | 3 | yes | slow; flee is reliable |
| Warrens gang | the Warrens, perilous | 3 | no | flee is unreliable |
| rooftop prowler | rooftops, perilous | 2 | no | fleeing means climbing down |

## An encounter

When one starts, the room view shows the creature with its picture and a
short line, and the actions change to:

- **Fight:** a roll against the creature's strength. Carrying a
  [weapon-capable tool](#tools-as-weapons) helps.
  - Win: it's driven off (and may leave something behind).
  - Lose the round: you take a wound and it stays.
- **Flee:** back the way you came. Always possible, but it may cost a wound,
  depending on the creature. You arrive in the previous room.
- **Light:** raise a lit lantern. Creatures that fear light leave at once.
  It burns oil.
- Anything else (walking on, taking things, digging) is blocked until the
  encounter is over. Talking still works.

Each command is one round. Creatures don't act between your commands, so
nobody is punished for reading slowly.

**Other players in the room** can join a fight. Each fighter's roll counts,
which matters for [named creatures](#named-creatures).

## Tools as weapons

There are no separate weapons. Tools you already carry help in a fight:

| Tool | Fight bonus |
|---|---|
| iron crowbar | +2 |
| lamplighter's hooked pole | +1 (reach) |
| spade | +1 |
| rope | none |

Only the best tool counts. This gives tools a second use and keeps the
satchel decisions interesting.

## Losing

On the third wound you collapse. You wake at your faction's hall (or the
Lantern Crossroads if you have none) with one wound.

- **What you carried stays where you fell,** as items in that room. Anyone
  can pick them up, including you, if you get back first.
- After a while (a few hours), unclaimed role items drift back to where
  they were first found, as described in the fair-play notes. Nothing is
  lost to the world for good.
- No other penalty. The trek back is the cost.

## Named creatures

A few creatures have names and are too strong to beat alone, for example
*the Thing under Blackfriars Wynd*.

- **Placement:** each lives in one place in a perilous area, placed by the
  engine like a buried treasure.
- **Fixed strength:** high enough that it takes three or more fighters in
  the same encounter.
- **Wounds stick:** a wound dealt to it lasts a while, so a group can wear
  it down over a session.
- **News:** the feed announces sightings and defeats.
- **Reward:** beating one is a permanent event, with a plaque, a unique
  item it guarded, and (with politics) a faction work completed and
  influence for everyone who fought.
- **Respawn:** a new named creature appears elsewhere later, so there's
  always one out there.

## Tie-ins

- **Quests:** factions post bounties ("drive the rats from the Gutter
  Stair", "end the Thing under Blackfriars Wynd").
- **Politics:** controlled districts are safer for members. A faction that
  lets its lamps go dark lets danger in.
- **Fair play:** danger slows sprinting where it matters. The per-hour
  budget on new rooms still protects the hosting bill, since gentle streets
  stay safe.

## Not in this version

Levels and experience points, armour and gear slots, player-versus-player
combat, creatures that follow you between rooms, creatures that wander on
their own, and permanent death.

## Data (sketch)

```
players            + wounds INT, wounded_at
encounters(room_id, player, creature, strength_left, started_at)   -- active fights
named_creatures(id, name, room_id, strength, strength_left, defeated_at)
bestiary                                                          -- a fixed table in code, like tool_kinds
```

## Build order

1. Wounds and resting; the top bar shows them.
2. Encounters for the common creatures by tier; fight, flee and light;
   losing and waking at the crossroads.
3. Tools as weapons; items left where you fell.
4. Named creatures and group fights, plus news-feed entries.
5. Tie-ins: bounties as quests, safer controlled districts (once politics
   exists).

## Open questions

- **Encounter chance:** are 10% and 20% too much or too little? It needs
  playtesting with the wander scripts.
- **Wounds heal:** healing in play time means an idle tab doesn't heal you.
  Is that right, or should wounds heal in real time?
- **Footpads:** stealing an item could feel bad. Keep it, or have footpads
  only take coins (once there are coins)?
- **Pictures:** does every creature encounter get its own picture? It adds
  a model call each time; probably one cached picture per creature type
  per region instead.
