use std::sync::atomic::{AtomicBool, Ordering};

static VERBOSE: AtomicBool = AtomicBool::new(false);

pub fn verbose() -> bool {
    VERBOSE.load(Ordering::Relaxed)
}

/// Diagnostics go to stderr (stdout carries the JSON stream), only with `--verbose` or `HERDR_STATUS_LOG`.
macro_rules! log {
    ($($arg:tt)*) => {
        if crate::verbose() {
            eprintln!("herdr-status-bridge: {}", format!($($arg)*));
        }
    };
}

mod demo;
mod herdr;
mod monitor;
mod payload;
mod pi;
mod standalone;
mod status;
mod timers;

use std::env;
use std::path::PathBuf;
use std::time::Duration;

use demo::get_demo_agents;
use payload::{emit_payload, StatusPayload};

const USAGE: &str = "\
Usage: herdr-status-bridge [OPTIONS]

Streams Herdr agent status as newline-delimited JSON on stdout.

Options:
  --once           Print a single snapshot and exit
  --demo           Emit fixed demo agents (no Herdr connection)
  --socket <PATH>  Watch only this Herdr socket (also: HERDR_SOCKET);
                   default: every session under $XDG_CONFIG_HOME/herdr
  --detect-external
                   Also list agent processes running outside Herdr
                   (status unknown, not counted in the summary)
  --verbose        Log diagnostics to stderr (also: HERDR_STATUS_LOG=1)
  -h, --help       Show this help
  -V, --version    Show version";

#[derive(Debug, Default, PartialEq)]
struct Args {
    once: bool,
    demo: bool,
    socket: Option<String>,
    verbose: bool,
    detect_external: bool,
}

fn parse_args(args: impl IntoIterator<Item = String>) -> Result<Option<Args>, String> {
    let mut parsed = Args::default();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--once" => parsed.once = true,
            "--demo" => parsed.demo = true,
            "--verbose" => parsed.verbose = true,
            "--detect-external" => parsed.detect_external = true,
            "--socket" => {
                parsed.socket = Some(args.next().ok_or("--socket requires a path")?);
            }
            "-h" | "--help" => {
                println!("{}", USAGE);
                return Ok(None);
            }
            "-V" | "--version" => {
                println!("herdr-status-bridge {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            other => return Err(format!("unknown argument: {}", other)),
        }
    }
    Ok(Some(parsed))
}

fn main() {
    let args = match parse_args(env::args().skip(1)) {
        Ok(Some(args)) => args,
        Ok(None) => return,
        Err(e) => {
            eprintln!("herdr-status-bridge: {}\n\n{}", e, USAGE);
            std::process::exit(2);
        }
    };
    VERBOSE.store(
        args.verbose || env::var_os("HERDR_STATUS_LOG").is_some(),
        Ordering::Relaxed,
    );

    if args.demo {
        loop {
            emit_payload(&mut StatusPayload::new(true, get_demo_agents()));
            if args.once {
                break;
            }
            std::thread::sleep(Duration::from_millis(3000));
        }
        return;
    }

    let explicit_socket = args
        .socket
        .map(PathBuf::from)
        .or_else(|| env::var_os("HERDR_SOCKET").map(PathBuf::from));
    if args.once {
        monitor::snapshot_once(explicit_socket.as_deref(), args.detect_external);
    } else {
        monitor::run(explicit_socket.as_deref(), args.detect_external);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Option<Args>, String> {
        parse_args(args.iter().map(|s| s.to_string()))
    }

    #[test]
    fn test_parse_args() {
        assert_eq!(parse(&[]), Ok(Some(Args::default())));
        assert_eq!(
            parse(&["--once", "--socket", "/tmp/h.sock", "--verbose"]),
            Ok(Some(Args {
                once: true,
                demo: false,
                socket: Some("/tmp/h.sock".into()),
                verbose: true,
                detect_external: false,
            }))
        );
        assert!(parse(&["--socket"]).is_err());
        assert!(parse(&["--bogus"]).is_err());
    }
}
