//// The explored-world map: an isometric view where each floor (z level) is a
//// tilted plane and the floors are stacked above one another. Drag to pan,
//// wheel or buttons to zoom, hover a room for its name, click it for a card,
//// click a floor's label to bring it forward.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
  FocusLevel(Int)
  Select(Int)
  Hover(Option(Int))
  Recenter
  Close
}

pub fn init(view: MapView) -> State {
  State(view, 1.0, 0.0, 0.0, None, None, None, None)
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

pub fn update(state: State, msg: Msg) -> State {
  case msg {
    ZoomBy(f) -> State(..state, zoom: clamp(state.zoom *. f, 0.4, 4.0))
    Wheel(dy) ->
      State(
        ..state,
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
    DragMove(x, y, width) ->
      case state.drag {
        None -> state
        Some(#(lx, ly)) -> {
          // Screen pixels → map units at the current zoom.
          let #(_, _, vb_w, _) = base_box(state.view)
          let per_px = vb_w /. state.zoom /. float.max(width, 1.0)
          State(
            ..state,
            pan_x: state.pan_x -. { x -. lx } *. per_px,
            pan_y: state.pan_y -. { y -. ly } *. per_px,
            drag: Some(#(x, y)),
          )
        }
      }
    DragEnd -> State(..state, drag: None)
    FocusLevel(z) ->
      State(..state, focus: case state.focus == Some(z) {
        True -> None
        False -> Some(z)
      })
    Select(id) ->
      State(..state, selected: case state.selected == Some(id) {
        True -> None
        False -> Some(id)
      })
    Hover(id) -> State(..state, hovered: id)
    Recenter -> State(..state, zoom: 1.0, pan_x: 0.0, pan_y: 0.0)
    Close -> state
  }
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

fn at(view: MapView, room: MapRoom) -> #(Float, Float) {
  project(view, int.to_float(room.x), int.to_float(room.y), room.z)
}

/// The box that fits everything, as #(min_x, min_y, width, height).
fn base_box(view: MapView) -> #(Float, Float, Float, Float) {
  let points = list.map(view.rooms, at(view, _))
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
          "Escape" -> Close
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
          event.on("mouseleave", decode.success(DragEnd)),
          event.on("wheel", {
            use dy <- decode.field("deltaY", number())
            decode.success(Wheel(dy))
          })
            |> event.prevent_default,
        ],
        // Bottom floor first, so higher floors are drawn over it.
        list.flat_map(levels, fn(z) { view_level(state, z) }),
      ),
      view_card(state),
      html.p([class("map-hint")], [
        text(
          "Drag to pan · scroll to zoom · click a floor's label to bring it forward",
        ),
      ]),
    ],
  )
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
              event.on_click(FocusLevel(z)),
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
  let named =
    here || state.hovered == Some(room.id) || state.selected == Some(room.id)
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
        event.on_click(Select(room.id)),
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

fn view_card(state: State) -> Element(Msg) {
  let found = case state.selected {
    Some(id) -> list.find(state.view.rooms, fn(r) { r.id == id })
    None -> Error(Nil)
  }
  case found {
    Error(Nil) -> element.none()
    Ok(room) ->
      html.aside([class("map-card")], [
        case room.art {
          Some(url) -> html.img([attribute.src(url), attribute.alt(room.name)])
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
      ])
  }
}
