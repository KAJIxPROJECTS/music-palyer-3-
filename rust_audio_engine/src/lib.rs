use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use std::fs::File;
use std::ffi::CStr;
use std::os::raw::c_char;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use ringbuf::traits::*;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions};
use symphonia::core::errors::Error;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

struct PlaybackControl {
    is_playing: AtomicBool,
    seek_request: AtomicBool,
    seek_target: Mutex<Option<f32>>,
    position_ms: AtomicU32,
    duration_ms: AtomicU32,
    buffer_epoch: AtomicU32,
    clear_acknowledged: AtomicU32,
    samples_played: AtomicU64,
}

pub struct Player {
    control: Arc<PlaybackControl>,
    _stream: cpal::Stream,
    stop_signal: Arc<AtomicBool>,
    decoding_thread: Option<thread::JoinHandle<()>>,
    load_path: Arc<Mutex<Option<String>>>,
    load_requested: Arc<AtomicBool>,
}

struct DecoderState {
    format_reader: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    in_sample_rate: u32,
    in_channels: usize,
    input_buffer: Vec<f32>,
    resample_fraction: f64,
}

fn open_file(path: &str) -> Result<(Box<dyn FormatReader>, Box<dyn Decoder>, u32, u32, usize, u64), Box<dyn std::error::Error>> {
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let hint = Hint::new();
    let format_opts = FormatOptions::default();
    let metadata_opts = MetadataOptions::default();
    let probed = symphonia::default::get_probe().format(&hint, mss, &format_opts, &metadata_opts)?;
    let format_reader = probed.format;
    let track = format_reader.default_track().ok_or("no track")?;
    let track_id = track.id;
    let decoder_opts = DecoderOptions::default();
    let decoder = symphonia::default::get_codecs().make(&track.codec_params, &decoder_opts)?;
    let in_sample_rate = track.codec_params.sample_rate.ok_or("no rate")?;
    let in_channels = track.codec_params.channels.ok_or("no channels")?.count();
    let mut duration_ms = 0;
    if let Some(n_frames) = track.codec_params.n_frames {
        if let Some(tb) = track.codec_params.time_base {
            let time = tb.calc_time(n_frames);
            duration_ms = time.seconds * 1000 + (time.frac * 1000.0) as u64;
        } else {
            duration_ms = (n_frames as f64 / in_sample_rate as f64 * 1000.0) as u64;
        }
    }
    Ok((format_reader, decoder, track_id, in_sample_rate, in_channels, duration_ms))
}

impl Player {
    pub fn new() -> Option<Self> {
        let host = cpal::default_host();
        let device = host.default_output_device()?;
        let supported_config = device.default_output_config().ok()?;
        let sample_format = supported_config.sample_format();
        let config: cpal::StreamConfig = supported_config.into();
        let out_sample_rate = config.sample_rate.0;
        let out_channels = config.channels as usize;

        let control = Arc::new(PlaybackControl {
            is_playing: AtomicBool::new(false),
            seek_request: AtomicBool::new(false),
            seek_target: Mutex::new(None),
            position_ms: AtomicU32::new(0),
            duration_ms: AtomicU32::new(0),
            buffer_epoch: AtomicU32::new(0),
            clear_acknowledged: AtomicU32::new(0),
            samples_played: AtomicU64::new(0),
        });

        let stop_signal = Arc::new(AtomicBool::new(false));
        let load_path: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let load_requested = Arc::new(AtomicBool::new(false));

        let rb = ringbuf::HeapRb::<f32>::new(96000);
        let (mut prod, mut cons) = rb.split();

        let control_cb = control.clone();
        let err_fn = |_| {};

        let stream = match sample_format {
            cpal::SampleFormat::F32 => {
                let control_cb = control_cb.clone();
                device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _| {
                        let epoch = control_cb.buffer_epoch.load(Ordering::Relaxed);
                        if epoch != control_cb.clear_acknowledged.load(Ordering::Relaxed) {
                            while cons.try_pop().is_some() {}
                            control_cb.clear_acknowledged.store(epoch, Ordering::Relaxed);
                        }
                        let playing = control_cb.is_playing.load(Ordering::Relaxed);
                        for sample in data.iter_mut() {
                            let mut s: f32 = 0.0;
                            if playing {
                                if let Some(ds) = cons.try_pop() {
                                    s = ds;
                                    control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                            *sample = s;
                        }
                        let played = control_cb.samples_played.load(Ordering::Relaxed);
                        let ms = (played as f64 / (out_sample_rate as f64 * out_channels as f64) * 1000.0) as u32;
                        control_cb.position_ms.store(ms, Ordering::Relaxed);
                    },
                    err_fn,
                    None
                ).ok()?
            }
            cpal::SampleFormat::I16 => {
                let control_cb = control_cb.clone();
                device.build_output_stream(
                    &config,
                    move |data: &mut [i16], _| {
                        let epoch = control_cb.buffer_epoch.load(Ordering::Relaxed);
                        if epoch != control_cb.clear_acknowledged.load(Ordering::Relaxed) {
                            while cons.try_pop().is_some() {}
                            control_cb.clear_acknowledged.store(epoch, Ordering::Relaxed);
                        }
                        let playing = control_cb.is_playing.load(Ordering::Relaxed);
                        for sample in data.iter_mut() {
                            let mut s: f32 = 0.0;
                            if playing {
                                if let Some(ds) = cons.try_pop() {
                                    s = ds;
                                    control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                            *sample = (s * 32767.0f32).clamp(-32768.0f32, 32767.0f32) as i16;
                        }
                        let played = control_cb.samples_played.load(Ordering::Relaxed);
                        let ms = (played as f64 / (out_sample_rate as f64 * out_channels as f64) * 1000.0) as u32;
                        control_cb.position_ms.store(ms, Ordering::Relaxed);
                    },
                    err_fn,
                    None
                ).ok()?
            }
            cpal::SampleFormat::U16 => {
                let control_cb = control_cb.clone();
                device.build_output_stream(
                    &config,
                    move |data: &mut [u16], _| {
                        let epoch = control_cb.buffer_epoch.load(Ordering::Relaxed);
                        if epoch != control_cb.clear_acknowledged.load(Ordering::Relaxed) {
                            while cons.try_pop().is_some() {}
                            control_cb.clear_acknowledged.store(epoch, Ordering::Relaxed);
                        }
                        let playing = control_cb.is_playing.load(Ordering::Relaxed);
                        for sample in data.iter_mut() {
                            let mut s: f32 = 0.0;
                            if playing {
                                if let Some(ds) = cons.try_pop() {
                                    s = ds;
                                    control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                            *sample = ((s * 0.5f32 + 0.5f32) * 65535.0f32).clamp(0.0f32, 65535.0f32) as u16;
                        }
                        let played = control_cb.samples_played.load(Ordering::Relaxed);
                        let ms = (played as f64 / (out_sample_rate as f64 * out_channels as f64) * 1000.0) as u32;
                        control_cb.position_ms.store(ms, Ordering::Relaxed);
                    },
                    err_fn,
                    None
                ).ok()?
            }
            _ => return None,
        };

        stream.play().ok()?;

        let stop_signal_thread = stop_signal.clone();
        let control_thread = control.clone();
        let load_path_thread = load_path.clone();
        let load_requested_thread = load_requested.clone();

        let decoding_thread = thread::spawn(move || {
            let mut state: Option<DecoderState> = None;
            while !stop_signal_thread.load(Ordering::Relaxed) {
                if load_requested_thread.load(Ordering::Relaxed) {
                    let path = {
                        let mut guard = load_path_thread.lock().unwrap();
                        guard.take()
                    };
                    if let Some(p) = path {
                        if let Ok((format_reader, decoder, track_id, in_sample_rate, in_channels, duration_ms)) = open_file(&p) {
                            state = Some(DecoderState {
                                format_reader,
                                decoder,
                                track_id,
                                in_sample_rate,
                                in_channels,
                                input_buffer: Vec::new(),
                                resample_fraction: 0.0,
                            });
                            control_thread.duration_ms.store(duration_ms as u32, Ordering::Relaxed);
                            control_thread.position_ms.store(0, Ordering::Relaxed);
                            control_thread.samples_played.store(0, Ordering::Relaxed);
                            let epoch = control_thread.buffer_epoch.fetch_add(1, Ordering::Relaxed) + 1;
                            for _ in 0..50 {
                                if control_thread.clear_acknowledged.load(Ordering::Relaxed) == epoch {
                                    break;
                                }
                                thread::sleep(Duration::from_millis(1));
                            }
                        }
                    }
                    load_requested_thread.store(false, Ordering::Relaxed);
                }

                if let Some(ref mut s) = state {
                    if control_thread.seek_request.load(Ordering::Relaxed) {
                        let target = {
                            let mut guard = control_thread.seek_target.lock().unwrap();
                            guard.take()
                        };
                        if let Some(secs) = target {
                            let seek_to = SeekTo::Time {
                                time: symphonia::core::units::Time::from(secs as f64),
                                track_id: Some(s.track_id),
                            };
                            if s.format_reader.seek(SeekMode::Coarse, seek_to).is_ok() {
                                s.input_buffer.clear();
                                s.resample_fraction = 0.0;
                                let played = (secs as f64 * out_sample_rate as f64 * out_channels as f64) as u64;
                                control_thread.samples_played.store(played, Ordering::Relaxed);
                                control_thread.position_ms.store((secs * 1000.0) as u32, Ordering::Relaxed);
                                let epoch = control_thread.buffer_epoch.fetch_add(1, Ordering::Relaxed) + 1;
                                for _ in 0..50 {
                                    if control_thread.clear_acknowledged.load(Ordering::Relaxed) == epoch {
                                        break;
                                    }
                                    thread::sleep(Duration::from_millis(1));
                                }
                            }
                        }
                        control_thread.seek_request.store(false, Ordering::Relaxed);
                    }

                    if prod.vacant_len() > 8000 {
                        match s.format_reader.next_packet() {
                            Ok(packet) => {
                                if packet.track_id() == s.track_id {
                                    if let Ok(decoded) = s.decoder.decode(&packet) {
                                        let mut sample_buf = SampleBuffer::<f32>::new(
                                            decoded.capacity() as u64,
                                            *decoded.spec(),
                                        );
                                        sample_buf.copy_interleaved_ref(decoded);
                                        let samples = sample_buf.samples();
                                        let in_frames = samples.len() / s.in_channels;
                                        let mut mixed = Vec::with_capacity(in_frames * out_channels);
                                        for i in 0..in_frames {
                                            let frame_start = i * s.in_channels;
                                            let frame = &samples[frame_start..frame_start + s.in_channels];
                                            if s.in_channels == out_channels {
                                                mixed.extend_from_slice(frame);
                                            } else if s.in_channels == 1 {
                                                for _ in 0..out_channels {
                                                    mixed.push(frame[0]);
                                                }
                                            } else {
                                                for c in 0..out_channels {
                                                    if c < s.in_channels {
                                                        mixed.push(frame[c]);
                                                    } else {
                                                        mixed.push(0.0);
                                                    }
                                                }
                                            }
                                        }
                                        s.input_buffer.extend_from_slice(&mixed);
                                        let ratio = s.in_sample_rate as f64 / out_sample_rate as f64;
                                        let mut output = Vec::new();
                                        while s.resample_fraction + 1.0 < (s.input_buffer.len() / out_channels) as f64 {
                                            let idx = s.resample_fraction.floor() as usize;
                                            let t = s.resample_fraction - idx as f64;
                                            for c in 0..out_channels {
                                                let s0 = s.input_buffer[idx * out_channels + c];
                                                let s1 = s.input_buffer[(idx + 1) * out_channels + c];
                                                let val = s0 + t as f32 * (s1 - s0);
                                                output.push(val);
                                            }
                                            s.resample_fraction += ratio;
                                        }
                                        let consumed_frames = s.resample_fraction.floor() as usize;
                                        s.input_buffer.drain(0..consumed_frames * out_channels);
                                        s.resample_fraction -= consumed_frames as f64;
                                        let mut pushed = 0;
                                        while pushed < output.len() {
                                            if stop_signal_thread.load(Ordering::Relaxed) {
                                                break;
                                            }
                                            let chunk = &output[pushed..];
                                            let written = prod.push_slice(chunk);
                                            if written == 0 {
                                                thread::sleep(Duration::from_millis(5));
                                            } else {
                                                pushed += written;
                                            }
                                        }
                                    }
                                }
                            }
                            Err(Error::IoError(ref err)) if err.kind() == std::io::ErrorKind::UnexpectedEof => {
                                control_thread.is_playing.store(false, Ordering::Relaxed);
                                let seek_to = SeekTo::Time {
                                    time: symphonia::core::units::Time::from(0.0),
                                    track_id: Some(s.track_id),
                                };
                                if s.format_reader.seek(SeekMode::Coarse, seek_to).is_ok() {
                                    s.input_buffer.clear();
                                    s.resample_fraction = 0.0;
                                    control_thread.samples_played.store(0, Ordering::Relaxed);
                                    control_thread.position_ms.store(0, Ordering::Relaxed);
                                    let epoch = control_thread.buffer_epoch.fetch_add(1, Ordering::Relaxed) + 1;
                                    for _ in 0..50 {
                                        if control_thread.clear_acknowledged.load(Ordering::Relaxed) == epoch {
                                            break;
                                        }
                                        thread::sleep(Duration::from_millis(1));
                                    }
                                }
                            }
                            Err(_) => {
                                thread::sleep(Duration::from_millis(10));
                            }
                        }
                    } else {
                        thread::sleep(Duration::from_millis(10));
                    }
                } else {
                    thread::sleep(Duration::from_millis(10));
                }
            }
        });

        Some(Player {
            control,
            _stream: stream,
            stop_signal,
            decoding_thread: Some(decoding_thread),
            load_path,
            load_requested,
        })
    }

    pub fn load(&self, path: &str) {
        {
            let mut guard = self.load_path.lock().unwrap();
            *guard = Some(path.to_string());
        }
        self.load_requested.store(true, Ordering::Relaxed);
    }

    pub fn play(&self) {
        self.control.is_playing.store(true, Ordering::Relaxed);
    }

    pub fn pause(&self) {
        self.control.is_playing.store(false, Ordering::Relaxed);
    }

    pub fn stop(&self) {
        self.control.is_playing.store(false, Ordering::Relaxed);
        self.seek(0.0);
    }

    pub fn seek(&self, seconds: f32) {
        {
            let mut guard = self.control.seek_target.lock().unwrap();
            *guard = Some(seconds);
        }
        self.control.seek_request.store(true, Ordering::Relaxed);
    }

    pub fn get_position(&self) -> u32 {
        self.control.position_ms.load(Ordering::Relaxed)
    }

    pub fn get_duration(&self) -> u32 {
        self.control.duration_ms.load(Ordering::Relaxed)
    }

    pub fn is_playing(&self) -> bool {
        self.control.is_playing.load(Ordering::Relaxed)
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.stop_signal.store(true, Ordering::Relaxed);
        if let Some(t) = self.decoding_thread.take() {
            let _ = t.join();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_create() -> *mut Player {
    if let Some(player) = Player::new() {
        Box::into_raw(Box::new(player))
    } else {
        std::ptr::null_mut()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_destroy(player: *mut Player) {
    if !player.is_null() {
        unsafe {
            let _ = Box::from_raw(player);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_load(player: *mut Player, path: *const c_char) -> i32 {
    if player.is_null() || path.is_null() {
        return -1;
    }
    let c_str = unsafe { CStr::from_ptr(path) };
    let path_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -2,
    };
    let p = unsafe { &*player };
    p.load(path_str);
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn player_play(player: *mut Player) {
    if !player.is_null() {
        let p = unsafe { &*player };
        p.play();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_pause(player: *mut Player) {
    if !player.is_null() {
        let p = unsafe { &*player };
        p.pause();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_stop(player: *mut Player) {
    if !player.is_null() {
        let p = unsafe { &*player };
        p.stop();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_seek(player: *mut Player, seconds: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        p.seek(seconds);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_get_position(player: *mut Player) -> u32 {
    if player.is_null() {
        return 0;
    }
    let p = unsafe { &*player };
    p.get_position()
}

#[unsafe(no_mangle)]
pub extern "C" fn player_get_duration(player: *mut Player) -> u32 {
    if player.is_null() {
        return 0;
    }
    let p = unsafe { &*player };
    p.get_duration()
}

#[unsafe(no_mangle)]
pub extern "C" fn player_is_playing(player: *mut Player) -> bool {
    if player.is_null() {
        return false;
    }
    let p = unsafe { &*player };
    p.is_playing()
}

#[unsafe(no_mangle)]
pub extern "C" fn player_get_device_name(name_buf: *mut u8, max_len: u32) -> i32 {
    let host = cpal::default_host();
    if let Some(device) = host.default_output_device() {
        if let Ok(name) = device.name() {
            let bytes = name.as_bytes();
            let len = std::cmp::min(bytes.len(), max_len as usize - 1);
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), name_buf, len);
                *name_buf.add(len) = 0;
            }
            return len as i32;
        }
    }
    -1
}

#[unsafe(no_mangle)]
pub extern "C" fn player_get_device_sample_rate() -> i32 {
    let host = cpal::default_host();
    if let Some(device) = host.default_output_device() {
        if let Ok(supported_config) = device.default_output_config() {
            return supported_config.sample_rate().0 as i32;
        }
    }
    -1
}

#[unsafe(no_mangle)]
pub extern "C" fn player_get_device_channels() -> i32 {
    let host = cpal::default_host();
    if let Some(device) = host.default_output_device() {
        if let Ok(supported_config) = device.default_output_config() {
            return supported_config.channels() as i32;
        }
    }
    -1
}

#[unsafe(no_mangle)]
pub extern "C" fn test_onnx_runtime() -> i32 {
    if ort::init()
        .with_name("rust_audio_engine")
        .commit()
    {
        1
    } else {
        0
    }
}
