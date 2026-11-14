import analytics
import gleeunit/should

pub fn analytics_skips_loopback_hosts_test() {
  analytics.track_on_this_host("localhost") |> should.equal(False)
  analytics.track_on_this_host("127.0.0.1") |> should.equal(False)
  analytics.track_on_this_host("[::1]") |> should.equal(False)
  analytics.track_on_this_host("fizzlayer.com") |> should.equal(True)
}

pub fn page_url_keeps_only_the_origin_and_path_test() {
  analytics.page_url("https://fizzlayer.com", "/app.html")
  |> should.equal("https://fizzlayer.com/app.html")
  analytics.page_url("http://localhost:3000", "/status")
  |> should.equal("http://localhost:3000/status")
}
