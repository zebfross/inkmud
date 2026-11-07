//// Builds the room on the far side of an unbuilt exit. Rooms sit on a fixed
//// grid, so if that cell is already built the exit simply joins the room
//// there. Otherwise the model proposes a room as JSON; this module checks
//// every field, fixes up the geometry (the way back always exists, ways out
//// into built cells join those rooms, neighbours pointing here get linked),
//// and writes it. A reply
//// that fails the checks is asked for again; after a few failures a plain
//// fallback room is written so a player is never stuck at a doorway.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import server/llm.{type Client}
import server/world/seed
import server/world/store.{type Store, NewExit}
import server/world/types.{type Direction, type Exit, type Room}

const attempts = 4

/// How far a cell is from the crossroads: steps across the streets, with
/// each level up or down counting double (going underground is a bigger
/// step than going round a corner).
pub fn distance(cell: types.Cell) -> Int {
  let #(x, y, z) = cell
  int.absolute_value(x) + int.absolute_value(y) + 2 * int.absolute_value(z)
}

/// 0 gentle (distance 0-2), 1 wary (3-5), 2 perilous (6 and beyond).
pub fn tier(cell: types.Cell) -> Int {
  case distance(cell) {
    d if d <= 2 -> 0
    d if d <= 5 -> 1
    _ -> 2
  }
}

pub fn tier_name(tier: Int) -> String {
  case tier {
    0 -> "gentle"
    1 -> "wary"
    _ -> "perilous"
  }
}

/// Percent chances for a new room at each difficulty.
pub type Odds {
  Odds(dark: Int, obstacle: Int, lock: Int, gift: Int, map: Int)
}

pub fn odds(tier: Int) -> Odds {
  case tier {
    // Near the crossroads: nothing in the way, and things worth finding.
    0 -> Odds(dark: 0, obstacle: 0, lock: 0, gift: 30, map: 0)
    1 -> Odds(dark: 25, obstacle: 20, lock: 15, gift: 15, map: 10)
    _ -> Odds(dark: 45, obstacle: 25, lock: 30, gift: 10, map: 12)
  }
}

/// Something worth picking up, for a gift: a tool of a kind not already
/// lying around (so finds stay varied), else a lantern if none is free,
/// else oil once lanterns exist. `None` if all of that is already about.
fn helpful_find(store: Store) -> Option(store.Pending) {
  let tools =
    types.tool_kinds
    |> list.filter(fn(k) { store.free_tools(store, k.kind) == 0 })
    |> list.map(fn(k) {
      store.Pending(
        name: k.name,
        looks: k.looks,
        role: "tool",
        unlocks: Some(k.kind),
      )
    })
  let lights = case store.free_lights(store) {
    0 -> [lantern()]
    _ -> []
  }
  let oil = case store.any_lights(store) {
    True -> [oil_tin()]
    False -> []
  }
  case list.flatten([tools, lights, oil]) {
    [] -> None
    options ->
      list.drop(options, int.random(list.length(options)))
      |> list.first
      |> option.from_result
  }
}

/// Bury a treasure somewhere a player could walk to (an unbuilt place
/// beyond an open way out, 2 to 8 steps from here; else nowhere, and no
/// map), and return the map that leads to it, plus a spade if there's
/// nothing to dig with lying around. With a note for the developer view.
fn bury_treasure(
  store: Store,
  here: types.Cell,
) -> #(List(store.Pending), String) {
  let spots =
    store.reachable_unbuilt(store)
    |> list.filter(fn(c) {
      let d = distance(#(c.0 - here.0, c.1 - here.1, c.2 - here.2))
      c != here && d >= 2 && d <= 8
    })
  case spots {
    [] -> #([], "")
    _ -> {
      let assert Ok(spot) =
        list.drop(spots, int.random(list.length(spots))) |> list.first
      let assert Ok(treasure) =
        list.drop(types.treasures, int.random(list.length(types.treasures)))
        |> list.first
      store.add_cache(store, spot, treasure)
      let map =
        store.Pending(
          name: "stained treasure map",
          looks: "a stained, hand-drawn map of the city streets with a small inked cross",
          role: "map",
          unlocks: Some(store.map_code(spot)),
        )
      let can_dig =
        list.any(types.digging_tools, fn(k) { store.free_tools(store, k) > 0 })
      let spade = case can_dig, types.tool_kind("spade") {
        False, Ok(k) -> [
          store.Pending(
            name: k.name,
            looks: k.looks,
            role: "tool",
            unlocks: Some("spade"),
          ),
        ]
        _, _ -> []
      }
      #(
        [map, ..spade],
        "used: a treasure map; "
          <> treasure.name
          <> " is buried at "
          <> cell_text(spot)
          <> case spade {
          [] -> ""
          _ -> ", with a spade left beside the map"
        },
      )
    }
  }
}

fn lantern() -> store.Pending {
  store.Pending(
    name: "bullseye lantern",
    looks: "a small tin lantern with a round glass lens and a wire handle",
    role: "light",
    unlocks: None,
  )
}

fn oil_tin() -> store.Pending {
  store.Pending(
    name: "tin of lamp oil",
    looks: "a small dented tin can of oil with a cork stopper",
    role: "fuel",
    unlocks: None,
  )
}

fn cell_text(cell: types.Cell) -> String {
  int.to_string(cell.0)
  <> ","
  <> int.to_string(cell.1)
  <> ","
  <> int.to_string(cell.2)
}

type Proposal {
  Proposal(
    name: String,
    description: String,
    /// What the picture shows (see `types.Room.picture`).
    picture: String,
    features: List(String),
    items: List(String),
    /// Item name → what it plainly looks like, for the picture. A game name
    /// can mislead an image model: "tin of lamp oil" gets drawn as a lamp,
    /// "a small dented tin can of oil" as the thing itself.
    looks: List(#(String, String)),
    exits: List(#(String, String)),
    /// Asked for when the engine wants a lock here: which new way out is
    /// locked, what bars it, and the key that opens it.
    lock: Option(LockPlan),
  )
}

pub type LockPlan {
  LockPlan(exit: String, desc: String, key_name: String, key_looks: String)
}

/// What a build has to honour besides the model's own ideas.
type Context {
  Context(
    client: Client,
    prompt: String,
    back: Direction,
    taken: List(String),
    /// The room the player came from: the new one mustn't copy it.
    from_description: String,
    /// Items promised to this cell (a key for a nearby lock): the room
    /// must have them and its description must mention them.
    required: List(store.Pending),
    /// Height of the new place: below 0 is underground.
    level: Int,
    shape: Shape,
  )
}

/// What a build did: which room is now beyond the exit, whether it was newly
/// written (so it needs a picture), and every room whose exits changed (so
/// their processes can reload).
pub type Built {
  Built(room_id: Int, new: Bool, touched: List(Int))
}

/// Make the exit `exit` of `from` lead somewhere, keeping the grid honest:
/// the room beyond is always exactly one step away. If that cell already has
/// a room, the exit joins it (that's how loops form). Otherwise a new room
/// is invented, written at that cell, and joined to every neighbour whose
/// own ways out point into it.
pub fn build(store: Store, client: Client, from: Room, exit: Exit) -> Built {
  let target = types.step(types.cell(from), exit.direction)
  case store.room_at(store, target) {
    Some(existing) -> join(store, from, exit.direction, existing)
    None -> invent(store, client, from, exit, target)
  }
}

/// `from`'s exit in direction `d` now leads to the existing room `to`; make
/// sure there's a way back from `to`, adding one if it had none.
fn join(store: Store, from: Room, d: Direction, to: Int) -> Built {
  store.link_exit(store, from.id, d, to)
  let back = types.opposite(d)
  case store.load_room(store, to) {
    Ok(other) ->
      case types.find_exit(other, back) {
        Ok(types.Exit(target: None, ..)) ->
          store.link_exit(store, other.id, back, from.id)
        Ok(_) -> Nil
        Error(Nil) ->
          store.add_exit(
            store,
            other.id,
            NewExit(
              back,
              "a way through toward " <> from.name,
              from.region,
              Some(from.id),
            ),
          )
      }
    Error(Nil) -> Nil
  }
  case store.load_room(store, to) {
    Ok(other) ->
      case
        needs_door(#(from.setting, from.building, from.z), #(
          other.setting,
          other.building,
          other.z,
        ))
      {
        True -> store.set_door(store, from.id, d)
        False -> Nil
      }
    Error(Nil) -> Nil
  }
  Built(room_id: to, new: False, touched: [from.id, to])
}

fn invent(
  store: Store,
  client: Client,
  from: Room,
  exit: Exit,
  target: types.Cell,
) -> Built {
  let back = types.opposite(exit.direction)
  let region =
    store.region(store, exit.target_region)
    |> result.unwrap(types.Region(exit.target_region, exit.target_region, ""))
  // Rooms already built around the new cell, other than the one we came
  // from: #(direction from the new room, that room).
  let neighbours =
    types.all_directions
    |> list.filter(fn(d) { d != back })
    |> list.filter_map(fn(d) {
      case store.room_at(store, types.step(target, d)) {
        Some(id) -> store.load_room(store, id) |> result.map(fn(r) { #(d, r) })
        None -> Error(Nil)
      }
    })
  // Promised to this cell (a key for a lock nearby), and whether to ask for
  // a lock here: only if at least two new ways out could lead somewhere new
  // (one locked, one to the room holding its key), which the model's exits
  // decide; checked again after it answers.
  let level = target.2
  // Difficulty grows with distance from the crossroads: near it, no dark,
  // no locks or obstacles, and the only things to find are helpful.
  let tier = tier(target)
  let odds = odds(tier)
  // Some places below the streets are pitch dark.
  let dark = level < 0 && int.random(100) < odds.dark
  // Something helpful to pick up now and then (a tool, a light, oil).
  let gift = case int.random(100) < odds.gift {
    True -> option.values([helpful_find(store)])
    False -> []
  }
  // Now and then a treasure map (and, if nothing to dig with is about, a
  // spade to go with it).
  let #(treasure_map, map_note) = case int.random(100) < odds.map {
    True -> bury_treasure(store, target)
    False -> #([], "")
  }
  let required =
    list.flatten([store.pending_at(store, target), gift, treasure_map])
  // Upstairs is a dead end: nothing to lock there.
  let want_lock = level < 1 && int.random(100) < odds.lock
  let shape = shape(store, from, exit, target)
  let prompt =
    prompt(
      store,
      from,
      exit,
      region,
      back,
      neighbours,
      required,
      want_lock,
      level,
      shape,
      dark,
    )
  let ctx =
    Context(
      client:,
      prompt:,
      back:,
      taken: store.room_names(store),
      from_description: from.description,
      required:,
      level:,
      shape:,
    )
  let #(proposal, build_log) = propose(ctx, attempts)
  // The model can insist on a name through every retry; and two rooms built
  // at the same moment can't see each other's. Re-read and set it apart.
  let proposal =
    Proposal(
      ..proposal,
      name: unique_name(proposal.name, store.room_names(store)),
    )
  let proposed =
    list.filter_map(proposal.exits, fn(e) {
      use d <- result.map(types.parse_direction(e.0))
      #(d, e.1)
    })
  // A neighbour that already has a way out pointing into this cell gets
  // one back, even if the model didn't think of it.
  let facing =
    list.filter(neighbours, fn(n) {
      result.is_ok(types.find_exit(n.1, types.opposite(n.0)))
    })
  let new_exits =
    list.flatten([
      [
        NewExit(
          back,
          case exit.door, shape.setting {
            True, types.Inside -> "the door back out to " <> from.name
            True, _ -> "the door back into " <> from.name
            False, _ -> "back toward " <> from.name
          },
          from.region,
          Some(from.id),
        ),
      ],
      list.map(proposed, fn(e) {
        // A way out into a built cell leads to the room that's there.
        let target =
          list.key_find(neighbours, e.0)
          |> result.map(fn(r) { r.id })
          |> option.from_result
        NewExit(e.0, e.1, region.id, target)
      }),
      facing
        |> list.filter(fn(n) { result.is_error(list.key_find(proposed, n.0)) })
        |> list.map(fn(n) {
          NewExit(
            n.0,
            "toward " <> { n.1 }.name,
            { n.1 }.region,
            Some({ n.1 }.id),
          )
        }),
    ])
  case
    store.insert_room(
      store,
      region.id,
      proposal.name,
      proposal.description,
      proposal.features,
      proposal.items,
      new_exits,
      target,
    )
  {
    // Another build claimed the cell while this one was thinking: use theirs.
    Error(Nil) ->
      case store.room_at(store, target) {
        Some(existing) -> join(store, from, exit.direction, existing)
        None -> panic as "room insert failed with the cell still empty"
      }
    Ok(id) -> {
      store.set_picture(store, id, proposal.picture)
      // What kind of place it is; a new building is known by its first room.
      let building = case shape.setting, shape.building {
        types.Inside, None -> Some(id)
        types.Inside, b -> b
        _, _ -> None
      }
      store.set_setting(store, id, shape.setting, building)
      case shape.door {
        Some(d) ->
          case
            list.any(proposal.exits, fn(e) { e.0 == types.direction_name(d) })
          {
            True -> store.set_door(store, id, d)
            False -> Nil
          }
        None -> Nil
      }
      // Promised items get their role (a key, and the lock it opens); the
      // model's own items are valuables (the column's default).
      list.each(required, fn(r) {
        store.set_item_role(store, id, r.name, r.role, r.unlocks)
        case r.role {
          "light" -> store.set_item_charge(store, id, r.name, types.lantern_oil)
          _ -> Nil
        }
      })
      store.clear_pending(store, target)
      let dark_note = case dark {
        False -> ""
        True -> {
          store.set_dark(store, id)
          // Never a dark place without a light to be had: if none is free,
          // promise one to an unbuilt place at street level (never dark,
          // reachable by anyone).
          case store.free_lights(store) {
            0 ->
              case store.street_cell_for_light(store) {
                Some(cell) -> {
                  store.add_pending(store, cell, lantern())
                  "used: dark; no free light anywhere, so a lantern is promised to the street-level place at "
                  <> cell_text(cell)
                }
                None ->
                  "used: dark; no free light, and no unbuilt street-level place to promise one to"
              }
            _ -> "used: dark (a light is already to be had)"
          }
        }
      }
      // The model often leaves the lock out when asked: then the engine
      // picks the way to lock and asks just for what the lock looks like.
      let proposal = case want_lock, proposal.lock {
        True, None ->
          Proposal(
            ..proposal,
            lock: invent_lock(client, region, proposal, back, neighbours),
          )
        _, _ -> proposal
      }
      // A door is never locked or blocked by the builder: a shop you can see
      // is a shop you can go into.
      let unbarred = case shape.door {
        Some(d) ->
          Proposal(
            ..proposal,
            exits: list.filter(proposal.exits, fn(e) {
              e.0 != types.direction_name(d)
            }),
          )
        None -> proposal
      }
      let lock_note =
        place_lock(store, id, target, unbarred, neighbours, back, from)
      // Sometimes (and not as well as a lock) a way out is blocked by an
      // obstacle a tool gets you past.
      let obstacle_note = case
        lock_note == "" && int.random(100) < odds.obstacle
      {
        True ->
          place_obstacle(
            store,
            client,
            id,
            target,
            unbarred,
            neighbours,
            back,
            from,
            region,
          )
        False -> ""
      }
      // What each item plainly looks like, for its close-up when examined.
      list.each(proposal.items, fn(item) {
        case list.key_find(proposal.looks, item) {
          Ok(look) if look != "" -> store.set_item_look(store, id, item, look)
          _ -> Nil
        }
      })
      store.save_build_debug(
        store,
        id,
        prompt,
        list.append(
          build_log,
          [
            "difficulty: " <> tier_name(tier),
            map_note,
            lock_note,
            obstacle_note,
            dark_note,
          ]
            |> list.filter(non_empty)
            |> list.map(fn(note) {
              store.BuildAttempt(feedback: "", reply: "", problem: note)
            }),
        ),
      )
      // Joining last: until these run, nobody can walk into a half-written
      // room. Then the neighbours: an unbuilt exit of theirs pointing here
      // now leads here; one we gave a way out toward gets a way back.
      store.link_exit(store, from.id, exit.direction, id)
      let touched =
        list.filter_map(neighbours, fn(n) {
          let #(d, other) = n
          let toward_us = types.opposite(d)
          let ours = list.any(new_exits, fn(e) { e.direction == d })
          case types.find_exit(other, toward_us), ours {
            Ok(types.Exit(target: None, ..)), _ -> {
              store.link_exit(store, other.id, toward_us, id)
              Ok(other.id)
            }
            Error(Nil), True -> {
              store.add_exit(
                store,
                other.id,
                NewExit(
                  toward_us,
                  "a way through toward " <> proposal.name,
                  region.id,
                  Some(id),
                ),
              )
              Ok(other.id)
            }
            _, _ -> Error(Nil)
          }
        })
      // A way into a neighbour of another kind (a street beside a building,
      // two buildings side by side) is a door.
      list.each(neighbours, fn(n) {
        let #(d, other) = n
        case
          list.any(new_exits, fn(e) { e.direction == d })
          && needs_door(#(shape.setting, building, target.2), #(
            other.setting,
            other.building,
            other.z,
          ))
        {
          True -> store.set_door(store, id, d)
          False -> Nil
        }
      })
      Built(room_id: id, new: True, touched: [from.id, ..touched])
    }
  }
}

/// Block one of the room's new ways out (one leading somewhere unbuilt) with
/// an obstacle of a random tool kind, described by a small question to the
/// model. If no tool of that kind is free anywhere, one is promised to an
/// unbuilt place reachable without passing the obstacle; if there's nowhere
/// for it, there's no obstacle.
fn place_obstacle(
  store: Store,
  client: Client,
  room_id: Int,
  cell: types.Cell,
  proposal: Proposal,
  neighbours: List(#(Direction, Room)),
  back: Direction,
  from: Room,
  region: types.Region,
) -> String {
  let open_exits =
    proposal.exits
    |> list.filter_map(fn(e) {
      use d <- result.try(types.parse_direction(e.0))
      case
        d != back
        && result.is_error(list.key_find(neighbours, d))
        && store.room_at(store, types.step(cell, d)) == None
      {
        True -> Ok(#(d, e.1))
        False -> Error(Nil)
      }
    })
  let kinds = types.tool_kinds
  let assert Ok(kind) =
    list.drop(kinds, int.random(list.length(kinds))) |> list.first
  case open_exits {
    [] -> ""
    [#(blocked, hint), ..others] -> {
      let blocked_cell = types.step(cell, blocked)
      let tool_spot = case store.free_tools(store, kind.kind) {
        0 -> {
          let here =
            list.map(others, fn(o) {
              #(
                types.step(cell, o.0),
                "beyond this room's way " <> types.direction_name(o.0),
              )
            })
          let behind =
            from.exits
            |> list.filter(fn(e) {
              e.target == None && e.lock == None && e.obstacle == None
            })
            |> list.map(fn(e) {
              #(
                types.step(types.cell(from), e.direction),
                "beyond "
                  <> from.name
                  <> "'s way "
                  <> types.direction_name(e.direction),
              )
            })
            |> list.filter(fn(c) {
              c.0 != cell
              && c.0 != blocked_cell
              && store.room_at(store, c.0) == None
            })
          case list.append(here, behind) {
            [spot, ..] -> Ok(Some(spot))
            [] -> Error(Nil)
          }
        }
        _ -> Ok(None)
      }
      case tool_spot {
        Error(Nil) ->
          "obstacle dropped: no "
          <> kind.name
          <> " is to be had, and nowhere reachable to promise one"
        Ok(spot) -> {
          let desc =
            describe_obstacle(client, region, proposal.name, hint, kind)
          store.set_obstacle(
            store,
            room_id,
            blocked,
            types.Obstacle(kind: kind.kind, desc:),
          )
          let tool_note = case spot {
            Some(#(tool_cell, where)) -> {
              store.add_pending(
                store,
                tool_cell,
                store.Pending(
                  name: kind.name,
                  looks: kind.looks,
                  role: "tool",
                  unlocks: Some(kind.kind),
                ),
              )
              "; " <> a(kind.name) <> " is promised to the room " <> where
            }
            None -> "; " <> a(kind.name) <> " is already to be had"
          }
          "used: the way "
          <> types.direction_name(blocked)
          <> " is blocked ("
          <> desc
          <> ")"
          <> tool_note
        }
      }
    }
  }
}

/// "a crowbar", "an iron crowbar".
fn a(name: String) -> String {
  case
    list.contains(
      ["a", "e", "i", "o", "u"],
      string.slice(string.lowercase(name), 0, 1),
    )
  {
    True -> "an " <> name
    False -> "a " <> name
  }
}

/// What blocks the way, in the model's words if it gives some.
fn describe_obstacle(
  client: Client,
  region: types.Region,
  place: String,
  hint: String,
  kind: types.ToolKind,
) -> String {
  let ask =
    seed.setting
    <> "\n\nA place called \""
    <> place
    <> "\" in "
    <> region.name
    <> ". One way out of it ("
    <> hint
    <> ") is blocked by "
    <> kind.obstacles
    <> ". Describe what blocks it, in 5-12 words."
    <> "\nReply with JSON only: {\"obstacle\": \"what blocks the way\"}"
  let fallback = case kind.kind {
    "crowbar" -> "a rusted iron grate, its hinges seized"
    "rope" -> "a sheer drop where the stairs have fallen away"
    "spade" -> "a heap of fallen rubble and earth choking the way"
    _ -> "a ladder pulled up well out of reach"
  }
  // It has to be something this tool deals with (one model reply was "a
  // decrepit wooden wheel" for a crowbar): otherwise, the stock one.
  let fits = fn(desc: String) {
    let text = string.lowercase(desc)
    obstacle_words(kind.kind) |> list.any(string.contains(text, _))
  }
  case llm.generate(client, llm.Ask(..llm.ask_json(ask), timeout: 30_000)) {
    Ok(text) ->
      case json.parse(text, decode.at(["obstacle"], decode.string)) {
        Ok(desc) ->
          case lock_text(desc) {
            "" -> fallback
            desc ->
              case fits(desc) {
                True -> desc
                False -> fallback
              }
          }
        Error(_) -> fallback
      }
    Error(Nil) -> fallback
  }
}

/// Words that show an obstacle is the kind its tool deals with.
pub fn obstacle_words(kind: String) -> List(String) {
  case kind {
    "crowbar" -> [
      "grate",
      "board",
      "plank",
      "hatch",
      "nailed",
      "stuck",
      "rusted shut",
      "jammed",
      "shutter",
      "bars",
    ]
    "rope" -> [
      "drop",
      "stair",
      "ledge",
      "gap",
      "shaft",
      "chasm",
      "pit",
      "collapsed",
      "fallen away",
      "climb",
    ]
    "spade" -> [
      "rubble", "earth", "cave-in", "caved", "silt", "mud", "heap",
      "fallen stone", "landslide", "buried",
    ]
    _ -> [
      "ladder",
      "hatch",
      "drawbridge",
      "out of reach",
      "overhead",
      "high above",
      "raised",
      "pulled up",
    ]
  }
}

/// A lock for one of the room's new ways out (the first that doesn't lead
/// into a built place), described by a small, focused question to the model;
/// a plain locked door if it doesn't answer usefully. `place_lock` still
/// checks there's somewhere for the key.
fn invent_lock(
  client: Client,
  region: types.Region,
  proposal: Proposal,
  back: Direction,
  neighbours: List(#(Direction, Room)),
) -> Option(LockPlan) {
  let candidate =
    proposal.exits
    |> list.filter_map(fn(e) {
      use d <- result.try(types.parse_direction(e.0))
      case d != back && result.is_error(list.key_find(neighbours, d)) {
        True -> Ok(#(d, e.1))
        False -> Error(Nil)
      }
    })
    |> list.first
  use #(d, hint) <- option.then(option.from_result(candidate))
  let ask =
    seed.setting
    <> "\n\nA place called \""
    <> proposal.name
    <> "\" in "
    <> region.name
    <> ". One way out of it ("
    <> hint
    <> ") is locked. Describe what bars that way and the key that opens it."
    <> "\nReply with JSON only: {\"lock\": \"5-12 words: a door, gate, grate, hatch or shutter and how it is locked\", "
    <> "\"key\": {\"name\": \"2-4 words ending in 'key'\", \"looks\": \"what the key plainly looks like, 4-10 words\"}}"
  let decoder = {
    use desc <- decode.field("lock", decode.string)
    use name <- decode.optional_field(
      "key",
      "",
      decode.optional_field("name", "", decode.string, decode.success),
    )
    use looks <- decode.optional_field(
      "key",
      "",
      decode.optional_field("looks", "", decode.string, decode.success),
    )
    decode.success(#(desc, name, looks))
  }
  let #(desc, name, looks) = case
    llm.generate(client, llm.Ask(..llm.ask_json(ask), timeout: 30_000))
  {
    Ok(text) ->
      case json.parse(text, decoder) {
        Ok(#(desc, name, looks)) if desc != "" -> #(desc, name, looks)
        _ -> #("", "", "")
      }
    Error(Nil) -> #("", "", "")
  }
  Some(
    LockPlan(
      exit: types.direction_name(d),
      desc: case lock_text(desc) {
        "" -> "a stout locked door"
        text -> text
      },
      key_name: key_name(name),
      key_looks: case clean(looks, 80) {
        "" -> "a heavy old iron key"
        text -> text
      },
    ),
  )
}

/// A lock's description: one clause, at most 14 words, never cut mid-word.
fn lock_text(text: String) -> String {
  first_sentence(clean(text, 300), 14)
}

/// Lock the way out the model chose, and promise its key to an unbuilt
/// place reachable without passing the lock, so the puzzle can always be
/// solved: beyond another of this room's new ways out, or failing that,
/// beyond one of the previous room's unexplored ways out. Both the locked
/// cell and the key's cell must be unbuilt — a key can't be added to a room
/// whose text is already written. Returns a note for the developer view
/// ("" if there's no lock).
fn place_lock(
  store: Store,
  room_id: Int,
  cell: types.Cell,
  proposal: Proposal,
  neighbours: List(#(Direction, Room)),
  back: Direction,
  from: Room,
) -> String {
  let open_exits =
    proposal.exits
    |> list.filter_map(fn(e) { types.parse_direction(e.0) })
    |> list.filter(fn(d) {
      d != back
      && result.is_error(list.key_find(neighbours, d))
      && store.room_at(store, types.step(cell, d)) == None
    })
  case proposal.lock {
    None -> ""
    Some(plan) ->
      case types.parse_direction(string.lowercase(string.trim(plan.exit))) {
        Error(Nil) -> "lock dropped: \"" <> plan.exit <> "\" isn't a direction"
        Ok(locked) -> {
          let locked_cell = types.step(cell, locked)
          let here =
            open_exits
            |> list.filter(fn(d) { d != locked })
            |> list.map(fn(d) {
              #(
                types.step(cell, d),
                "beyond this room's way " <> types.direction_name(d),
              )
            })
          let behind =
            from.exits
            |> list.filter(fn(e) { e.target == None && e.lock == None })
            |> list.map(fn(e) {
              #(
                types.step(types.cell(from), e.direction),
                "beyond "
                  <> from.name
                  <> "'s way "
                  <> types.direction_name(e.direction),
              )
            })
            |> list.filter(fn(c) {
              c.0 != cell
              && c.0 != locked_cell
              && store.room_at(store, c.0) == None
            })
          case list.contains(open_exits, locked), list.append(here, behind) {
            True, [#(key_cell, where), ..] -> {
              let lock_id =
                "lock-"
                <> int.to_string(room_id)
                <> "-"
                <> types.direction_name(locked)
              store.lock_exit(store, room_id, locked, lock_id, plan.desc)
              store.add_pending(
                store,
                key_cell,
                store.Pending(
                  name: plan.key_name,
                  looks: plan.key_looks,
                  role: "key",
                  unlocks: Some(lock_id),
                ),
              )
              "used: locked the way "
              <> types.direction_name(locked)
              <> " ("
              <> plan.desc
              <> "); its key, "
              <> plan.key_name
              <> ", is promised to the room "
              <> where
            }
            _, _ ->
              "lock dropped: the locked way must lead somewhere unbuilt, and there must be another unbuilt place, reachable without it, for the key"
          }
        }
      }
  }
}

/// The city has three levels: the underground (−1), the streets (0) and
/// upstairs (+1). The underground is one connected network; upstairs is a
/// dead end, a single room you climb to and come back down from.
pub const lowest_level = -1

pub const highest_level = 1

/// Percent of street places that may have a way up (a fire escape, a
/// belfry ladder) onto a rooftop.
pub const up_chance = 20

/// Percent of street places with a door into a building.
pub const door_chance = 40

/// Percent of buildings with stairs up to a floor above.
pub const stairs_chance = 50

/// Rooms a building has on the ground floor, at most.
pub const building_rooms = 3

/// What the engine decides about a new place before the model describes
/// it: what kind of place it is, which ways out it may have, and whether
/// one of them is a door into a building.
pub type Shape {
  Shape(
    setting: types.Setting,
    /// An inside place's building; `None` for a new building (it takes the
    /// new room's id) and for places outside.
    building: Option(Int),
    /// The player came through a door to get here.
    via_door: Bool,
    /// Directions the model may give new ways out in.
    choices: List(String),
    /// A way out the engine wants to be a door into a building.
    door: Option(Direction),
    /// At most this many new ways out on the same level (a building's
    /// rooms are few).
    rooms_left: Int,
  )
}

/// Outdoors or inside (and which building) for the place beyond `from`'s
/// way out. Below the streets is always below. At street level, a door
/// takes you from outside to inside or back, and otherwise you stay as you
/// were; coming up from below brings you out onto a street. Upstairs is in
/// the same building as the room below it, or a rooftop above a street.
pub fn setting_for(
  from: #(types.Setting, Option(Int), Int),
  through_door: Bool,
  level: Int,
) -> #(types.Setting, Option(Int)) {
  let #(setting, building, id) = from
  let building = option.or(building, Some(id))
  case level, setting, through_door {
    l, _, _ if l < 0 -> #(types.Below, None)
    _, types.Inside, False -> #(types.Inside, building)
    _, types.Inside, True -> #(types.Outdoors, None)
    0, types.Outdoors, True -> #(types.Inside, None)
    _, _, _ -> #(types.Outdoors, None)
  }
}

/// The directions a place may have new ways out in. Upstairs has none; the
/// underground has no way further down. `across` (other places on the same
/// level) and `up` are decided per place.
pub fn choices(level: Int, across: Bool, up: Bool) -> List(String) {
  case level >= highest_level {
    True -> []
    False ->
      list.flatten([
        case across {
          True -> ["north", "south", "east", "west"]
          False -> []
        },
        case up || level < 0 {
          True -> ["up"]
          False -> []
        },
        case level > lowest_level {
          True -> ["down"]
          False -> []
        },
      ])
  }
}

/// At most `left` ways out on the same level (north, south, east, west);
/// ways up and down are kept.
pub fn keep_across(
  exits: List(#(String, String)),
  left: Int,
) -> List(#(String, String)) {
  case exits {
    [] -> []
    [e, ..rest] ->
      case e.0 == "up" || e.0 == "down" {
        True -> [e, ..keep_across(rest, left)]
        False if left > 0 -> [e, ..keep_across(rest, left - 1)]
        False -> keep_across(rest, left)
      }
  }
}

/// Two neighbouring places joined by a way through need a door between
/// them when one is a street and the other a building, or they're two
/// buildings. Settings and buildings, and heights (only side by side).
pub fn needs_door(
  a: #(types.Setting, Option(Int), Int),
  b: #(types.Setting, Option(Int), Int),
) -> Bool {
  case a, b {
    #(_, _, za), #(_, _, zb) if za != zb -> False
    #(types.Below, _, _), _ | _, #(types.Below, _, _) -> False
    #(types.Inside, ba, _), #(types.Inside, bb, _) -> ba != bb
    #(sa, _, _), #(sb, _, _) -> sa != sb
  }
}

fn shape(store: Store, from: Room, exit: Exit, target: types.Cell) -> Shape {
  let level = target.2
  let #(setting, building) =
    setting_for(#(from.setting, from.building, from.id), exit.door, level)
  let back = types.opposite(exit.direction)
  // How many more rooms beside this one the building may have: rooms built
  // and ways already leading to rooms to come both count.
  let #(rooms_left, up) = case setting, building {
    types.Inside, Some(b) -> {
      let #(ground, upstairs) = store.building_rooms(store, b)
      let #(open_across, open_up) = store.building_open_ways(store, b)
      #(
        building_rooms - ground - 1 - open_across,
        upstairs + open_up == 0 && level == 0 && int.random(100) < stairs_chance,
      )
    }
    // The first room of a new building.
    types.Inside, None -> #(building_rooms - 1, int.random(100) < stairs_chance)
    types.Outdoors, _ -> #(3, level == 0 && int.random(100) < up_chance)
    types.Below, _ -> #(3, True)
  }
  let choices = choices(level, rooms_left > 0, up)
  // Now and then a street has a door into a building, on a side where
  // nothing is built yet.
  let door = case
    setting == types.Outdoors && level == 0 && int.random(100) < door_chance
  {
    False -> None
    True ->
      [types.North, types.South, types.East, types.West]
      |> list.filter(fn(d) {
        d != back && store.room_at(store, types.step(target, d)) == None
      })
      |> list.shuffle
      |> list.first
      |> option.from_result
  }
  Shape(setting:, building:, via_door: exit.door, choices:, door:, rooms_left:)
}

/// What a place of this kind, at this height, has to be.
fn place_rule(shape: Shape, level: Int, from: Room) -> String {
  case shape.setting, level {
    types.Below, _ ->
      "This place is below the streets: it must be underground, a sewer, tunnel, cellar, crypt, cistern or cavern. No sky, no streets, no alleys, no shopfronts. There is no way further down."
    types.Outdoors, 0 ->
      "This place is outdoors, at street level, under the open sky: a street, lane, alley, court, yard, square, quay, bridge or market. Not inside a building, tunnel, cave or grotto: buildings stand around it, and you only go into one through its door."
      <> case shape.via_door {
        True ->
          " The player has just stepped out of "
          <> from.name
          <> " through its door."
        False -> ""
      }
    types.Outdoors, _ ->
      "This place is a rooftop, high above the street, open to the sky: reached by a fire escape, an outside stair or a belfry ladder, looking out over the city. There is no way further up and no way on: the only way out is back down."
    types.Inside, 0 ->
      "This place is inside a building: a shop, inn, tavern, workshop, pawnshop, apothecary, chapel, warehouse or house. Walls and a ceiling around you; lamps or candles light it; no open sky."
      <> case shape.via_door {
        True ->
          " The player has just come in from the street through its door (the way back)."
        False ->
          " It is a further room of the same building as "
          <> from.name
          <> " (a back room, a storeroom, a workroom, a parlour)."
      }
    types.Inside, _ ->
      "This place is upstairs inside the building below ("
      <> from.name
      <> "): an upper room, a garret, a loft or a belfry, reached by its stairs. Walls and a ceiling around you. There is no way further up and no way on: the only way out is back down."
  }
}

/// A street-level place that's indoors or underground (it should be out
/// under the sky): words in its name, and in its description or picture.
pub fn indoor_words(
  name: String,
  text: String,
  setting: types.Setting,
  level: Int,
) -> List(String) {
  case setting == types.Outdoors && level == 0 {
    False -> []
    True -> {
      let name = string.lowercase(name)
      let text = string.lowercase(text)
      let in_name =
        [
          "tunnel", "grotto", "cavern", "cave", "depths", "cistern", "crypt",
          "cellar", "sewer", "hall", "chamber", "corridor",
        ]
        |> list.filter(string.contains(name, _))
      let in_text =
        [
          "grotto", "cavern", "corridor", "hallway", "ceiling", "chandelier",
          "indoors", "you push open",
        ]
        |> list.filter(string.contains(text, _))
      list.unique(list.append(in_name, in_text))
    }
  }
}

/// A place inside a building that describes being out under the sky.
pub fn outdoor_words(text: String, setting: types.Setting) -> List(String) {
  case setting {
    types.Inside -> {
      let text = string.lowercase(text)
      ["open sky", "under the sky", "beneath the sky", "starlit sky"]
      |> list.filter(string.contains(text, _))
    }
    _ -> []
  }
}

/// An underground place that describes streets or sky: not underground.
pub fn above_ground_words(description: String, level: Int) -> List(String) {
  case level < 0 {
    False -> []
    True -> {
      let text = string.lowercase(description)
      ["street", "alley", "sky", "rooftop", "shopfront", "storefront"]
      |> list.filter(string.contains(text, _))
    }
  }
}

fn prompt(
  store: Store,
  from: Room,
  exit: Exit,
  region: types.Region,
  back: Direction,
  neighbours: List(#(Direction, Room)),
  required: List(store.Pending),
  want_lock: Bool,
  level: Int,
  shape: Shape,
  dark: Bool,
) -> String {
  let used = case list.take(list.reverse(store.room_names(store)), 40) {
    [] -> "none yet"
    names -> string.join(names, ", ")
  }
  let around = case neighbours {
    [] -> ""
    _ ->
      "\nAlready built right next to this place (an exit in that direction joins it): "
      <> neighbours
      |> list.map(fn(n) { types.direction_name(n.0) <> " — " <> { n.1 }.name })
      |> string.join("; ")
      <> "."
  }
  let must_contain = case required {
    [] -> ""
    _ ->
      "\nThis place must contain: "
      <> required
      |> list.map(fn(r) { r.name <> " (" <> r.looks <> ")" })
      |> string.join("; ")
      <> ". Mention each by its exact name in the description; they are added for you."
  }
  let lock = case want_lock {
    False -> ""
    True ->
      "\nGive 2 or 3 exits, and make exactly one of them (not the way back) locked: add "
      <> "\"lock\": {\"exit\": \"its direction\", \"lock\": \"what bars that way, 5-12 words, in your own words and fitting this place: a door, gate, grate, hatch or shutter, and how it is locked\", "
      <> "\"key\": {\"name\": \"the key that opens it: 2-4 words ending in 'key'\", \"looks\": \"what the key plainly looks like, 4-10 words\"}} at the top level of the JSON, next to \"exits\". "
      <> "The key is not here; it lies somewhere nearby. Mention the lock in the description."
  }
  seed.setting
  <> "\n\nRegion: "
  <> region.name
  <> " — "
  <> region.theme
  // Only the previous place's name, not its description: shown that, a 3B
  // model often copied it (items and all) into the new room.
  <> "\n\nThe player leaves \""
  <> from.name
  <> "\" going "
  <> types.direction_name(exit.direction)
  <> ". Before going, they saw: \""
  <> exit.hint
  <> "\".\nPlace names already used in the city (invent a new one, do not reuse these): "
  <> used
  <> "."
  <> around
  <> "\n"
  <> place_rule(shape, level, from)
  <> case dark {
    True ->
      " It is pitch dark here, with no lamps or candles burning: describe what the player's own lantern, held up, reveals in its small circle of light."
    False -> ""
  }
  <> must_contain
  <> "\n\nInvent the new place they arrive in, in your own words. It must match what they saw and fit the region."
  <> "\nReply with JSON only, in exactly this shape:\n"
  <> "{\"name\": \"2-5 word place name\", "
  <> "\"description\": \"2-4 sentences, second person present tense\", "
  <> "\"picture\": \"one plain sentence, under 25 words, describing what a painting of this place shows (the place itself, its light and its main features); nothing that isn't in the description\", "
  <> "\"features\": [\"3-5 short visual details, including any objects here\"], "
  <> case shape.choices {
    [] -> "\"exits\": []}"
    choices ->
      "\"exits\": [{\"direction\": \""
      <> string.join(choices, "|")
      <> "\", \"hint\": \"short phrase: what you see of that way out\"}]}"
  }
  <> "\nThe description must mention every visual detail, and should hint at each way out without listing directions."
  <> " A way down must look like a way down (stairs, a ladder, a grate, a hatch, a hole) and a way up like a way up."
  <> case shape.choices, want_lock {
    [], _ ->
      "\nGive no exits: the only way out is back the way the player came."
    _, True -> ""
    _, False ->
      case shape.setting {
        types.Inside ->
          "\nGive 0 to 2 exits: further rooms of this building"
          <> case list.contains(shape.choices, "up") {
            True -> ", a staircase up to the floor above"
            False -> ""
          }
          <> case list.contains(shape.choices, "down") {
            True -> ", or steps down to a cellar"
            False -> ""
          }
          <> ". None is fine: a small place you leave the way you came."
        _ ->
          "\nGive 1 to 3 exits."
          <> case
            shape.setting == types.Outdoors
            && list.contains(shape.choices, "up")
          {
            True ->
              " This place may have a way up onto a rooftop (a fire escape, an outside stair, a belfry ladder), but only if it fits."
            False -> ""
          }
      }
  }
  <> case shape.door {
    Some(d) ->
      "\nOne of the exits must be \""
      <> types.direction_name(d)
      <> "\": the door into a building beside this place (a shop, inn, tavern, workshop, pawnshop, apothecary, chapel, warehouse or house). Its hint names the building and its door, and the description mentions that door."
    None -> ""
  }
  <> " Do not use the direction \""
  <> types.direction_name(back)
  <> "\" — that is the way back."
  <> lock
}

/// Ask for a room, check it, and ask again on failure. A retry tells the
/// model what was wrong: sent the identical prompt, a small model tends to
/// give the identical answer (one proposed the same taken name nine times).
/// The proposal used, and every reply along the way (for the developer
/// view of how the room was made).
fn propose(ctx: Context, left: Int) -> #(Proposal, List(store.BuildAttempt)) {
  let #(proposal, log) = attempt(ctx, "", left, [])
  #(proposal, list.reverse(log))
}

fn attempt(
  ctx: Context,
  feedback: String,
  left: Int,
  log: List(store.BuildAttempt),
) -> #(Proposal, List(store.BuildAttempt)) {
  let retry = fn(reply: String, problem: String) {
    logging.log(logging.Info, "room proposal rejected: " <> problem)
    attempt(
      ctx,
      "\n\nYour previous answer was rejected: " <> problem <> ". Fix that.",
      left - 1,
      [store.BuildAttempt(feedback:, reply:, problem:), ..log],
    )
  }
  case left {
    0 -> {
      logging.log(
        logging.Warning,
        "room builder gave up; writing fallback room",
      )
      let fallback = fallback()
      #(with_required(fallback, ctx.required), [
        store.BuildAttempt(
          feedback: "",
          reply: "",
          problem: "gave up after every attempt failed: wrote the fallback room",
        ),
        ..log
      ])
    }
    _ ->
      case llm.generate(ctx.client, llm.ask_json(ctx.prompt <> feedback)) {
        Ok(text) ->
          case parse(text, ctx.back) {
            Ok(proposal) -> {
              let offered = proposal.exits
              let proposal =
                Proposal(
                  ..proposal,
                  exits: proposal.exits
                    |> list.filter(fn(e) {
                      list.contains(ctx.shape.choices, e.0)
                    })
                    |> keep_across(ctx.shape.rooms_left),
                )
              // Ways it described that this place can't have (a way up from
              // most streets): the description would promise them.
              let impossible =
                offered
                |> list.filter(fn(e) { !list.contains(proposal.exits, e) })
                |> list.map(fn(e) { e.0 })
              // No way on but back, below the top floor: a dead end, though
              // the description almost always describes ways on.
              let no_way_on =
                proposal.exits == []
                && ctx.shape.choices != []
                && ctx.shape.setting != types.Inside
              // The door the engine asked for, missing.
              let no_door = case ctx.shape.door {
                Some(d) ->
                  !list.any(proposal.exits, fn(e) {
                    e.0 == types.direction_name(d)
                  })
                None -> False
              }
              let indoors =
                indoor_words(
                  proposal.name,
                  proposal.description <> " " <> proposal.picture,
                  ctx.shape.setting,
                  ctx.level,
                )
              let outdoorsy =
                outdoor_words(
                  proposal.description <> " " <> proposal.picture,
                  ctx.shape.setting,
                )
              let duplicate =
                list.contains(ctx.taken, string.lowercase(proposal.name))
              let copied = repeats(proposal.description, ctx.from_description)
              // The picture line too: it alone decides what's drawn.
              let surfaced =
                above_ground_words(
                  proposal.description <> " " <> proposal.picture,
                  ctx.level,
                )
              let missing =
                list.filter(proposal.items, fn(i) {
                  !mentions(proposal.description, i)
                })
              let unmentioned =
                list.filter(ctx.required, fn(r) {
                  !mentions(proposal.description, r.name)
                })
              let wrong_setting = case indoors, outdoorsy {
                [_, ..], _ ->
                  Some(
                    "this place is outdoors at street level, under the sky, but it mentions "
                    <> string.join(indoors, ", ")
                    <> "; make it a street, lane, alley, court, square or quay, and name it like one",
                  )
                _, [_, ..] ->
                  Some(
                    "this place is inside a building, with a ceiling, but it mentions "
                    <> string.join(outdoorsy, ", ")
                    <> "; describe the room indoors",
                  )
                _, _ -> None
              }
              let door_problem = case ctx.shape.door, no_door {
                Some(d), True ->
                  Some(
                    "one exit must be \""
                    <> types.direction_name(d)
                    <> "\", the door into a building beside this place; add it, with a hint naming the building, and mention the door in the description",
                  )
                _, _ -> None
              }
              case
                left > 1,
                no_way_on,
                impossible,
                option.or(wrong_setting, door_problem)
              {
                True, True, _, _ ->
                  retry(
                    text,
                    "there is no way on besides the way back; give 1 to 3 exits, each with \"direction\" exactly one of "
                      <> string.replace(
                      string.join(ctx.shape.choices, ", "),
                      "|",
                      ", ",
                    )
                      <> ", and describe each",
                  )
                True, _, [_, ..], _ ->
                  retry(
                    text,
                    "this place can't have a way "
                      <> string.join(impossible, " or ")
                      <> "; leave it out of the exits and the description",
                  )
                True, _, _, Some(problem) -> retry(text, problem)
                _, _, _, _ ->
                  case duplicate, copied, missing, unmentioned, surfaced {
                    // One retry for a taken name: the model tends to repeat it
                    // however it's told, and `unique_name` can set it apart.
                    True, _, _, _, _ if left == attempts ->
                      retry(
                        text,
                        "\""
                          <> proposal.name
                          <> "\" is already a place in the city; choose a different name",
                      )
                    _, True, _, _, _ if left > 1 ->
                      retry(
                        text,
                        "the description repeats the previous place's description; describe this new place in your own words",
                      )
                    _, _, [_, ..], _, _ if left > 1 ->
                      retry(
                        text,
                        "the description doesn't mention "
                          <> string.join(missing, ", ")
                          <> " by name; mention each item in the description, or drop it",
                      )
                    _, _, _, [_, ..], _ if left > 1 ->
                      retry(
                        text,
                        "this place must contain "
                          <> string.join(
                          list.map(unmentioned, fn(r) { r.name }),
                          ", ",
                        )
                          <> "; mention each by its exact name in the description",
                      )
                    // Accept. On the last try, keep only items the description
                    // shows (a name still taken is set apart by `unique_name`),
                    // and make sure promised items are there and mentioned.
                    // The picture line is trimmed to the setting.
                    _, _, _, _, [_, ..] if left > 1 ->
                      retry(
                        text,
                        "this place is underground, below the streets, but the description mentions "
                          <> string.join(surfaced, ", ")
                          <> "; describe a tunnel, sewer, cellar, crypt or cavern instead",
                      )
                    _, _, _, _, _ -> {
                      let items =
                        list.filter(proposal.items, mentions(
                          proposal.description,
                          _,
                        ))
                      let dropped =
                        list.filter(proposal.items, fn(i) {
                          !list.contains(items, i)
                        })
                      let proposal =
                        Proposal(..proposal, items:)
                        |> with_required(ctx.required)
                      let note = case dropped {
                        [] -> ""
                        _ ->
                          "used, but dropped items the description never mentions: "
                          <> string.join(dropped, ", ")
                      }
                      #(
                        Proposal(
                          ..proposal,
                          picture: complete_picture(proposal),
                        ),
                        [
                          store.BuildAttempt(
                            feedback:,
                            reply: text,
                            problem: note,
                          ),
                          ..log
                        ],
                      )
                    }
                  }
              }
            }
            Error(reason) -> retry(text, reason)
          }
        Error(Nil) -> {
          logging.log(logging.Warning, "room builder: no answer from model")
          attempt(ctx, feedback, left - 1, [
            store.BuildAttempt(
              feedback:,
              reply: "",
              problem: "no answer from the model",
            ),
            ..log
          ])
        }
      }
  }
}

/// Promised items are always in the room, and always in its text: any the
/// description still doesn't mention get a sentence of their own.
fn with_required(p: Proposal, required: List(store.Pending)) -> Proposal {
  let names = list.map(required, fn(r) { r.name })
  let unmentioned =
    list.filter(required, fn(r) { !mentions(p.description, r.name) })
  let description = case unmentioned {
    [] -> p.description
    _ ->
      string.trim(p.description)
      <> " Here you also find "
      <> string.join(list.map(unmentioned, fn(r) { r.name }), " and ")
      <> "."
  }
  Proposal(
    ..p,
    description:,
    items: list.append(
      list.filter(p.items, fn(i) { !list.contains(names, i) }),
      names,
    ),
    looks: list.append(
      p.looks,
      list.map(required, fn(r) { #(r.name, r.looks) }),
    ),
  )
}

/// A key's name says it's a key: "Raven's Claw" → "raven's claw key"; no
/// name → "iron key". (The model once offered a "silver flask".)
pub fn key_name(raw: String) -> String {
  case item_name(raw) {
    "" -> "iron key"
    name ->
      case string.contains(name, "key") {
        True -> name
        False -> name <> " key"
      }
  }
}

/// Does `text` repeat a run of 8 or more words from `source`? (The model,
/// shown the previous room's description, sometimes just copied it.)
pub fn repeats(text: String, source: String) -> Bool {
  let words = fn(s: String) {
    s
    |> string.lowercase
    |> string.to_graphemes
    |> list.map(fn(g) {
      case string.contains("abcdefghijklmnopqrstuvwxyz0123456789'", g) {
        True -> g
        False -> " "
      }
    })
    |> string.concat
    |> string.split(" ")
    |> list.filter(non_empty)
  }
  let runs = fn(ws: List(String)) {
    list.window(ws, 8) |> list.map(string.join(_, " "))
  }
  let source_runs = runs(words(source))
  source_runs != []
  && list.any(runs(words(text)), list.contains(source_runs, _))
}

fn parse(text: String, back: Direction) -> Result(Proposal, String) {
  // Lenient where it can be: one malformed exit or item is dropped, not
  // the whole room. An exit given as a bare "north" gets an empty hint (and
  // is then dropped by the checks below, which need a hint).
  let exit =
    decode.one_of(
      {
        use direction <- decode.field("direction", decode.string)
        use hint <- decode.optional_field("hint", "", decode.string)
        decode.success(Ok(#(direction, hint)))
      },
      [
        decode.string |> decode.map(fn(d) { Ok(#(d, "")) }),
        decode.success(Error(Nil)),
      ],
    )
  let strings =
    decode.list(
      decode.one_of(decode.string |> decode.map(Ok), [
        decode.success(Error(Nil)),
      ]),
    )
    |> decode.map(result.values)
  let decoder = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use picture <- decode.optional_field(
      "picture",
      "",
      decode.one_of(decode.string, [decode.success("")]),
    )
    use features <- decode.optional_field("features", [], strings)
    // Each item as {"name", "looks"}, or just a name.
    let item =
      decode.one_of(
        {
          use name <- decode.field("name", decode.string)
          use looks <- decode.optional_field("looks", "", decode.string)
          decode.success(Ok(#(name, looks)))
        },
        [
          decode.string |> decode.map(fn(n) { Ok(#(n, "")) }),
          decode.success(Error(Nil)),
        ],
      )
    use items <- decode.optional_field(
      "items",
      [],
      decode.list(item) |> decode.map(result.values),
    )
    use exits <- decode.optional_field(
      "exits",
      [],
      decode.list(exit) |> decode.map(result.values),
    )
    // {"exit", "lock", "key": {"name", "looks"}}; anything malformed is no
    // lock rather than a rejected room.
    let key = {
      use name <- decode.optional_field("name", "", decode.string)
      use looks <- decode.optional_field("looks", "", decode.string)
      decode.success(#(name, looks))
    }
    let lock_plan = {
      use exit <- decode.field("exit", decode.string)
      use desc <- decode.field("lock", decode.string)
      // A lock without a key described still gets one (a plain key).
      use key <- decode.optional_field(
        "key",
        #("", ""),
        decode.one_of(key, [decode.success(#("", ""))]),
      )
      decode.success(
        Some(LockPlan(exit:, desc:, key_name: key.0, key_looks: key.1)),
      )
    }
    let maybe_lock = decode.one_of(lock_plan, [decode.success(None)])
    use top_lock <- decode.optional_field("lock", None, maybe_lock)
    // Sometimes it's put inside the exits list instead: as one of its
    // entries, or as a "lock" on an exit.
    use exit_entries <- decode.optional_field(
      "exits",
      [],
      decode.list(
        decode.one_of(lock_plan, [
          {
            use direction <- decode.field("direction", decode.string)
            use desc <- decode.field("lock", decode.string)
            decode.success(Some(LockPlan(direction, desc, "", "")))
          },
          decode.success(None),
        ]),
      ),
    )
    let lock = case top_lock {
      Some(plan) -> Some(plan)
      None -> exit_entries |> option.values |> list.first |> option.from_result
    }
    decode.success(Proposal(
      name:,
      description:,
      picture:,
      features:,
      items: list.map(items, fn(i) { i.0 }),
      looks: items,
      exits:,
      lock:,
    ))
  }
  use p <- result.try(
    json.parse(text, decoder)
    |> result.map_error(fn(_) {
      logging.log(
        logging.Info,
        "unreadable room JSON: "
          <> string.slice(string.replace(text, "\n", " "), 0, 240),
      )
      "the reply wasn't JSON with \"name\" and \"description\" strings in the shape asked for"
    }),
  )
  let name = clean(p.name, 60)
  let description = clean(p.description, 900)
  use <- guard(name == "", "empty name")
  use <- guard(string.length(description) < 20, "description too short")
  let back_name = types.direction_name(back)
  let exits =
    p.exits
    |> list.map(fn(e) { #(string.lowercase(string.trim(e.0)), clean(e.1, 140)) })
    // "down a rickety ladder": the direction is the first word, and the rest
    // will do for a hint if there's none.
    |> list.map(fn(e) {
      case string.split_once(e.0, " ") {
        Ok(#(first, rest)) ->
          case types.parse_direction(first), e.1 {
            Ok(_), "" -> #(first, clean(rest, 140))
            Ok(_), hint -> #(first, hint)
            Error(Nil), _ -> e
          }
        Error(Nil) -> e
      }
    })
    |> list.filter(fn(e) {
      result.is_ok(types.parse_direction(e.0)) && e.0 != back_name && e.1 != ""
    })
    // Normalise "n" → "north" so the uniqueness check below means something.
    |> list.filter_map(fn(e) {
      use d <- result.map(types.parse_direction(e.0))
      #(types.direction_name(d), e.1)
    })
    |> list.unique
    |> unique_by_direction([])
    |> list.take(3)
  Ok(Proposal(
    name:,
    description:,
    picture: clean(p.picture, 400),
    // Only items with a role the game uses can be picked up, and the model
    // doesn't hand those out (the engine places keys). Anything it offers as
    // an item is scenery: kept as a visual detail.
    features: list.append(p.features, p.items)
      |> list.map(clean(_, 120))
      |> list.filter(non_empty)
      |> list.unique
      |> list.take(6),
    items: [],
    looks: [],
    exits:,
    lock: option.map(p.lock, fn(l) {
      LockPlan(
        exit: l.exit,
        desc: lock_text(l.desc),
        key_name: key_name(l.key_name),
        key_looks: case clean(l.key_looks, 80) {
          "" -> "a heavy old iron key"
          looks -> looks
        },
      )
    }),
  ))
}

fn unique_by_direction(
  exits: List(#(String, String)),
  seen: List(String),
) -> List(#(String, String)) {
  case exits {
    [] -> []
    [e, ..rest] ->
      case list.contains(seen, e.0) {
        True -> unique_by_direction(rest, seen)
        False -> [e, ..unique_by_direction(rest, [e.0, ..seen])]
      }
  }
}

fn guard(bad: Bool, reason: String, next: fn() -> Result(a, String)) {
  case bad {
    True -> Error(reason)
    False -> next()
  }
}

/// One line, trimmed, capped.
fn clean(text: String, max: Int) -> String {
  text
  |> string.replace("\n", " ")
  |> string.trim
  |> string.slice(0, max)
}

/// "A rusted bell clapper, half-buried in the dust" → "rusted bell clapper";
/// "small, rusty key" → "small rusty key". Lowercase, no leading article,
/// no trailing "lying in…/half-buried…" clause, at most 4 words.
pub fn item_name(text: String) -> String {
  let text =
    clean(string.lowercase(text), 80)
    |> string.replace(",", " ")
    |> string.replace(".", "")
  let words = string.split(text, " ") |> list.filter(non_empty)
  let words = case words {
    ["a", ..rest] | ["an", ..rest] | ["the", ..rest] | ["some", ..rest] -> rest
    _ -> words
  }
  words
  |> list.take_while(fn(w) {
    !list.contains(
      [
        "in",
        "on",
        "lying",
        "half-buried",
        "that",
        "which",
        "with",
        "from",
        "under",
        "near",
      ],
      w,
    )
  })
  |> list.take(4)
  |> string.join(" ")
}

/// Does the description show this item? Judged by its head noun: "burnt
/// offering" needs "offering", "seaweed-wrapped fish" needs "fish". A plural
/// or singular either way counts ("shells" for "shell").
pub fn mentions(description: String, item: String) -> Bool {
  let text = string.lowercase(description)
  let head =
    string.split(item, " ")
    |> list.last
    |> result.unwrap(item)
    |> string.split("-")
    |> list.last
    |> result.unwrap(item)
    |> string.lowercase
  let stem = case string.ends_with(head, "s") && string.length(head) > 3 {
    True -> string.drop_end(head, 1)
    False -> head
  }
  stem != "" && string.contains(text, stem)
}

/// "Saltwater's Dark Bend" taken → "Old Saltwater's Dark Bend", then
/// "Little …", and so on. `taken` is lowercased.
pub fn unique_name(name: String, taken: List(String)) -> String {
  let free = fn(n) { !list.contains(taken, string.lowercase(n)) }
  case free(name) {
    True -> name
    False -> {
      // "A Fog-Choked Passage" → "Lower Fog-Choked Passage", not
      // "Lower A Fog-Choked Passage".
      let base = case string.split_once(name, " ") {
        Ok(#("The", rest)) | Ok(#("A", rest)) | Ok(#("An", rest)) -> rest
        _ -> name
      }
      // Not "Upper"/"Lower": rooms have real levels, and those would lie.
      ["Old", "Little", "Far", "Back", "Hidden", "Narrow", "Inner"]
      |> list.map(fn(prefix) { prefix <> " " <> base })
      |> list.find(free)
      |> result.unwrap(name <> " " <> int.to_string(list.length(taken)))
    }
  }
}

fn non_empty(s: String) -> Bool {
  s != ""
}

/// The picture line as stored: the setting only (an establishing shot of
/// the place), being the first sentence of what the model wrote, capped at
/// 30 words; later sentences are where a 3B model invents lockets, vendors
/// and salmon. Items are drawn separately, up close, when examined.
fn complete_picture(p: Proposal) -> String {
  case first_sentence(p.picture, 30) {
    "" -> setting_from(p.name, p.features)
    setting -> setting
  }
  <> "."
}

/// Up to the first full stop (or `max_words` words, whichever is shorter).
pub fn first_sentence(text: String, max_words: Int) -> String {
  let sentence = case string.split_once(string.trim(text), ". ") {
    Ok(#(first, _)) -> first
    Error(Nil) -> string.trim(text)
  }
  sentence
  |> string.split(" ")
  |> list.filter(non_empty)
  |> list.take(max_words)
  |> string.join(" ")
  |> fn(s) {
    case string.ends_with(s, ".") {
      True -> string.drop_end(s, 1)
      False -> s
    }
  }
}

fn setting_from(name: String, features: List(String)) -> String {
  case list.take(features, 3) {
    [] -> name
    details -> name <> ": " <> string.join(details, ", ")
  }
}

fn fallback() -> Proposal {
  Proposal(
    name: "A Fog-Choked Passage",
    description: "The fog here is so thick you can barely see your own hands. Damp stone walls press close on either side, and the only sound is water dripping somewhere ahead.",
    picture: "A narrow passage between damp stone walls, almost lost in thick fog.",
    features: ["thick fog", "damp stone walls", "dripping water"],
    items: [],
    looks: [],
    exits: [],
    lock: None,
  )
}
