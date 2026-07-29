use std::env;
use std::fs;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 || args[1] != "parse" {
        eprintln!("Usage: glue parse <file>");
        process::exit(1);
    }
    let filename = &args[2];
    let source = match fs::read_to_string(filename) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Error reading {}: {}", filename, e);
            process::exit(1);
        }
    };
    // TODO: parse and print AST
    eprintln!("Source: {} bytes", source.len());
}
