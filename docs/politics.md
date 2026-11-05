# Design: factions and politics

Status: **draft**, nothing built yet.

## Why

Exploring is fun, but on its own it's aimless: you walk, a room appears, you
walk again. Politics gives every action a purpose beyond itself. A new place
claimed, a treasure delivered or a lamp lit all count for your side, and the
city visibly changes hands. Over time the results build up into a history
of Vellmoor that players wrote.

## Principles

- **The engine owns the numbers.** Influence, control, votes and policies
  live in SQLite under fixed rules. The model only writes flavour
  (proclamations, plaques, hall descriptions, errand text). It can never
  hand a faction a district.
- **Built from what exists.** Regions, light and dark, keys, treasure and
  promised items already work. Politics gives them a reason, rather than
  adding a separate game beside them.
- **Works with three players.** Factions push back on their own, so the map
  stays contested even when you're alone (see [Pushback](#pushback)).
- **Fixed vocabularies.** Promises, policies and levers are chosen from
  lists the engine knows how to enforce, never free text.
- **You can always see it.** Every political change is announced in the
  news feed and shows on the map. Politics you can't see happening isn't
  politics.

## Factions

One per region, each with a hall near its home.

| Faction | Home region | Wants | Leader's title |
|---|---|---|---|
| The Lamplighters' Guild | Lantern Ward | light and order: every street lit | Master Lamplighter |
| The Aldermen | the Hill | wealth and law: treasure in the coffers | First Alderman |
| The Tidewardens | the Drowned Quarter | the old city's secrets, kept or uncovered | Warden of the Tide |
| The Rookery | the Warrens | the dark, the tunnels, what others lose | the Rook |

**Pledging.** You pledge at a faction's hall with `pledge`. The pledge is
saved with your player. You can renounce and pledge elsewhere, but only once
per term, and you lose your influence for that term (no hopping to whoever
is winning).

**Unpledged players** can explore and trade as now. They earn no influence,
can't vote, and can't pass members-only doors.

**Halls** are seeded rooms, one per region, near the crossroads at gentle
difficulty. Each has a notice board (news, candidates, plaques) and is
where treasure is delivered. A hall's description changes with its
faction's fortunes (the model rewrites the flavour at each reckoning).

## Territory and influence

**Districts.** Control is held per district, not per room or per whole
region. A district is a block of the grid (say 4×4 cells on one level), so
fights are local and a region can be divided between factions. Rooms already
have fixed coordinates, so a room's district is `(x div 4, y div 4, z)` and
needs no extra storage.

**Influence** is a per-faction score in each district, and it decides who
holds the territory. (This is separate from leadership: a player's
influence only qualifies them to stand for office; see
[Leadership](#leadership).) The faction with the most influence in a
district controls it. For a district to pass from one faction to another,
the rival faction must beat the holder's influence there by a margin (for
example 20%), so control doesn't flicker back and forth when two factions
are close.

**Earning influence** (each action credits both the faction's district
score and the player's term total):

| Action | Influence | Notes |
|---|---|---|
| Discover a new place | +5 in its district | the first to walk it; builds are already single-flight, so exactly one discoverer |
| Deliver treasure to your hall | +10 to +30 in the district where it was dug | by treasure value |
| Light a street lamp (Lamplighters, Aldermen) | +3 | the place becomes lit for everyone |
| Douse a street lamp (Rookery, Tidewardens) | +3 | the place becomes dark for everyone |
| Complete a faction errand | +10 | see [Errands](#errands) |
| Clear an obstacle | +2 | already permanent for everyone |

Values are starting guesses, to be tuned by playing.

**Decay.** District influence fades by a few percent a day, so holdings
need tending and abandoned districts drift back into contention.

## Lamps

Builds on the existing light system. Some street-level and underground
places get a **lamp post or wall lamp** as a fixed feature.

- `light lamp` needs a lit lantern and burns some of its oil.
- `douse lamp` needs nothing.
- A lit place is lit for everyone: no lantern needed, and you see the full
  view. A doused place goes back to dark. Darkness is a stored room state
  (the "state-change vocabulary" from the README).
- The four factions split on this naturally: Lamplighters and Aldermen
  light, Rookery and Tidewardens douse. Lamps then become the most visible
  front line of the conflict.

## Control perks

What holding a district does, for members of the controlling faction there:

- **Colour on the map:** every player's map tints the district.
- **Cheaper or free lamp oil** from that district's oil sellers (needs
  [shops](#open-questions)).
- **Members-only doors:** some exits in a controlled district are guild
  doors, open only to members.
- **Default light:** new places built in a Lamplighter-held district start
  lit; in a Rookery-held one, dark.

## Terms and the reckoning

A **term** is one week. At the **reckoning** (a fixed weekly time):

1. Control of every district is recorded.
2. Elections close, the new leaders take office and their promises become
   policy (see [Leadership](#leadership)).
3. The model writes a short proclamation per faction from the facts (what
   they held, gained and lost, who leads now). It's posted in the news feed
   and on the hall's board.
4. A **plaque** goes up in each hall, a permanent line of history such as
   *"In the third week, under the Rook Wren, the Rookery held the Drowned
   Quarter."*
5. Players' term influence resets. District influence carries over (with
   decay).

## Leadership

**Eligibility.** The five members with the most influence earned this term
may stand. Using this term's influence rather than lifetime totals means
newcomers can rise and nobody sits on top forever. Standing is optional
("Stand for office" at the hall).

**Campaign.**
- **A pitch:** a sentence or two of player text, shown in the news feed and
  on the hall's board. It goes through moderation (see [Moderation](#moderation)).
- **One promise** from a fixed list, for example:

| Promise | Effect next term |
|---|---|
| Take the ‹district/region› | +50% influence for members there |
| Cheap oil for members | oil free for members in held districts |
| Close the doors | guild doors refuse non-members everywhere the faction holds |
| War on ‹faction› | +50% influence for taking that faction's districts |
| Light (or darken) the streets | lamp actions count double |

**Influence only opens the door.** It decides who may stand, nothing more.
Only votes decide who leads.

**Vote.** One vote per member who earned any influence this term. That keeps
out drive-by and second-tab voters (on top of accounts). Voting closes at
the reckoning, and the candidate with the most votes leads. A tie goes to
whoever reached that count first.

**No votes or no candidates.** The sitting leader carries on for another
term, with no new promise. If there is no sitting leader, the faction stays
leaderless: no promise, and its pushback is aimed at its home region.

**Office.**
- The title shows next to the leader's name wherever it appears.
- The winning promise is enforced for the whole term.
- **One lever:** once a day the leader chooses where the faction's
  [pushback](#pushback) is aimed. That's enough to matter, not enough to
  wreck things.
- The leader's name goes on that term's plaque.
- **Absence:** a leader who doesn't log in for 3 days steps down, and the
  candidate with the next-most votes that term takes over. With no such
  candidate, the faction is leaderless until the next reckoning.

**Not in this version:** taxes, tolls, impeachment, alliances, attacking
other players.

## Pushback

With few players, nothing would ever change hands. So each faction acts on
its own:

- Every few hours, each faction adds a small amount of influence to a few
  districts. It prefers districts bordering its own and districts its
  leader aimed it at. A leaderless faction aims at its home region.
- Its NPC members light or douse a few lamps (announced: *"Rookery hands
  have doused the lamps of Blackfriars Wynd"*).
- Pushback is weaker than an active player, so playing always matters, but
  strong enough to undo an unattended conquest within a few days.

## Errands

Small tasks a hall posts on its board, built from the promised-item
machinery that already guarantees keys and lanterns are reachable:

- "Bring a key to the Tidewardens' archive": a key is promised to an unbuilt
  place, and the archive gets a lock it opens.
- "Light the lamps of ‹district›": three lamps in a district.
- "Recover the Aldermen's lost ledger": a treasure-map hunt with a named item.

The engine picks the errand type and target; the model writes the text.

## News feed

A slim read-only feed (side column on desktop, a tab on phones), shown from
the moment you log in. Its entries are generated by the engine:

- "Wren has found a new place: Gloomy Warren Depths (the Warrens)"
- "The Rookery has taken the Drowned Quarter's eastern streets"
- "Seeker delivered a purse of old sovereigns to the Aldermen"
- "Wren stands for the Rookery: ‘The dark is ours.’ Promise: war on the Lamplighters"
- Reckoning proclamations

Player chat (`shout`) can come later. The feed is valuable without it.

## Moderation

Campaign pitches are the first player-written text other players see.
- Short limit (140 characters), one pitch per candidate per term, editable.
- A model pass checks it; anything flagged is held and shown only to its
  author until reviewed.
- An admin command can remove a pitch or bar a player from standing.

## Prerequisites

- **Accounts.** Names are currently first-come per browser. Votes, pledges
  and leadership need real identities, or a second tab is a second vote.
  The simplest option is an emailed sign-in link or a passkey, with the
  existing device takeover kept.

## Data (sketch)

```
factions(id, name, region_id, title, hall_room_id)
pledges(player, faction_id, pledged_at, term)
influence(term, faction_id, district_x, district_y, z, amount)       -- district scores
player_influence(term, player, faction_id, amount)                   -- for eligibility and votes
control(term, district_x, district_y, z, faction_id)                 -- recorded at each reckoning
candidates(term, faction_id, player, pitch, promise, promise_arg, status)
votes(term, faction_id, voter, candidate)
leaders(term, faction_id, player, promise, promise_arg, aimed_at)
plaques(id, faction_id, term, text)
news(id, at, kind, text)
lamps(room_id, lit)                                                   -- or a column on rooms
```

## Build order

Each step is playable on its own.

0. **Accounts.**
1. **Factions:** pledging and halls, plus the news feed.
2. **Influence:** from discoveries and treasure, districts, and the map
   coloured by control.
3. **Lamps:** lamps and control perks.
4. **The reckoning:** the weekly reckoning, proclamations and plaques.
5. **Leadership:** candidates, campaigns, the vote and policies.
6. **Pushback and errands.**

## Open questions

- **District size:** is 4×4 too big or too small? It depends how far people
  actually roam.
- **Term length:** is a week right with few players? Maybe 3 days at first.
- **Shops and money:** the oil perk and "treasure value" imply an economy.
  Build a minimal one (coins and an oil seller) inside step 2 or 3, or
  defer those perks?
- **Unexplored districts:** does anyone hold them? Proposal: nobody, until
  someone discovers a place there.
- **Leaving the region theme:** can the Rookery take Lantern Ward
  entirely? (Proposal: yes, but the home hall can never be lost.)
- **Visibility of others' influence:** can players see exact numbers, or
  only who's ahead?
