//// Danger: the creatures of Vellmoor, where they turn up, and the dice.
//// Everything here is the engine's: the model never decides who wins.
//// See docs/danger.md.

import envoy
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Wounds you can take; the last one puts you down.
pub const max_wounds = 3

/// A wound heals by itself after this long (real time).
pub const heal_seconds = 1200

pub type Level {
  Below
  Street
  Upstairs
}

pub type Creature {
  Creature(
    kind: String,
    name: String,
    /// Hits it takes to drive off; also how hard it is to hit.
    strength: Int,
    /// A lit lantern raised drives it off at once.
    fears_light: Bool,
    /// Percent chance that fleeing from it costs a wound.
    flee_risk: Int,
    level: Level,
    /// Only in perilous places (far from the crossroads).
    perilous_only: Bool,
    /// Only in this region, if set.
    region: Option(String),
    /// What it's doing as you meet it; one is picked.
    arrives: List(String),
    /// What a picture of it shows.
    looks: String,
  )
}

pub const bestiary = [
  Creature(
    kind: "rats",
    name: "swarm of sewer rats",
    strength: 1,
    fears_light: True,
    flee_risk: 10,
    level: Below,
    perilous_only: False,
    region: None,
    arrives: [
      "A swarm of sewer rats boils out of a drain, squealing, and pours toward your boots.",
      "Red eyes glint in the dark. A tide of sewer rats comes scrabbling over the stones at you.",
    ],
    looks: "a swarm of sewer rats with glinting red eyes pouring across wet stones",
  ),
  Creature(
    kind: "dog",
    name: "stray dog",
    strength: 1,
    fears_light: False,
    flee_risk: 25,
    level: Street,
    perilous_only: False,
    region: None,
    arrives: [
      "A gaunt stray dog steps out of the fog, hackles up, growling low.",
      "A stray dog bars the way, ribs showing, teeth bared.",
    ],
    looks: "a gaunt stray dog with bared teeth and raised hackles, in fog",
  ),
  Creature(
    kind: "footpad",
    name: "footpad",
    strength: 2,
    fears_light: False,
    flee_risk: 30,
    level: Street,
    perilous_only: False,
    region: None,
    arrives: [
      "A footpad in a muffler slips out of a doorway, a cosh in his fist. \"Your purse, friend.\"",
      "Footsteps behind you quicken. A footpad with a cosh blocks your way.",
    ],
    looks: "a Victorian footpad in a muffler and flat cap, holding a cosh",
  ),
  Creature(
    kind: "drowned",
    name: "drowned thing",
    strength: 3,
    fears_light: True,
    flee_risk: 15,
    level: Below,
    perilous_only: True,
    region: None,
    arrives: [
      "Something pale and bloated drags itself out of the black water, reaching for you with soft grey hands.",
      "The water stirs. A drowned thing rises, weed in its hair, and shuffles toward you.",
    ],
    looks: "a pale, bloated drowned figure with weed in its hair rising from black water",
  ),
  Creature(
    kind: "gang",
    name: "Warrens gang",
    strength: 3,
    fears_light: False,
    flee_risk: 50,
    level: Below,
    perilous_only: True,
    region: Some("warrens"),
    arrives: [
      "Lanterns unshutter all around you: a Warrens gang, knives out, grinning.",
      "Three figures with knives step out of the tunnel mouths. The Warrens gang wants what you carry.",
    ],
    looks: "a gang of ragged Victorian thugs with knives and shuttered lanterns in a brick tunnel",
  ),
  Creature(
    kind: "prowler",
    name: "rooftop prowler",
    strength: 2,
    fears_light: False,
    flee_risk: 30,
    level: Upstairs,
    perilous_only: True,
    region: None,
    arrives: [
      "A lean figure drops from the chimneys above and lands crouched before you, blade drawn.",
    ],
    looks: "a lean cloaked rooftop prowler crouching among chimneys with a blade",
  ),
]

pub fn creature(kind: String) -> Option(Creature) {
  list.find(bestiary, fn(c) { c.kind == kind }) |> option.from_result
}

pub fn level_of(z: Int) -> Level {
  case z {
    z if z < 0 -> Below
    0 -> Street
    _ -> Upstairs
  }
}

/// Percent chance of meeting something on entering a place. None near the
/// crossroads; more the further out; more in the dark. `ENCOUNTER_CHANCE`
/// (for testing) overrides it for any place beyond the gentle streets.
pub fn encounter_chance(tier: Int, dark: Bool) -> Int {
  case tier, override() {
    0, _ -> 0
    _, Some(percent) -> percent
    1, None -> 10 + dark_bonus(dark)
    _, None -> 20 + dark_bonus(dark)
  }
}

fn dark_bonus(dark: Bool) -> Int {
  case dark {
    True -> 10
    False -> 0
  }
}

fn override() -> Option(Int) {
  case envoy.get("ENCOUNTER_CHANCE") {
    Ok(text) ->
      case int.parse(string.trim(text)) {
        Ok(n) -> Some(int.clamp(n, 0, 100))
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
}

/// The creatures that could be met at this level, region and difficulty.
pub fn candidates(z: Int, region: String, tier: Int) -> List(Creature) {
  let level = level_of(z)
  list.filter(bestiary, fn(c) {
    c.level == level
    && { !c.perilous_only || tier >= 2 }
    && case c.region {
      Some(r) -> r == region
      None -> True
    }
  })
}

/// Roll for an encounter on entering a place.
pub fn roll_encounter(
  z: Int,
  region: String,
  tier: Int,
  dark: Bool,
) -> Option(Creature) {
  case int.random(100) < encounter_chance(tier, dark) {
    False -> None
    True -> pick(candidates(z, region, tier))
  }
}

pub fn pick(from: List(a)) -> Option(a) {
  case from {
    [] -> None
    _ ->
      list.drop(from, int.random(list.length(from)))
      |> list.first
      |> option.from_result
  }
}

/// A blow lands on a roll of a die plus the weapon's bonus of at least two
/// more than the creature's strength: rats (1) on a 3+, a drowned thing (3)
/// on a 5+, or a 3+ with a crowbar.
pub fn hits(die: Int, bonus: Int, strength: Int) -> Bool {
  die + bonus >= 2 + strength
}

pub fn roll_die() -> Int {
  int.random(6) + 1
}

/// What the best tool you carry adds in a fight (only the best counts).
pub fn weapon_bonus(tool_kinds: List(String)) -> Int {
  tool_kinds
  |> list.map(fn(kind) {
    case kind {
      "crowbar" -> 2
      "pole" | "spade" -> 1
      _ -> 0
    }
  })
  |> list.fold(0, int.max)
}

/// The tool you fight with: the one giving the best bonus, if any.
pub fn weapon(tools: List(#(String, String))) -> Option(String) {
  tools
  |> list.filter(fn(t) { weapon_bonus([t.1]) > 0 })
  |> list.sort(fn(a, b) {
    int.compare(weapon_bonus([b.1]), weapon_bonus([a.1]))
  })
  |> list.first
  |> option.from_result
  |> option.map(fn(t) { t.0 })
}

/// Seconds since 1970.
pub fn now() -> Int {
  system_time(atom.create("second"))
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int
