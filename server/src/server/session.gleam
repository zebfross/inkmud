//// One process per connected player: the websocket. It parses commands,
//// forwards them to the player's current room, and moves the player between
//// rooms. Anything slow (a model call, a room being built) runs elsewhere
//// and comes back as an `Event`, so the socket never stalls.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import mist.{type Connection, type ResponseData}
import server/art
import server/command.{type Command}
import server/llm.{type Client}
import server/world/map
import server/world/room
import server/world/seed
import server/world/store.{type Store}
import server/world/types.{type Direction, type Room}
import server/world/world
import shared/protocol.{type ServerMsg, Line, Narration, System}

pub type Deps {
  Deps(
    store: Store,
    world: Subject(world.Message),
    fast: Client,
    start_room: Int,
    dev_tools: Bool,
    art: Subject(art.Message),
  )
}

pub type Event {
  Out(ServerMsg)
  Moved(Direction, world.Arrival)
  /// `room_id` is where the player was when they typed it.
  Interpreted(original: String, room_id: Int, result: Result(String, Nil))
  /// The world was reset; this is the new start room.
  WorldWasReset(start: Int)
  /// The same player connected from the same browser; this session ends.
  WasReplaced
  /// Close the connection (shortly after being replaced).
  Retire
  /// Background work that already sent what it had to say.
  Quiet
}

type Session {
  Session(
    deps: Deps,
    self: Subject(Event),
    name: Option(String),
    room_id: Int,
    room: Option(Subject(room.Message)),
    moving: Bool,
    /// The way the player came into the room they're in.
    came_from: Option(Direction),
  )
}

pub fn handle(req: Request(Connection), deps: Deps) -> Response(ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      let self = process.new_subject()
      let selector = process.new_selector() |> process.select(self)
      #(
        Session(
          deps:,
          self:,
          name: None,
          room_id: deps.start_room,
          room: None,
          moving: False,
          came_from: None,
        ),
        Some(selector),
      )
    },
    on_close: fn(session) {
      case session.name {
        Some(name) -> {
          case session.room {
            Some(r) -> process.send(r, room.Leave(name, process.self(), None))
            None -> Nil
          }
          process.send(session.deps.world, world.Logout(name, process.self()))
        }
        None -> Nil
      }
    },
    handler: fn(session, message, conn) {
      case message {
        mist.Text(text) ->
          case protocol.decode_client(text) {
            Ok(msg) -> mist.continue(client_message(session, msg, conn))
            Error(Nil) -> mist.continue(session)
          }
        // Replaced by a newer connection from the same browser: say so,
        // then close a moment later (closing straight away discards the
        // message before it reaches the browser). Its room and online entry
        // already belong to the new session; the late Leave and Logout this
        // one sends on closing are ignored there.
        mist.Custom(WasReplaced) -> {
          send(conn, protocol.Replaced)
          process.send_after(session.self, 1000, Retire)
          mist.continue(session)
        }
        mist.Custom(Retire) -> mist.stop()
        mist.Custom(event) -> mist.continue(on_event(session, event, conn))
        mist.Binary(_) -> mist.continue(session)
        mist.Closed | mist.Shutdown -> mist.stop()
      }
    },
  )
}

fn send(conn: mist.WebsocketConnection, msg: ServerMsg) -> Nil {
  let _ = mist.send_text_frame(conn, protocol.encode_server(msg))
  Nil
}

fn system(conn, text: String) -> Nil {
  send(conn, Line(System, text))
}

// CLIENT MESSAGES -------------------------------------------------------------

fn client_message(session: Session, msg: protocol.ClientMsg, conn) -> Session {
  case msg, session.name {
    protocol.Hello(raw, device), None ->
      case clean_name(raw) {
        Error(Nil) -> {
          system(conn, "Pick a name of 2 to 16 letters.")
          session
        }
        Ok(name) ->
          case
            world.login(
              session.deps.world,
              name,
              device,
              fn(start) { process.send(session.self, WorldWasReset(start)) },
              fn() { process.send(session.self, WasReplaced) },
            )
          {
            False -> {
              send(conn, protocol.NameTaken(name))
              session
            }
            True -> {
              send(conn, protocol.Welcome(name, session.deps.dev_tools))
              send(
                conn,
                protocol.Inventory(store.inventory(session.deps.store, name)),
              )
              let room_id =
                store.player_room(session.deps.store, name)
                |> option.unwrap(session.deps.start_room)
              enter(Session(..session, name: Some(name)), room_id, None, conn)
            }
          }
      }
    protocol.Hello(_, _), Some(_) -> session
    protocol.Command(text), Some(_) ->
      run(session, command.parse(text), False, conn)
    protocol.Command(_), None -> session
    protocol.ResetWorld, Some(_) ->
      case session.deps.dev_tools {
        True -> {
          // The reply comes back to every session (this one included) as
          // WorldWasReset.
          let _ = world.reset(session.deps.world)
          session
        }
        False -> {
          system(conn, "That isn't available on this server.")
          session
        }
      }
    protocol.ResetWorld, None -> session
    protocol.RequestMap, Some(name) -> {
      send(conn, protocol.Map(map_view(session.deps, name, session.room_id)))
      session
    }
    protocol.RequestMap, None -> session
    protocol.RequestDebug(room_id), Some(_) ->
      case
        session.deps.dev_tools,
        store.load_room(session.deps.store, room_id)
      {
        True, Ok(room_data) -> {
          let debug = store.load_debug(session.deps.store, room_id)
          send(
            conn,
            protocol.Debug(protocol.DebugView(
              room_id:,
              name: room_data.name,
              description: room_data.description,
              picture: room_data.picture,
              features: room_data.features,
              items: room_data.items,
              image_prompt_sent: debug.image_prompt,
              image_seed: debug.image_seed,
              image_prompt_now: art.image_prompt(room_data),
              builder_prompt: debug.builder_prompt,
              attempts: list.map(debug.attempts, fn(a) {
                protocol.DebugAttempt(a.feedback, a.reply, a.problem)
              }),
            )),
          )
          session
        }
        True, Error(Nil) -> session
        False, _ -> {
          system(conn, "That isn't available on this server.")
          session
        }
      }
    protocol.RequestDebug(_), None -> session
  }
}

fn clean_name(raw: String) -> Result(String, Nil) {
  let letters =
    raw
    |> string.trim
    |> string.to_graphemes
    |> list.filter(fn(g) {
      string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", g)
    })
    |> string.concat
  case string.length(letters) {
    n if n >= 2 && n <= 16 ->
      Ok(
        string.uppercase(string.slice(letters, 0, 1))
        <> string.lowercase(string.drop_start(letters, 1)),
      )
    _ -> Error(Nil)
  }
}

fn enter(
  session: Session,
  room_id: Int,
  from: Option(Direction),
  conn,
) -> Session {
  let assert Some(name) = session.name
  case world.get_room(session.deps.world, room_id) {
    Ok(r) -> {
      let self = session.self
      process.send(
        r,
        room.Enter(
          name,
          process.self(),
          fn(msg) { process.send(self, Out(msg)) },
          from,
        ),
      )
      store.set_player_room(session.deps.store, name, room_id)
      store.record_visit(session.deps.store, name, room_id)
      process.send(session.deps.world, world.Prefetch(room_id))
      Session(
        ..session,
        room_id:,
        room: Some(r),
        moving: False,
        came_from: from,
      )
    }
    Error(Nil) -> {
      system(
        conn,
        "The fog swallows that place. You find yourself back at the crossroads.",
      )
      case room_id == session.deps.start_room {
        True -> session
        False -> enter(session, session.deps.start_room, None, conn)
      }
    }
  }
}

// COMMANDS --------------------------------------------------------------------

fn run(session: Session, cmd: Command, interpreted: Bool, conn) -> Session {
  let assert Some(name) = session.name
  let tell_room = fn(msg) {
    case session.room {
      Some(r) -> process.send(r, msg)
      None -> Nil
    }
  }
  case cmd {
    command.Go(d) ->
      case session.moving {
        True -> {
          system(conn, "You're already on your way.")
          session
        }
        False -> {
          let self = session.self
          process.send(
            session.deps.world,
            world.Traverse(name, session.room_id, d, session.came_from, fn(a) {
              process.send(self, Moved(d, a))
            }),
          )
          Session(..session, moving: True)
        }
      }
    command.Look -> {
      tell_room(room.Look(name))
      session
    }
    command.Take(thing) -> {
      tell_room(room.Take(name, thing))
      session
    }
    command.Drop(thing) -> {
      tell_room(room.Drop(name, thing))
      session
    }
    command.Say(words) -> {
      tell_room(room.Say(name, words))
      session
    }
    command.Inventory -> {
      let items = store.inventory(session.deps.store, name)
      send(conn, protocol.Inventory(items))
      let light = store.carried_light(session.deps.store, name)
      let described =
        list.map(items, fn(item) {
          case light {
            Some(#(_, lit, oil)) if lit == item ->
              case oil {
                0 -> item <> " (out of oil)"
                _ ->
                  item
                  <> " (oil for "
                  <> int.to_string(oil)
                  <> " steps in the dark)"
              }
            _ -> item
          }
        })
      system(conn, case described {
        [] -> "You are carrying nothing."
        _ -> "You are carrying: " <> string.join(described, ", ") <> "."
      })
      session
    }
    command.Refill -> {
      case store.refill(session.deps.store, name) {
        Ok(#(light, fuel, oil)) -> {
          send(
            conn,
            Line(
              Narration,
              "You pour the "
                <> fuel
                <> " into the "
                <> light
                <> ". It burns bright again, with oil for "
                <> int.to_string(oil)
                <> " steps in the dark.",
            ),
          )
          send(
            conn,
            protocol.Inventory(store.inventory(session.deps.store, name)),
          )
          // Lit again in a dark place: see it now.
          tell_room(room.Refresh)
          tell_room(room.Look(name))
        }
        Error(reason) -> system(conn, reason)
      }
      session
    }
    command.Help -> {
      system(conn, command.help_text)
      session
    }
    command.LookToward(d) -> {
      tell_room(room.LookToward(name, d))
      session
    }
    // The words first, then (if it's something really here) a close-up of
    // it, drawn once and kept: the room's picture shows the place, examining
    // shows the thing.
    command.Examine(thing) -> {
      let self = session.self
      let deps = session.deps
      background(session, fn(room_data, inventory) {
        // Only things you could pick up (or carry) are worth a closer look,
        // and only if you can see them.
        let blind = room_data.dark && !store.has_light(deps.store, name)
        case blind, find_examinable(deps.store, room_data, name, thing) {
          True, _ ->
            process.send(self, Out(Line(System, "It's too dark to see.")))
          False, Some(found) -> {
            process.send(
              self,
              Out(examine(deps.fast, room_data, inventory, found.name)),
            )
            art.closeup(deps.art, deps.store, room_data, found, fn(url) {
              process.send(self, Out(protocol.Closeup(found.name, url)))
            })
          }
          False, None ->
            process.send(
              self,
              Out(Line(
                System,
                "There's nothing more to see there. (You can examine things you could pick up.)",
              )),
            )
        }
        Quiet
      })
      session
    }
    command.Unknown(text) ->
      case interpreted || string.trim(text) == "" {
        True -> {
          system(conn, "You can't do that here. (Type help for commands.)")
          session
        }
        False -> {
          background(session, fn(room_data, inventory) {
            Interpreted(
              text,
              room_data.id,
              interpret(session.deps.fast, room_data, inventory, text),
            )
          })
          session
        }
      }
  }
}

/// Run `work` in its own process with the current room and inventory, and
/// deliver its result back to this session as an event.
fn background(session: Session, work: fn(Room, List(String)) -> Event) -> Nil {
  let Session(self:, deps:, room:, name:, ..) = session
  case room, name {
    Some(r), Some(name) -> {
      process.spawn_unlinked(fn() {
        let room_data = process.call(r, 2000, room.Snapshot)
        process.send(self, work(room_data, store.inventory(deps.store, name)))
      })
      Nil
    }
    _, _ -> Nil
  }
}

// EVENTS ----------------------------------------------------------------------

fn on_event(session: Session, event: Event, conn) -> Session {
  case event {
    // Handled in the socket handler, which closes the connection.
    WasReplaced | Retire | Quiet -> session
    // A room view sent just before the player left that room arrives
    // after they're somewhere else. It's stale: drop it.
    Out(protocol.Room(view)) if view.id != session.room_id -> session
    Out(msg) -> {
      send(conn, msg)
      session
    }
    Moved(d, world.Building) -> {
      send(
        conn,
        protocol.Busy(
          "The fog thickens as the way "
          <> types.direction_name(d)
          <> " takes shape…",
        ),
      )
      session
    }
    // A key opened a lock on the way; the move carries on.
    Moved(_, world.Opened(text)) -> {
      send(conn, Line(Narration, text))
      send(
        conn,
        protocol.Inventory(store.inventory(
          session.deps.store,
          option.unwrap(session.name, ""),
        )),
      )
      session
    }
    Moved(_, world.Blocked(reason)) -> {
      system(conn, reason)
      Session(..session, moving: False)
    }
    Moved(d, world.Arrived(id)) -> {
      let assert Some(name) = session.name
      case session.room {
        Some(r) -> process.send(r, room.Leave(name, process.self(), Some(d)))
        None -> Nil
      }
      let session = enter(session, id, Some(types.opposite(d)), conn)
      burn_in_the_dark(session, name, id, conn)
      session
    }
    // Typed in a room the player has since left: it no longer means anything.
    // The old room's process is gone; start over at the new first room.
    WorldWasReset(start) -> {
      send(conn, protocol.WorldReset)
      send(conn, protocol.Inventory([]))
      system(conn, "The fog rolls in and the city is written anew.")
      enter(Session(..session, room: None, moving: False), start, None, conn)
    }
    Interpreted(_, room_id, _) if room_id != session.room_id -> session
    Interpreted(original, _, result) ->
      case result {
        Ok(text) ->
          case command.parse(text) {
            command.Unknown(_) ->
              run(session, command.Unknown(original), True, conn)
            cmd -> {
              system(conn, "› " <> command.describe(cmd))
              run(session, cmd, True, conn)
            }
          }
        Error(Nil) -> run(session, command.Unknown(original), True, conn)
      }
  }
}

// MODEL CALLS -----------------------------------------------------------------

fn context(room_data: Room, inventory: List(String)) -> String {
  "Place: "
  <> room_data.name
  <> ". "
  <> room_data.description
  <> "\nVisible details: "
  <> string.join(room_data.features, "; ")
  <> "\nItems here: "
  <> list_or_none(room_data.items)
  <> "\nExits: "
  <> list_or_none(
    list.map(room_data.exits, fn(e) {
      types.direction_name(e.direction) <> " (" <> e.hint <> ")"
    }),
  )
  <> "\nThe player carries: "
  <> list_or_none(inventory)
}

fn list_or_none(items: List(String)) -> String {
  case items {
    [] -> "nothing"
    _ -> string.join(items, ", ")
  }
}

/// Free-form input → one command from the fixed set, or none.
fn interpret(
  client: Client,
  room_data: Room,
  inventory: List(String),
  text: String,
) -> Result(String, Nil) {
  let prompt =
    "You translate a player's input in a text adventure into ONE game command.\n"
    <> "Allowed commands: go north | go south | go east | go west | go up | go down | fill lantern | look | look <north/south/east/west/up/down> | examine <thing> | take <item> | drop <item> | inventory | say <words> | help\n\n"
    <> context(room_data, inventory)
    <> "\n\nPlayer input: \""
    <> text
    <> "\"\n\nReply with JSON only: {\"command\": \"<one allowed command>\"}. "
    <> "Use the exit whose description matches what the player wants: to go there use go, to only look that way (\"what's down there?\") use look <direction>. If nothing fits, reply {\"command\": \"none\"}."
  case
    llm.generate(
      client,
      llm.Ask(..llm.ask_json(prompt), temperature: 0.0, timeout: 20_000),
    )
  {
    Ok(reply) ->
      case json.parse(reply, decode.at(["command"], decode.string)) {
        Ok("none") | Ok("") -> Error(Nil)
        Ok(cmd) -> Ok(cmd)
        Error(_) -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// A closer look. Not saved: it may add colour but not facts.
fn examine(
  client: Client,
  room_data: Room,
  inventory: List(String),
  thing: String,
) -> ServerMsg {
  let prompt =
    seed.setting
    <> "\n\n"
    <> context(room_data, inventory)
    <> "\n\nThe player examines \""
    <> thing
    <> "\". In 1-2 sentences, second person present tense, describe what they notice. Only describe things in the place description, visible details or items above; add texture to them but do not add new objects, people, creatures, exits or items. If \""
    <> thing
    <> "\" is not plausibly here, reply exactly: NOTHING"
  case llm.generate(client, llm.Ask(..llm.ask(prompt), timeout: 30_000)) {
    Ok(text) ->
      case string.starts_with(string.trim(text), "NOTHING") {
        True -> Line(System, "You don't see that here.")
        False -> Line(Narration, string.trim(text))
      }
    Error(Nil) -> Line(System, "You can't make it out clearly.")
  }
}

// MAP -------------------------------------------------------------------------

/// The rooms this player has visited, laid out on a grid, with the
/// passages between them and the ways out they haven't taken yet.
fn map_view(deps: Deps, name: String, current: Int) -> protocol.MapView {
  let visited = store.visited(deps.store, name)
  let rooms = list.filter_map(visited, store.load_room(deps.store, _))
  let seen = set.from_list(visited)
  let regions =
    store.regions(deps.store)
    |> list.map(fn(r) { #(r.id, r.name) })
    |> dict.from_list
  // Rooms carry their own grid positions now; the map just reads them.
  let placed = list.map(rooms, fn(r) { map.Placed(r, r.x, r.y, r.z) })
  protocol.MapView(
    current:,
    rooms: list.map(placed, fn(p) {
      protocol.MapRoom(
        id: p.room.id,
        name: p.room.name,
        region: dict.get(regions, p.room.region) |> result.unwrap(""),
        art: p.room.art_url,
        x: p.x,
        y: p.y,
        z: p.z,
        unexplored: p.room.exits
          |> list.filter(fn(e) {
            case e.target {
              Some(t) -> !set.contains(seen, t)
              None -> True
            }
          })
          |> list.map(fn(e) { types.direction_name(e.direction) }),
      )
    }),
    links: placed
      |> list.flat_map(fn(p) {
        list.filter_map(p.room.exits, fn(e) {
          case e.target {
            Some(t) ->
              case set.contains(seen, t) {
                True -> Ok(#(int.min(p.room.id, t), int.max(p.room.id, t)))
                False -> Error(Nil)
              }
            None -> Error(Nil)
          }
        })
      })
      |> list.unique,
  )
}

// CLOSE-UPS -------------------------------------------------------------------

/// What "examine <thing>" refers to, if it's really here: an item in the
/// room or one carried. Matched by exact name, or by every word asked for
/// appearing in its name.
fn find_examinable(
  store: Store,
  room_data: Room,
  player: String,
  query: String,
) -> Option(store.Examinable) {
  // Only things you could pick up (or carry): not the room's scenery.
  let candidates = store.examinable_items(store, room_data.id, player)
  let q =
    query
    |> string.lowercase
    |> string.trim
  let words =
    string.split(q, " ")
    |> list.filter(fn(w) {
      string.length(w) > 2 && !list.contains(["the", "and", "with"], w)
    })
  let exact = list.find(candidates, fn(c) { string.lowercase(c.name) == q })
  case exact, words {
    Ok(found), _ -> Some(found)
    Error(Nil), [] -> None
    Error(Nil), _ ->
      list.find(candidates, fn(c) {
        let name = string.lowercase(c.name)
        list.all(words, string.contains(name, _))
      })
      |> option.from_result
  }
}

// LIGHT -----------------------------------------------------------------------

/// A step into a dark place uses a unit of the player's light. Warn as it
/// runs low; when it goes out, the place goes dark for them.
fn burn_in_the_dark(session: Session, name: String, room_id: Int, conn) -> Nil {
  case store.load_room(session.deps.store, room_id) {
    Ok(here) if here.dark ->
      case store.burn(session.deps.store, name) {
        Some(#(light, 0)) -> {
          send(
            conn,
            Line(
              Narration,
              "Your " <> light <> " sputters and goes out. Darkness closes in.",
            ),
          )
          case session.room {
            Some(r) -> {
              process.send(r, room.Refresh)
              process.send(r, room.Look(name))
            }
            None -> Nil
          }
        }
        Some(#(light, left)) if left == 10 || left == 5 || left == 2 ->
          system(
            conn,
            "Your "
              <> light
              <> " gutters: oil for "
              <> int.to_string(left)
              <> " more steps in the dark.",
          )
        _ -> Nil
      }
    _ -> Nil
  }
}
