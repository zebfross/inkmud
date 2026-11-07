//// The browser client: a story log, the room's picture, clickable actions
//// and a command box, over one websocket.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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

@external(javascript, "./client_ffi.mjs", "showScene")
fn ffi_show_scene() -> Nil

@external(javascript, "./client_ffi.mjs", "revealLatest")
fn ffi_reveal_latest() -> Nil

@external(javascript, "./client_ffi.mjs", "now")
fn ffi_now() -> String

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
  /// A close-up of something examined: the picture's URL; the entry's text
  /// is what it shows.
  Picture(url: String)
}

/// `at`: when it happened, "23:41".
type Entry {
  Entry(kind: Kind, text: String, at: String)
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
    inventory: List(protocol.ItemView),
    /// Wounds taken, of the most a player can take.
    wounds: Int,
    max_wounds: Int,
    /// The full history, opened on demand (the screen shows the latest).
    journal_open: Bool,
    /// Just moved (or moving): the new room's picture is what to show, so
    /// its description arriving doesn't pull the page down to the text.
    on_the_move: Bool,
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
    /// The "something feels off" note box, while open, and its text.
    feedback: Option(String),
    /// Dev only: the "how this room was made" panel.
    debug_open: Bool,
    debug: Option(protocol.DebugView),
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
  ToggleJournal
  OpenDebug
  CloseDebug
  DebugKey(String)
  ToggleMore
  OpenFeedback
  CloseFeedback
  FeedbackInput(String)
  SendFeedback
  ExitTap(String)
  PressStart(protocol.ExitView)
  PressHeld(Int)
  PressEnd
  PressCancel
  Scrolled
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
      wounds: 0,
      max_wounds: 3,
      journal_open: False,
      on_the_move: False,
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
      feedback: None,
      debug_open: False,
      debug: None,
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
    ToggleJournal -> {
      let open = !model.journal_open
      #(Model(..model, journal_open: open, more_open: False), case open {
        True -> scroll()
        False -> effect.none()
      })
    }
    OpenDebug ->
      case model.room {
        Some(room) -> #(
          Model(..model, debug_open: True, more_open: False),
          send(model, protocol.RequestDebug(room.id)),
        )
        None -> #(model, effect.none())
      }
    CloseDebug -> #(
      Model(..model, debug_open: False, debug: None),
      effect.none(),
    )
    DebugKey("Escape") -> #(
      Model(..model, debug_open: False, debug: None),
      effect.none(),
    )
    DebugKey(_) -> #(model, effect.none())
    ToggleMore -> #(Model(..model, more_open: !model.more_open), effect.none())
    OpenFeedback -> #(
      Model(..model, feedback: Some(""), more_open: False),
      effect.after_paint(fn(_, _) { ffi_focus("feedback-text") }),
    )
    CloseFeedback -> #(Model(..model, feedback: None), effect.none())
    FeedbackInput(text) -> #(
      Model(..model, feedback: Some(text)),
      effect.none(),
    )
    SendFeedback ->
      case model.feedback {
        Some(note) ->
          case string.trim(note) {
            "" -> #(model, effect.none())
            _ -> #(
              Model(..model, feedback: None),
              send(model, protocol.Feedback(note, feedback_context(model))),
            )
          }
        None -> #(model, effect.none())
      }
    Noop -> #(model, effect.none())
    Scrolled -> #(model, follow_text(model))
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
  let model = Model(..add(model, Echo, command), on_the_move: is_move(command))
  #(
    model,
    effect.batch([send(model, protocol.Command(command)), follow_text(model)]),
  )
}

fn is_move(command: String) -> Bool {
  let c = string.lowercase(string.trim(command))
  list.contains(
    [
      "n",
      "s",
      "e",
      "w",
      "u",
      "d",
      "north",
      "south",
      "east",
      "west",
      "up",
      "down",
    ],
    c,
  )
  || string.starts_with(c, "go ")
}

/// After new text: keep the journal at its newest, and bring the newest
/// chronicle entry into view, unless the player is moving, when the new
/// room's picture is what they should see.
fn follow_text(model: Model) -> Effect(Msg) {
  case model.on_the_move {
    True -> effect.after_paint(fn(_, _) { ffi_scroll_log() })
    False -> scroll()
  }
}

/// Bring the scene (the new room's picture) into view.
fn show_scene() -> Effect(Msg) {
  effect.after_paint(fn(_, _) { ffi_show_scene() })
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
    protocol.Debug(view) ->
      case model.debug_open {
        True -> #(
          Model(..model, debug: Some(view)),
          effect.after_paint(fn(_, _) { ffi_focus("debug") }),
        )
        False -> #(model, effect.none())
      }
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
      let follow =
        effect.batch([
          case new_room && model.map_open {
            True -> send(model, protocol.RequestMap)
            False -> effect.none()
          },
          case new_room && model.debug_open {
            True -> send(model, protocol.RequestDebug(room.id))
            False -> effect.none()
          },
        ])
      // A new room: show its picture, and hold the text where it is (its
      // description is right under the picture) until the next command.
      case new_room {
        True -> #(
          Model(..model, room: Some(room), on_the_move: True),
          effect.batch([show_scene(), follow]),
        )
        False -> #(Model(..model, room: Some(room)), follow)
      }
    }
    protocol.Line(tone, text) -> {
      let kind = case tone {
        protocol.Narration -> Narration
        protocol.Social -> Social
        protocol.System -> System
      }
      let model = add(model, kind, text)
      #(model, follow_text(model))
    }
    protocol.Art(room_id, url) ->
      case model.room {
        Some(room) if room.id == room_id -> #(
          Model(..model, room: Some(protocol.RoomView(..room, art: Some(url)))),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }
    protocol.Busy(text) -> {
      let model = add(model, Waiting, text)
      #(model, follow_text(model))
    }
    protocol.Closeup(name, url) -> {
      let model = add(model, Picture(url), name)
      #(model, follow_text(model))
    }
    protocol.Inventory(items) -> #(
      Model(..model, inventory: items),
      effect.none(),
    )
    protocol.Health(wounds, max) -> #(
      Model(..model, wounds:, max_wounds: max),
      effect.none(),
    )
  }
}

fn add(model: Model, kind: Kind, text: String) -> Model {
  Model(
    ..model,
    log: list.take([Entry(kind, text, ffi_now()), ..model.log], 400),
  )
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
  effect.after_paint(fn(_, _) {
    ffi_scroll_log()
    ffi_reveal_latest()
  })
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
    // The latest system message (a name already in use, say).
    case list.find(model.log, fn(e) { e.kind == System }) {
      Ok(entry) -> html.p([class("login-message")], [text(entry.text)])
      Error(Nil) -> element.none()
    },
  ])
}

fn bool_guard(when: Bool, then: fn() -> a, otherwise: fn() -> a) -> a {
  case when {
    True -> then()
    False -> otherwise()
  }
}

/// The game screen (after the Stitch "Blackfriars Wynd" design): a top bar
/// and the place's name; the scene with its ways out labelled on it; the
/// chronicle of what just happened (newest largest, full history in the
/// journal); who and what is here; a compass, the satchel and a glimpse
/// along a way out; and the command line. On a phone the panels stack, with
/// tabs at the bottom to jump between them.
fn view_game(model: Model) -> Element(Msg) {
  html.div([class("shell")], [
    case model.map {
      Some(state) -> element.map(worldmap.view(state), MapMsg)
      None -> element.none()
    },
    view_topbar(model),
    case model.room {
      None ->
        html.main([class("board")], [
          html.p([class("waiting-room")], [
            text("Finding your way through the fog…"),
          ]),
        ])
      Some(room) ->
        html.main([class("board")], [
          html.div([class("columns")], [
            html.div([class("main-col")], [
              view_scene(room),
              view_encounter(model, room),
              view_chronicle(model),
              view_souls(room),
              view_curios(room),
            ]),
            html.aside([class("side-col")], [
              view_compass(room),
              view_satchel(model),
              view_glimpse(model),
              html.div([class("wide-only")], [view_dev_tools(model)]),
            ]),
          ]),
        ])
    },
    view_commandbar(model),
    view_tabs(),
    case model.journal_open {
      True -> view_journal(model)
      False -> element.none()
    },
    case model.more_open {
      True -> view_more_sheet(model)
      False -> element.none()
    },
    case model.feedback {
      Some(note) -> view_feedback(note)
      None -> element.none()
    },
    case model.debug_open, model.debug {
      True, Some(debug) -> view_debug(debug)
      _, _ -> element.none()
    },
  ])
}

/// A Material Symbols glyph.
fn icon(name: String) -> Element(Msg) {
  html.span([class("icon"), attribute.attribute("aria-hidden", "true")], [
    text(name),
  ])
}

fn icon_button(glyph: String, label: String, msg: Msg) -> Element(Msg) {
  html.button(
    [
      class("icon-button"),
      attribute.title(label),
      attribute.attribute("aria-label", label),
      event.on_click(msg),
    ],
    [icon(glyph)],
  )
}

fn view_topbar(model: Model) -> Element(Msg) {
  let name = option.unwrap(model.name, "")
  html.header([class("topbar")], [
    html.div([class("brand")], [
      html.span([class("brand-mark")], [icon("local_fire_department")]),
      html.div([class("brand-text")], [
        html.span([class("brand-name")], [text("Vellmoor")]),
        html.span([class("brand-sub")], [text("a city of gaslight and fog")]),
      ]),
    ]),
    case model.room {
      Some(room) ->
        html.div([class("place-pill")], [icon("explore"), text(room.name)])
      None -> element.none()
    },
    html.div([class("topbar-right")], [
      view_health(model),
      view_lantern_gauge(model),
      icon_button("map", "Map", OpenMap),
      icon_button("history_edu", "Journal", ToggleJournal),
      icon_button("rate_review", "Feedback", OpenFeedback),
      icon_button("more_horiz", "More", ToggleMore),
      html.div([class("player")], [
        html.span([class("player-name")], [text(name)]),
        html.span([class("avatar")], [text(string.slice(name, 0, 1))]),
      ]),
    ]),
  ])
}

/// The carried lantern's oil, if there is one.
/// Hearts: one per wound you can still take.
fn view_health(model: Model) -> Element(Msg) {
  let left = int.max(0, model.max_wounds - model.wounds)
  html.div(
    [
      class(case model.wounds {
        0 -> "health"
        _ -> "health hurt"
      }),
      attribute.title(case model.wounds {
        0 -> "Unhurt"
        n ->
          int.to_string(n)
          <> " of "
          <> int.to_string(model.max_wounds)
          <> " wounds: rest at the Lantern Crossroads, or they heal slowly"
      }),
    ],
    list.append(
      list.repeat(html.span([class("heart full")], [icon("favorite")]), left),
      list.repeat(
        html.span([class("heart empty")], [icon("heart_broken")]),
        model.max_wounds - left,
      ),
    ),
  )
}

/// A creature in the way: what it is, how much fight it has left, and
/// what you can do about it.
fn view_encounter(model: Model, room: RoomView) -> Element(Msg) {
  case room.foe {
    None -> element.none()
    Some(foe) -> {
      let has_light =
        list.any(model.inventory, fn(i) {
          i.role == "light" && i.note != "out of oil"
        })
      html.section([class("card encounter"), attribute.id("encounter")], [
        html.div([class("encounter-picture")], [
          case foe.art {
            Some(url) -> html.img([attribute.src(url), attribute.alt(foe.name)])
            None -> html.span([class("encounter-glyph")], [icon("pets")])
          },
        ]),
        html.div([class("encounter-body")], [
          html.div([class("card-head")], [
            html.h2([], [icon("swords"), text(foe.name)]),
            html.span(
              [class("pips"), attribute.title("How much fight it has left")],
              list.append(
                list.repeat(html.span([class("pip on")], []), foe.left),
                list.repeat(
                  html.span([class("pip")], []),
                  foe.strength - foe.left,
                ),
              ),
            ),
          ]),
          html.p([class("encounter-line")], [text(foe.line)]),
          html.div([class("encounter-actions")], [
            html.button(
              [class("action primary"), event.on_click(Run("fight"))],
              [
                icon("swords"),
                text("Fight"),
              ],
            ),
            html.button([class("action"), event.on_click(Run("flee"))], [
              icon("directions_run"),
              text("Flee"),
            ]),
            case has_light {
              True ->
                html.button(
                  [
                    class(case foe.fears_light {
                      True -> "action light-hint"
                      False -> "action"
                    }),
                    event.on_click(Run("raise lantern")),
                  ],
                  [icon("wb_incandescent"), text("Raise lantern")],
                )
              False -> element.none()
            },
          ]),
        ]),
      ])
    }
  }
}

fn view_lantern_gauge(model: Model) -> Element(Msg) {
  case list.find(model.inventory, fn(i) { i.role == "light" }) {
    Error(Nil) -> element.none()
    Ok(light) -> {
      let oil = case string.split(light.note, " ") {
        ["oil", n] -> int.parse(n) |> result.unwrap(0)
        _ -> 0
      }
      let pct = int.min(100, oil * 100 / 30)
      html.div(
        [class("gauge"), attribute.title(light.name <> ": " <> light.note)],
        [
          icon("wb_incandescent"),
          html.span([class("gauge-label")], [text("Lantern")]),
          html.span([class("gauge-track")], [
            html.span(
              [
                class("gauge-fill"),
                attribute.styles([#("width", int.to_string(pct) <> "%")]),
              ],
              [],
            ),
          ]),
          html.span([class("gauge-value")], [text(int.to_string(oil))]),
        ],
      )
    }
  }
}

/// The picture, with the ways out labelled where they lead: north at the
/// top, east at the right, and so on. A label goes that way.
fn view_scene(room: RoomView) -> Element(Msg) {
  html.section([class("card scene"), attribute.id("scene")], [
    html.div([class("scene-frame")], [
      case room.dark, room.art {
        True, _ -> html.div([class("scene-picture dark")], [text("pitch dark")])
        // The whole (square) picture, with a blurred copy filling the frame.
        False, Some(url) ->
          element.fragment([
            html.div(
              [
                class("scene-backdrop"),
                attribute.styles([#("background-image", "url(" <> url <> ")")]),
              ],
              [],
            ),
            html.img([
              attribute.src(url),
              attribute.alt(room.name),
              class("scene-picture"),
            ]),
          ])
        False, None ->
          html.div([class("scene-picture pending")], [
            text("the ink is still drying…"),
          ])
      },
      html.div([class("scene-vignette")], []),
      html.div([class("scene-tag")], [icon("location_on"), text(room.region)]),
      element.fragment(
        list.map(room.exits, fn(e) {
          html.button(
            [
              class("scene-label at-" <> e.direction),
              attribute.title(e.hint),
              event.on_click(ExitTap(e.direction)),
              event.on("mouseenter", decode.success(Glimpse(e))),
              event.on("mouseleave", decode.success(Unglimpse)),
            ],
            [
              icon(case e.lock, e.obstacle {
                Some(_), _ -> "lock"
                None, Some(_) -> "construction"
                None, None -> compass_glyph(e.direction)
              }),
              text(e.direction),
            ],
          )
        }),
      ),
    ]),
  ])
}

fn compass_glyph(direction: String) -> String {
  case direction {
    "north" -> "north"
    "south" -> "south"
    "east" -> "east"
    "west" -> "west"
    "up" -> "stairs"
    _ -> "stairs_2"
  }
}

/// What just happened, newest at the top so it's always in view: your last
/// command and its answer (large), then the turns before it (smaller). Each
/// turn reads top to bottom from the command. Each entry has its time; the
/// full history is in the journal.
fn view_chronicle(model: Model) -> Element(Msg) {
  let #(latest, earlier) = case turns(model.log, [], []) {
    [] -> #([], [])
    [latest, ..earlier] -> #(latest, list.flatten(earlier) |> list.take(6))
  }
  html.section([class("card chronicle")], [
    html.div([class("card-head")], [
      html.h2([], [icon("history_edu"), text("Chronicle")]),
      html.button([class("link-button"), event.on_click(ToggleJournal)], [
        text("Journal"),
        icon("chevron_right"),
      ]),
    ]),
    html.div([class("chronicle-feed")], [
      html.div(
        [class("chronicle-latest")],
        list.map(latest, fn(entry) {
          view_entry(entry, case entry.kind {
            Echo -> "earlier"
            _ -> "latest"
          })
        }),
      ),
      case earlier {
        [] -> element.none()
        _ ->
          html.div(
            [class("chronicle-earlier")],
            list.map(earlier, view_entry(_, "earlier")),
          )
      },
    ]),
  ])
}

/// The newest-first log as turns, newest turn first: each turn is a command
/// you typed and what followed it, in the order it happened.
fn turns(
  log: List(Entry),
  turn: List(Entry),
  done: List(List(Entry)),
) -> List(List(Entry)) {
  case log {
    [] ->
      case turn {
        [] -> list.reverse(done)
        _ -> list.reverse([turn, ..done])
      }
    [Entry(kind: Echo, ..) as entry, ..rest] ->
      turns(rest, [], [[entry, ..turn], ..done])
    [entry, ..rest] -> turns(rest, [entry, ..turn], done)
  }
}

fn view_entry(entry: Entry, emphasis: String) -> Element(Msg) {
  let time = html.span([class("entry-time")], [text(entry.at)])
  case entry.kind {
    Heading ->
      html.div([class("entry heading " <> emphasis)], [
        time,
        html.span([class("entry-text")], [text("— " <> entry.text <> " —")]),
      ])
    Picture(url) ->
      html.div([class("entry picture " <> emphasis)], [
        time,
        html.figure([class("closeup")], [
          html.img([
            attribute.src(url),
            attribute.alt(entry.text),
            event.on("load", decode.success(Scrolled)),
          ]),
          html.figcaption([], [text(entry.text)]),
        ]),
      ])
    _ -> {
      let kind = case entry.kind {
        Narration -> "narration"
        Social -> "social"
        System -> "system"
        Echo -> "echo"
        Waiting -> "waiting"
        _ -> ""
      }
      let body = case entry.kind {
        Echo -> "› " <> entry.text
        _ -> entry.text
      }
      html.div([class("entry " <> kind <> " " <> emphasis)], [
        time,
        html.span([class("entry-text")], [text(body)]),
      ])
    }
  }
}

fn view_souls(room: RoomView) -> Element(Msg) {
  case room.others {
    [] -> element.none()
    others ->
      html.section([class("card souls")], [
        html.div([class("card-head")], [
          html.h2([], [icon("groups"), text("Souls here")]),
          html.span([class("count")], [
            text(int.to_string(list.length(others)) <> " present"),
          ]),
        ]),
        html.div(
          [class("tiles")],
          list.map(others, fn(other) {
            html.div([class("tile")], [
              html.div([class("tile-head")], [
                html.span([class("tile-icon")], [icon("person")]),
                html.span([class("tile-name")], [text(other)]),
              ]),
              html.div([class("tile-actions")], [
                html.button(
                  [
                    class("action"),
                    event.on_click(Run("say Hail, " <> other <> "!")),
                  ],
                  [text("Hail")],
                ),
              ]),
            ])
          }),
        ),
      ])
  }
}

fn view_curios(room: RoomView) -> Element(Msg) {
  case room.items, room.dark {
    [], _ | _, True -> element.none()
    items, False ->
      html.section([class("card curios")], [
        html.div([class("card-head")], [
          html.h2([], [icon("widgets"), text("Curios here")]),
          html.span([class("count")], [
            text(
              int.to_string(list.length(items))
              <> case items {
                [_] -> " item"
                _ -> " items"
              },
            ),
          ]),
        ]),
        html.div(
          [class("tiles")],
          list.map(items, fn(item) {
            html.div([class("tile")], [
              html.div([class("tile-head")], [
                html.span([class("tile-icon role-" <> item.role)], [
                  icon(role_glyph(item.role)),
                ]),
                html.span([class("tile-name")], [text(item.name)]),
                html.span([class("badge role-" <> item.role)], [
                  text(item.note),
                ]),
              ]),
              html.div([class("tile-actions")], [
                html.button(
                  [
                    class("action"),
                    event.on_click(Run("examine " <> item.name)),
                  ],
                  [text("Inspect")],
                ),
                html.button(
                  [
                    class("action primary"),
                    event.on_click(Run("take " <> item.name)),
                  ],
                  [icon("pan_tool"), text("Take")],
                ),
              ]),
            ])
          }),
        ),
      ])
  }
}

fn role_glyph(role: String) -> String {
  case role {
    "key" -> "key"
    "light" -> "wb_incandescent"
    "fuel" -> "oil_barrel"
    "tool" -> "construction"
    "map" -> "map"
    "treasure" -> "diamond"
    _ -> "category"
  }
}

/// The compass: north, east, south and west around a hub; up and down
/// beside it, with whether each is open, locked or blocked.
fn view_compass(room: RoomView) -> Element(Msg) {
  let find = fn(d) { list.find(room.exits, fn(e) { e.direction == d }) }
  let point = fn(d: String, letter: String) {
    case find(d) {
      Ok(e) ->
        html.button(
          [
            class(
              "point at-"
              <> d
              <> case e.lock, e.obstacle {
                Some(_), _ -> " barred"
                None, Some(_) -> " barred"
                None, None -> ""
              },
            ),
            attribute.title(e.hint),
            event.on_click(ExitTap(d)),
            event.on("mouseenter", decode.success(Glimpse(e))),
            event.on("mouseleave", decode.success(Unglimpse)),
            event.on("focus", decode.success(Glimpse(e))),
            event.on("blur", decode.success(Unglimpse)),
            event.on("touchstart", decode.success(PressStart(e))),
            event.on("touchend", decode.success(PressEnd)),
            event.on("touchmove", decode.success(PressCancel)),
          ],
          [text(letter)],
        )
      Error(Nil) -> html.span([class("point none at-" <> d)], [text(letter)])
    }
  }
  let rise = fn(d: String, label: String) {
    case find(d) {
      Ok(e) -> {
        let #(state, word) = case e.lock, e.obstacle {
          Some(_), _ -> #("locked", "Locked")
          None, Some(_) -> #("blocked", "Blocked")
          None, None -> #("open", "Open")
        }
        html.button(
          [
            class("rise"),
            attribute.title(e.hint),
            event.on_click(ExitTap(d)),
            event.on("mouseenter", decode.success(Glimpse(e))),
            event.on("mouseleave", decode.success(Unglimpse)),
          ],
          [
            icon(compass_glyph(d)),
            html.span([class("rise-label")], [text(label)]),
            html.span([class("state " <> state)], [text(word)]),
          ],
        )
      }
      Error(Nil) ->
        html.span([class("rise none")], [
          icon(compass_glyph(d)),
          html.span([class("rise-label")], [text(label)]),
          html.span([class("state")], [text("—")]),
        ])
    }
  }
  html.section([class("card compass"), attribute.id("compass")], [
    html.div([class("card-head")], [
      html.h2([], [icon("explore"), text("Ways out")]),
      html.span([class("count")], [
        text(int.to_string(list.length(room.exits)) <> " passages"),
      ]),
    ]),
    html.div([class("compass-body")], [
      html.div([class("dial")], [
        point("north", "N"),
        point("east", "E"),
        point("south", "S"),
        point("west", "W"),
        html.div([class("hub")], [
          html.span([class("hub-label")], [text("you")]),
          html.span([class("hub-value")], [icon("my_location")]),
        ]),
      ]),
      html.div([class("rises")], [
        rise("up", "Up"),
        rise("down", "Down"),
        html.button([class("rise look"), event.on_click(Run("look"))], [
          icon("visibility"),
          html.span([class("rise-label")], [text("Look")]),
        ]),
      ]),
    ]),
  ])
}

/// What you carry, as slots: tap one to examine it.
fn view_satchel(model: Model) -> Element(Msg) {
  let carried = model.inventory
  let empty = int.max(0, 8 - list.length(carried))
  html.section([class("card satchel"), attribute.id("satchel")], [
    html.div([class("card-head")], [
      html.h2([], [icon("backpack"), text("Satchel")]),
      html.span([class("count")], [
        text(int.to_string(list.length(carried)) <> " carried"),
      ]),
    ]),
    html.div(
      [class("slots")],
      list.append(
        list.map(carried, fn(item) {
          html.button(
            [
              class("slot role-" <> item.role),
              attribute.title(item.name <> " (" <> item.note <> "): examine"),
              event.on_click(Run("examine " <> item.name)),
            ],
            [
              icon(role_glyph(item.role)),
              html.span([class("slot-name")], [text(item.name)]),
              html.span([class("slot-note")], [text(item.note)]),
            ],
          )
        }),
        list.repeat(html.span([class("slot empty")], [text("empty")]), empty),
      ),
    ),
  ])
}

/// A glimpse along the way out being pointed at (or held), else a hint.
fn view_glimpse(model: Model) -> Element(Msg) {
  html.section([class("card glimpse-card")], [
    icon("visibility"),
    case model.glimpse {
      Some(e) ->
        html.p([], [
          html.span([class("glimpse-dir")], [text(e.direction)]),
          text(e.hint),
          case e.lock, e.obstacle {
            Some(lock), _ ->
              html.span([class("glimpse-lock")], [text(" · locked: " <> lock)])
            None, Some(o) ->
              html.span([class("glimpse-lock")], [text(" · " <> o)])
            None, None -> element.none()
          },
        ])
      None ->
        html.p([class("idle")], [
          html.span([class("for-mouse")], [
            text(
              "Point at a way out to glimpse along it, or type “look north”.",
            ),
          ]),
          html.span([class("for-touch")], [
            text("Hold a way out to glimpse along it."),
          ]),
        ])
    },
  ])
}

fn view_commandbar(model: Model) -> Element(Msg) {
  let in_danger = case model.room {
    Some(protocol.RoomView(foe: Some(_), ..)) -> True
    _ -> False
  }
  let quick = case in_danger, model.wounds {
    True, _ -> [
      #("Fight", "fight"),
      #("Flee", "flee"),
      #("Raise lantern", "raise lantern"),
      #("Look", "look"),
    ]
    False, 0 -> [
      #("Look", "look"),
      #("Inventory", "inventory"),
      #("Dig", "dig"),
      #("Fill lantern", "fill lantern"),
      #("Help", "help"),
    ]
    False, _ -> [
      #("Look", "look"),
      #("Rest", "rest"),
      #("Inventory", "inventory"),
      #("Dig", "dig"),
      #("Fill lantern", "fill lantern"),
      #("Help", "help"),
    ]
  }
  html.footer([class("commandbar")], [
    html.div([class("quick")], [
      html.span([class("quick-label")], [text("Quick")]),
      element.fragment(
        list.map(quick, fn(q) {
          html.button([class("quick-chip"), event.on_click(Run(q.1))], [
            text(q.0),
          ])
        }),
      ),
    ]),
    html.form([class("prompt"), event.on_submit(fn(_) { Submit })], [
      html.span([class("caret")], [text(">_")]),
      html.input([
        attribute.id("command"),
        attribute.placeholder(
          "Enter a command (e.g. 'go north', 'take spade', 'examine map')…",
        ),
        attribute.value(model.input),
        attribute.autocomplete("off"),
        attribute.attribute("autocapitalize", "off"),
        attribute.attribute("enterkeyhint", "send"),
        attribute.attribute("spellcheck", "false"),
        event.on_input(Input),
        event.on_keydown(Key),
      ]),
      html.button([class("execute")], [icon("send"), text("Execute")]),
    ]),
  ])
}

/// Phone: jump between the panels, or open the map.
fn view_tabs() -> Element(Msg) {
  let tab = fn(href: String, glyph: String, label: String) {
    html.a([class("tab"), attribute.href(href)], [
      icon(glyph),
      html.span([], [text(label)]),
    ])
  }
  html.nav([class("tabs")], [
    tab("#scene", "terminal", "Story"),
    tab("#satchel", "backpack", "Satchel"),
    html.button([class("tab"), event.on_click(OpenMap)], [
      icon("map"),
      html.span([], [text("Map")]),
    ]),
  ])
}

/// The whole history, newest at the bottom.
fn view_journal(model: Model) -> Element(Msg) {
  html.div([class("drawer-backdrop"), event.on_click(ToggleJournal)], [
    html.aside(
      [class("drawer"), event.on_click(Noop) |> event.stop_propagation],
      [
        html.div([class("card-head")], [
          html.h2([], [icon("history_edu"), text("Journal")]),
          icon_button("close", "Close", ToggleJournal),
        ]),
        html.div(
          [attribute.id("log"), class("journal-feed")],
          model.log
            |> list.reverse
            |> list.map(view_entry(_, "earlier")),
        ),
      ],
    ),
  ])
}

/// Phone: the things that don't earn a place on screen all the time.
/// What the player was looking at, sent with their note: the place and
/// their last few chronicle entries, oldest first.
fn feedback_context(model: Model) -> String {
  let place = case model.room {
    Some(room) -> "Place: " <> room.name <> " (" <> room.region <> ")\n"
    None -> ""
  }
  place
  <> {
    model.log
    |> list.take(12)
    |> list.reverse
    |> list.map(fn(e) { e.at <> " " <> e.text })
    |> string.join("\n")
  }
}

/// A note about something that felt off: no need to know what to fix.
fn view_feedback(note: String) -> Element(Msg) {
  html.div(
    [class("sheet-backdrop feedback-backdrop"), event.on_click(CloseFeedback)],
    [
      html.form(
        [
          class("sheet feedback"),
          event.on_click(Noop) |> event.stop_propagation,
          event.on_submit(fn(_) { SendFeedback }),
        ],
        [
          html.h2([], [icon("rate_review"), text("Something feels off?")]),
          html.p([class("feedback-hint")], [
            text(
              "Say what felt weird; no need to know the fix. Where you are and what just happened are sent with it.",
            ),
          ]),
          html.textarea(
            [
              attribute.id("feedback-text"),
              attribute.placeholder(
                "e.g. the picture doesn't match the description…",
              ),
              attribute.attribute("rows", "5"),
              event.on_input(FeedbackInput),
            ],
            note,
          ),
          html.div([class("feedback-actions")], [
            html.button(
              [
                class("link"),
                attribute.type_("button"),
                event.on_click(CloseFeedback),
              ],
              [text("Cancel")],
            ),
            html.button(
              [class("execute"), attribute.disabled(string.trim(note) == "")],
              [icon("send"), text("Send")],
            ),
          ]),
        ],
      ),
    ],
  )
}

fn view_more_sheet(model: Model) -> Element(Msg) {
  html.div([class("sheet-backdrop"), event.on_click(ToggleMore)], [
    html.div([class("sheet"), event.on_click(Noop) |> event.stop_propagation], [
      html.button([class("chip feedback-chip"), event.on_click(OpenFeedback)], [
        text("Something feels off…"),
      ]),
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
        html.div([class("chips")], [
          html.button([class("chip"), event.on_click(OpenDebug)], [
            text("Show prompts for this room"),
          ]),
          html.button([class("chip danger"), event.on_click(AskReset)], [
            text("Reset world"),
          ]),
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

// DEBUG -----------------------------------------------------------------------

/// Dev only: how the current room was made, so a mismatch between its text,
/// items and picture can be traced to the prompt or reply that caused it.
fn view_debug(d: protocol.DebugView) -> Element(Msg) {
  let pre = fn(body: String) { html.pre([class("debug-pre")], [text(body)]) }
  let field = fn(label: String, body: Element(Msg)) {
    html.div([class("debug-field")], [
      html.h4([], [text(label)]),
      body,
    ])
  }
  let list_or_none = fn(xs: List(String)) {
    case xs {
      [] -> "(none)"
      _ -> string.join(xs, "\n")
    }
  }
  html.div(
    [
      class("debug-overlay"),
      attribute.id("debug"),
      attribute.attribute("tabindex", "-1"),
      event.on_keydown(DebugKey),
    ],
    [
      html.div([class("map-bar")], [
        html.h2([], [text("How this room was made")]),
        html.span([class("map-count")], [
          text("room " <> int.to_string(d.room_id) <> " · " <> d.name),
        ]),
        html.div([class("map-buttons")], [
          html.button(
            [
              class("chip"),
              attribute.title("Close (Esc)"),
              event.on_click(CloseDebug),
            ],
            [text("✕")],
          ),
        ]),
      ]),
      html.div([class("debug-body")], [
        html.section([class("debug-section")], [
          html.h3([], [text("Picture")]),
          field("Image prompt sent", case d.image_prompt_sent {
            Some(sent) -> pre(sent)
            None -> html.p([class("debug-note")], [text("Not drawn yet.")])
          }),
          case d.image_prompt_sent == Some(d.image_prompt_now) {
            True -> element.none()
            False -> field("Image prompt if drawn now", pre(d.image_prompt_now))
          },
          field(
            "Seed",
            pre(case d.image_seed {
              Some(seed) -> int.to_string(seed)
              None -> "—"
            }),
          ),
          field(
            "Stored picture line",
            pre(case d.picture {
              "" ->
                "(none: built before picture lines existed; composed from the facts below)"
              picture -> picture
            }),
          ),
        ]),
        html.section([class("debug-section")], [
          html.h3([], [text("Stored room")]),
          field("Description", pre(d.description)),
          field("Items", pre(list_or_none(d.items))),
          field("Visual details", pre(list_or_none(d.features))),
        ]),
        html.section([class("debug-section")], [
          html.h3([], [text("Room builder")]),
          case d.builder_prompt {
            "" ->
              html.p([class("debug-note")], [
                text(
                  "No record: built before prompts were saved. Reset the world to rebuild with records.",
                ),
              ])
            prompt ->
              html.details([], [
                html.summary([], [
                  text(
                    "Prompt ("
                    <> int.to_string(string.length(prompt))
                    <> " characters)",
                  ),
                ]),
                pre(prompt),
              ])
          },
          ..list.index_map(d.attempts, fn(a, i) {
            let status = case a.problem {
              "" -> html.span([class("debug-ok")], [text("used")])
              problem ->
                case string.starts_with(problem, "used") {
                  True -> html.span([class("debug-ok")], [text(problem)])
                  False ->
                    html.span([class("debug-bad")], [
                      text("rejected: " <> problem),
                    ])
                }
            }
            html.div([class("debug-attempt")], [
              html.h4([], [
                text("Reply " <> int.to_string(i + 1) <> " "),
                status,
              ]),
              case a.feedback {
                "" -> element.none()
                feedback ->
                  field(
                    "Feedback added to the prompt",
                    pre(string.trim(feedback)),
                  )
              },
              case a.reply {
                "" -> element.none()
                reply -> pre(reply)
              },
            ])
          })
        ]),
      ]),
    ],
  )
}
