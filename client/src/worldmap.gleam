//// The explored-world map: an isometric view where each floor (z level) is a
//// tilted plane and the floors are stacked above one another. Drag to pan,
//// wheel or buttons to zoom, hover a room for its name, click it for a card,
//// click a floor's label to bring it forward.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute.{type Attribute, attribute, class}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/element/svg
import lustre/event
import shared/protocol.{type MapRoom, type MapView}

pub type State {
  State(
    view: MapView,
    zoom: Float,
    /// Pan offset in map units.
    pan_x: Float,
    pan_y: Float,
    /// Last pointer position while dragging, in screen pixels.
    drag: Option(#(Float, Float)),
    /// Distance between two fingers at the last pinch step.
    pinch: Option(Float),
    focus: Option(Int),
    selected: Option(Int),
    hovered: Option(Int),
  )
}

pub type Msg {
  ZoomBy(Float)
  Wheel(Float)
  DragStart(Float, Float)
  DragMove(x: Float, y: Float, width: Float)
  DragEnd
  /// Touch: one finger pans, two pinch to zoom.
  TouchStart(List(#(Float, Float)))
  TouchMove(points: List(#(Float, Float)), width: Float)
  TouchEnd
  FocusLevel(Int)
  Select(Int)
  Hover(Option(Int))
  Recenter
  /// Put away the room card (any interaction other than picking a room).
  Dismiss
  Close
}

pub fn init(view: MapView) -> State {
  State(view, 1.0, 0.0, 0.0, None, None, None, None, None)
}

/// New data (the player moved): keep the camera, drop a selection that no
/// longer exists.
pub fn refresh(state: State, view: MapView) -> State {
  let selected = case state.selected {
    Some(id) ->
      case list.any(view.rooms, fn(r) { r.id == id }) {
        True -> Some(id)
        False -> None
      }
    None -> None
  }
  State(..state, view:, selected:)
}

/// The room card closes on anything that isn't choosing a room: zooming,
/// panning, focusing a floor, recentering, clicking elsewhere, Esc.
pub fn update(state: State, msg: Msg) -> State {
  case msg {
    ZoomBy(f) ->
      State(..state, zoom: clamp(state.zoom *. f, 0.4, 4.0), selected: None)
    Wheel(dy) ->
      State(
        ..state,
        selected: None,
        zoom: clamp(
          state.zoom
            *. case dy >. 0.0 {
            True -> 0.9
            False -> 1.1
          },
          0.4,
          4.0,
        ),
      )
    DragStart(x, y) -> State(..state, drag: Some(#(x, y)))
    TouchStart(points) ->
      case points {
        [p] -> State(..state, drag: Some(p), pinch: None)
        [p, q, ..] -> State(..state, drag: None, pinch: Some(distance(p, q)))
        [] -> state
      }
    TouchMove(points, width) ->
      case points, state.pinch {
        [#(x, y)], _ -> update(state, DragMove(x:, y:, width:))
        [p, q, ..], Some(before) -> {
          let now = distance(p, q)
          State(
            ..state,
            zoom: clamp(state.zoom *. now /. float.max(before, 1.0), 0.4, 4.0),
            pinch: Some(now),
            selected: None,
          )
        }
        _, _ -> state
      }
    TouchEnd -> State(..state, drag: None, pinch: None)
    DragMove(x, y, width) ->
      case state.drag {
        None -> state
        Some(#(lx, ly)) -> {
          // Screen pixels → map units at the current zoom.
          let #(_, _, vb_w, _) = base_box(state.view)
          let per_px = vb_w /. state.zoom /. float.max(width, 1.0)
          // A real drag, not the jitter of a click.
          let moved =
            float.absolute_value(x -. lx) +. float.absolute_value(y -. ly)
            >. 3.0
          State(
            ..state,
            pan_x: state.pan_x -. { x -. lx } *. per_px,
            pan_y: state.pan_y -. { y -. ly } *. per_px,
            drag: Some(#(x, y)),
            selected: case moved {
              True -> None
              False -> state.selected
            },
          )
        }
      }
    DragEnd -> State(..state, drag: None)
    FocusLevel(z) ->
      State(..state, selected: None, focus: case state.focus == Some(z) {
        True -> None
        False -> Some(z)
      })
    Select(id) ->
      State(..state, selected: case state.selected == Some(id) {
        True -> None
        False -> Some(id)
      })
    Hover(id) -> State(..state, hovered: id)
    Recenter ->
      State(..state, zoom: 1.0, pan_x: 0.0, pan_y: 0.0, selected: None)
    Dismiss -> State(..state, selected: None)
    Close -> state
  }
}

fn distance(a: #(Float, Float), b: #(Float, Float)) -> Float {
  let dx = a.0 -. b.0
  let dy = a.1 -. b.1
  float.square_root(dx *. dx +. dy *. dy) |> result.unwrap(0.0)
}

fn clamp(v: Float, lo: Float, hi: Float) -> Float {
  float.min(hi, float.max(lo, v))
}

// PROJECTION ------------------------------------------------------------------

/// Half the width and half the height of one grid cell on screen.
const cell_w = 38.0

const cell_h = 19.0

/// Vertical distance between floors: enough that the biggest floor's plane
/// doesn't swallow the one above it.
fn level_gap(view: MapView) -> Float {
  let sums = list.map(view.rooms, fn(r) { r.x + r.y })
  let spread = case sums {
    [] -> 0
    [first, ..] ->
      list.fold(sums, first, int.max) - list.fold(sums, first, int.min)
  }
  float.max(130.0, int.to_float(spread) *. cell_h +. 80.0)
}

fn project(view: MapView, x: Float, y: Float, z: Int) -> #(Float, Float) {
  #(
    { x -. y } *. cell_w,
    { x +. y } *. cell_h -. int.to_float(z) *. level_gap(view),
  )
}

fn mark_at(view: MapView, mark: #(Int, Int, Int)) -> #(Float, Float) {
  project(view, int.to_float(mark.0), int.to_float(mark.1), mark.2)
}

fn at(view: MapView, room: MapRoom) -> #(Float, Float) {
  project(view, int.to_float(room.x), int.to_float(room.y), room.z)
}

/// The box that fits everything, as #(min_x, min_y, width, height).
fn base_box(view: MapView) -> #(Float, Float, Float, Float) {
  let points =
    list.append(
      list.map(view.rooms, at(view, _)),
      list.map(view.marks, mark_at(view, _)),
    )
  case points {
    [] -> #(-200.0, -150.0, 400.0, 300.0)
    [#(fx, fy), ..] -> {
      let min_x = list.fold(points, fx, fn(m, p) { float.min(m, p.0) })
      let max_x = list.fold(points, fx, fn(m, p) { float.max(m, p.0) })
      let min_y = list.fold(points, fy, fn(m, p) { float.min(m, p.1) })
      let max_y = list.fold(points, fy, fn(m, p) { float.max(m, p.1) })
      let pad = 140.0
      let w = float.max(max_x -. min_x +. 2.0 *. pad, 480.0)
      let h = float.max(max_y -. min_y +. 2.0 *. pad, 360.0)
      let cx = { min_x +. max_x } /. 2.0
      let cy = { min_y +. max_y } /. 2.0
      #(cx -. w /. 2.0, cy -. h /. 2.0, w, h)
    }
  }
}

fn view_box(state: State) -> String {
  let #(x, y, w, h) = base_box(state.view)
  let zw = w /. state.zoom
  let zh = h /. state.zoom
  let cx = x +. w /. 2.0 +. state.pan_x
  let cy = y +. h /. 2.0 +. state.pan_y
  [cx -. zw /. 2.0, cy -. zh /. 2.0, zw, zh]
  |> list.map(num)
  |> string.join(" ")
}

fn num(f: Float) -> String {
  float.to_string(float.to_precision(f, 1))
}

fn points(ps: List(#(Float, Float))) -> Attribute(msg) {
  attribute(
    "points",
    ps |> list.map(fn(p) { num(p.0) <> "," <> num(p.1) }) |> string.join(" "),
  )
}

// VIEW ------------------------------------------------------------------------

pub fn view(state: State) -> Element(Msg) {
  let map = state.view
  let levels =
    map.rooms
    |> list.map(fn(r) { r.z })
    |> list.unique
    |> list.sort(int.compare)
  html.div(
    [
      class("map-overlay"),
      attribute.id("map"),
      attribute("tabindex", "-1"),
      event.on_keydown(fn(key) {
        case key {
          "Escape" ->
            case state.selected {
              Some(_) -> Dismiss
              None -> Close
            }
          "+" | "=" -> ZoomBy(1.25)
          "-" -> ZoomBy(0.8)
          _ -> Hover(state.hovered)
        }
      }),
    ],
    [
      html.div([class("map-bar")], [
        html.h2([], [text("Your map of Vellmoor")]),
        html.span([class("map-count")], [
          text(int.to_string(list.length(map.rooms)) <> " places explored"),
        ]),
        html.div([class("map-buttons")], [
          button("−", "Zoom out", ZoomBy(0.8)),
          button("+", "Zoom in", ZoomBy(1.25)),
          button("⟲", "Recenter", Recenter),
          button("✕", "Close map (Esc)", Close),
        ]),
      ]),
      html.div([class("map-stage")], [
        svg.svg(
          [
            class(case state.drag {
              Some(_) -> "map-canvas dragging"
              None -> "map-canvas"
            }),
            attribute("viewBox", view_box(state)),
            attribute("preserveAspectRatio", "xMidYMid meet"),
            event.on("mousedown", pointer(DragStart)),
            event.on("mousemove", {
              use x <- decode.field("clientX", number())
              use y <- decode.field("clientY", number())
              use width <- decode.subfield(
                ["currentTarget", "clientWidth"],
                number(),
              )
              decode.success(DragMove(x:, y:, width:))
            }),
            event.on("mouseup", decode.success(DragEnd)),
            event.on("touchstart", touches() |> decode.map(TouchStart)),
            event.on("touchmove", {
              use points <- decode.then(touches())
              use width <- decode.subfield(
                ["currentTarget", "clientWidth"],
                number(),
              )
              decode.success(TouchMove(points:, width:))
            }),
            event.on("touchend", decode.success(TouchEnd)),
            event.on("touchcancel", decode.success(TouchEnd)),
            event.on_click(Dismiss),
            event.on("mouseleave", decode.success(DragEnd)),
            event.on("wheel", {
              use dy <- decode.field("deltaY", number())
              decode.success(Wheel(dy))
            })
              |> event.prevent_default,
          ],
          // Bottom floor first, so higher floors are drawn over it; treasure
          // marks on top of everything.
          list.append(
            list.flat_map(levels, fn(z) { view_level(state, z) }),
            list.map(map.marks, fn(m) { view_mark(map, m) }),
          ),
        ),
        view_compass(),
      ]),
      view_card(state),
      html.p([class("map-hint")], [
        text(
          "Drag to pan · scroll to zoom · click a floor's label to bring it forward",
        ),
      ]),
    ],
  )
}

// COMPASS ---------------------------------------------------------------------

/// A compass rose drawn on the ground in the map's own projection, so its
/// points line up with the streets: north runs up and to the right, east
/// down and to the right. It stays in the corner while the map pans and
/// zooms. Letters stay upright so they're easy to read.
fn view_compass() -> Element(Msg) {
  // Ground coordinates (east, south) to the compass's screen coordinates,
  // the same shape as `project`.
  let iso = fn(gx: Float, gy: Float) -> #(Float, Float) {
    #({ gx -. gy } *. 1.0, { gx +. gy } *. 0.5)
  }
  let scale = fn(v: #(Float, Float), k: Float) { #(v.0 *. k, v.1 *. k) }
  let origin = #(0.0, 0.0)
  // A pointed arm from the middle toward `dir`, shaded half light, half
  // dark, its width set toward `side` (the next point round).
  let arm = fn(dir: #(Float, Float), side: #(Float, Float), length, width, cls) {
    let tip = iso(dir.0 *. length, dir.1 *. length)
    let left = iso(side.0 *. width, side.1 *. width)
    let right = iso(0.0 -. side.0 *. width, 0.0 -. side.1 *. width)
    [
      svg.polygon([class(cls <> " lit"), points([origin, tip, left])]),
      svg.polygon([class(cls <> " shade"), points([origin, tip, right])]),
    ]
  }
  let cardinals = [
    #("N", #(0.0, -1.0), #(1.0, 0.0)),
    #("E", #(1.0, 0.0), #(0.0, 1.0)),
    #("S", #(0.0, 1.0), #(-1.0, 0.0)),
    #("W", #(-1.0, 0.0), #(0.0, -1.0)),
  ]
  let d = 0.7071
  let diagonals = [
    #(#(d, 0.0 -. d), #(d, d)),
    #(#(d, d), #(0.0 -. d, d)),
    #(#(0.0 -. d, d), #(0.0 -. d, 0.0 -. d)),
    #(#(0.0 -. d, 0.0 -. d), #(d, 0.0 -. d)),
  ]
  let ring = fn(r: Float, cls: String) {
    // A circle on the ground is an ellipse twice as wide as it is tall.
    svg.ellipse([
      class(cls),
      attribute("cx", "0"),
      attribute("cy", "0"),
      attribute("rx", num(r *. 1.4142)),
      attribute("ry", num(r *. 0.7071)),
    ])
  }
  html.div([class("map-compass"), attribute("aria-hidden", "true")], [
    svg.svg([attribute("viewBox", "-80 -46 160 92")], [
      ring(44.0, "compass-ring"),
      ring(36.0, "compass-ring inner"),
      ..list.flatten([
        list.flat_map(diagonals, fn(dg) {
          arm(dg.0, dg.1, 30.0, 5.0, "compass-arm minor")
        }),
        list.flat_map(cardinals, fn(c) {
          let cls = case c.0 {
            "N" -> "compass-arm north"
            _ -> "compass-arm"
          }
          arm(c.1, c.2, 44.0, 7.0, cls)
        }),
        [svg.circle([class("compass-pin"), attribute("r", "2.5")])],
        list.map(cardinals, fn(c) {
          let #(x, y) = scale(iso(c.1.0, c.1.1), 56.0)
          svg.text(
            [
              class(case c.0 {
                "N" -> "compass-letter north"
                _ -> "compass-letter"
              }),
              attribute("x", num(x)),
              attribute("y", num(y)),
              attribute("text-anchor", "middle"),
              attribute("dominant-baseline", "central"),
            ],
            c.0,
          )
        }),
      ])
    ]),
  ])
}

fn button(label: String, title: String, msg: Msg) -> Element(Msg) {
  html.button([class("chip"), attribute.title(title), event.on_click(msg)], [
    text(label),
  ])
}

fn pointer(make: fn(Float, Float) -> Msg) -> decode.Decoder(Msg) {
  use x <- decode.field("clientX", number())
  use y <- decode.field("clientY", number())
  decode.success(make(x, y))
}

/// The first two fingers on the screen, in screen pixels.
fn touches() -> decode.Decoder(List(#(Float, Float))) {
  let point = fn(i) {
    decode.at(["touches", int.to_string(i)], {
      use x <- decode.field("clientX", number())
      use y <- decode.field("clientY", number())
      decode.success(#(x, y))
    })
  }
  use count <- decode.subfield(["touches", "length"], decode.int)
  case count {
    0 -> decode.success([])
    1 -> point(0) |> decode.map(fn(p) { [p] })
    _ -> {
      use p <- decode.then(point(0))
      use q <- decode.then(point(1))
      decode.success([p, q])
    }
  }
}

fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn level_name(z: Int) -> String {
  case z {
    0 -> "Street level"
    _ if z < 0 -> int.to_string(-z) <> " below the streets"
    _ -> int.to_string(z) <> " above the streets"
  }
}

fn view_level(state: State, z: Int) -> List(Element(Msg)) {
  let map = state.view
  let rooms = list.filter(map.rooms, fn(r) { r.z == z })
  let dim = case state.focus {
    Some(f) -> f != z
    None -> False
  }
  let assert [first, ..] = rooms
  let min_x = list.fold(rooms, first.x, fn(m, r) { int.min(m, r.x) })
  let max_x = list.fold(rooms, first.x, fn(m, r) { int.max(m, r.x) })
  let min_y = list.fold(rooms, first.y, fn(m, r) { int.min(m, r.y) })
  let max_y = list.fold(rooms, first.y, fn(m, r) { int.max(m, r.y) })
  let pad = 0.85
  let corner = fn(x, y) { project(map, x, y, z) }
  let x0 = int.to_float(min_x) -. pad
  let x1 = int.to_float(max_x) +. pad
  let y0 = int.to_float(min_y) -. pad
  let y1 = int.to_float(max_y) +. pad
  let label_at = corner(x0, y1)
  let ids = list.map(rooms, fn(r) { r.id })
  let links =
    list.filter(map.links, fn(l) {
      list.contains(ids, l.0) || list.contains(ids, l.1)
    })
  [
    svg.g(
      [
        class(case dim {
          True -> "map-level dim"
          False -> "map-level"
        }),
      ],
      list.flatten([
        [
          svg.polygon([
            class("map-plane"),
            points([
              corner(x0, y0),
              corner(x1, y0),
              corner(x1, y1),
              corner(x0, y1),
            ]),
          ]),
          svg.text(
            [
              class("map-level-label"),
              attribute("x", num(label_at.0 -. 6.0)),
              attribute("y", num(label_at.1 +. 18.0)),
              attribute("text-anchor", "end"),
              event.on_click(FocusLevel(z)) |> event.stop_propagation,
            ],
            level_name(z),
          ),
        ],
        list.filter_map(links, fn(l) { view_link(map, z, l) }),
        rooms
          |> list.sort(fn(a, b) { int.compare(a.x + a.y, b.x + b.y) })
          |> list.flat_map(fn(r) { view_room(state, r) }),
      ]),
    ),
  ]
}

/// A passage, drawn with the floor of its lower end: flat on the floor, or a
/// dashed shaft between floors.
fn view_link(
  map: MapView,
  z: Int,
  link: #(Int, Int),
) -> Result(Element(Msg), Nil) {
  case
    list.find(map.rooms, fn(r) { r.id == link.0 }),
    list.find(map.rooms, fn(r) { r.id == link.1 })
  {
    Ok(a), Ok(b) if a.z == z && b.z == z ->
      Ok(line(at(map, a), at(map, b), "map-link"))
    Ok(a), Ok(b) ->
      case a.z != b.z && z == int.min(a.z, b.z) {
        True -> Ok(line(at(map, a), at(map, b), "map-link shaft"))
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn line(a: #(Float, Float), b: #(Float, Float), cls: String) -> Element(Msg) {
  svg.line([
    class(cls),
    attribute("x1", num(a.0)),
    attribute("y1", num(a.1)),
    attribute("x2", num(b.0)),
    attribute("y2", num(b.1)),
  ])
}

fn region_class(region: String) -> String {
  case region {
    "Lantern Ward" -> "ward"
    "Cathedral Hill" -> "hill"
    "The Drowned Quarter" -> "drowned"
    "The Warrens" -> "warrens"
    _ -> "other"
  }
}

fn view_room(state: State, room: MapRoom) -> List(Element(Msg)) {
  let map = state.view
  let #(cx, cy) = at(map, room)
  let here = room.id == map.current
  // One name at a time, so neighbours' labels never overlap: the room
  // picked (or pointed at), or else the room you're in.
  let named = case option.or(state.selected, state.hovered) {
    Some(id) -> id == room.id
    None -> here
  }
  let stubs =
    list.map(room.unexplored, fn(d) {
      let #(dx, dy) = case d {
        "north" -> #(0.0, -0.45)
        "south" -> #(0.0, 0.45)
        "east" -> #(0.45, 0.0)
        "west" -> #(-0.45, 0.0)
        _ -> #(0.0, 0.0)
      }
      let end = case d {
        "up" -> #(cx, cy -. 30.0)
        "down" -> #(cx, cy +. 30.0)
        _ ->
          project(
            map,
            int.to_float(room.x) +. dx,
            int.to_float(room.y) +. dy,
            room.z,
          )
      }
      svg.g([], [
        line(#(cx, cy), end, "map-stub"),
        svg.circle([
          class("map-stub-end"),
          attribute("cx", num(end.0)),
          attribute("cy", num(end.1)),
          attribute("r", "2.5"),
        ]),
      ])
    })
  let tile =
    svg.g(
      [
        class(
          "map-room "
          <> region_class(room.region)
          <> case here {
            True -> " here"
            False -> ""
          }
          <> case state.selected == Some(room.id) {
            True -> " selected"
            False -> ""
          },
        ),
        event.on_click(Select(room.id)) |> event.stop_propagation,
        event.on("mouseenter", decode.success(Hover(Some(room.id)))),
        event.on("mouseleave", decode.success(Hover(None))),
      ],
      [
        svg.title([], [text(room.name)]),
        svg.polygon([
          class("map-tile"),
          points([
            #(cx, cy -. 13.0),
            #(cx +. 26.0, cy),
            #(cx, cy +. 13.0),
            #(cx -. 26.0, cy),
          ]),
        ]),
        case here {
          True ->
            svg.circle([
              class("map-here"),
              attribute("cx", num(cx)),
              attribute("cy", num(cy)),
              attribute("r", "6"),
            ])
          False -> element.none()
        },
      ],
    )
  let label = case named {
    True -> [
      svg.text(
        [
          class("map-name"),
          attribute("x", num(cx)),
          attribute("y", num(cy -. 20.0)),
          attribute("text-anchor", "middle"),
        ],
        room.name,
      ),
    ]
    False -> []
  }
  list.flatten([stubs, [tile], label])
}

/// A cross where a treasure map says to dig.
fn view_mark(map: MapView, mark: #(Int, Int, Int)) -> Element(Msg) {
  let #(cx, cy) = mark_at(map, mark)
  svg.g([class("map-mark")], [
    svg.title([], [text("Where your treasure map says to dig")]),
    svg.text(
      [
        attribute("x", num(cx)),
        attribute("y", num(cy +. 7.0)),
        attribute("text-anchor", "middle"),
      ],
      "✕",
    ),
  ])
}

fn view_card(state: State) -> Element(Msg) {
  let found = case state.selected {
    Some(id) -> list.find(state.view.rooms, fn(r) { r.id == id })
    None -> Error(Nil)
  }
  case found {
    Error(Nil) -> element.none()
    Ok(room) ->
      html.aside(
        [
          class("map-card"),
          attribute.title("Click to close"),
          event.on_click(Dismiss),
        ],
        [
          case room.art {
            Some(url) ->
              html.img([attribute.src(url), attribute.alt(room.name)])
            None -> element.none()
          },
          html.div([class("map-card-text")], [
            html.span([class("region")], [text(room.region)]),
            html.strong([], [text(room.name)]),
            html.span([class("map-card-meta")], [
              text(case room.id == state.view.current {
                True -> "You are here. "
                False -> ""
              }),
              text(level_name(room.z) <> "."),
              text(case room.unexplored {
                [] -> ""
                ways -> " Unexplored: " <> string.join(ways, ", ") <> "."
              }),
            ]),
          ]),
        ],
      )
  }
}
