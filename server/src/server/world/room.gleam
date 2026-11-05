//// One process per room in use. Its mailbox is the room's action queue:
//// two players grabbing the same item arrive as two messages, handled in
//// order, so exactly one of them gets it. Everyone present hears the same
//// thing happen.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import server/art
import server/world/store.{type Store}
import server/world/types.{type Direction, type Room}
import shared/protocol.{
  type ServerMsg, ExitView, Line, Narration, RoomView, Social, System,
}

pub type Notify =
  fn(ServerMsg) -> Nil

pub type Message {
  /// `owner` is the player's session process. When the same player
  /// reconnects (taking over from a stale connection), the old session's
  /// late Leave carries the old owner and is ignored.
  Enter(name: String, owner: Pid, notify: Notify, from: Option(Direction))
  Leave(name: String, owner: Pid, toward: Option(Direction))
  Look(name: String)
  LookToward(name: String, direction: Direction)
  Take(name: String, query: String)
  Drop(name: String, query: String)
  Say(name: String, words: String)
  /// The database changed underneath (an exit was linked): reload.
  Refresh
  ArtReady(url: String)
  /// Read the current room (for the builder, the interpreter, examine).
  Snapshot(reply: Subject(Room))
  /// Shut down (world reset). A normal exit, so the linked world registry
  /// carries on; killing the process would take the registry down with it.
  Stop
}

type State {
  State(
    self: Subject(Message),
    store: Store,
    art: Subject(art.Message),
    room: Room,
    occupants: List(#(String, Notify)),
    owners: Dict(String, Pid),
    /// The way each player came in: in the dark, without a light, the only
    /// way out they can find.
    entered: Dict(String, Direction),
    art_requested: Bool,
  )
}

pub fn start(
  store: Store,
  art_queue: Subject(art.Message),
  room: Room,
) -> Subject(Message) {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      State(
        self:,
        store:,
        art: art_queue,
        room:,
        occupants: [],
        owners: dict.new(),
        entered: dict.new(),
        art_requested: False,
      )
      |> actor.initialised
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

/// Some things need light: in a dark place without one you can't find
/// what's lying around or see along a way out.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let needs_sight = case message {
    Take(name, _) -> Some(#(name, "It's too dark to find anything here."))
    LookToward(name, _) -> Some(#(name, "It's too dark to see that way."))
    _ -> None
  }
  case needs_sight {
    Some(#(name, refusal)) ->
      case sees(state, name) {
        True -> handle_seen(state, message)
        False -> {
          tell(state, name, Line(System, refusal))
          actor.continue(state)
        }
      }
    None -> handle_seen(state, message)
  }
}

fn handle_seen(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Enter(name, owner, notify, from) -> {
      let state =
        State(
          ..state,
          owners: dict.insert(state.owners, name, owner),
          entered: case from {
            Some(d) -> dict.insert(state.entered, name, d)
            None -> dict.delete(state.entered, name)
          },
        )
      let arrival = case from {
        Some(d) ->
          name <> " arrives from the " <> types.direction_name(d) <> "."
        None -> name <> " steps out of the fog."
      }
      broadcast(state, Line(Social, arrival))
      let state =
        State(..state, occupants: [
          #(name, notify),
          ..list.filter(state.occupants, fn(o) { o.0 != name })
        ])
      describe(state, name, notify)
      refresh_except(state, name)
      request_art(state) |> actor.continue
    }

    Leave(name, owner, toward) ->
      case dict.get(state.owners, name) == Ok(owner) {
        // From a session that has since been replaced: not this player
        // leaving.
        False -> actor.continue(state)
        True -> {
          let state =
            State(
              ..state,
              occupants: list.filter(state.occupants, fn(o) { o.0 != name }),
              owners: dict.delete(state.owners, name),
            )
          let text = case toward {
            Some(d) -> name <> " leaves " <> types.direction_name(d) <> "."
            None -> name <> " fades into the fog."
          }
          broadcast(state, Line(Social, text))
          refresh_all(state)
          actor.continue(state)
        }
      }

    Look(name) -> {
      case list.key_find(state.occupants, name) {
        Ok(notify) -> describe(state, name, notify)
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }

    LookToward(name, d) -> {
      tell(state, name, Line(Narration, look_toward(state.room.exits, d)))
      actor.continue(state)
    }

    Take(name, query) if query == "all" || query == "everything" -> {
      case state.room.items {
        [] -> tell(state, name, Line(System, "There's nothing here to take."))
        items ->
          list.each(items, fn(item) {
            case store.take_item(state.store, state.room.id, name, item) {
              Ok(item) -> {
                tell(
                  state,
                  name,
                  Line(Narration, "You take the " <> item <> "."),
                )
                broadcast_except(
                  state,
                  name,
                  Line(Social, name <> " picks up the " <> item <> "."),
                )
              }
              Error(Nil) -> Nil
            }
          })
      }
      let state = reload(state)
      refresh_all(state)
      actor.continue(state)
    }

    Take(name, query) -> {
      case store.take_item(state.store, state.room.id, name, query) {
        Ok(item) -> {
          tell(state, name, Line(Narration, "You take the " <> item <> "."))
          broadcast_except(
            state,
            name,
            Line(Social, name <> " picks up the " <> item <> "."),
          )
        }
        Error(Nil) ->
          tell(state, name, Line(System, "You don't see that here."))
      }
      let state = reload(state)
      refresh_all(state)
      actor.continue(state)
    }

    Drop(name, query) -> {
      case store.drop_item(state.store, state.room.id, name, query) {
        Ok(item) -> {
          tell(state, name, Line(Narration, "You set down the " <> item <> "."))
          broadcast_except(
            state,
            name,
            Line(Social, name <> " drops the " <> item <> "."),
          )
        }
        Error(Nil) ->
          tell(state, name, Line(System, "You aren't carrying that."))
      }
      let state = reload(state)
      refresh_all(state)
      actor.continue(state)
    }

    Say(name, words) -> {
      tell(state, name, Line(Social, "You say, \"" <> words <> "\""))
      broadcast_except(
        state,
        name,
        Line(Social, name <> " says, \"" <> words <> "\""),
      )
      actor.continue(state)
    }

    Refresh -> {
      let state = reload(state)
      refresh_all(state)
      actor.continue(state)
    }

    ArtReady(url) -> {
      let state =
        State(..state, room: types.Room(..state.room, art_url: Some(url)))
      broadcast(state, protocol.Art(state.room.id, url))
      actor.continue(state)
    }

    Snapshot(reply) -> {
      process.send(reply, state.room)
      actor.continue(state)
    }

    Stop -> actor.stop()
  }
}

fn reload(state: State) -> State {
  let room =
    store.load_room(state.store, state.room.id) |> result.unwrap(state.room)
  // Keep art that arrived via message before the row was re-read.
  let room = case room.art_url {
    None -> types.Room(..room, art_url: state.room.art_url)
    Some(_) -> room
  }
  State(..state, room:)
}

fn request_art(state: State) -> State {
  case state.room.art_url, state.art_requested {
    None, False -> {
      let self = state.self
      art.request(state.art, state.store, state.room, fn(url) {
        process.send(self, ArtReady(url))
      })
      State(..state, art_requested: True)
    }
    _, _ -> state
  }
}

/// The side panel first (the client starts a new section of the log for a
/// new room), then the description in the story log.
fn describe(state: State, name: String, notify: Notify) {
  let view = view(state, name)
  notify(protocol.Room(view))
  notify(Line(Narration, view.description))
}

/// An exit someone without a light could still feel their way along:
/// built, unlocked, and to somewhere lit.
pub fn leads_to_light(store: Store, e: types.Exit) -> Bool {
  case e.target, e.lock, e.obstacle {
    Some(t), None, None ->
      case store.load_room(store, t) {
        Ok(beyond) -> !beyond.dark
        Error(Nil) -> False
      }
    _, _, _ -> False
  }
}

/// Can this player see here? (Lit places always; dark ones with a light.)
fn sees(state: State, player: String) -> Bool {
  !state.room.dark || store.has_light(state.store, player)
}

/// "To the north, worn stone stairs climb toward a broken bell tower."
/// Answered from the stored hint: no model call, and it can't contradict
/// what's on the other side.
pub fn look_toward(exits: List(types.Exit), d: Direction) -> String {
  case list.find(exits, fn(e) { e.direction == d }) {
    Error(Nil) -> "There's no way " <> types.direction_name(d) <> " from here."
    Ok(exit) -> {
      let lead = case d {
        types.Up -> "Above you, "
        types.Down -> "Below, "
        _ -> "To the " <> types.direction_name(d) <> ", "
      }
      let hint = string.trim(exit.hint)
      let seen = case string.starts_with(hint, "back toward ") {
        True ->
          lead <> "the way leads back to " <> string.drop_start(hint, 12) <> "."
        False -> lead <> lowercase_first(hint) <> end_stop(hint)
      }
      case exit.lock, exit.obstacle {
        Some(lock), _ -> seen <> " " <> types.barred(lock)
        None, Some(obstacle) -> seen <> " " <> types.obstructed(obstacle)
        None, None -> seen
      }
    }
  }
}

fn lowercase_first(text: String) -> String {
  string.lowercase(string.slice(text, 0, 1)) <> string.drop_start(text, 1)
}

fn end_stop(text: String) -> String {
  case
    string.ends_with(text, ".")
    || string.ends_with(text, "!")
    || string.ends_with(text, "?")
  {
    True -> ""
    False -> "."
  }
}

fn refresh_all(state: State) {
  list.each(state.occupants, fn(o) { { o.1 }(protocol.Room(view(state, o.0))) })
}

fn refresh_except(state: State, name: String) {
  list.each(state.occupants, fn(o) {
    case o.0 == name {
      True -> Nil
      False -> { o.1 }(protocol.Room(view(state, o.0)))
    }
  })
}

fn view(state: State, for: String) -> protocol.RoomView {
  let room = state.room
  let region =
    store.region(state.store, room.region)
    |> result.map(fn(r) { r.name })
    |> result.unwrap("")
  let others =
    state.occupants
    |> list.map(fn(o) { o.0 })
    |> list.filter(fn(n) { n != for })
  case sees(state, for) {
    True ->
      RoomView(
        id: room.id,
        region:,
        name: room.name,
        description: room.description,
        exits: list.map(room.exits, fn(e) {
          ExitView(
            types.direction_name(e.direction),
            e.hint,
            e.lock,
            option.map(e.obstacle, types.obstructed),
          )
        }),
        items: room.items,
        features: room.features,
        others:,
        art: room.art_url,
        dark: False,
      )
    // In the dark: no description, picture or items, and only the way
    // you came in (or, if you didn't come in, say after logging in here,
    // the ways back toward somewhere lit).
    False ->
      RoomView(
        id: room.id,
        region:,
        name: "Darkness",
        description: "It is pitch dark. You can't see a thing; all you can find is the way you came.",
        exits: room.exits
          |> list.filter(fn(e) {
            case dict.get(state.entered, for) {
              Ok(back) -> e.direction == back
              Error(Nil) -> leads_to_light(state.store, e)
            }
          })
          |> list.map(fn(e) {
            ExitView(
              types.direction_name(e.direction),
              "the way you came",
              None,
              None,
            )
          }),
        items: [],
        features: [],
        others:,
        art: None,
        dark: True,
      )
  }
}

fn tell(state: State, name: String, msg: ServerMsg) {
  case list.key_find(state.occupants, name) {
    Ok(notify) -> notify(msg)
    Error(Nil) -> Nil
  }
}

fn broadcast(state: State, msg: ServerMsg) {
  list.each(state.occupants, fn(o) { { o.1 }(msg) })
}

fn broadcast_except(state: State, name: String, msg: ServerMsg) {
  list.each(state.occupants, fn(o) {
    case o.0 == name {
      True -> Nil
      False -> { o.1 }(msg)
    }
  })
}
