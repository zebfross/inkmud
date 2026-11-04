//// The fixed command set. Typed commands are parsed here with no model
//// involved; anything that doesn't parse goes to the interpreter, which may
//// only answer with one of these.

import gleam/string
import server/world/types.{type Direction}

pub type Command {
  Go(Direction)
  Look
  /// Look along a way out without taking it.
  LookToward(Direction)
  Examine(String)
  Take(String)
  Drop(String)
  Inventory
  Say(String)
  Help
  Unknown(String)
}

pub fn parse(input: String) -> Command {
  let text = string.trim(input)
  let lower = string.lowercase(text)
  let #(verb, rest) = case string.split_once(lower, " ") {
    Ok(#(verb, rest)) -> #(verb, string.trim(rest))
    Error(Nil) -> #(lower, "")
  }
  case types.parse_direction(lower) {
    Ok(d) -> Go(d)
    Error(Nil) ->
      case verb, rest {
        "go", d | "walk", d | "move", d | "head", d | "climb", d ->
          case types.parse_direction(d) {
            Ok(d) -> Go(d)
            Error(Nil) -> Unknown(text)
          }
        "l", "" | "look", "" -> Look
        "look", thing ->
          look_at(
            strip_prefix(thing, [
              "at ",
              "in ",
              "on ",
              "to the ",
              "toward the ",
              "towards the ",
              "toward ",
              "towards ",
            ]),
          )
        "examine", thing
        | "x", thing
        | "inspect", thing
        | "read", thing
          if thing != ""
        -> look_at(strip_prefix(thing, ["the "]))
        "take", thing | "get", thing | "grab", thing if thing != "" ->
          Take(strip_prefix(thing, ["the "]))
        "pick", thing if thing != "" ->
          Take(strip_prefix(thing, ["up the ", "up "]))
        "drop", thing if thing != "" -> Drop(strip_prefix(thing, ["the "]))
        "i", "" | "inv", "" | "inventory", "" -> Inventory
        "help", "" | "?", "" -> Help
        "say", _ -> say(string.drop_start(text, 3))
        _, _ ->
          case string.starts_with(text, "'") || string.starts_with(text, "\"") {
            True -> say(string.drop_start(text, 1))
            False -> Unknown(text)
          }
      }
  }
}

/// A direction is a way out to look along; anything else is a thing.
fn look_at(thing: String) -> Command {
  case types.parse_direction(thing) {
    Ok(d) -> LookToward(d)
    Error(Nil) -> Examine(thing)
  }
}

fn say(words: String) -> Command {
  case string.trim(words) {
    "" -> Unknown("say")
    words -> Say(string.slice(words, 0, 300))
  }
}

fn strip_prefix(text: String, prefixes: List(String)) -> String {
  case prefixes {
    [] -> text
    [p, ..rest] ->
      case string.starts_with(text, p) {
        True -> string.drop_start(text, string.length(p))
        False -> strip_prefix(text, rest)
      }
  }
}

/// How a command reads when echoed back (e.g. after interpretation).
pub fn describe(command: Command) -> String {
  case command {
    Go(d) -> "go " <> types.direction_name(d)
    Look -> "look"
    LookToward(d) -> "look " <> types.direction_name(d)
    Examine(t) -> "examine " <> t
    Take(t) -> "take " <> t
    Drop(t) -> "drop " <> t
    Inventory -> "inventory"
    Say(w) -> "say " <> w
    Help -> "help"
    Unknown(t) -> t
  }
}

pub const help_text = "Commands: north/south/east/west/up/down (or n/s/e/w/u/d), look, look <direction>, examine <thing>, take <item>, drop <item>, inventory (i), say <words> (or 'words), help. You can also just type what you want to do."
