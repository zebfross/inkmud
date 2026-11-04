//// Text-model client. Development talks to Ollama's `/api/generate`; setting
//// MODEL_API_BASE_URL switches to an OpenAI-compatible `/chat/completions`
//// (a hosted provider in production). Same idea as quillstack's transport:
//// callers never know which one answered.
////
//// Any failure — refused, timed out, non-2xx, unreadable — is `Error(Nil)`.
//// Callers decide what "no answer" means for them.

import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import server/config.{type ModelConfig}

pub type Endpoint {
  Ollama(base_url: String)
  OpenAi(base_url: String, api_key: Option(String))
}

pub type Client {
  Client(endpoint: Endpoint, model: String)
}

pub type Role {
  Fast
  Builder
}

pub fn client(config: ModelConfig, role: Role) -> Client {
  case config.api_base_url {
    Some(base_url) -> {
      let model = case role {
        Fast -> option.unwrap(config.api_fast_model, config.fast_model)
        Builder -> option.unwrap(config.api_builder_model, config.builder_model)
      }
      Client(OpenAi(base_url:, api_key: config.api_key), model)
    }
    None ->
      Client(Ollama(config.ollama_base_url), case role {
        Fast -> config.fast_model
        Builder -> config.builder_model
      })
  }
}

pub type Ask {
  Ask(prompt: String, json: Bool, temperature: Float, timeout: Int)
}

pub fn ask(prompt: String) -> Ask {
  Ask(prompt:, json: False, temperature: 0.7, timeout: 60_000)
}

pub fn ask_json(prompt: String) -> Ask {
  Ask(prompt:, json: True, temperature: 0.7, timeout: 90_000)
}

/// The model's reply text.
pub fn generate(client: Client, question: Ask) -> Result(String, Nil) {
  case client.endpoint {
    Ollama(base_url) -> ollama(base_url, client.model, question)
    OpenAi(base_url, api_key) ->
      openai(base_url, api_key, client.model, question)
  }
}

fn ollama(base_url: String, model: String, q: Ask) -> Result(String, Nil) {
  let body =
    json.object(
      list.flatten([
        [
          #("model", json.string(model)),
          #("prompt", json.string(q.prompt)),
          #("stream", json.bool(False)),
          #("keep_alive", json.string("30m")),
          #(
            "options",
            json.object([#("temperature", json.float(q.temperature))]),
          ),
        ],
        case q.json {
          True -> [#("format", json.string("json"))]
          False -> []
        },
      ]),
    )
  use text <- result.try(post(base_url <> "/api/generate", [], body, q.timeout))
  json.parse(text, decode.at(["response"], decode.string))
  |> result.replace_error(Nil)
}

fn openai(
  base_url: String,
  api_key: Option(String),
  model: String,
  q: Ask,
) -> Result(String, Nil) {
  let body =
    json.object(
      list.flatten([
        [
          #("model", json.string(model)),
          #(
            "messages",
            json.preprocessed_array([
              json.object([
                #("role", json.string("user")),
                #("content", json.string(q.prompt)),
              ]),
            ]),
          ),
          #("temperature", json.float(q.temperature)),
        ],
        case q.json {
          True -> [
            #(
              "response_format",
              json.object([#("type", json.string("json_object"))]),
            ),
          ]
          False -> []
        },
      ]),
    )
  let headers = case api_key {
    Some(key) -> [#("authorization", "Bearer " <> key)]
    None -> []
  }
  use text <- result.try(post(
    base_url <> "/chat/completions",
    headers,
    body,
    q.timeout,
  ))
  let first = decode.at(["message", "content"], decode.string)
  case json.parse(text, decode.at(["choices"], decode.list(first))) {
    Ok([content, ..]) -> Ok(content)
    _ -> Error(Nil)
  }
}

fn post(
  url: String,
  headers: List(#(String, String)),
  body: json.Json,
  timeout: Int,
) -> Result(String, Nil) {
  use base <- result.try(request.to(url))
  let req =
    list.fold(
      headers,
      base
        |> request.set_method(Post)
        |> request.set_header("content-type", "application/json")
        |> request.set_body(json.to_string(body)),
      fn(r, h) { request.set_header(r, h.0, h.1) },
    )
  case httpc.configure() |> httpc.timeout(timeout) |> httpc.dispatch(req) {
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response.body)
    _ -> Error(Nil)
  }
}
