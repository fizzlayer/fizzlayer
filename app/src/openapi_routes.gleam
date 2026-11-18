//// Pulls `/api/gateway/*` paths out of `parse_route` in `src/gateway/mod.rs`
//// so a test can require each one to appear in `public/openapi.json`.

import gleam/list
import gleam/string

pub fn paths_from_rust(source: String) -> List(String) {
  slice_fn(source)
  |> string.split("\n")
  |> list.filter_map(arm_path)
}

fn slice_fn(source: String) -> String {
  case string.split_once(source, "fn parse_route") {
    Error(_) -> ""
    Ok(#(_, rest)) ->
      case string.split_once(rest, "#[cfg(test)]") {
        Ok(#(body, _)) -> body
        Error(_) -> rest
      }
  }
}

fn arm_path(line: String) -> Result(String, Nil) {
  case string.contains(line, "[\"") && string.contains(line, "]") {
    False -> Error(Nil)
    True ->
      case string.split_once(line, "[") {
        Error(_) -> Error(Nil)
        Ok(#(_, rest)) ->
          case string.split_once(rest, "]") {
            Error(_) -> Error(Nil)
            Ok(#(inside, _)) -> Ok(join_parts(inside))
          }
      }
  }
}

fn join_parts(inside: String) -> String {
  inside
  |> string.split(",")
  |> list.map(string.trim)
  |> list.map(part_name)
  |> list.filter(fn(part) { part != "" })
  |> list.fold("/api/gateway", fn(acc, part) { acc <> "/" <> part })
}

fn part_name(token: String) -> String {
  case string.starts_with(token, "\"") {
    True -> unquote(token)
    False ->
      case token {
        "id" -> "{id}"
        "server" -> "{server_id}"
        "policy" -> "{policy_id}"
        "alert" -> "{alert_id}"
        "approval" -> "{approval_id}"
        "token" -> "{token_id}"
        _ -> ""
      }
  }
}

fn unquote(token: String) -> String {
  case string.split_once(token, "\"") {
    Error(_) -> ""
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Ok(#(name, _)) -> name
        Error(_) -> ""
      }
  }
}
