//// Room pictures. One actor owns the queue so only one picture is drawn at
//// a time (the GPU is shared with the text model), and so two requests for
//// the same room share one drawing. Pictures are saved to disk and their URL
//// to the room's row: each room is drawn once, ever.
////
//// The fast text model turns the room's stored facts — never player text —
//// into an image prompt; the image service (imagegen/) draws it.

import exception
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import server/llm.{type Client}
import server/world/store.{type Store}
import server/world/types.{type Room}
import simplifile

/// SDXL-Turbo runs without guidance, so negative prompts do nothing: the
/// era has to be pinned with positive words here.
/// Keep it to medium and era: anything about *place* ("city", "street",
/// "fog") here outweighs the room's own subject, and every room comes out
/// as the same gaslit street.
pub const style = "ink and watercolor illustration, Victorian era, 19th century, muted palette, dramatic lighting"

pub type Message {
  /// `urgent`: someone is standing in the room; draw it before rooms that
  /// were only built ahead of time.
  Request(room: Room, urgent: Bool, notify: fn(String) -> Nil)
  /// `generation` is the world the drawing was for; one finishing after a
  /// reset is for a world that no longer exists and is ignored.
  Done(generation: Int, room_id: Int, result: Result(String, Nil))
  /// Dev only: stop drawing, forget the queue, delete every picture.
  Reset(reply: Subject(Nil))
}

type State {
  State(
    self: Subject(Message),
    store: Store,
    client: Client,
    image_api: String,
    art_dir: String,
    waiting: Dict(Int, List(fn(String) -> Nil)),
    queue: List(Room),
    /// The drawing in progress: its room, and its process so a reset can
    /// stop it.
    drawing: Option(#(Int, Pid)),
    generation: Int,
  )
}

pub fn start(
  store: Store,
  client: Client,
  image_api: String,
  art_dir: String,
) -> Subject(Message) {
  let _ = simplifile.create_directory_all(art_dir)
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      State(
        self:,
        store:,
        client:,
        image_api:,
        art_dir:,
        waiting: dict.new(),
        queue: [],
        drawing: None,
        generation: 0,
      )
      |> actor.initialised
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

/// For a room someone is in: drawn first.
pub fn request(art: Subject(Message), room: Room, notify: fn(String) -> Nil) {
  process.send(art, Request(room, True, notify))
}

/// For a room just built ahead of anyone arriving.
pub fn prepare(art: Subject(Message), room: Room) {
  process.send(art, Request(room, False, fn(_) { Nil }))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Request(room, urgent, notify) ->
      case
        store.art_url(state.store, room.id),
        dict.get(state.waiting, room.id)
      {
        // Already drawn (perhaps ahead of time): hand it over.
        Some(url), _ -> {
          notify(url)
          state
        }
        // Being drawn or queued: wait for it, moving it up if now urgent.
        None, Ok(others) ->
          State(
            ..state,
            waiting: dict.insert(state.waiting, room.id, [notify, ..others]),
            // Urgent and only queued: move it up. Already being drawn:
            // leave the queue alone, or it would be drawn twice.
            queue: case
              urgent
              && state.drawing |> option.map(fn(d) { d.0 }) != Some(room.id)
            {
              True -> [
                room,
                ..list.filter(state.queue, fn(r) { r.id != room.id })
              ]
              False -> state.queue
            },
          )
        None, Error(Nil) ->
          State(
            ..state,
            waiting: dict.insert(state.waiting, room.id, [notify]),
            queue: case urgent {
              True -> [room, ..state.queue]
              False -> list.append(state.queue, [room])
            },
          )
          |> next
      }
      |> actor.continue
    Done(generation, _, _) if generation != state.generation ->
      actor.continue(state)
    Done(_, room_id, result) -> {
      let notifies = dict.get(state.waiting, room_id) |> result.unwrap([])
      case result {
        Ok(url) -> list.each(notifies, fn(n) { n(url) })
        Error(Nil) -> Nil
      }
      State(
        ..state,
        waiting: dict.delete(state.waiting, room_id),
        drawing: None,
      )
      |> next
      |> actor.continue
    }
    Reset(reply) -> {
      case state.drawing {
        Some(#(_, pid)) -> process.kill(pid)
        None -> Nil
      }
      case simplifile.read_directory(state.art_dir) {
        Ok(files) ->
          list.each(files, fn(f) {
            case string.ends_with(f, ".png") {
              True -> {
                let _ = simplifile.delete(state.art_dir <> "/" <> f)
                Nil
              }
              False -> Nil
            }
          })
        Error(_) -> Nil
      }
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          waiting: dict.new(),
          queue: [],
          drawing: None,
          generation: state.generation + 1,
        ),
      )
    }
  }
}

/// Dev only. Returns once nothing more will be drawn for the old world.
pub fn reset(art: Subject(Message)) -> Nil {
  process.call(art, 10_000, Reset)
}

fn next(state: State) -> State {
  case state.drawing, state.queue {
    Some(_), _ | _, [] -> state
    None, [room, ..rest] -> {
      let State(self:, store:, client:, image_api:, art_dir:, generation:, ..) =
        state
      let pid =
        process.spawn_unlinked(fn() {
          let result =
            exception.rescue(fn() {
              draw(store, client, image_api, art_dir, room)
            })
            |> result.replace_error(Nil)
            |> result.flatten
          process.send(self, Done(generation, room.id, result))
        })
      State(..state, queue: rest, drawing: Some(#(room.id, pid)))
    }
  }
}

fn draw(
  store: Store,
  client: Client,
  image_api: String,
  art_dir: String,
  room: Room,
) -> Result(String, Nil) {
  let prompt = image_prompt(client, room) <> ", " <> style
  logging.log(
    logging.Info,
    "drawing room " <> int.to_string(room.id) <> ": " <> prompt,
  )
  let body =
    json.object([
      #("prompt", json.string(prompt)),
      #("seed", json.int(1000 + room.id)),
    ])
    |> json.to_string
    |> bit_array.from_string
  use base <- result.try(request.to(image_api <> "/generate"))
  let req =
    base
    |> request.set_method(Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(120_000)
    |> httpc.dispatch_bits(req)
    |> result.replace_error(Nil),
  )
  case response.status {
    200 -> {
      let file = "room-" <> int.to_string(room.id) <> ".png"
      use _ <- result.try(
        simplifile.write_bits(art_dir <> "/" <> file, response.body)
        |> result.replace_error(Nil),
      )
      let url = "/art/" <> file
      store.set_art(store, room.id, url)
      Ok(url)
    }
    status -> {
      logging.log(
        logging.Warning,
        "image service answered "
          <> int.to_string(status)
          <> " for room "
          <> int.to_string(room.id),
      )
      Error(Nil)
    }
  }
}

/// A short visual prompt from the room's facts. Falls back to the facts
/// themselves if the model doesn't answer.
fn image_prompt(client: Client, room: Room) -> String {
  let facts = string.join(list.append(room.features, room.items), ", ")
  // Not the whole setting guide: a small model copies its "what exists" list
  // straight into the prompt, and every room comes out the same. The era is
  // pinned by `style`; this only needs to keep modern things out.
  let ask =
    "Write a short image-generation prompt (max 30 words, comma-separated visual details of this one place, no character names, no story, no quotes). The place is in a Victorian-era gaslamp city; never mention modern objects. Reply with the prompt only.\nPlace: "
    <> room.name
    <> "\nDescription: "
    <> room.description
    <> "\nVisible: "
    <> facts
    <> "\nPrompt:"
  case
    llm.generate(
      client,
      llm.Ask(..llm.ask(ask), temperature: 0.4, timeout: 30_000),
    )
  {
    Ok(text) ->
      case clean_prompt(text) {
        "" -> room.name <> ", " <> facts
        prompt -> prompt
      }
    Error(Nil) -> room.name <> ", " <> facts
  }
}

/// The model's reply, minus chatter: "Here is a short prompt for X:" lines,
/// quotes, and anything past the first real line.
pub fn clean_prompt(reply: String) -> String {
  let preamble = fn(line: String) {
    let lower = string.lowercase(line)
    string.ends_with(line, ":")
    || string.starts_with(lower, "here is")
    || string.starts_with(lower, "here's")
    || string.starts_with(lower, "sure")
  }
  let line =
    reply
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(fn(l) { l != "" })
    |> list.map(fn(l) {
      // "Here is a prompt for X: actual, prompt" on one line.
      case preamble(l), string.split_once(l, ":") {
        True, Ok(#(_, after)) -> string.trim(after)
        _, _ -> l
      }
    })
    |> list.find(fn(l) { l != "" && !preamble(l) })
    |> result.unwrap("")
  line |> string.replace("\"", "") |> string.slice(0, 300)
}
