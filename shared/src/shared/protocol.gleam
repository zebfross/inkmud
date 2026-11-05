//// The websocket protocol between the browser and the game server. Both
//// sides compile this module, so a message can only be sent in a shape the
//// other side can read.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option, None}

// CLIENT → SERVER -------------------------------------------------------------

pub type ClientMsg {
  /// First message on a connection: who is playing, and a random key this
  /// browser keeps, so reconnecting from the same browser can take over
  /// from a connection that hasn't closed yet.
  Hello(name: String, device: String)
  /// Anything typed (or clicked) in the command box.
  Command(text: String)
  /// Dev only (the server refuses it otherwise): wipe and rebuild the world.
  ResetWorld
  /// Send me my map.
  RequestMap
  /// Dev only: how this room was made (prompts and replies).
  RequestDebug(room_id: Int)
}

pub fn encode_client(msg: ClientMsg) -> String {
  case msg {
    Hello(name:, device:) ->
      json.object([
        #("t", json.string("hello")),
        #("name", json.string(name)),
        #("device", json.string(device)),
      ])
    Command(text:) ->
      json.object([
        #("t", json.string("command")),
        #("text", json.string(text)),
      ])
    ResetWorld -> json.object([#("t", json.string("reset"))])
    RequestMap -> json.object([#("t", json.string("map"))])
    RequestDebug(room_id:) ->
      json.object([#("t", json.string("debug")), #("room", json.int(room_id))])
  }
  |> json.to_string
}

pub fn decode_client(text: String) -> Result(ClientMsg, Nil) {
  let decoder = {
    use tag <- decode.field("t", decode.string)
    case tag {
      "hello" -> {
        use name <- decode.field("name", decode.string)
        use device <- decode.optional_field("device", "", decode.string)
        decode.success(Hello(name:, device:))
      }
      "command" -> {
        use text <- decode.field("text", decode.string)
        decode.success(Command(text:))
      }
      "reset" -> decode.success(ResetWorld)
      "map" -> decode.success(RequestMap)
      "debug" -> {
        use room_id <- decode.field("room", decode.int)
        decode.success(RequestDebug(room_id:))
      }
      _ -> decode.failure(Command(""), "ClientMsg")
    }
  }
  json.parse(text, decoder) |> option_error
}

// SERVER → CLIENT -------------------------------------------------------------

pub type ExitView {
  /// `lock`: what bars it, if it's locked.
  ExitView(direction: String, hint: String, lock: Option(String))
}

pub type RoomView {
  RoomView(
    id: Int,
    region: String,
    name: String,
    description: String,
    exits: List(ExitView),
    items: List(String),
    /// Visual details worth a closer look (examinable).
    features: List(String),
    others: List(String),
    /// URL of the room's picture, once one exists.
    art: Option(String),
    /// Pitch dark and the player has no light: shown nothing but the ways
    /// back toward light.
    dark: Bool,
  )
}

/// A visited room on the player's map, at grid position x (east), y (south),
/// z (up: one level per floor).
pub type MapRoom {
  MapRoom(
    id: Int,
    name: String,
    region: String,
    art: Option(String),
    x: Int,
    y: Int,
    z: Int,
    /// Ways out not yet taken (leading somewhere unvisited or unbuilt).
    unexplored: List(String),
  )
}

pub type MapView {
  MapView(rooms: List(MapRoom), links: List(#(Int, Int)), current: Int)
}

/// Dev only: everything that went into a room, for debugging mismatches
/// between its text, items and picture.
pub type DebugAttempt {
  /// `problem` empty: this reply was used.
  DebugAttempt(feedback: String, reply: String, problem: String)
}

pub type DebugView {
  DebugView(
    room_id: Int,
    name: String,
    description: String,
    picture: String,
    features: List(String),
    items: List(String),
    /// Exactly what was sent to the image model, if the room has been drawn.
    image_prompt_sent: Option(String),
    image_seed: Option(Int),
    /// What would be sent if it were drawn now.
    image_prompt_now: String,
    builder_prompt: String,
    attempts: List(DebugAttempt),
  )
}

pub type Tone {
  /// The world describing itself.
  Narration
  /// Something another player did.
  Social
  /// Game messages: errors, help, waiting.
  System
}

pub type ServerMsg {
  /// `dev_tools`: the server allows developer actions (world reset).
  Welcome(name: String, dev_tools: Bool)
  /// The world was wiped and rebuilt: forget everything shown so far.
  WorldReset
  /// Someone with this name is already connected (perhaps this same player,
  /// on a connection the server hasn't seen close yet).
  NameTaken(name: String)
  /// This player connected again from the same browser (another tab, or a
  /// phone that woke up): this connection is closing. Don't reconnect on
  /// your own, or the two would keep taking the name from each other.
  Replaced
  /// The player's map, in answer to RequestMap.
  Map(MapView)
  /// Dev only, in answer to RequestDebug.
  Debug(DebugView)
  Room(RoomView)
  Line(tone: Tone, text: String)
  /// The picture for a room is ready.
  Art(room_id: Int, url: String)
  /// A close-up of something just examined (`name`), to show in the story.
  Closeup(name: String, url: String)
  /// Work is under way that the player is waiting on (a room being built).
  Busy(text: String)
  Inventory(items: List(String))
}

pub fn encode_server(msg: ServerMsg) -> String {
  case msg {
    Welcome(name:, dev_tools:) ->
      json.object([
        #("t", json.string("welcome")),
        #("name", json.string(name)),
        #("dev", json.bool(dev_tools)),
      ])
    WorldReset -> json.object([#("t", json.string("world_reset"))])
    Replaced -> json.object([#("t", json.string("replaced"))])
    NameTaken(name:) ->
      json.object([
        #("t", json.string("name_taken")),
        #("name", json.string(name)),
      ])
    Debug(d) ->
      json.object([
        #("t", json.string("debug")),
        #("room", json.int(d.room_id)),
        #("name", json.string(d.name)),
        #("description", json.string(d.description)),
        #("picture", json.string(d.picture)),
        #("features", json.array(d.features, json.string)),
        #("items", json.array(d.items, json.string)),
        #("image_prompt_sent", json.nullable(d.image_prompt_sent, json.string)),
        #("image_seed", json.nullable(d.image_seed, json.int)),
        #("image_prompt_now", json.string(d.image_prompt_now)),
        #("builder_prompt", json.string(d.builder_prompt)),
        #(
          "attempts",
          json.array(d.attempts, fn(a) {
            json.object([
              #("feedback", json.string(a.feedback)),
              #("reply", json.string(a.reply)),
              #("problem", json.string(a.problem)),
            ])
          }),
        ),
      ])
    Map(view) ->
      json.object([
        #("t", json.string("map")),
        #("current", json.int(view.current)),
        #(
          "rooms",
          json.array(view.rooms, fn(r) {
            json.object([
              #("id", json.int(r.id)),
              #("name", json.string(r.name)),
              #("region", json.string(r.region)),
              #("art", json.nullable(r.art, json.string)),
              #("x", json.int(r.x)),
              #("y", json.int(r.y)),
              #("z", json.int(r.z)),
              #("unexplored", json.array(r.unexplored, json.string)),
            ])
          }),
        ),
        #(
          "links",
          json.array(view.links, fn(l) { json.array([l.0, l.1], json.int) }),
        ),
      ])
    Room(view) ->
      json.object([#("t", json.string("room")), #("room", room_json(view))])
    Line(tone:, text:) ->
      json.object([
        #("t", json.string("line")),
        #("tone", json.string(tone_name(tone))),
        #("text", json.string(text)),
      ])
    Closeup(name:, url:) ->
      json.object([
        #("t", json.string("closeup")),
        #("name", json.string(name)),
        #("url", json.string(url)),
      ])
    Art(room_id:, url:) ->
      json.object([
        #("t", json.string("art")),
        #("room", json.int(room_id)),
        #("url", json.string(url)),
      ])
    Busy(text:) ->
      json.object([#("t", json.string("busy")), #("text", json.string(text))])
    Inventory(items:) ->
      json.object([
        #("t", json.string("inventory")),
        #("items", json.array(items, json.string)),
      ])
  }
  |> json.to_string
}

fn room_json(view: RoomView) -> Json {
  json.object([
    #("id", json.int(view.id)),
    #("region", json.string(view.region)),
    #("name", json.string(view.name)),
    #("description", json.string(view.description)),
    #(
      "exits",
      json.array(view.exits, fn(e) {
        json.object([
          #("direction", json.string(e.direction)),
          #("hint", json.string(e.hint)),
          #("lock", json.nullable(e.lock, json.string)),
        ])
      }),
    ),
    #("items", json.array(view.items, json.string)),
    #("features", json.array(view.features, json.string)),
    #("others", json.array(view.others, json.string)),
    #("art", json.nullable(view.art, json.string)),
    #("dark", json.bool(view.dark)),
  ])
}

fn tone_name(tone: Tone) -> String {
  case tone {
    Narration -> "narration"
    Social -> "social"
    System -> "system"
  }
}

fn tone_decoder() -> Decoder(Tone) {
  use name <- decode.then(decode.string)
  case name {
    "narration" -> decode.success(Narration)
    "social" -> decode.success(Social)
    _ -> decode.success(System)
  }
}

fn room_decoder() -> Decoder(RoomView) {
  let exit = {
    use direction <- decode.field("direction", decode.string)
    use hint <- decode.field("hint", decode.string)
    use lock <- decode.optional_field(
      "lock",
      None,
      decode.optional(decode.string),
    )
    decode.success(ExitView(direction:, hint:, lock:))
  }
  use id <- decode.field("id", decode.int)
  use region <- decode.field("region", decode.string)
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  use exits <- decode.field("exits", decode.list(exit))
  use items <- decode.field("items", decode.list(decode.string))
  use features <- decode.optional_field(
    "features",
    [],
    decode.list(decode.string),
  )
  use others <- decode.field("others", decode.list(decode.string))
  use art <- decode.optional_field("art", None, decode.optional(decode.string))
  use dark <- decode.optional_field("dark", False, decode.bool)
  decode.success(RoomView(
    id:,
    region:,
    name:,
    description:,
    exits:,
    items:,
    features:,
    others:,
    art:,
    dark:,
  ))
}

pub fn decode_server(text: String) -> Result(ServerMsg, Nil) {
  let decoder = {
    use tag <- decode.field("t", decode.string)
    case tag {
      "welcome" -> {
        use name <- decode.field("name", decode.string)
        use dev_tools <- decode.optional_field("dev", False, decode.bool)
        decode.success(Welcome(name:, dev_tools:))
      }
      "world_reset" -> decode.success(WorldReset)
      "replaced" -> decode.success(Replaced)
      "debug" -> {
        let attempt = {
          use feedback <- decode.field("feedback", decode.string)
          use reply <- decode.field("reply", decode.string)
          use problem <- decode.field("problem", decode.string)
          decode.success(DebugAttempt(feedback:, reply:, problem:))
        }
        let strings = decode.list(decode.string)
        use room_id <- decode.field("room", decode.int)
        use name <- decode.field("name", decode.string)
        use description <- decode.field("description", decode.string)
        use picture <- decode.field("picture", decode.string)
        use features <- decode.field("features", strings)
        use items <- decode.field("items", strings)
        use image_prompt_sent <- decode.field(
          "image_prompt_sent",
          decode.optional(decode.string),
        )
        use image_seed <- decode.field(
          "image_seed",
          decode.optional(decode.int),
        )
        use image_prompt_now <- decode.field("image_prompt_now", decode.string)
        use builder_prompt <- decode.field("builder_prompt", decode.string)
        use attempts <- decode.field("attempts", decode.list(attempt))
        decode.success(
          Debug(DebugView(
            room_id:,
            name:,
            description:,
            picture:,
            features:,
            items:,
            image_prompt_sent:,
            image_seed:,
            image_prompt_now:,
            builder_prompt:,
            attempts:,
          )),
        )
      }
      "map" -> {
        let map_room = {
          use id <- decode.field("id", decode.int)
          use name <- decode.field("name", decode.string)
          use region <- decode.field("region", decode.string)
          use art <- decode.optional_field(
            "art",
            None,
            decode.optional(decode.string),
          )
          use x <- decode.field("x", decode.int)
          use y <- decode.field("y", decode.int)
          use z <- decode.field("z", decode.int)
          use unexplored <- decode.field(
            "unexplored",
            decode.list(decode.string),
          )
          decode.success(MapRoom(
            id:,
            name:,
            region:,
            art:,
            x:,
            y:,
            z:,
            unexplored:,
          ))
        }
        let link = {
          use pair <- decode.then(decode.list(decode.int))
          case pair {
            [a, b] -> decode.success(#(a, b))
            _ -> decode.failure(#(0, 0), "link")
          }
        }
        use current <- decode.field("current", decode.int)
        use rooms <- decode.field("rooms", decode.list(map_room))
        use links <- decode.field("links", decode.list(link))
        decode.success(Map(MapView(rooms:, links:, current:)))
      }
      "name_taken" -> {
        use name <- decode.field("name", decode.string)
        decode.success(NameTaken(name:))
      }
      "room" -> {
        use view <- decode.field("room", room_decoder())
        decode.success(Room(view))
      }
      "line" -> {
        use tone <- decode.field("tone", tone_decoder())
        use text <- decode.field("text", decode.string)
        decode.success(Line(tone:, text:))
      }
      "closeup" -> {
        use name <- decode.field("name", decode.string)
        use url <- decode.field("url", decode.string)
        decode.success(Closeup(name:, url:))
      }
      "art" -> {
        use room_id <- decode.field("room", decode.int)
        use url <- decode.field("url", decode.string)
        decode.success(Art(room_id:, url:))
      }
      "busy" -> {
        use text <- decode.field("text", decode.string)
        decode.success(Busy(text:))
      }
      "inventory" -> {
        use items <- decode.field("items", decode.list(decode.string))
        decode.success(Inventory(items:))
      }
      _ -> decode.failure(Busy(""), "ServerMsg")
    }
  }
  json.parse(text, decoder) |> option_error
}

fn option_error(result: Result(a, e)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}
