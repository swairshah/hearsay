import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "sound")

/// Plays bundled sound effects for recording lifecycle events.
final class SoundPlayer {
    
    static let shared = SoundPlayer()
    
    enum Sound: String {
        case recordingStart = "dictation-start"
        case recordingStop = "dictation-stop"
        case paste = "paste"
        case toggleLock = "popo-lock"
        case screenshot = "screenshot"
    }
    
    /// Whether sound effects are enabled (persisted in UserDefaults).
    var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundEffectsDisabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundEffectsDisabled") }
    }
    
    private var players: [Sound: AVAudioPlayer] = [:]
    
    private init() {
        preload(.recordingStart)
        preload(.recordingStop)
        preload(.paste)
        preload(.toggleLock)
        preload(.screenshot)
    }
    
    func play(_ sound: Sound) {
        guard isEnabled else {
            print("SoundPlayer: DISABLED, skipping \(sound.rawValue)")
            return
        }
        
        guard let player = players[sound] else {
            print("SoundPlayer: NOT LOADED \(sound.rawValue)")
            return
        }
        
        print("SoundPlayer: Playing \(sound.rawValue)")
        // Per-sound volume adjustment
        player.volume = sound == .screenshot ? 0.2 : 1.0
        // Reset to beginning if already playing and replay
        player.currentTime = 0
        player.play()
    }
    
    private func preload(_ sound: Sound) {
        // Try .wav first, then .aif
        let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav")
            ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "aif")
        guard let url else {
            print("SoundPlayer: FILE NOT FOUND \(sound.rawValue)")
            return
        }
        
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[sound] = player
            print("SoundPlayer: Preloaded \(sound.rawValue) from \(url.lastPathComponent)")
        } catch {
            print("SoundPlayer: FAILED to load \(sound.rawValue): \(error)")
        }
    }
}
