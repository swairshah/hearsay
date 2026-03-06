import AVFoundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.swair.hearsay", category: "microphone")

/// Manages microphone device enumeration, priority ordering, and automatic fallback.
/// Monitors device connect/disconnect events and selects the highest-priority available device.
final class MicrophoneManager {
    
    static let shared = MicrophoneManager()
    
    // MARK: - Types
    
    struct AudioDevice: Equatable, Codable {
        let uid: String
        let name: String
        let isBuiltIn: Bool
        
        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            lhs.uid == rhs.uid
        }
    }
    
    // MARK: - Callbacks
    
    /// Called when the active device changes (including on disconnect/fallback).
    /// Provides the new device or nil if no devices are available.
    var onActiveDeviceChanged: ((AudioDevice?) -> Void)?
    
    /// Called when the device list changes (connect/disconnect).
    var onDeviceListChanged: (([AudioDevice]) -> Void)?
    
    // MARK: - State
    
    /// Currently available input devices
    private(set) var availableDevices: [AudioDevice] = []
    
    /// The currently active device
    private(set) var activeDevice: AudioDevice?
    
    /// The user-selected device UID (nil = system default / auto)
    private(set) var selectedDeviceUID: String?
    
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listenerRegistered = false
    
    // MARK: - UserDefaults Keys
    
    private static let selectedDeviceKey = "selectedMicrophoneUID"
    
    // MARK: - Init
    
    private init() {
        loadSelectedDevice()
        refreshDevices()
        startDeviceMonitoring()
    }
    
    deinit {
        stopDeviceMonitoring()
    }
    
    // MARK: - Public API
    
    /// Select a specific microphone by UID.
    /// Pass nil to use the system default (auto-selects built-in mic as fallback).
    func selectDevice(uid: String?) {
        selectedDeviceUID = uid
        saveSelectedDevice()
        updateActiveDevice()
    }
    
    /// Get the AudioDeviceID (CoreAudio) for a given device UID.
    /// Returns nil if the device is not found.
    func audioDeviceID(for uid: String) -> AudioDeviceID? {
        // Look up the device by iterating available devices and matching UID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard status == noErr else { return nil }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return nil }
        
        for deviceID in deviceIDs {
            if getDeviceUID(deviceID) == uid {
                return deviceID
            }
        }
        
        return nil
    }
    
    /// Force a refresh of the device list and active device.
    func refresh() {
        refreshDevices()
    }
    
    // MARK: - Device Enumeration
    
    private func refreshDevices() {
        let newDevices = enumerateInputDevices()
        let changed = newDevices != availableDevices
        availableDevices = newDevices
        
        if changed {
            logger.info("Device list changed: \(newDevices.map { $0.name }.joined(separator: ", "))")
            onDeviceListChanged?(newDevices)
        }
        
        updateActiveDevice()
    }
    
    private func enumerateInputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard status == noErr else {
            logger.error("Failed to get device list size: \(status)")
            return []
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else {
            logger.error("Failed to get device list: \(status)")
            return []
        }
        
        var result: [AudioDevice] = []
        
        for deviceID in deviceIDs {
            // Check if device has input channels
            guard hasInputChannels(deviceID) else { continue }
            
            guard let uid = getDeviceUID(deviceID),
                  let name = getDeviceName(deviceID) else { continue }
            
            let isBuiltIn = getTransportType(deviceID) == kAudioDeviceTransportTypeBuiltIn
            
            result.append(AudioDevice(uid: uid, name: name, isBuiltIn: isBuiltIn))
        }
        
        return result
    }
    
    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }
        
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }
        
        let status2 = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status2 == noErr else { return false }
        
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
    
    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid)
        guard status == noErr else { return nil }
        return uid as String
    }
    
    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr else { return nil }
        return name as String
    }
    
    private func getTransportType(_ deviceID: AudioDeviceID) -> AudioDevicePropertyID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transport)
        return transport
    }
    
    // MARK: - Active Device Selection
    
    private func updateActiveDevice() {
        let newActive: AudioDevice?
        
        if let uid = selectedDeviceUID,
           let device = availableDevices.first(where: { $0.uid == uid }) {
            // User selected a specific device and it's available
            newActive = device
        } else if selectedDeviceUID != nil {
            // User selected a device but it's not available — fall back to built-in
            newActive = availableDevices.first(where: { $0.isBuiltIn }) ?? availableDevices.first
        } else {
            // No explicit selection — prefer built-in mic, else first available
            newActive = availableDevices.first(where: { $0.isBuiltIn }) ?? availableDevices.first
        }
        
        if newActive != activeDevice {
            let oldName = activeDevice?.name ?? "none"
            let newName = newActive?.name ?? "none"
            logger.info("Active device changed: \(oldName) → \(newName)")
            activeDevice = newActive
            onActiveDeviceChanged?(newActive)
        }
    }
    
    // MARK: - Device Monitoring
    
    private func startDeviceMonitoring() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        listenerBlock = block
        
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        
        if status == noErr {
            listenerRegistered = true
            logger.info("Device monitoring started")
        } else {
            logger.error("Failed to start device monitoring: \(status)")
        }
    }
    
    private func stopDeviceMonitoring() {
        guard listenerRegistered, let block = listenerBlock else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        
        listenerRegistered = false
        listenerBlock = nil
        logger.info("Device monitoring stopped")
    }
    
    // MARK: - Persistence
    
    private func loadSelectedDevice() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.selectedDeviceKey)
    }
    
    private func saveSelectedDevice() {
        if let uid = selectedDeviceUID {
            UserDefaults.standard.set(uid, forKey: Self.selectedDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedDeviceKey)
        }
    }
}
