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

#[derive(Clone, Copy)]
struct BiquadFilter {
    b0: f32, b1: f32, b2: f32,
    a1: f32, a2: f32,
    x1: f32, x2: f32,
    y1: f32, y2: f32,
}

impl BiquadFilter {
    fn new() -> Self {
        Self {
            b0: 1.0, b1: 0.0, b2: 0.0,
            a1: 0.0, a2: 0.0,
            x1: 0.0, x2: 0.0,
            y1: 0.0, y2: 0.0,
        }
    }

    fn set_peaking(&mut self, sample_rate: f32, freq: f32, q: f32, gain_db: f32) {
        let w0 = 2.0 * std::f32::consts::PI * freq / sample_rate;
        let alpha = w0.sin() / (2.0 * q);
        let a = 10.0f32.powf(gain_db / 40.0);
        let cos_w0 = w0.cos();
        let b0 = 1.0 + alpha * a;
        let b1 = -2.0 * cos_w0;
        let b2 = 1.0 - alpha * a;
        let a0 = 1.0 + alpha / a;
        let a1 = -2.0 * cos_w0;
        let a2 = 1.0 - alpha / a;
        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }

    fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

struct DelayLine {
    buffer: Vec<f32>,
    write_idx: usize,
}

impl DelayLine {
    fn new(delay_samples: usize) -> Self {
        Self {
            buffer: vec![0.0; delay_samples],
            write_idx: 0,
        }
    }

    fn process(&mut self, input: f32, feedback: f32) -> f32 {
        if self.buffer.is_empty() { return input; }
        let read_idx = (self.write_idx + 1) % self.buffer.len();
        let delayed = self.buffer[read_idx];
        self.buffer[self.write_idx] = input + delayed * feedback;
        self.write_idx = read_idx;
        delayed
    }
}

struct Reverb {
    delays_l: Vec<DelayLine>,
    delays_r: Vec<DelayLine>,
}

impl Reverb {
    fn new(sample_rate: u32) -> Self {
        let sr = sample_rate as f32;
        let sizes = [0.035, 0.047, 0.059, 0.071];
        let delays_l = sizes.iter().map(|&s| DelayLine::new((s * sr) as usize)).collect();
        let delays_r = sizes.iter().map(|&s| DelayLine::new(((s + 0.003) * sr) as usize)).collect();
        Self { delays_l, delays_r }
    }

    fn process(&mut self, left: f32, right: f32, room_size: f32, mix: f32) -> (f32, f32) {
        if mix <= 0.001 {
            return (left, right);
        }
        let feedback = room_size.clamp(0.0, 0.95);
        let mut rev_l = 0.0;
        for d in self.delays_l.iter_mut() {
            rev_l += d.process(left, feedback);
        }
        rev_l /= self.delays_l.len() as f32;
        let mut rev_r = 0.0;
        for d in self.delays_r.iter_mut() {
            rev_r += d.process(right, feedback);
        }
        rev_r /= self.delays_r.len() as f32;
        let out_l = left * (1.0 - mix) + rev_l * mix;
        let out_r = right * (1.0 - mix) + rev_r * mix;
        (out_l, out_r)
    }
}

fn process_dsp_frame(
    left: f32,
    right: f32,
    preamp: f32,
    left_filters: &mut [BiquadFilter],
    right_filters: &mut [BiquadFilter],
    stereo_width: f32,
    pan: f32,
    reverb: &mut Reverb,
    room_size: f32,
    mix: f32,
    limiter: bool,
    limit_thresh: f32,
    limit_ratio: f32,
) -> (f32, f32) {
    let mut left = left * preamp;
    let mut right = right * preamp;
    for band in 0..10 {
        left = left_filters[band].process(left);
        right = right_filters[band].process(right);
    }
    let mid = (left + right) * 0.5;
    let side = (left - right) * 0.5;
    let side_widened = side * stereo_width;
    left = mid + side_widened;
    right = mid - side_widened;
    let (rev_l, rev_r) = reverb.process(left, right, room_size, mix);
    left = rev_l;
    right = rev_r;
    if pan < 0.0 {
        right *= 1.0 + pan;
    } else if pan > 0.0 {
        left *= 1.0 - pan;
    }
    if limiter {
        let thresh_linear = 10.0f32.powf(limit_thresh / 20.0);
        if left.abs() > thresh_linear {
            left = left.signum() * (thresh_linear + (left.abs() - thresh_linear) / limit_ratio);
        }
        if right.abs() > thresh_linear {
            right = right.signum() * (thresh_linear + (right.abs() - thresh_linear) / limit_ratio);
        }
    }
    (left, right)
}

struct PlaybackControl {
    is_playing: AtomicBool,
    seek_request: AtomicBool,
    seek_target: Mutex<Option<f32>>,
    position_ms: AtomicU32,
    duration_ms: AtomicU32,
    buffer_epoch: AtomicU32,
    clear_acknowledged: AtomicU32,
    samples_played: AtomicU64,
    preamp_gain: Mutex<f32>,
    eq_gains: Mutex<[f32; 10]>,
    stereo_expansion: Mutex<f32>,
    stereo_pan: Mutex<f32>,
    reverb_room_size: Mutex<f32>,
    reverb_mix: Mutex<f32>,
    limiter_enabled: AtomicBool,
    limiter_threshold: Mutex<f32>,
    limiter_ratio: Mutex<f32>,
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
            preamp_gain: Mutex::new(1.0),
            eq_gains: Mutex::new([0.0; 10]),
            stereo_expansion: Mutex::new(100.0),
            stereo_pan: Mutex::new(0.0),
            reverb_room_size: Mutex::new(0.0),
            reverb_mix: Mutex::new(0.0),
            limiter_enabled: AtomicBool::new(false),
            limiter_threshold: Mutex::new(0.0),
            limiter_ratio: Mutex::new(1.0),
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
                let mut left_filters = vec![BiquadFilter::new(); 10];
                let mut right_filters = vec![BiquadFilter::new(); 10];
                let freqs = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
                let mut reverb = Reverb::new(out_sample_rate);
                device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _| {
                        let epoch = control_cb.buffer_epoch.load(Ordering::Relaxed);
                        if epoch != control_cb.clear_acknowledged.load(Ordering::Relaxed) {
                            while cons.try_pop().is_some() {}
                            control_cb.clear_acknowledged.store(epoch, Ordering::Relaxed);
                        }
                        let playing = control_cb.is_playing.load(Ordering::Relaxed);
                        let preamp = *control_cb.preamp_gain.lock().unwrap();
                        let eq_gains = *control_cb.eq_gains.lock().unwrap();
                        let stereo_width = *control_cb.stereo_expansion.lock().unwrap() / 100.0;
                        let pan = *control_cb.stereo_pan.lock().unwrap();
                        let room_size = *control_cb.reverb_room_size.lock().unwrap() / 100.0;
                        let mix = *control_cb.reverb_mix.lock().unwrap() / 100.0;
                        let limiter = control_cb.limiter_enabled.load(Ordering::Relaxed);
                        let limit_thresh = *control_cb.limiter_threshold.lock().unwrap();
                        let limit_ratio = *control_cb.limiter_ratio.lock().unwrap();
                        for i in 0..10 {
                            left_filters[i].set_peaking(out_sample_rate as f32, freqs[i], 1.0, eq_gains[i]);
                            right_filters[i].set_peaking(out_sample_rate as f32, freqs[i], 1.0, eq_gains[i]);
                        }
                        let mut idx = 0;
                        while idx < data.len() {
                            let mut left = 0.0;
                            let mut right = 0.0;
                            if playing {
                                if let Some(l_val) = cons.try_pop() {
                                    left = l_val;
                                    control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                }
                                if out_channels > 1 {
                                    if let Some(r_val) = cons.try_pop() {
                                        right = r_val;
                                        control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                    }
                                } else {
                                    right = left;
                                }
                            }
                            let (l_out, r_out) = process_dsp_frame(
                                left,
                                right,
                                preamp,
                                &mut left_filters,
                                &mut right_filters,
                                stereo_width,
                                pan,
                                &mut reverb,
                                room_size,
                                mix,
                                limiter,
                                limit_thresh,
                                limit_ratio,
                            );
                            if out_channels == 1 {
                                data[idx] = l_out;
                                idx += 1;
                            } else {
                                if idx < data.len() {
                                    data[idx] = l_out;
                                }
                                if idx + 1 < data.len() {
                                    data[idx + 1] = r_out;
                                }
                                for c in 2..out_channels {
                                    if idx + c < data.len() {
                                        data[idx + c] = 0.0;
                                    }
                                }
                                idx += out_channels;
                            }
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
                let mut left_filters = vec![BiquadFilter::new(); 10];
                let mut right_filters = vec![BiquadFilter::new(); 10];
                let freqs = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
                let mut reverb = Reverb::new(out_sample_rate);
                device.build_output_stream(
                    &config,
                    move |data: &mut [i16], _| {
                        let epoch = control_cb.buffer_epoch.load(Ordering::Relaxed);
                        if epoch != control_cb.clear_acknowledged.load(Ordering::Relaxed) {
                            while cons.try_pop().is_some() {}
                            control_cb.clear_acknowledged.store(epoch, Ordering::Relaxed);
                        }
                        let playing = control_cb.is_playing.load(Ordering::Relaxed);
                        let preamp = *control_cb.preamp_gain.lock().unwrap();
                        let eq_gains = *control_cb.eq_gains.lock().unwrap();
                        let stereo_width = *control_cb.stereo_expansion.lock().unwrap() / 100.0;
                        let pan = *control_cb.stereo_pan.lock().unwrap();
                        let room_size = *control_cb.reverb_room_size.lock().unwrap() / 100.0;
                        let mix = *control_cb.reverb_mix.lock().unwrap() / 100.0;
                        let limiter = control_cb.limiter_enabled.load(Ordering::Relaxed);
                        let limit_thresh = *control_cb.limiter_threshold.lock().unwrap();
                        let limit_ratio = *control_cb.limiter_ratio.lock().unwrap();
                        for i in 0..10 {
                            left_filters[i].set_peaking(out_sample_rate as f32, freqs[i], 1.0, eq_gains[i]);
                            right_filters[i].set_peaking(out_sample_rate as f32, freqs[i], 1.0, eq_gains[i]);
                        }
                        let mut idx = 0;
                        while idx < data.len() {
                            let mut left = 0.0;
                            let mut right = 0.0;
                            if playing {
                                if let Some(l_val) = cons.try_pop() {
                                    left = l_val;
                                    control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                }
                                if out_channels > 1 {
                                    if let Some(r_val) = cons.try_pop() {
                                        right = r_val;
                                        control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                    }
                                } else {
                                    right = left;
                                }
                            }
                            let (l_out, r_out) = process_dsp_frame(
                                left,
                                right,
                                preamp,
                                &mut left_filters,
                                &mut right_filters,
                                stereo_width,
                                pan,
                                &mut reverb,
                                room_size,
                                mix,
                                limiter,
                                limit_thresh,
                                limit_ratio,
                            );
                            if out_channels == 1 {
                                data[idx] = (l_out * 32767.0).clamp(-32768.0, 32767.0) as i16;
                                idx += 1;
                            } else {
                                if idx < data.len() {
                                    data[idx] = (l_out * 32767.0).clamp(-32768.0, 32767.0) as i16;
                                }
                                if idx + 1 < data.len() {
                                    data[idx + 1] = (r_out * 32767.0).clamp(-32768.0, 32767.0) as i16;
                                }
                                for c in 2..out_channels {
                                    if idx + c < data.len() {
                                        data[idx + c] = 0;
                                    }
                                }
                                idx += out_channels;
                            }
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
                let mut left_filters = vec![BiquadFilter::new(); 10];
                let mut right_filters = vec![BiquadFilter::new(); 10];
                let freqs = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
                let mut reverb = Reverb::new(out_sample_rate);
                device.build_output_stream(
                    &config,
                    move |data: &mut [u16], _| {
                        let epoch = control_cb.buffer_epoch.load(Ordering::Relaxed);
                        if epoch != control_cb.clear_acknowledged.load(Ordering::Relaxed) {
                            while cons.try_pop().is_some() {}
                            control_cb.clear_acknowledged.store(epoch, Ordering::Relaxed);
                        }
                        let playing = control_cb.is_playing.load(Ordering::Relaxed);
                        let preamp = *control_cb.preamp_gain.lock().unwrap();
                        let eq_gains = *control_cb.eq_gains.lock().unwrap();
                        let stereo_width = *control_cb.stereo_expansion.lock().unwrap() / 100.0;
                        let pan = *control_cb.stereo_pan.lock().unwrap();
                        let room_size = *control_cb.reverb_room_size.lock().unwrap() / 100.0;
                        let mix = *control_cb.reverb_mix.lock().unwrap() / 100.0;
                        let limiter = control_cb.limiter_enabled.load(Ordering::Relaxed);
                        let limit_thresh = *control_cb.limiter_threshold.lock().unwrap();
                        let limit_ratio = *control_cb.limiter_ratio.lock().unwrap();
                        for i in 0..10 {
                            left_filters[i].set_peaking(out_sample_rate as f32, freqs[i], 1.0, eq_gains[i]);
                            right_filters[i].set_peaking(out_sample_rate as f32, freqs[i], 1.0, eq_gains[i]);
                        }
                        let mut idx = 0;
                        while idx < data.len() {
                            let mut left = 0.0;
                            let mut right = 0.0;
                            if playing {
                                if let Some(l_val) = cons.try_pop() {
                                    left = l_val;
                                    control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                }
                                if out_channels > 1 {
                                    if let Some(r_val) = cons.try_pop() {
                                        right = r_val;
                                        control_cb.samples_played.fetch_add(1, Ordering::Relaxed);
                                    }
                                } else {
                                    right = left;
                                }
                            }
                            let (l_out, r_out) = process_dsp_frame(
                                left,
                                right,
                                preamp,
                                &mut left_filters,
                                &mut right_filters,
                                stereo_width,
                                pan,
                                &mut reverb,
                                room_size,
                                mix,
                                limiter,
                                limit_thresh,
                                limit_ratio,
                            );
                            if out_channels == 1 {
                                data[idx] = ((l_out * 0.5 + 0.5) * 65535.0).clamp(0.0, 65535.0) as u16;
                                idx += 1;
                            } else {
                                if idx < data.len() {
                                    data[idx] = ((l_out * 0.5 + 0.5) * 65535.0).clamp(0.0, 65535.0) as u16;
                                }
                                if idx + 1 < data.len() {
                                    data[idx + 1] = ((r_out * 0.5 + 0.5) * 65535.0).clamp(0.0, 65535.0) as u16;
                                }
                                for c in 2..out_channels {
                                    if idx + c < data.len() {
                                        data[idx + c] = 32768;
                                    }
                                }
                                idx += out_channels;
                            }
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
                                }
                                control_thread.position_ms.store(control_thread.duration_ms.load(Ordering::Relaxed), Ordering::Relaxed);
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

#[unsafe(no_mangle)]
pub extern "C" fn player_set_preamp(player: *mut Player, db: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        let preamp = 10.0f32.powf(db / 20.0);
        *p.control.preamp_gain.lock().unwrap() = preamp;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_eq_band(player: *mut Player, band_idx: i32, db: f32) {
    if !player.is_null() && band_idx >= 0 && band_idx < 10 {
        let p = unsafe { &*player };
        p.control.eq_gains.lock().unwrap()[band_idx as usize] = db;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_stereo_expansion(player: *mut Player, percent: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        *p.control.stereo_expansion.lock().unwrap() = percent;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_stereo_pan(player: *mut Player, pan: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        *p.control.stereo_pan.lock().unwrap() = pan;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_reverb_room_size(player: *mut Player, percent: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        *p.control.reverb_room_size.lock().unwrap() = percent;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_reverb_mix(player: *mut Player, percent: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        *p.control.reverb_mix.lock().unwrap() = percent;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_limiter_enabled(player: *mut Player, enabled: bool) {
    if !player.is_null() {
        let p = unsafe { &*player };
        p.control.limiter_enabled.store(enabled, Ordering::Relaxed);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_limiter_threshold(player: *mut Player, db: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        *p.control.limiter_threshold.lock().unwrap() = db;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn player_set_limiter_ratio(player: *mut Player, ratio: f32) {
    if !player.is_null() {
        let p = unsafe { &*player };
        *p.control.limiter_ratio.lock().unwrap() = ratio;
    }
}
