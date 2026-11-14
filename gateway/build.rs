fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?);
    let proto = manifest.join("proto/ext_mcp.proto");
    println!("cargo:rerun-if-changed={}", proto.display());
    // The proto imports google/protobuf/struct.proto from the system protoc include path.
    tonic_build::configure()
        .build_client(false)
        .build_server(true)
        .compile_protos(
            &[proto],
            &[
                manifest.join("proto"),
                std::path::PathBuf::from("/usr/include"),
            ],
        )?;
    Ok(())
}
