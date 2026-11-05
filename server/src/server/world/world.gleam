//// The world registry. It starts room processes on demand, tracks who is
//// online, and owns room building:
////
//// - Single flight: each unbuilt exit has at most one build in progress.
////   Everyone who walks into it while it's being built waits on that one
////   build, so a room can never be invented twice.
//// - At most two builds at a time (the model is a shared GPU). Prefetches
////   only ever use one slot, so a build someone is standing at the doorway
////   waiting for can always start at once, and jumps the queue.
//// - Prefetch: when a player enters a room, its unbuilt exits are queued,
////   so the next room is usually ready before anyone reaches it.
////
//// Nothing here blocks: builds run in their own unlinked process and report
//// back with `Built`.

import exception
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import logging
import server/art
import server/llm.{type Client}
import server/world/builder
import server/world/room
import server/world/seed
import server/world/store.{type Store}
import server/world/types.{type Direction}

pub type Arrival {
  /// A room is being built; the player should be told to wait.
  Building
  Arrived(room_id: Int)
  Blocked(reason: String)
  /// The player's key opened a lock on the way (more replies follow).
  Opened(text: String)
}

type Key =
  #(Int, Direction)

pub type Message {
  GetRoom(id: Int, reply: Subject(Result(Subject(room.Message), Nil)))
  Traverse(
    player: String,
    room_id: Int,
    direction: Direction,
    reply: fn(Arrival) -> Nil,
  )
  Prefetch(room_id: Int)
  Built(key: Key, result: Result(builder.Built, Nil))
  /// `on_reset` is how a dev reset tells this player's session to start over
  /// in the new world's first room (whose id it is given).
  ///
  /// `device` identifies the browser (a random key it keeps). The same
  /// player reconnecting from the same browser — a refresh, a phone waking
  /// up while its old connection lingers — takes over: the old session is
  /// told via its `kick`. Another browser asking for a name in use is
  /// refused.
  Login(
    name: String,
    device: String,
    session: Pid,
    on_reset: fn(Int) -> Nil,
    kick: fn() -> Nil,
    reply: Subject(Bool),
  )
  /// Only counts if `session` is still the one holding the name.
  Logout(name: String, session: Pid)
  /// Dev only: wipe the world, write the seed again, and send every
  /// connected player to the start. Replies with the new start room's id.
  Reset(reply: Subject(Int))
}

type Online {
  Online(
    device: String,
    session: Pid,
    on_reset: fn(Int) -> Nil,
    kick: fn() -> Nil,
  )
}

type State {
  State(
    self: Subject(Message),
    store: Store,
    builder: Client,
    art: Subject(art.Message),
    rooms: Dict(Int, Subject(room.Message)),
    online: Dict(String, Online),
    /// Builds asked for, and who is waiting on each.
    waiting: Dict(Key, List(fn(Arrival) -> Nil)),
    /// Not started yet, in priority order.
    queue: List(Key),
    /// Builds running, with their process so a reset can stop them.
    active: List(#(Key, Pid)),
  )
}

pub fn start(
  store: Store,
  builder: Client,
  art_queue: Subject(art.Message),
) -> Subject(Message) {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      State(
        self:,
        store:,
        builder:,
        art: art_queue,
        rooms: dict.new(),
        online: dict.new(),
        waiting: dict.new(),
        queue: [],
        active: [],
      )
      |> actor.initialised
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

pub fn get_room(
  world: Subject(Message),
  id: Int,
) -> Result(Subject(room.Message), Nil) {
  process.call(world, 5000, GetRoom(id, _))
}

pub fn login(
  world: Subject(Message),
  name: String,
  device: String,
  on_reset: fn(Int) -> Nil,
  kick: fn() -> Nil,
) -> Bool {
  process.call(world, 5000, Login(
    name,
    device,
    process.self(),
    on_reset,
    kick,
    _,
  ))
}

pub fn reset(world: Subject(Message)) -> Int {
  process.call(world, 30_000, Reset)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    GetRoom(id, reply) -> {
      let #(state, found) = ensure_room(state, id)
      process.send(reply, found)
      actor.continue(state)
    }

    Login(name, device, session, on_reset, kick, reply) -> {
      let allowed = case dict.get(state.online, name) {
        Error(Nil) -> True
        Ok(old) if device != "" && old.device == device -> {
          old.kick()
          True
        }
        Ok(_) -> False
      }
      process.send(reply, allowed)
      case allowed {
        False -> actor.continue(state)
        True ->
          actor.continue(
            State(
              ..state,
              online: dict.insert(
                state.online,
                name,
                Online(device:, session:, on_reset:, kick:),
              ),
            ),
          )
      }
    }

    Logout(name, session) ->
      case dict.get(state.online, name) {
        Ok(entry) if entry.session == session ->
          actor.continue(
            State(..state, online: dict.delete(state.online, name)),
          )
        _ -> actor.continue(state)
      }

    Reset(reply) -> {
      // Stop everything that could still write into the old world: room
      // processes, builds in flight, and the drawing queue. Builds and
      // drawings run unlinked, so killing them touches nothing else.
      dict.each(state.rooms, fn(_, r) { process.send(r, room.Stop) })
      list.each(state.active, fn(a) { process.kill(a.1) })
      art.reset(state.art)
      let start = store.wipe_and(state.store, seed.run)
      logging.log(logging.Info, "world reset by a developer")
      process.send(reply, start)
      dict.each(state.online, fn(_, entry) { entry.on_reset(start) })
      actor.continue(
        State(
          ..state,
          rooms: dict.new(),
          waiting: dict.new(),
          queue: [],
          active: [],
        ),
      )
    }

    Traverse(player, room_id, direction, reply) ->
      case feel_the_way(state.store, player, room_id, direction) {
        Error(reason) -> {
          reply(Blocked(reason))
          actor.continue(state)
        }
        Ok(Nil) -> through_lock(state, player, room_id, direction, reply)
      }

    Prefetch(room_id) ->
      case store.load_room(state.store, room_id) {
        Error(Nil) -> actor.continue(state)
        Ok(from) -> {
          let new =
            from.exits
            |> list.filter(fn(e) { e.target == None })
            |> list.map(fn(e) { #(room_id, e.direction) })
            |> list.filter(fn(k) {
              !dict.has_key(state.waiting, k) && !is_active(state, k)
            })
          State(
            ..state,
            waiting: list.fold(new, state.waiting, fn(w, k) {
              dict.insert(w, k, [])
            }),
            queue: list.append(state.queue, new),
          )
          |> run_next
          |> actor.continue
        }
      }

    Built(key, result) -> {
      let waiters = dict.get(state.waiting, key) |> result.unwrap([])
      let arrival = case result {
        Ok(built) -> {
          // A new room: draw it now, so the picture is usually there before
          // anyone is. (An exit that joined an existing room needs none.)
          case built.new, store.load_room(state.store, built.room_id) {
            True, Ok(new_room) -> art.prepare(state.art, state.store, new_room)
            _, _ -> Nil
          }
          Arrived(built.room_id)
        }
        Error(Nil) ->
          Blocked("The fog is too thick to go that way just now. Try again.")
      }
      list.each(waiters, fn(w) { w(arrival) })
      // Exits changed (the source room's, and any neighbours joined to the
      // new room): those rooms' processes reload.
      let touched = case result {
        Ok(built) -> [key.0, ..built.touched] |> list.unique
        Error(Nil) -> [key.0]
      }
      list.each(touched, fn(id) {
        case dict.get(state.rooms, id) {
          Ok(r) -> process.send(r, room.Refresh)
          Error(Nil) -> Nil
        }
      })
      State(
        ..state,
        waiting: dict.delete(state.waiting, key),
        active: list.filter(state.active, fn(a) { a.0 != key }),
      )
      |> run_next
      |> actor.continue
    }
  }
}

/// In a dark place without a light, you can't find the ways out: only feel
/// your way back toward somewhere already lit.
fn feel_the_way(
  store: Store,
  player: String,
  room_id: Int,
  direction: Direction,
) -> Result(Nil, String) {
  case store.load_room(store, room_id) {
    Ok(from) if from.dark ->
      case store.has_light(store, player) {
        True -> Ok(Nil)
        False -> {
          let lit = case types.find_exit(from, direction) {
            Ok(types.Exit(target: Some(t), lock: None, ..)) ->
              case store.load_room(store, t) {
                Ok(beyond) -> !beyond.dark
                Error(Nil) -> False
              }
            _ -> False
          }
          case lit {
            True -> Ok(Nil)
            False ->
              Error(
                "It's too dark to find your way. You can only feel your way back toward somewhere lit.",
              )
          }
        }
      }
    _ -> Ok(Nil)
  }
}

/// Past any darkness: through the exit's lock, if it has one.
fn through_lock(
  state: State,
  player: String,
  room_id: Int,
  direction: Direction,
  reply: fn(Arrival) -> Nil,
) -> actor.Next(State, Message) {
  case store.pass(state.store, player, room_id, direction) {
    store.Barred(lock) -> {
      reply(Blocked(types.barred(lock)))
      actor.continue(state)
    }
    store.Unlocked(key:, ..) -> {
      reply(Opened(
        "You fit the "
        <> key
        <> " into the lock. It turns with a heavy click and the way opens; you leave the key where it is.",
      ))
      // The exit changed for everyone: its room shows it open.
      case dict.get(state.rooms, room_id) {
        Ok(r) -> process.send(r, room.Refresh)
        Error(Nil) -> Nil
      }
      traverse(state, room_id, direction, reply)
    }
    store.Obstructed(obstacle) -> {
      reply(Blocked(types.obstructed(obstacle)))
      actor.continue(state)
    }
    store.Cleared(tool: _, obstacle:) -> {
      reply(
        Opened(case types.tool_kind(obstacle.kind) {
          Ok(kind) -> kind.clears
          Error(Nil) -> "You get past it."
        }),
      )
      case dict.get(state.rooms, room_id) {
        Ok(r) -> process.send(r, room.Refresh)
        Error(Nil) -> Nil
      }
      traverse(state, room_id, direction, reply)
    }
    store.Open -> traverse(state, room_id, direction, reply)
  }
}

/// Go through an exit (already past any lock): to the room beyond, or wait
/// while it's built.
fn traverse(
  state: State,
  room_id: Int,
  direction: Direction,
  reply: fn(Arrival) -> Nil,
) -> actor.Next(State, Message) {
  case store.load_room(state.store, room_id) {
    Error(Nil) -> {
      reply(Blocked("You can't go that way."))
      actor.continue(state)
    }
    Ok(from) ->
      case types.find_exit(from, direction) {
        Error(Nil) -> {
          reply(Blocked("You can't go that way."))
          actor.continue(state)
        }
        Ok(types.Exit(target: Some(id), ..)) -> {
          reply(Arrived(id))
          actor.continue(state)
        }
        Ok(types.Exit(target: None, ..)) -> {
          reply(Building)
          let key = #(room_id, direction)
          let waiters = dict.get(state.waiting, key) |> result.unwrap([])
          let queue = case is_active(state, key) {
            True -> state.queue
            // Someone is waiting: to the front of the queue.
            False -> [key, ..list.filter(state.queue, fn(k) { k != key })]
          }
          State(
            ..state,
            waiting: dict.insert(state.waiting, key, [reply, ..waiters]),
            queue:,
          )
          |> run_next
          |> actor.continue
        }
      }
  }
}

fn ensure_room(
  state: State,
  id: Int,
) -> #(State, Result(Subject(room.Message), Nil)) {
  case dict.get(state.rooms, id) {
    Ok(subject) -> #(state, Ok(subject))
    Error(Nil) ->
      case store.load_room(state.store, id) {
        Ok(data) -> {
          let subject = room.start(state.store, state.art, data)
          #(
            State(..state, rooms: dict.insert(state.rooms, id, subject)),
            Ok(subject),
          )
        }
        Error(Nil) -> #(state, Error(Nil))
      }
  }
}

const max_builds = 2

fn run_next(state: State) -> State {
  case state.queue {
    [] -> state
    [key, ..rest] -> {
      let someone_waiting = case dict.get(state.waiting, key) {
        Ok([_, ..]) -> True
        _ -> False
      }
      let slots = case someone_waiting {
        True -> max_builds
        False -> 1
      }
      case list.length(state.active) < slots {
        False -> state
        True -> start_build(State(..state, queue: rest), key) |> run_next
      }
    }
  }
}

fn is_active(state: State, key: Key) -> Bool {
  list.any(state.active, fn(a) { a.0 == key })
}

fn start_build(state: State, key: Key) -> State {
  let State(self:, store:, builder: client, ..) = state
  let pid =
    process.spawn_unlinked(fn() {
      let result =
        exception.rescue(fn() {
          // Re-read: another build may have linked this exit meanwhile.
          let assert Ok(from) = store.load_room(store, key.0)
          let assert Ok(exit) = types.find_exit(from, key.1)
          case exit.target {
            Some(id) -> builder.Built(room_id: id, new: False, touched: [])
            None -> builder.build(store, client, from, exit)
          }
        })
        |> result.replace_error(Nil)
      case result {
        Error(Nil) -> logging.log(logging.Error, "room build crashed")
        Ok(_) -> Nil
      }
      process.send(self, Built(key, result))
    })
  State(..state, active: [#(key, pid), ..state.active])
}
