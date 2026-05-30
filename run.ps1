# VibeSync AI Unified Run Script

# 1. Compile Rust Audio Engine
Write-Host "=== 1. Building Rust Audio Engine (Release) ===" -ForegroundColor Cyan
cargo build --manifest-path rust_audio_engine/Cargo.toml --release
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to build Rust Audio Engine"
    exit $LASTEXITCODE
}

# 2. Determine App Folder (handles rename)
$AppFolder = "mini_chatbox_ai"
if (Test-Path "music_player_4") {
    $AppFolder = "music_player_4"
}

# 3. Copy DLL to prevent FFI failures
Write-Host "=== 2. Syncing dynamic library DLL ===" -ForegroundColor Cyan
Copy-Item "rust_audio_engine/target/release/rust_audio_engine.dll" "$AppFolder/" -Force

$ReleaseDir = "$AppFolder/build/windows/x64/runner/Release"
if (!(Test-Path $ReleaseDir)) {
    New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null
}
Copy-Item "rust_audio_engine/target/release/rust_audio_engine.dll" "$ReleaseDir/" -Force

$DebugDir = "$AppFolder/build/windows/x64/runner/Debug"
if (!(Test-Path $DebugDir)) {
    New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null
}
Copy-Item "rust_audio_engine/target/release/rust_audio_engine.dll" "$DebugDir/" -Force

# 4. Start Flutter Application
Write-Host "=== 3. Launching Flutter Application ===" -ForegroundColor Cyan
Set-Location -Path $AppFolder
flutter run -d windows
