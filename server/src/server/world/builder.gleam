//// Builds the room on the far side of an unbuilt exit. The model proposes a
//// room as JSON; this module checks every field, fixes up the geometry (the
//// way back always exists and always points home), and writes it. A reply
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

const attempts = 3

type Proposal {
  Proposal(
    name: String,
    description: String,
    features: List(String),
    items: List(String),
    exits: List(#(String, String)),
  )
}

/// Build, save and link the room beyond `exit` of `from`. Returns its id.
pub fn build(store: Store, client: Client, from: Room, exit: Exit) -> Int {
  let back = types.opposite(exit.direction)
  let region =
    store.region(store, exit.target_region)
    |> result.unwrap(types.Region(exit.target_region, exit.target_region, ""))
  let prompt = prompt(store, from, exit, region, back)
  let taken = store.room_names(store)
  let proposal = propose(client, prompt, back, taken, attempts)
  // The model can insist on a name through every retry; and two rooms built
  // at the same moment can't see each other's. Re-read and set it apart.
  let proposal =
    Proposal(
      ..proposal,
      name: unique_name(proposal.name, store.room_names(store)),
    )
  let new_exits = [
    NewExit(back, "back toward " <> from.name, from.region, Some(from.id)),
    ..list.filter_map(proposal.exits, fn(e) {
      use d <- result.map(types.parse_direction(e.0))
      NewExit(d, e.1, region.id, None)
    })
  ]
  let id =
    store.insert_room(
      store,
      region.id,
      proposal.name,
      proposal.description,
      proposal.features,
      proposal.items,
      new_exits,
    )
  // Linking last: until this runs, nobody can walk into a half-written room.
  store.link_exit(store, from.id, exit.direction, id)
  id
}

fn prompt(
  store: Store,
  from: Room,
  exit: Exit,
  region: types.Region,
  back: Direction,
) -> String {
  let nearby = case list.take(list.reverse(store.room_names(store)), 40) {
    [] -> "none yet"
    names -> string.join(names, ", ")
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
  <> nearby
  <> ".\n\nInvent the place they arrive in. It must match what they saw and fit the region."
  <> "\nReply with JSON only, in exactly this shape:\n"
  <> "{\"name\": \"2-5 word place name\", "
  <> "\"description\": \"2-4 sentences, second person present tense\", "
  <> "\"features\": [\"3-5 short visual details\"], "
  <> "\"items\": [\"0-2 small portable objects lying here, each a short name of 1-4 words such as 'brass key'\"], "
  <> "\"exits\": [{\"direction\": \"north|south|east|west|up|down\", \"hint\": \"short phrase: what you see of that way out\"}]}"
  <> "\nThe description must mention every item by its exact name, and every visual detail, and should hint at each way out without listing directions."
  <> "\nGive 1 to 3 exits. Do not use the direction \""
  <> types.direction_name(back)
  <> "\" — that is the way back."
}

fn propose(
  client: Client,
  prompt: String,
  back: Direction,
  taken: List(String),
  left: Int,
) -> Proposal {
  case left {
    0 -> {
      logging.log(
        logging.Warning,
        "room builder gave up; writing fallback room",
      )
      fallback()
    }
    _ ->
      case llm.generate(client, llm.ask_json(prompt)) {
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
                True, _ if left > 1 -> {
                  logging.log(
                    logging.Info,
                    "room proposal rejected: name already used: "
                      <> proposal.name,
                  )
                  propose(client, prompt, back, taken, left - 1)
                }
                _, [] -> proposal
                _, missing if left > 1 -> {
                  logging.log(
                    logging.Info,
                    "room proposal rejected: description doesn't mention "
                      <> string.join(missing, ", "),
                  )
                  propose(client, prompt, back, taken, left - 1)
                }
                // Last try: keep only what the text actually shows.
                _, _ ->
                  Proposal(
                    ..proposal,
                    items: list.filter(proposal.items, mentions(
                      proposal.description,
                      _,
                    )),
                  )
              }
            }
            Error(reason) -> {
              logging.log(logging.Info, "room proposal rejected: " <> reason)
              propose(client, prompt, back, taken, left - 1)
            }
          }
        Error(Nil) -> {
          logging.log(logging.Warning, "room builder: no answer from model")
          propose(client, prompt, back, taken, left - 1)
        }
      }
  }
}

fn parse(text: String, back: Direction) -> Result(Proposal, String) {
  let exit = {
    use direction <- decode.field("direction", decode.string)
    use hint <- decode.field("hint", decode.string)
    decode.success(#(direction, hint))
  }
  let strings = decode.list(decode.string)
  let decoder = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use features <- decode.optional_field("features", [], strings)
    use items <- decode.optional_field("items", [], strings)
    use exits <- decode.optional_field("exits", [], decode.list(exit))
    decode.success(Proposal(name:, description:, features:, items:, exits:))
  }
  use p <- result.try(
    json.parse(text, decoder) |> result.replace_error("not the expected JSON"),
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
    features: p.features
      |> list.map(clean(_, 120))
      |> list.filter(non_empty)
      |> list.take(6),
    items: p.items
      |> list.map(item_name)
      |> list.filter(non_empty)
      |> list.take(2),
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
      let base = case string.starts_with(name, "The ") {
        True -> string.drop_start(name, 4)
        False -> name
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

fn fallback() -> Proposal {
  Proposal(
    name: "A Fog-Choked Passage",
    description: "The fog here is so thick you can barely see your own hands. Damp stone walls press close on either side, and the only sound is water dripping somewhere ahead.",
    features: ["thick fog", "damp stone walls", "dripping water"],
    items: [],
    exits: [],
  )
}
