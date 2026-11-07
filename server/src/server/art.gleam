//// Pictures: room establishing shots and examine close-ups. One actor owns
//// the queue so only one picture is drawn at a time (the GPU is shared with
//// the text model), and so two requests for the same picture share one
//// drawing. Every picture is saved to disk with its URL in the database:
//// each is drawn once, ever.
////
//// Prompts are built from stored facts, never player text and never a
//// model rewrite, and always start with the style (the image model reads
//// only the first 77 tokens of a prompt; overflow falls off the end).

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
import server/world/store.{type Examinable, type Store}
import server/world/types.{type Room}
import simplifile

/// SDXL-Turbo runs without guidance, so negative prompts do nothing: the
/// era has to be pinned with positive words here. Keep it to medium and era:
/// anything about *place* here outweighs the subject, and every room comes
/// out as the same gaslit street.
pub const style = "Ink and watercolor illustration, Victorian era, muted palette, dramatic lighting"

/// One picture to draw.
pub type Job {
  Job(
    /// Identifies the picture: requests with the same key share a drawing.
    key: String,
    prompt: String,
    seed: Int,
    /// File name under the art directory.
    file: String,
    /// Already drawn? (Checked when asked, so a picture is never redrawn.)
    cached: fn() -> Option(String),
    /// Record the finished picture's URL.
    save: fn(String) -> Nil,
  )
}

pub type Message {
  /// `urgent`: someone is waiting to see it; draw it before pictures that
  /// were only queued ahead of time.
  Request(job: Job, urgent: Bool, notify: fn(String) -> Nil)
  /// `generation` is the world the drawing was for; one finishing after a
  /// reset is for a world that no longer exists and is ignored.
  Done(generation: Int, key: String, result: Result(String, Nil))
  /// Dev only: stop drawing, forget the queue, delete every picture.
  Reset(reply: Subject(Nil))
}

type State {
  State(
    self: Subject(Message),
    image_api: String,
    art_dir: String,
    waiting: Dict(String, List(fn(String) -> Nil)),
    queue: List(Job),
    /// The drawing in progress: its key, and its process so a reset can
    /// stop it.
    drawing: Option(#(String, Pid)),
    generation: Int,
  )
}

pub fn start(
  store: Store,
  image_api: String,
  art_dir: String,
) -> Subject(Message) {
  let _ = store
  let _ = simplifile.create_directory_all(art_dir)
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(self) {
      State(
        self:,
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

// ROOM PICTURES ---------------------------------------------------------------

/// For a room someone is in: drawn first.
pub fn request(
  art: Subject(Message),
  store: Store,
  room: Room,
  notify: fn(String) -> Nil,
) {
  process.send(art, Request(room_job(store, room), True, notify))
}

/// For a room just built ahead of anyone arriving.
pub fn prepare(art: Subject(Message), store: Store, room: Room) {
  process.send(art, Request(room_job(store, room), False, fn(_) { Nil }))
}

fn room_job(store: Store, room: Room) -> Job {
  let prompt = image_prompt(room)
  let seed = 1000 + room.id
  Job(
    key: "room-" <> int.to_string(room.id),
    prompt:,
    seed:,
    file: "room-" <> int.to_string(room.id) <> ".png",
    cached: fn() { store.art_url(store, room.id) },
    save: fn(url) {
      store.set_art(store, room.id, url)
      store.save_image_debug(store, room.id, prompt, seed)
    },
  )
}

/// A room's picture is an establishing shot: the place, its light and its
/// landmarks. Items aren't forced in: a fast model draws one strong subject
/// well but not a scene plus small objects (a strong landmark like a gas
/// lamp always won). Items get their own close-ups when examined.
pub fn image_prompt(room: Room) -> String {
  style <> ". " <> level(room.z) <> setting(room)
}

/// Where the place is, said before the scene so the 77-token limit can't
/// cut it off: the picture line alone ("a still pool, gaslight above")
/// can read as a dockside, when the place is a cavern under the streets.
/// Worded as what's there, never "no sky": the image model's text encoder
/// doesn't do negation, so "no sky" draws a sky.
pub fn level(z: Int) -> String {
  case z {
    0 -> "Outdoors in the city, open sky above. "
    z if z < 0 ->
      "Interior of an underground passage beneath the city, arched stone ceiling overhead, lantern light. "
    _ -> "An upper room or rooftop, high above the city streets. "
  }
}

/// The setting part of a room's stored picture line, whichever form it was
/// stored in; composed from the room's facts if it has none.
fn setting(room: Room) -> String {
  let picture = string.trim(room.picture)
  let from_line = case
    string.split_once(picture, ". Behind: "),
    string.split_once(picture, " In the foreground: ")
  {
    // "Close-up of ..., large in the foreground. Behind: <setting>."
    Ok(#(_, behind)), _ -> behind
    // "<setting>. In the foreground: <items>."
    _, Ok(#(before, _)) -> before
    _, _ -> picture
  }
  case strip_stop(string.trim(from_line)) {
    "" ->
      case list.take(room.features, 3) {
        [] -> room.name
        details -> room.name <> ": " <> string.join(details, ", ")
      }
    line -> line
  }
  <> "."
}

// CLOSE-UPS -------------------------------------------------------------------

/// Draw `thing` up close (when examined), alone, so it's the only subject.
/// `notify` gets the picture's URL, straight away if it was drawn before.
pub fn closeup(
  art: Subject(Message),
  store: Store,
  room: Room,
  thing: Examinable,
  notify: fn(String) -> Nil,
) {
  let prompt = closeup_prompt(room, thing)
  let job =
    Job(
      key: "closeup-" <> thing.key,
      prompt:,
      seed: seed_for(thing.key),
      file: "closeup-" <> thing.key <> ".png",
      cached: fn() { store.closeup_url(store, thing.key) },
      save: fn(url) { store.set_closeup(store, thing.key, url, prompt) },
    )
  process.send(art, Request(job, True, notify))
}

/// A creature's picture: one per kind, drawn once and kept.
pub fn creature(
  art: Subject(Message),
  store: Store,
  kind: String,
  looks: String,
  notify: fn(String) -> Nil,
) {
  let key = "creature-" <> kind
  let prompt =
    style
    <> ". "
    <> looks
    <> ", menacing, centered, filling the frame, finely detailed."
  let job =
    Job(
      key:,
      prompt:,
      seed: seed_for(key),
      file: key <> ".png",
      cached: fn() { store.closeup_url(store, key) },
      save: fn(url) { store.set_closeup(store, key, url, prompt) },
    )
  process.send(art, Request(job, True, notify))
}

/// The thing itself, centred and large; the room only as a blurred hint of
/// where it is, so its landmarks can't take over the picture.
pub fn closeup_prompt(room: Room, thing: Examinable) -> String {
  style
  <> ". Close-up of "
  <> strip_stop(thing.looks)
  <> ", centered, filling the frame, finely detailed. Softly blurred background: "
  <> room.name
  <> "."
}

/// A steady seed per key, so a redraw of the same thing looks the same.
fn seed_for(key: String) -> Int {
  key
  |> string.to_utf_codepoints
  |> list.fold(7, fn(h, c) {
    { h * 31 + string.utf_codepoint_to_int(c) } % 1_000_000
  })
}

// QUEUE -----------------------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Request(job, urgent, notify) ->
      case job.cached(), dict.get(state.waiting, job.key) {
        // Already drawn (perhaps ahead of time): hand it over.
        Some(url), _ -> {
          notify(url)
          state
        }
        // Being drawn or queued: wait for it, moving it up if now urgent.
        None, Ok(others) ->
          State(
            ..state,
            waiting: dict.insert(state.waiting, job.key, [notify, ..others]),
            // Urgent and only queued: move it up. Already being drawn:
            // leave the queue alone, or it would be drawn twice.
            queue: case
              urgent
              && state.drawing |> option.map(fn(d) { d.0 }) != Some(job.key)
            {
              True -> [
                job,
                ..list.filter(state.queue, fn(j) { j.key != job.key })
              ]
              False -> state.queue
            },
          )
        None, Error(Nil) ->
          State(
            ..state,
            waiting: dict.insert(state.waiting, job.key, [notify]),
            queue: case urgent {
              True -> [job, ..state.queue]
              False -> list.append(state.queue, [job])
            },
          )
          |> next
      }
      |> actor.continue
    Done(generation, _, _) if generation != state.generation ->
      actor.continue(state)
    Done(_, key, result) -> {
      let notifies = dict.get(state.waiting, key) |> result.unwrap([])
      case result {
        Ok(url) -> list.each(notifies, fn(n) { n(url) })
        Error(Nil) -> Nil
      }
      State(..state, waiting: dict.delete(state.waiting, key), drawing: None)
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
    None, [job, ..rest] -> {
      let State(self:, image_api:, art_dir:, generation:, ..) = state
      let pid =
        process.spawn_unlinked(fn() {
          let result =
            exception.rescue(fn() { draw(image_api, art_dir, job) })
            |> result.replace_error(Nil)
            |> result.flatten
          process.send(self, Done(generation, job.key, result))
        })
      State(..state, queue: rest, drawing: Some(#(job.key, pid)))
    }
  }
}

fn draw(image_api: String, art_dir: String, job: Job) -> Result(String, Nil) {
  logging.log(logging.Info, "drawing " <> job.key <> ": " <> job.prompt)
  let body =
    json.object([
      #("prompt", json.string(job.prompt)),
      #("seed", json.int(job.seed)),
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
      use _ <- result.try(
        simplifile.write_bits(art_dir <> "/" <> job.file, response.body)
        |> result.replace_error(Nil),
      )
      let url = "/art/" <> job.file
      job.save(url)
      Ok(url)
    }
    status -> {
      logging.log(
        logging.Warning,
        "image service answered " <> int.to_string(status) <> " for " <> job.key,
      )
      Error(Nil)
    }
  }
}

fn strip_stop(text: String) -> String {
  case string.ends_with(text, ".") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}
