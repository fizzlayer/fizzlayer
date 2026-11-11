#[tokio::main]
async fn main() {
    if let Err(error) = fizz::serve::run().await {
        eprintln!("fizz-serve: {error}");
        std::process::exit(1);
    }
}
