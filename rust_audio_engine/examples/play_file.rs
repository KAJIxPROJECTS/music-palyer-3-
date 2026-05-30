use std::env;
use std::thread;
use std::time::Duration;
use std::io::Write;
use rust_audio_engine::Player;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        std::process::exit(1);
    }
    let path = &args[1];
    let player = Player::new().unwrap();
    player.load(path);
    thread::sleep(Duration::from_millis(500));
    player.play();
    while player.is_playing() || player.get_position() == 0 {
        thread::sleep(Duration::from_millis(100));
        let pos = player.get_position();
        let dur = player.get_duration();
        print!("\r{}/{} ms", pos, dur);
        std::io::stdout().flush().unwrap();
        if dur > 0 && pos >= dur {
            break;
        }
    }
}
