//// inkmud server: open the world database (seeding it on first run), start
//// the world and art processes, then serve the client, room art and the
//// game websocket.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import logging
import mist.{type Connection, type ResponseData}
import server/art
import server/config.{type Config}
import server/llm
import server/session
import server/world/seed
import server/world/store
import server/world/world

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)
  let config = config.load()
  let store = store.open(config.db_path)
  let start_room = case store.room_count(store) {
    0 -> {
      logging.log(logging.Info, "new world: seeding Vellmoor")
      seed.run(store)
    }
    _ -> 1
  }
  let fast = llm.client(config.model, llm.Fast)
  let builder = llm.client(config.model, llm.Builder)
  let art_queue =
    art.start(store, fast, config.image_api_base_url, config.art_dir)
  let world = world.start(store, builder, art_queue)
  let deps =
    session.Deps(
      store:,
      world:,
      fast:,
      start_room:,
      dev_tools: config.dev_tools,
    )

  let assert Ok(_) =
    mist.new(fn(req) { route(req, config, deps) })
    |> mist.bind("0.0.0.0")
    |> mist.port(config.port)
    |> mist.after_start(fn(port, _, _) {
      logging.log(
        logging.Info,
        "inkmud listening on http://localhost:"
          <> int.to_string(port)
          <> " (text: "
          <> fast.model
          <> " / "
          <> builder.model
          <> ", images: "
          <> config.image_api_base_url
          <> ")"
          <> case config.dev_tools {
          True -> " — DEV TOOLS ON"
          False -> ""
        },
      )
    })
    |> mist.start
  process.sleep_forever()
}

fn route(
  req: Request(Connection),
  config: Config,
  deps: session.Deps,
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["ws"] -> session.handle(req, deps)
    [] -> file(config.static_dir <> "/index.html", "text/html; charset=utf-8")
    ["app.js"] -> file(config.static_dir <> "/app.js", "text/javascript")
    ["style.css"] -> file(config.static_dir <> "/style.css", "text/css")
    ["art", name] ->
      case safe_name(name) {
        True -> file(config.art_dir <> "/" <> name, "image/png")
        False -> not_found()
      }
    _ -> not_found()
  }
}

fn safe_name(name: String) -> Bool {
  string.ends_with(name, ".png")
  && !string.contains(name, "..")
  && list.all(string.to_graphemes(name), fn(g) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789-_.", g)
  })
}

fn file(path: String, content_type: String) -> Response(ResponseData) {
  case mist.send_file(path, offset: 0, limit: None) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_header("cache-control", "no-cache")
      |> response.set_body(body)
    Error(_) -> not_found()
  }
}

fn not_found() -> Response(ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
}
