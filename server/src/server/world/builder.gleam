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
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import logging
import server/llm.{type Client}
import server/world/seed
import server/world/store.{type Store, NewExit}
import server/world/types.{type Direction, type Exit, type Room}

const attempts = 4

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
  let prompt = prompt(store, from, exit, region, back, neighbours)
  let taken = store.room_names(store)
  let #(proposal, build_log) = propose(client, prompt, back, taken, attempts)
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
      [NewExit(back, "back toward " <> from.name, from.region, Some(from.id))],
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
      // What each item plainly looks like, for its close-up when examined.
      list.each(proposal.items, fn(item) {
        case list.key_find(proposal.looks, item) {
          Ok(look) if look != "" -> store.set_item_look(store, id, item, look)
          _ -> Nil
        }
      })
      store.save_build_debug(store, id, prompt, build_log)
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
      Built(room_id: id, new: True, touched: [from.id, ..touched])
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
  seed.setting
  <> "\n\nRegion: "
  <> region.name
  <> " — "
  <> region.theme
  <> "\n\nThe player is in \""
  <> from.name
  <> "\": "
  <> from.description
  <> "\nThey go "
  <> types.direction_name(exit.direction)
  <> ". Before going, they saw: \""
  <> exit.hint
  <> "\".\nPlace names already used in the city (invent a new one, do not reuse these): "
  <> used
  <> "."
  <> around
  <> "\n\nInvent the place they arrive in. It must match what they saw and fit the region."
  <> "\nReply with JSON only, in exactly this shape:\n"
  <> "{\"name\": \"2-5 word place name\", "
  <> "\"description\": \"2-4 sentences, second person present tense\", "
  <> "\"picture\": \"one plain sentence, under 25 words, describing what a painting of this place shows (the place itself, its light and its main features); nothing that isn't in the description\", "
  <> "\"features\": [\"3-5 short visual details\"], "
  <> "\"items\": [{\"name\": \"short name of 1-4 words, such as 'brass key'\", \"looks\": \"what it plainly looks like, 4-10 words, such as 'a small tarnished brass key'\"}] (0-2 small portable objects lying here), "
  <> "\"exits\": [{\"direction\": \"north|south|east|west|up|down\", \"hint\": \"short phrase: what you see of that way out\"}]}"
  <> "\nThe description must mention every item by its exact name, and every visual detail, and should hint at each way out without listing directions."
  <> "\nGive 1 to 3 exits. Do not use the direction \""
  <> types.direction_name(back)
  <> "\" — that is the way back."
}

/// Ask for a room, check it, and ask again on failure. A retry tells the
/// model what was wrong: sent the identical prompt, a small model tends to
/// give the identical answer (one proposed the same taken name nine times).
/// The proposal used, and every reply along the way (for the developer
/// view of how the room was made).
fn propose(
  client: Client,
  prompt: String,
  back: Direction,
  taken: List(String),
  left: Int,
) -> #(Proposal, List(store.BuildAttempt)) {
  let #(proposal, log) = attempt(client, prompt, "", back, taken, left, [])
  #(proposal, list.reverse(log))
}

fn attempt(
  client: Client,
  prompt: String,
  feedback: String,
  back: Direction,
  taken: List(String),
  left: Int,
  log: List(store.BuildAttempt),
) -> #(Proposal, List(store.BuildAttempt)) {
  let retry = fn(reply: String, problem: String) {
    logging.log(logging.Info, "room proposal rejected: " <> problem)
    attempt(
      client,
      prompt,
      "\n\nYour previous answer was rejected: " <> problem <> ". Fix that.",
      back,
      taken,
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
      #(fallback(), [
        store.BuildAttempt(
          feedback: "",
          reply: "",
          problem: "gave up after every attempt failed: wrote the fallback room",
        ),
        ..log
      ])
    }
    _ ->
      case llm.generate(client, llm.ask_json(prompt <> feedback)) {
        Ok(text) ->
          case parse(text, back) {
            Ok(proposal) -> {
              let duplicate =
                list.contains(taken, string.lowercase(proposal.name))
              let missing =
                list.filter(proposal.items, fn(i) {
                  !mentions(proposal.description, i)
                })
              case duplicate, missing {
                // One retry for a taken name: the model tends to repeat it
                // however it's told, and `unique_name` can set it apart.
                True, _ if left == attempts ->
                  retry(
                    text,
                    "\""
                      <> proposal.name
                      <> "\" is already a place in the city; choose a different name",
                  )
                _, [_, ..] if left > 1 ->
                  retry(
                    text,
                    "the description doesn't mention "
                      <> string.join(missing, ", ")
                      <> " by name; mention each item in the description, or drop it",
                  )
                // Accept. On the last try, keep only items the description
                // shows (a name still taken is set apart by `unique_name`).
                // The picture line is trimmed and the items added by code.
                _, _ -> {
                  let items =
                    list.filter(proposal.items, mentions(
                      proposal.description,
                      _,
                    ))
                  let dropped =
                    list.filter(proposal.items, fn(i) {
                      !list.contains(items, i)
                    })
                  let proposal = Proposal(..proposal, items:)
                  let note = case dropped {
                    [] -> ""
                    _ ->
                      "used, but dropped items the description never mentions: "
                      <> string.join(dropped, ", ")
                  }
                  #(Proposal(..proposal, picture: complete_picture(proposal)), [
                    store.BuildAttempt(feedback:, reply: text, problem: note),
                    ..log
                  ])
                }
              }
            }
            Error(reason) -> retry(text, reason)
          }
        Error(Nil) -> {
          logging.log(logging.Warning, "room builder: no answer from model")
          attempt(client, prompt, feedback, back, taken, left - 1, [
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
    decode.success(Proposal(
      name:,
      description:,
      picture:,
      features:,
      items: list.map(items, fn(i) { i.0 }),
      looks: items,
      exits:,
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
    features: p.features
      |> list.map(clean(_, 120))
      |> list.filter(non_empty)
      |> list.take(6),
    items: p.items
      |> list.map(item_name)
      |> list.filter(non_empty)
      |> list.take(2),
    looks: list.map(p.looks, fn(l) { #(item_name(l.0), clean(l.1, 80)) }),
    exits:,
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

/// "Saltwater's Dark Bend" taken → "Lower Saltwater's Dark Bend", then
/// "Old …", and so on. `taken` is lowercased.
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
      ["Lower", "Upper", "Old", "Little", "Far", "Hidden", "Back"]
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
  )
}
