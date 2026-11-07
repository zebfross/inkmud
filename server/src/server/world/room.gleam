//// One process per room in use. Its mailbox is the room's action queue:
//// two players grabbing the same item arrive as two messages, handled in
//// order, so exactly one of them gets it. Everyone present hears the same
//// thing happen.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import server/art
import server/world/builder
import server/world/danger
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
  /// A round against the creature here.
  Fight(name: String, reply: fn(Outcome) -> Nil)
  /// Raise a lit lantern at it.
  Brandish(name: String, reply: fn(Outcome) -> Nil)
  /// Run from it (the session then takes the player back the way they came).
  Flee(name: String, reply: fn(Outcome) -> Nil)
  /// A creature's picture is ready.
  FoeArt(kind: String, url: String)
}

/// How a round went, for the player's session.
pub type Outcome {
  NoFoe
  /// A blow landed; `defeated` if it drove the creature off.
  Struck(defeated: Bool)
  /// The creature hurt you: you now have `wounds`.
  Hurt(wounds: Int)
  /// The last wound: you're down, and what you carried is left here.
  Collapsed
  /// Your lantern drove it off.
  Drove
  NoLight
  NotAfraid
  /// Got away (perhaps hurt on the way): now go.
  Escaped(wounds: Int)
}

/// A creature in the room, and how many more hits it takes.
type Foe {
  Foe(creature: danger.Creature, left: Int, line: String, art: Option(String))
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
    /// A creature everyone here faces, until it's driven off or nobody's
    /// left (it wanders away).
    foe: Option(Foe),
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
        foe: None,
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
  // Nothing gets picked up or put down with a creature at your heels.
  let busy = case message, state.foe {
    Take(name, _), Some(foe) | Drop(name, _), Some(foe) ->
      Some(#(name, "Not with the " <> foe.creature.name <> " on you!"))
    _, _ -> None
  }
  case busy {
    Some(#(name, refusal)) -> {
      tell(state, name, Line(System, refusal))
      actor.continue(state)
    }
    None -> handle_sighted(state, message, needs_sight)
  }
}

fn handle_sighted(
  state: State,
  message: Message,
  needs_sight: Option(#(String, String)),
) -> actor.Next(State, Message) {
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
      let state = case state.foe, from {
        // Already here: the newcomer faces it too.
        Some(foe), _ -> {
          tell(
            state,
            name,
            Line(Narration, "The " <> foe.creature.name <> " is here!"),
          )
          state
        }
        // Walking in (not waking up here) may meet something.
        None, Some(_) -> meet(state)
        None, None -> state
      }
      request_art(state) |> actor.continue
    }

    Leave(name, owner, toward) ->
      case dict.get(state.owners, name) == Ok(owner) {
        // From a session that has since been replaced: not this player
        // leaving.
        False -> actor.continue(state)
        True -> {
          let occupants = list.filter(state.occupants, fn(o) { o.0 != name })
          let state =
            State(
              ..state,
              occupants:,
              owners: dict.delete(state.owners, name),
              // With nobody left to bother, it wanders off.
              foe: case occupants {
                [] -> None
                _ -> state.foe
              },
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
      // Their satchel changed too.
      tell(state, name, inventory_msg(state.store, name))
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
      // Their satchel changed too.
      tell(state, name, inventory_msg(state.store, name))
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
      // Their satchel changed too.
      tell(state, name, inventory_msg(state.store, name))
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

    Fight(name, reply) ->
      case state.foe {
        None -> {
          tell(state, name, Line(System, "There's nothing here to fight."))
          reply(NoFoe)
          actor.continue(state)
        }
        Some(foe) -> fight(state, foe, name, reply) |> actor.continue
      }

    Brandish(name, reply) ->
      case state.foe, store.carried_light(state.store, name) {
        None, _ -> {
          tell(state, name, Line(System, "There's nothing here to scare off."))
          reply(NoFoe)
          actor.continue(state)
        }
        Some(_), None | Some(_), Some(#(_, _, 0)) -> {
          tell(state, name, Line(System, "You have no lit lantern to raise."))
          reply(NoLight)
          actor.continue(state)
        }
        Some(foe), Some(#(_, light, _)) ->
          case foe.creature.fears_light {
            False -> {
              tell(
                state,
                name,
                Line(
                  Narration,
                  "You raise the "
                    <> light
                    <> ". The "
                    <> foe.creature.name
                    <> " squints into it, and doesn't back off an inch.",
                ),
              )
              reply(NotAfraid)
              actor.continue(state)
            }
            True -> {
              let _ = store.burn(state.store, name)
              tell(
                state,
                name,
                Line(
                  Narration,
                  "You thrust the "
                    <> light
                    <> " forward and turn the flame up high. The "
                    <> foe.creature.name
                    <> " recoils from the glare and is gone.",
                ),
              )
              broadcast_except(
                state,
                name,
                Line(
                  Social,
                  name
                    <> " drives off the "
                    <> foe.creature.name
                    <> " with a blaze of lantern light.",
                ),
              )
              let state = State(..state, foe: None)
              refresh_all(state)
              reply(Drove)
              actor.continue(state)
            }
          }
      }

    Flee(name, reply) ->
      case state.foe {
        None -> {
          reply(Escaped(store.wounds(state.store, name)))
          actor.continue(state)
        }
        Some(foe) ->
          case int.random(100) < foe.creature.flee_risk {
            False -> {
              tell(state, name, Line(Narration, "You turn and run."))
              reply(Escaped(store.wounds(state.store, name)))
              actor.continue(state)
            }
            // Hurt on the way out, but away (unless that was the last wound).
            True ->
              wound(state, foe, name, "as you turn to run", reply)
              |> actor.continue
          }
      }

    FoeArt(kind, url) ->
      case state.foe {
        Some(foe) if foe.creature.kind == kind -> {
          let state = State(..state, foe: Some(Foe(..foe, art: Some(url))))
          refresh_all(state)
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
  }
}

/// Roll for something waiting here, and if so, bring it on.
fn meet(state: State) -> State {
  let room = state.room
  // Nothing comes at you indoors.
  let met = case room.setting == types.Inside {
    True -> None
    False ->
      danger.roll_encounter(
        room.z,
        room.region,
        builder.tier(types.cell(room)),
        room.dark,
      )
  }
  case met {
    None -> state
    Some(creature) -> {
      let line =
        danger.pick(creature.arrives)
        |> option.unwrap("Something comes at you out of the fog.")
      let self = state.self
      art.creature(
        state.art,
        state.store,
        creature.kind,
        creature.looks,
        fn(url) { process.send(self, FoeArt(creature.kind, url)) },
      )
      let state =
        State(
          ..state,
          foe: Some(Foe(creature:, left: creature.strength, line:, art: None)),
        )
      refresh_all(state)
      broadcast(state, Line(Narration, line))
      state
    }
  }
}

/// One round: a die, plus your best tool, against its strength.
fn fight(
  state: State,
  foe: Foe,
  name: String,
  reply: fn(Outcome) -> Nil,
) -> State {
  let tools = store.carried_tools(state.store, name)
  let bonus = danger.weapon_bonus(list.map(tools, fn(t) { t.1 }))
  let with = case danger.weapon(tools) {
    Some(tool) -> " with the " <> tool
    None -> ""
  }
  let creature = foe.creature
  case danger.hits(danger.roll_die(), bonus, creature.strength) {
    False -> wound(state, foe, name, "past your guard", reply)
    True ->
      case foe.left - 1 {
        0 -> {
          tell(
            state,
            name,
            Line(
              Narration,
              "You strike"
                <> with
                <> ". The "
                <> creature.name
                <> " has had enough, and flees!",
            ),
          )
          broadcast_except(
            state,
            name,
            Line(Social, name <> " drives off the " <> creature.name <> "."),
          )
          let state = State(..state, foe: None)
          refresh_all(state)
          reply(Struck(True))
          state
        }
        left -> {
          tell(
            state,
            name,
            Line(
              Narration,
              "Your blow lands"
                <> with
                <> ". The "
                <> creature.name
                <> " falters.",
            ),
          )
          broadcast_except(
            state,
            name,
            Line(
              Social,
              name <> " lands a blow on the " <> creature.name <> ".",
            ),
          )
          let state = State(..state, foe: Some(Foe(..foe, left:)))
          refresh_all(state)
          reply(Struck(False))
          state
        }
      }
  }
}

/// The creature hurts a player; the last wound puts them down, and what
/// they carried stays here.
fn wound(
  state: State,
  foe: Foe,
  name: String,
  how: String,
  reply: fn(Outcome) -> Nil,
) -> State {
  let creature = foe.creature
  let wounds = store.add_wound(state.store, name)
  case wounds >= danger.max_wounds {
    False -> {
      tell(
        state,
        name,
        Line(
          Narration,
          "The "
            <> creature.name
            <> " gets at you "
            <> how
            <> ". You're hurt ("
            <> int.to_string(wounds)
            <> " of "
            <> int.to_string(danger.max_wounds)
            <> " wounds).",
        ),
      )
      broadcast_except(
        state,
        name,
        Line(Social, "The " <> creature.name <> " wounds " <> name <> "."),
      )
      reply(Hurt(wounds))
      state
    }
    True -> {
      let dropped = store.drop_all(state.store, state.room.id, name)
      tell(
        state,
        name,
        Line(
          Narration,
          "The "
            <> creature.name
            <> " is too much for you. Everything goes black…",
        ),
      )
      broadcast_except(
        state,
        name,
        Line(
          Social,
          name
            <> " collapses"
            <> case dropped {
            [] -> "."
            _ -> ", and what they carried spills across the ground."
          },
        ),
      )
      let state = reload(state)
      refresh_all(state)
      reply(Collapsed)
      state
    }
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

/// Items as the client shows them, with a short note: a light's oil, what
/// a tool is for.
pub fn item_views(rows: List(store.ItemRow)) -> List(protocol.ItemView) {
  list.map(rows, fn(row) {
    let note = case row.role {
      "light" ->
        case row.charge {
          0 -> "out of oil"
          n -> "oil " <> int.to_string(n)
        }
      "tool" -> option.unwrap(row.unlocks, "tool")
      role -> role
    }
    protocol.ItemView(name: row.name, role: row.role, note:)
  })
}

/// What a player carries, for their satchel.
pub fn inventory_msg(store: Store, player: String) -> ServerMsg {
  protocol.Inventory(item_views(store.carried_item_rows(store, player)))
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
            e.door,
          )
        }),
        items: item_views(store.room_item_rows(state.store, room.id)),
        features: room.features,
        others:,
        art: room.art_url,
        dark: False,
        foe: foe_view(state),
        setting: types.setting_name(room.setting),
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
              e.door,
            )
          }),
        items: [],
        features: [],
        others:,
        art: None,
        dark: True,
        foe: foe_view(state),
        setting: types.setting_name(room.setting),
      )
  }
}

fn foe_view(state: State) -> Option(protocol.FoeView) {
  option.map(state.foe, fn(foe) {
    protocol.FoeView(
      kind: foe.creature.kind,
      name: foe.creature.name,
      line: foe.line,
      strength: foe.creature.strength,
      left: foe.left,
      fears_light: foe.creature.fears_light,
      art: foe.art,
    )
  })
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
