//// Settings, all from the environment, with defaults for local development
//// (Ollama and the image service running natively on the Mac).

import envoy
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Config {
  Config(
    port: Int,
    db_path: String,
    art_dir: String,
    static_dir: String,
    model: ModelConfig,
    /// The image service (imagegen/). Its own settings pick local SDXL-Turbo
    /// or a hosted API; this server only ever talks to it.
    image_api_base_url: String,
    /// DEV_TOOLS=1: allow developer actions such as resetting the world.
    /// Off unless set; scripts/dev.sh sets it.
    dev_tools: Bool,
  )
}

pub type ModelConfig {
  ModelConfig(
    ollama_base_url: String,
    /// Fast model: narration, image prompts, interpreting free-form input.
    fast_model: String,
    /// Model that builds rooms. The 3B model builds a valid room in ~3-4 s on
    /// an M1 Pro; an 8B model is more careful but ~3x slower.
    builder_model: String,
    /// Set → use an OpenAI-compatible endpoint instead of Ollama.
    api_base_url: Option(String),
    api_key: Option(String),
    api_fast_model: Option(String),
    api_builder_model: Option(String),
  )
}

pub fn load() -> Config {
  Config(
    port: get("PORT", "4300") |> int.parse |> result.unwrap(4300),
    db_path: get("DB_PATH", "inkmud.db"),
    art_dir: get("ART_DIR", "art"),
    static_dir: get("STATIC_DIR", "priv/static"),
    model: ModelConfig(
      ollama_base_url: get("OLLAMA_BASE_URL", "http://localhost:11434"),
      fast_model: get("FAST_MODEL", "llama3.2:3b"),
      builder_model: get("BUILDER_MODEL", "llama3.2:3b"),
      api_base_url: optional("MODEL_API_BASE_URL"),
      api_key: optional("MODEL_API_KEY"),
      api_fast_model: optional("MODEL_API_FAST_MODEL"),
      api_builder_model: optional("MODEL_API_BUILDER_MODEL"),
    ),
    image_api_base_url: get("IMAGE_API_BASE_URL", "http://localhost:7860"),
    dev_tools: case get("DEV_TOOLS", "") {
      "1" | "true" | "yes" -> True
      _ -> False
    },
  )
}

fn get(name: String, default: String) -> String {
  case envoy.get(name) {
    Ok("") | Error(Nil) -> default
    Ok(value) -> value
  }
}

fn optional(name: String) -> Option(String) {
  case envoy.get(name) {
    Ok("") | Error(Nil) -> None
    Ok(value) -> Some(value)
  }
}
