use std::io::{self, Write};
use std::thread;
use std::time::Duration;
use rust_audio_engine::Player;

struct PlaybackController {
    player: Player,
    queue: Vec<String>,
    index: usize,
}

impl PlaybackController {
    fn new() -> Self {
        PlaybackController {
            player: Player::new().expect("failed to init player"),
            queue: Vec::new(),
            index: 0,
        }
    }

    fn add(&mut self, path: String) {
        self.queue.push(path);
    }

    fn play(&mut self) {
        if self.queue.is_empty() {
            return;
        }
        if self.index >= self.queue.len() {
            self.index = 0;
        }
        let path = &self.queue[self.index];
        self.player.load(path);
        thread::sleep(Duration::from_millis(500));
        self.player.play();
    }

    fn pause(&self) {
        self.player.pause();
    }

    fn resume(&self) {
        self.player.play();
    }

    fn stop(&self) {
        self.player.stop();
    }

    fn next(&mut self) {
        if self.queue.is_empty() {
            return;
        }
        self.index = (self.index + 1) % self.queue.len();
        self.play();
    }

    fn prev(&mut self) {
        if self.queue.is_empty() {
            return;
        }
        if self.index == 0 {
            self.index = self.queue.len() - 1;
        } else {
            self.index -= 1;
        }
        self.play();
    }

    fn seek(&self, seconds: f32) {
        self.player.seek(seconds);
    }
}

fn main() {
    let mut controller = PlaybackController::new();
    let mut input = String::new();
    loop {
        print!("> ");
        io::stdout().flush().unwrap();
        input.clear();
        if io::stdin().read_line(&mut input).is_err() {
            break;
        }
        let line = input.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.splitn(2, ' ').collect();
        let command = parts[0];
        match command {
            "add" => {
                if parts.len() >= 2 {
                    controller.add(parts[1].to_string());
                }
            }
            "play" => {
                controller.play();
            }
            "pause" => {
                controller.pause();
            }
            "resume" => {
                controller.resume();
            }
            "stop" => {
                controller.stop();
            }
            "next" => {
                controller.next();
            }
            "prev" => {
                controller.prev();
            }
            "seek" => {
                if parts.len() >= 2 {
                    if let Ok(secs) = parts[1].parse::<f32>() {
                        controller.seek(secs);
                    }
                }
            }
            "list" => {
                for (i, track) in controller.queue.iter().enumerate() {
                    let active = if i == controller.index { "*" } else { " " };
                    println!("{} [{}] {}", active, i, track);
                }
            }
            "status" => {
                let playing = controller.player.is_playing();
                let pos = controller.player.get_position();
                let dur = controller.player.get_duration();
                println!("playing: {}", playing);
                println!("position: {}/{} ms", pos, dur);
            }
            "exit" => {
                break;
            }
            _ => {}
        }
    }
}
