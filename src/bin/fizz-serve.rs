fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("init") => {
            let rest: Vec<String> = args.collect();
            match fizz::selfhost::init(&rest) {
                Ok(_) => {}
                Err(error) => {
                    eprintln!("fizz-serve init: {error}");
                    std::process::exit(1);
                }
            }
        }
        Some(other) => {
            eprintln!(
                "fizz-serve: unknown command `{other}`. Run with no arguments to serve, or `init --out PATH`."
            );
            std::process::exit(2);
        }
        None => serve(),
    }
}

#[tokio::main]
async fn serve() {
    if let Err(error) = fizz::serve::run().await {
        eprintln!("fizz-serve: {error}");
        std::process::exit(1);
    }
}
