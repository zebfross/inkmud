//// The browser client: a story log, the room's picture, clickable actions
//// and a command box, over one websocket.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import shared/protocol.{type RoomView, type ServerMsg}
import worldmap

// FFI -------------------------------------------------------------------------

pub type Socket

@external(javascript, "./client_ffi.mjs", "connect")
fn ffi_connect(
  on_open: fn(Socket) -> Nil,
  on_message: fn(String) -> Nil,
  on_close: fn() -> Nil,
) -> Nil

@external(javascript, "./client_ffi.mjs", "send")
fn ffi_send(socket: Socket, text: String) -> Nil

@external(javascript, "./client_ffi.mjs", "after")
fn ffi_after(ms: Int, callback: fn() -> Nil) -> Nil

@external(javascript, "./client_ffi.mjs", "scrollLog")
fn ffi_scroll_log() -> Nil

@external(javascript, "./client_ffi.mjs", "focusInput")
fn ffi_focus_input() -> Nil

@external(javascript, "./client_ffi.mjs", "deviceKey")
fn ffi_device_key() -> String

@external(javascript, "./client_ffi.mjs", "buzz")
fn ffi_buzz() -> Nil

@external(javascript, "./client_ffi.mjs", "focusElement")
fn ffi_focus(id: String) -> Nil

@external(javascript, "./client_ffi.mjs", "savedName")
fn ffi_saved_name() -> String

@external(javascript, "./client_ffi.mjs", "saveName")
fn ffi_save_name(name: String) -> Nil

@external(javascript, "./client_ffi.mjs", "forgetName")
fn ffi_forget_name() -> Nil

@external(javascript, "./client_ffi.mjs", "reload")
fn ffi_reload() -> Nil

// MODEL -----------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

type Kind {
  Heading
  Narration
  Social
  System
  Echo
  Waiting
}

type Entry {
  Entry(kind: Kind, text: String)
}

type Model {
  Model(
    socket: Option(Socket),
    /// Set once the server has welcomed us.
    name: Option(String),
    name_input: String,
    input: String,
    /// Most recent first.
    history: List(String),
    history_pos: Int,
    /// Most recent first, capped.
    log: List(Entry),
    room: Option(RoomView),
    inventory: List(String),
    /// The server allows developer actions.
    dev_tools: Bool,
    /// The Reset world button was clicked once; waiting for "Yes".
    confirming_reset: Bool,
    /// A name submitted before the connection opened, sent once it does.
    pending_name: Option(String),
    /// Logging back in with the name saved from last time (after a
    /// refresh): no name form, and a taken name is retried for a moment.
    signing_in: Bool,
    retries: Int,
    /// The map overlay, while open. `None` with `map_open` = waiting for it.
    map: Option(worldmap.State),
    map_open: Bool,
    /// Phone: the ⋯ sheet (leave, developer tools).
    more_open: Bool,
    /// Touch-and-hold on an exit: which one, and a token so a hold timer
    /// that fires after the finger lifted (or a newer press) is ignored.
    pressing: Option(protocol.ExitView),
    press_token: Int,
    /// The hold showed a glimpse: swallow the tap that follows lifting.
    held: Bool,
    /// This player connected again from another tab or window of this
    /// browser, which took over. Don't reconnect until asked.
    replaced: Bool,
    /// The way out being hovered or focused: its hint shows under the chips.
    glimpse: Option(protocol.ExitView),
  )
}

type Msg {
  Opened(Socket)
  Received(String)
  Closed
  Reconnect
  NameInput(String)
  SubmitName
  Input(String)
  Submit
  Run(String)
  Key(String)
  RetryLogin
  Leave
  OpenMap
  MapMsg(worldmap.Msg)
  PlayHere
  ToggleMore
  ExitTap(String)
  PressStart(protocol.ExitView)
  PressHeld(Int)
  PressEnd
  PressCancel
  Noop
  Glimpse(protocol.ExitView)
  Unglimpse
  AskReset
  CancelReset
  ConfirmReset
}

fn init(_) -> #(Model, Effect(Msg)) {
  let saved = string.trim(ffi_saved_name())
  #(
    Model(
      socket: None,
      name: None,
      name_input: saved,
      input: "",
      history: [],
      history_pos: -1,
      log: [],
      room: None,
      inventory: [],
      dev_tools: False,
      confirming_reset: False,
      pending_name: case saved {
        "" -> None
        name -> Some(name)
      },
      signing_in: saved != "",
      retries: 0,
      glimpse: None,
      map: None,
      map_open: False,
      more_open: False,
      pressing: None,
      press_token: 0,
      held: False,
      replaced: False,
    ),
    connect(),
  )
}

fn connect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    ffi_connect(
      fn(socket) { dispatch(Opened(socket)) },
      fn(text) { dispatch(Received(text)) },
      fn() { dispatch(Closed) },
    )
  })
}

// UPDATE ----------------------------------------------------------------------

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Opened(socket) -> {
      let model = Model(..model, socket: Some(socket))
      // Reconnected mid-game: log straight back in. Or a name was entered
      // while still connecting: send it now.
      case model.name, model.pending_name {
        Some(name), _ | None, Some(name) -> #(
          Model(..model, pending_name: None),
          send(model, protocol.Hello(name, ffi_device_key())),
        )
        None, None -> #(model, effect.none())
      }
    }
    Closed if model.replaced -> #(Model(..model, socket: None), effect.none())
    Closed -> #(
      add(
        Model(..model, socket: None),
        System,
        "Connection lost. Reconnecting…",
      ),
      effect.from(fn(dispatch) { ffi_after(2000, fn() { dispatch(Reconnect) }) }),
    )
    Reconnect -> #(model, connect())
    Received(text) ->
      case protocol.decode_server(text) {
        Ok(server_msg) -> receive(model, server_msg)
        Error(Nil) -> #(model, effect.none())
      }
    NameInput(value) -> #(Model(..model, name_input: value), effect.none())
    SubmitName ->
      case string.trim(model.name_input) {
        "" -> #(model, effect.none())
        name ->
          case model.socket {
            Some(_) -> #(
              model,
              send(model, protocol.Hello(name, ffi_device_key())),
            )
            None -> #(Model(..model, pending_name: Some(name)), effect.none())
          }
      }
    Input(value) -> #(Model(..model, input: value), effect.none())
    Submit ->
      case string.trim(model.input) {
        "" -> #(model, effect.none())
        command -> {
          let model =
            Model(
              ..model,
              input: "",
              history: [command, ..model.history],
              history_pos: -1,
            )
          run(model, command)
        }
      }
    Run(command) -> {
      let #(model, eff) = run(model, command)
      #(model, effect.batch([eff, effect.from(fn(_) { ffi_focus_input() })]))
    }
    Key("ArrowUp") -> recall(model, model.history_pos + 1)
    Key("ArrowDown") -> recall(model, model.history_pos - 1)
    Key(_) -> #(model, effect.none())
    PlayHere -> #(Model(..model, replaced: False), connect())
    ToggleMore -> #(Model(..model, more_open: !model.more_open), effect.none())
    Noop -> #(model, effect.none())
    ExitTap(direction) ->
      case model.held {
        // The tap at the end of a hold: it was a look, not a step.
        True -> #(Model(..model, held: False), effect.none())
        False -> {
          let #(model, eff) = run(model, "go " <> direction)
          #(
            model,
            effect.batch([eff, effect.from(fn(_) { ffi_focus_input() })]),
          )
        }
      }
    PressStart(exit) -> {
      let token = model.press_token + 1
      #(
        Model(..model, pressing: Some(exit), press_token: token, held: False),
        effect.from(fn(dispatch) {
          ffi_after(450, fn() { dispatch(PressHeld(token)) })
        }),
      )
    }
    PressHeld(token) ->
      case model.pressing, token == model.press_token {
        Some(exit), True -> #(
          Model(..model, glimpse: Some(exit), held: True),
          effect.from(fn(_) { ffi_buzz() }),
        )
        _, _ -> #(model, effect.none())
      }
    PressEnd -> #(Model(..model, pressing: None), effect.none())
    // The finger slid (scrolling the row of chips): no hold.
    PressCancel -> #(Model(..model, pressing: None), effect.none())
    OpenMap -> #(
      Model(..model, map_open: True),
      send(model, protocol.RequestMap),
    )
    MapMsg(worldmap.Close) -> #(
      Model(..model, map_open: False, map: None),
      effect.from(fn(_) { ffi_focus_input() }),
    )
    MapMsg(msg) -> #(
      Model(..model, map: option.map(model.map, worldmap.update(_, msg))),
      effect.none(),
    )
    RetryLogin -> #(
      Model(..model, retries: model.retries + 1),
      send(model, protocol.Hello(model.name_input, ffi_device_key())),
    )
    // Forget the saved name and start again at the name screen. Position and
    // inventory stay on the server under the old name.
    Leave -> {
      ffi_forget_name()
      ffi_reload()
      #(model, effect.none())
    }
    Glimpse(exit) -> #(Model(..model, glimpse: Some(exit)), effect.none())
    Unglimpse -> #(Model(..model, glimpse: None), effect.none())
    AskReset -> #(Model(..model, confirming_reset: True), effect.none())
    CancelReset -> #(Model(..model, confirming_reset: False), effect.none())
    ConfirmReset -> #(
      Model(..model, confirming_reset: False),
      send(model, protocol.ResetWorld),
    )
  }
}

fn run(model: Model, command: String) -> #(Model, Effect(Msg)) {
  #(
    add(model, Echo, command),
    effect.batch([send(model, protocol.Command(command)), scroll()]),
  )
}

fn recall(model: Model, pos: Int) -> #(Model, Effect(Msg)) {
  case pos < 0 {
    True -> #(Model(..model, input: "", history_pos: -1), effect.none())
    False ->
      case list.drop(model.history, pos) {
        [command, ..] -> #(
          Model(..model, input: command, history_pos: pos),
          effect.none(),
        )
        [] -> #(model, effect.none())
      }
  }
}

fn receive(model: Model, msg: ServerMsg) -> #(Model, Effect(Msg)) {
  case msg {
    protocol.Welcome(name, dev_tools) -> {
      ffi_save_name(name)
      #(
        Model(
          ..model,
          name: Some(name),
          dev_tools:,
          signing_in: False,
          retries: 0,
        ),
        effect.from(fn(_) { ffi_focus_input() }),
      )
    }
    // Right after a refresh the old connection may not have closed yet, so
    // the server still sees this name online: try again shortly.
    protocol.NameTaken(_) if model.signing_in && model.retries < 4 -> #(
      model,
      effect.from(fn(dispatch) {
        ffi_after(1500, fn() { dispatch(RetryLogin) })
      }),
    )
    protocol.NameTaken(name) -> #(
      add(
        Model(..model, signing_in: False, retries: 0),
        System,
        "Someone named " <> name <> " is already wandering the fog.",
      ),
      effect.none(),
    )
    protocol.Replaced -> #(
      Model(..model, replaced: True, map: None, map_open: False),
      effect.none(),
    )
    protocol.Map(view) ->
      case model.map_open {
        False -> #(model, effect.none())
        True -> {
          let first = option.is_none(model.map)
          #(
            Model(
              ..model,
              map: Some(case model.map {
                Some(state) -> worldmap.refresh(state, view)
                None -> worldmap.init(view)
              }),
            ),
            case first {
              True -> effect.after_paint(fn(_, _) { ffi_focus("map") })
              False -> effect.none()
            },
          )
        }
      }
    // Everything on screen belonged to the old world.
    protocol.WorldReset -> #(
      Model(
        ..model,
        log: [],
        room: None,
        inventory: [],
        history_pos: -1,
        map: None,
        map_open: False,
      ),
      effect.none(),
    )
    protocol.Room(room) -> {
      let new_room = case model.room {
        Some(old) -> old.id != room.id
        None -> True
      }
      let model = case new_room {
        True ->
          add(Model(..clear_waiting(model), glimpse: None), Heading, room.name)
        False -> model
      }
      // Keep art we already have if this view was sent before it arrived.
      let room = case room.art, model.room {
        None, Some(old) if old.id == room.id ->
          protocol.RoomView(..room, art: old.art)
        _, _ -> room
      }
      let follow = case new_room && model.map_open {
        True -> send(model, protocol.RequestMap)
        False -> effect.none()
      }
      #(Model(..model, room: Some(room)), effect.batch([scroll(), follow]))
    }
    protocol.Line(tone, text) -> {
      let kind = case tone {
        protocol.Narration -> Narration
        protocol.Social -> Social
        protocol.System -> System
      }
      #(add(model, kind, text), scroll())
    }
    protocol.Art(room_id, url) ->
      case model.room {
        Some(room) if room.id == room_id -> #(
          Model(..model, room: Some(protocol.RoomView(..room, art: Some(url)))),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }
    protocol.Busy(text) -> #(add(model, Waiting, text), scroll())
    protocol.Inventory(items) -> #(
      Model(..model, inventory: items),
      effect.none(),
    )
  }
}

fn add(model: Model, kind: Kind, text: String) -> Model {
  Model(..model, log: list.take([Entry(kind, text), ..model.log], 400))
}

fn clear_waiting(model: Model) -> Model {
  Model(..model, log: list.filter(model.log, fn(e) { e.kind != Waiting }))
}

fn send(model: Model, msg: protocol.ClientMsg) -> Effect(Msg) {
  case model.socket {
    Some(socket) ->
      effect.from(fn(_) { ffi_send(socket, protocol.encode_client(msg)) })
    None -> effect.none()
  }
}

fn scroll() -> Effect(Msg) {
  effect.after_paint(fn(_, _) { ffi_scroll_log() })
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  use <- bool_guard(model.replaced, fn() {
    html.main([class("login")], [
      html.h1([], [text("Vellmoor")]),
      html.p([class("tagline")], [
        text("You're playing in another window or tab."),
      ]),
      html.button([class("chip play-here"), event.on_click(PlayHere)], [
        text("Play here instead"),
      ]),
    ])
  })
  case model.name {
    None -> view_login(model)
    Some(_) -> view_game(model)
  }
}

fn view_login(model: Model) -> Element(Msg) {
  use <- bool_guard(model.signing_in, fn() {
    html.main([class("login")], [
      html.h1([], [text("Vellmoor")]),
      html.p([class("tagline")], [text("Returning to the fog…")]),
    ])
  })
  html.main([class("login")], [
    html.h1([], [text("Vellmoor")]),
    html.p([class("tagline")], [
      text("A city of lanterns and fog, written as you walk it."),
    ]),
    html.form([class("login-form"), event.on_submit(fn(_) { SubmitName })], [
      html.input([
        attribute.placeholder("Your name"),
        attribute.value(model.name_input),
        attribute.autofocus(True),
        attribute.autocomplete("off"),
        event.on_input(NameInput),
      ]),
      html.button([attribute.disabled(option.is_none(model.socket))], [
        text(case model.socket {
          Some(_) -> "Enter the fog"
          None -> "Connecting…"
        }),
      ]),
    ]),
    view_log_entries(
      list.filter(model.log, fn(e) { e.kind == System }) |> list.take(1),
    ),
  ])
}

fn bool_guard(when: Bool, then: fn() -> a, otherwise: fn() -> a) -> a {
  case when {
    True -> then()
    False -> otherwise()
  }
}

/// One set of elements, arranged by CSS: on a wide screen the picture and
/// actions sit beside the story; on a phone the picture is a banner (that
/// shrinks while typing), the story fills the middle, and the actions and
/// command box are pinned to the bottom, above the keyboard.
fn view_game(model: Model) -> Element(Msg) {
  html.main([class("game")], [
    case model.map {
      Some(state) -> element.map(worldmap.view(state), MapMsg)
      None -> element.none()
    },
    view_art(model.room),
    view_actions(model),
    // Phone: a held glimpse floats above the action row (inside the row it
    // would be clipped by its sideways scrolling).
    case model.glimpse {
      Some(e) ->
        html.p([class("glimpse-float")], [
          html.span([class("glimpse-dir")], [text(e.direction)]),
          text(e.hint),
        ])
      None -> element.none()
    },
    html.div([attribute.id("log"), class("log")], [
      view_log_entries(model.log),
    ]),
    html.form([class("prompt"), event.on_submit(fn(_) { Submit })], [
      html.span([class("caret")], [text("›")]),
      html.input([
        attribute.id("command"),
        attribute.placeholder("What do you do?"),
        attribute.value(model.input),
        attribute.autocomplete("off"),
        attribute.attribute("autocapitalize", "off"),
        attribute.attribute("enterkeyhint", "send"),
        event.on_input(Input),
        event.on_keydown(Key),
      ]),
      html.button([class("send"), attribute.title("Send")], [text("↵")]),
    ]),
    case model.more_open {
      True -> view_more_sheet(model)
      False -> element.none()
    },
  ])
}

fn view_art(room: Option(RoomView)) -> Element(Msg) {
  html.figure([class("art")], [
    case room {
      Some(protocol.RoomView(art: Some(url), name:, ..)) ->
        html.img([attribute.src(url), attribute.alt(name), class("picture")])
      _ ->
        html.div([class("picture pending")], [text("the ink is still drying…")])
    },
    case room {
      Some(r) ->
        html.figcaption([], [
          html.div([class("place")], [
            html.span([class("region")], [text(r.region)]),
            html.span([class("place-name")], [text(r.name)]),
          ]),
          html.div([class("caption-buttons")], [
            html.button(
              [
                class("chip map-button"),
                attribute.title("Open your map"),
                event.on_click(OpenMap),
              ],
              [text("Map")],
            ),
            html.button(
              [
                class("chip more-button"),
                attribute.title("More"),
                attribute.attribute("aria-label", "More"),
                event.on_click(ToggleMore),
              ],
              [text("⋯")],
            ),
          ]),
        ])
      None -> element.none()
    },
  ])
}

fn view_actions(model: Model) -> Element(Msg) {
  case model.room {
    None -> element.none()
    Some(room) ->
      html.div([class("actions")], [
        view_exits(room.exits, model.glimpse),
        group(
          "Here",
          list.map(room.items, fn(i) { chip("take " <> i, "take " <> i, "") }),
        ),
        group(
          "Carrying",
          list.map(model.inventory, fn(i) {
            chip(i, "examine " <> i, "Click to examine")
          }),
        ),
        group(
          "Also here",
          list.map(room.others, fn(p) {
            html.span([class("person")], [text(p)])
          }),
        ),
        // On a phone these live in the ⋯ sheet instead.
        html.div([class("wide-only")], [
          html.div([class("group leave")], [
            html.button([class("link"), event.on_click(Leave)], [
              text("Leave Vellmoor (change name)"),
            ]),
          ]),
          view_dev_tools(model),
        ]),
      ])
  }
}

/// Phone: the things that don't earn a place on screen all the time.
fn view_more_sheet(model: Model) -> Element(Msg) {
  html.div([class("sheet-backdrop"), event.on_click(ToggleMore)], [
    html.div([class("sheet"), event.on_click(Noop) |> event.stop_propagation], [
      html.button([class("chip"), event.on_click(Leave)], [
        text("Leave Vellmoor (change name)"),
      ]),
      view_dev_tools(model),
      html.button([class("link"), event.on_click(ToggleMore)], [
        text("Close"),
      ]),
    ]),
  ])
}

fn view_dev_tools(model: Model) -> Element(Msg) {
  case model.dev_tools, model.confirming_reset {
    False, _ -> element.none()
    True, False ->
      html.div([class("group dev")], [
        html.h3([], [text("Developer")]),
        html.button([class("chip danger"), event.on_click(AskReset)], [
          text("Reset world"),
        ]),
      ])
    True, True ->
      html.div([class("group dev")], [
        html.h3([], [text("Developer")]),
        html.p([class("dev-warning")], [
          text(
            "Delete every room, picture and player position, and rebuild the city from its first room?",
          ),
        ]),
        html.div([class("chips")], [
          html.button([class("chip danger"), event.on_click(ConfirmReset)], [
            text("Yes, reset"),
          ]),
          html.button([class("chip"), event.on_click(CancelReset)], [
            text("Cancel"),
          ]),
        ]),
      ])
  }
}

/// Exit chips, and beneath them a glimpse along one: looking without going.
/// With a mouse, hover (or keyboard focus) glimpses; on a touch screen,
/// press and hold. A tap or click goes.
fn view_exits(
  exits: List(protocol.ExitView),
  glimpse: Option(protocol.ExitView),
) -> Element(Msg) {
  case exits {
    [] -> element.none()
    _ ->
      html.div([class("group exits")], [
        html.h3([], [text("Ways out")]),
        html.div(
          [class("chips")],
          list.map(exits, fn(e) {
            html.button(
              [
                class("chip exit"),
                attribute.attribute("aria-description", e.hint),
                event.on_click(ExitTap(e.direction)),
                event.on("mouseenter", decode.success(Glimpse(e))),
                event.on("focus", decode.success(Glimpse(e))),
                event.on("mouseleave", decode.success(Unglimpse)),
                event.on("blur", decode.success(Unglimpse)),
                event.on("touchstart", decode.success(PressStart(e))),
                event.on("touchend", decode.success(PressEnd)),
                event.on("touchmove", decode.success(PressCancel)),
                event.on("contextmenu", decode.success(Noop))
                  |> event.prevent_default,
              ],
              [
                html.span([class("arrow")], [text(arrow(e.direction))]),
                text(e.direction),
              ],
            )
          }),
        ),
        case glimpse {
          Some(e) ->
            html.p([class("glimpse")], [
              html.span([class("glimpse-dir")], [text(e.direction)]),
              text(e.hint),
            ])
          None ->
            html.p([class("glimpse idle")], [
              html.span([class("for-mouse")], [
                text("Hover a way out to glimpse it, or type “look north”."),
              ]),
              html.span([class("for-touch")], [
                text("Hold a way out to glimpse it."),
              ]),
            ])
        },
      ])
  }
}

fn arrow(direction: String) -> String {
  case direction {
    "north" -> "↑"
    "south" -> "↓"
    "east" -> "→"
    "west" -> "←"
    "up" -> "⤒"
    "down" -> "⤓"
    _ -> "•"
  }
}

fn group(title: String, children: List(Element(Msg))) -> Element(Msg) {
  case children {
    [] -> element.none()
    _ ->
      html.div([class("group")], [
        html.h3([], [text(title)]),
        html.div([class("chips")], children),
      ])
  }
}

fn chip(label: String, command: String, hint: String) -> Element(Msg) {
  html.button(
    [class("chip"), attribute.title(hint), event.on_click(Run(command))],
    [text(label)],
  )
}

fn view_log_entries(entries: List(Entry)) -> Element(Msg) {
  element.fragment(
    entries
    |> list.reverse
    |> list.map(fn(entry) {
      case entry.kind {
        Heading -> html.h2([class("entry heading")], [text(entry.text)])
        Narration -> html.p([class("entry narration")], [text(entry.text)])
        Social -> html.p([class("entry social")], [text(entry.text)])
        System -> html.p([class("entry system")], [text(entry.text)])
        Echo -> html.p([class("entry echo")], [text("› " <> entry.text)])
        Waiting -> html.p([class("entry waiting")], [text(entry.text)])
      }
    }),
  )
}
