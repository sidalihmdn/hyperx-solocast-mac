import SwiftUI
import AVFoundation
import Accelerate

// Menu bar app for the HyperX SoloCast.
// Hardware settings (gain, mute, sample rate) go through CoreAudio.
// Gate, EQ and compressor are Apple's built-in audio units; the processed signal is sent to the
// BlackHole virtual device, which other apps then select as their microphone.
// The mic's vendor HID interface (usage page 0xFFC0, report 0x66) is undocumented, so it is left alone.

// MARK: - CoreAudio helpers

typealias Address = AudioObjectPropertyAddress

func address(_ selector: AudioObjectPropertySelector, input: Bool = false, element: UInt32 = 0) -> Address {
    Address(mSelector: selector,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioObjectPropertyScopeGlobal,
            mElement: element)
}

func read<T>(_ id: AudioObjectID, _ addr: Address, _ initial: T) -> T? {
    var addr = addr, value = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readArray<T>(_ id: AudioObjectID, _ addr: Address, _ initial: T) -> [T] {
    var addr = addr, size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
    var values = [T](repeating: initial, count: Int(size) / MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &values) == noErr ? values : []
}

@discardableResult
func write<T>(_ id: AudioObjectID, _ addr: Address, _ value: T) -> Bool {
    var addr = addr, value = value
    return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
}

func findDevice(named fragment: String) -> AudioObjectID? {
    readArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioObjectID(0))
        .first { id in
            let name = read(id, address(kAudioObjectPropertyName), nil as Unmanaged<CFString>?)
            return (name??.takeRetainedValue() as String?)?.contains(fragment) ?? false
        }
}

/// AVAudioEngine cannot keep input and output on two different devices (it ends up capturing from the
/// output device), so both nodes use one private aggregate: mic first, so its channels are inputs 1-2.
func makeAggregate(mic: AudioObjectID, sink: AudioObjectID) -> AudioObjectID? {
    guard let micUID = read(mic, address(kAudioDevicePropertyDeviceUID), nil as Unmanaged<CFString>?)??.takeRetainedValue(),
          let sinkUID = read(sink, address(kAudioDevicePropertyDeviceUID), nil as Unmanaged<CFString>?)??.takeRetainedValue()
    else { return nil }
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "SoloCast Engine",
        kAudioAggregateDeviceUIDKey: "local.solocast.engine",
        kAudioAggregateDeviceIsPrivateKey: 1,   // hidden from other apps, removed when this app quits
        kAudioAggregateDeviceMainSubDeviceKey: micUID,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: micUID],
            [kAudioSubDeviceUIDKey: sinkUID, kAudioSubDeviceDriftCompensationKey: 1],
        ],
    ]
    var id: AudioObjectID = 0
    return AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr ? id : nil
}

// MARK: - Processing (gate, EQ, compressor)

struct Settings: Codable, Equatable {
    var gateOn = false
    var gateThreshold: Float = -45      // dB; quieter than this is silenced
    var eqOn = false
    var eqGains: [Float] = [0, 0, 0, 0, 0]  // dB per band in Processor.bands
    var compOn = false
    var compThreshold: Float = -20      // dB; louder than this is compressed
    var makeup: Float = 0               // dB added after compression

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let saved = try? JSONDecoder().decode(Settings.self, from: data),
              saved.eqGains.count == Processor.bands.count else { return Settings() }
        return saved
    }
}

final class Meters: ObservableObject {
    @Published var input: Float = -120
    @Published var inputPeak: Float = -120
    @Published var output: Float = -120
    @Published var reduction: Float = 0   // dB of gain the compressor is removing right now
}

func peakDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return -120 }
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        var magnitude: Float = 0
        vDSP_maxmgv(channels[channel], 1, &magnitude, vDSP_Length(buffer.frameLength))
        peak = max(peak, magnitude)
    }
    return 20 * log10(max(peak, 1e-6))
}

final class Processor: ObservableObject {
    static let bands: [Float] = [80, 250, 1000, 4000, 10000]
    static let virtualDevice = "BlackHole"

    let meters = Meters()
    var persist = true
    @Published var routed = false   // true while processed audio is going to the virtual device
    @Published var settings = Settings.load() {
        didSet {
            apply()
            if persist, let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "settings")
            }
        }
    }

    private var engine = AVAudioEngine()
    private var eq = AVAudioUnitEQ(numberOfBands: bands.count)
    private var dynamics = Processor.makeDynamics()
    private var authorized = false
    private var currentMic: AudioObjectID?
    private var currentOutput: AudioObjectID?
    private var aggregate: AudioObjectID?

    private static func makeDynamics() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { self.authorized = granted }
        }
    }

    /// Connects source -> EQ -> gate/compressor -> main mixer on `engine`.
    func wire(_ engine: AVAudioEngine, from source: AVAudioNode, format: AVAudioFormat) {
        eq = AVAudioUnitEQ(numberOfBands: Self.bands.count)
        dynamics = Self.makeDynamics()
        engine.attach(eq)
        engine.attach(dynamics)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: dynamics, format: format)
        engine.connect(dynamics, to: engine.mainMixerNode, format: format)
        apply()
    }

    private func apply() {
        let s = settings
        eq.bypass = !s.eqOn
        for (index, band) in eq.bands.enumerated() {
            band.filterType = index == 0 ? .lowShelf : index == Self.bands.count - 1 ? .highShelf : .parametric
            band.frequency = Self.bands[index]
            band.bandwidth = 1.5
            band.gain = s.eqGains[index]
            band.bypass = false
        }
        // One Apple unit does both jobs: its expander is the gate (ratio 1 = off),
        // and a compressor threshold of +20 dB is never reached, so that is "off".
        set(kDynamicsProcessorParam_ExpansionRatio, s.gateOn ? 50 : 1)
        set(kDynamicsProcessorParam_ExpansionThreshold, s.gateThreshold)
        set(kDynamicsProcessorParam_Threshold, s.compOn ? s.compThreshold : 20)
        set(kDynamicsProcessorParam_HeadRoom, 5)
        set(kDynamicsProcessorParam_AttackTime, 0.005)
        set(kDynamicsProcessorParam_ReleaseTime, 0.15)
        set(kDynamicsProcessorParam_OverallGain, s.compOn ? s.makeup : 0)
    }

    private func set(_ parameter: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(dynamics.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }

    /// Called once a second: (re)starts the engine when the mic, the virtual device or the engine state changed.
    func sync(mic: AudioObjectID?) {
        guard authorized else { return }
        let output = findDevice(named: Self.virtualDevice)
        if engine.isRunning, mic == currentMic, output == currentOutput { return }
        engine.stop()
        engine = AVAudioEngine()   // fresh engine: drops old taps and device bindings
        if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = nil
        currentMic = mic
        currentOutput = output
        routed = false
        // Without the virtual device the engine still needs an output to run: use the speakers, silenced below.
        let speakers = read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
        guard let mic, let sink = output ?? speakers else { return }
        aggregate = makeAggregate(mic: mic, sink: sink)
        guard let aggregate else { NSLog("SoloCast: could not create aggregate device"); return }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(aggregate)
            try engine.outputNode.auAudioUnit.setDeviceID(aggregate)
            let input = engine.inputNode
            wire(engine, from: input, format: input.outputFormat(forBus: 0))
            // Without the virtual device the engine only feeds the meters: keep the speakers silent.
            engine.mainMixerNode.outputVolume = output == nil ? 0 : 1
            let meters = meters, unit = dynamics.audioUnit
            var logged = false
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                let level = peakDecibels(buffer)
                // Diagnostic: exactly -120 dB here means no real signal is arriving from the mic.
                if !logged { logged = true; NSLog("SoloCast: first input buffer peak %.1f dB", level) }
                DispatchQueue.main.async {
                    meters.input = max(level, meters.input - 1.5)          // fast attack, smooth fall
                    meters.inputPeak = max(level, meters.inputPeak - 0.3)  // slow-falling peak marker
                }
            }
            dynamics.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                let level = peakDecibels(buffer)
                var reduction: AudioUnitParameterValue = 0
                AudioUnitGetParameter(unit, kDynamicsProcessorParam_CompressionAmount, kAudioUnitScope_Global, 0, &reduction)
                DispatchQueue.main.async {
                    meters.output = max(level, meters.output - 1.5)
                    meters.reduction = reduction
                }
            }
            try engine.start()
            routed = output != nil
        } catch {
            NSLog("SoloCast: engine start failed: \(error)")
        }
    }
}

// MARK: - Hardware settings

final class Mic: ObservableObject {
    let processor = Processor()
    @Published var id: AudioObjectID?
    @Published var gain: Float = 0
    @Published var decibels: Float = 0
    @Published var muted = false
    @Published var rate: Float64 = 0
    @Published var rates: [Float64] = []
    private var timer: Timer?

    /// Polls once a second: picks up plug/unplug and changes made in other apps.
    func startPolling() {
        processor.requestMicrophone()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.processor.sync(mic: self.id)
        }
    }

    func refresh() {
        let found = findDevice(named: "SoloCast")
        if found != id { id = found }
        guard let id else { return }
        // Assign only on change so the menu does not redraw every second.
        func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Mic, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        update(\.gain, read(id, address(kAudioDevicePropertyVolumeScalar, input: true, element: 1), Float(0)) ?? 0)
        update(\.decibels, read(id, address(kAudioDevicePropertyVolumeDecibels, input: true, element: 1), Float(0)) ?? 0)
        update(\.muted, (read(id, address(kAudioDevicePropertyMute, input: true), UInt32(0)) ?? 0) != 0)
        update(\.rate, read(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0)
        update(\.rates, readArray(id, address(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange()).map(\.mMinimum))
    }

    func setGain(_ value: Float) {
        guard let id else { return }
        // The mic reports two channels with separate gain; keep them equal.
        for channel: UInt32 in 1...2 {
            write(id, address(kAudioDevicePropertyVolumeScalar, input: true, element: channel), value)
        }
        refresh()
    }

    func setMuted(_ value: Bool) {
        guard let id else { return }
        write(id, address(kAudioDevicePropertyMute, input: true), UInt32(value ? 1 : 0))
        refresh()
    }

    func setRate(_ value: Float64) {
        guard let id else { return }
        write(id, address(kAudioDevicePropertyNominalSampleRate), value)
        refresh()
    }
}

// MARK: - UI

let accent = Color(red: 1.0, green: 0.22, blue: 0.30)

func meterFraction(_ decibels: Float) -> CGFloat { CGFloat(min(max((decibels + 60) / 60, 0), 1)) }

extension Text {
    func caption() -> some View {
        font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1.5).foregroundStyle(.white.opacity(0.55))
    }
    func readout() -> some View {
        font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
    }
}

struct MeterBar: View {
    let label: String
    let level: Float
    var peak: Float?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).caption().frame(width: 26, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7),
                                           .init(color: .yellow, location: 0.88), .init(color: .red, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) { Capsule().frame(width: width * meterFraction(level)) }
                    if let peak, peak > -60 {
                        Capsule().fill(peak > -1 ? Color.red : .white).frame(width: 2)
                            .offset(x: max(width * meterFraction(peak) - 2, 0))
                    }
                }
                .animation(.linear(duration: 0.05), value: level)
            }
            .frame(height: 8)
            Text(level > -60 ? String(format: "%.0f", level) : "-∞").readout().frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) level")
        .accessibilityValue(level > -60 ? "\(Int(level)) decibels" : "silent")
    }
}

struct MeterPanel: View {
    @ObservedObject var meters: Meters   // observed here only, so 40+ updates a second redraw just the bars
    var body: some View {
        VStack(spacing: 8) {
            MeterBar(label: "IN", level: meters.input, peak: meters.inputPeak)
            MeterBar(label: "OUT", level: meters.output)
        }
    }
}

struct ReductionReadout: View {
    @ObservedObject var meters: Meters
    var body: some View {
        Text(String(format: "GR %.1f dB", -abs(meters.reduction))).readout()
            .foregroundStyle(abs(meters.reduction) > 0.5 ? accent : .white.opacity(0.4))
            .accessibilityLabel("Gain reduction")
    }
}

struct Card<Content: View>: View {
    let title: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).caption()
                Spacer()
                if let isOn {
                    Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent)
                }
            }
            content
                .opacity(isOn?.wrappedValue == false ? 0.35 : 1)
                .disabled(isOn?.wrappedValue == false)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}

struct ParameterRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var unit = "dB"

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range).controlSize(.small).tint(accent).accessibilityLabel(label)
            Text(String(format: "%+.0f %@", value, unit)).readout().frame(width: 52, alignment: .trailing)
        }
    }
}

/// Vertical EQ fader. Drag to set, double-click to reset to 0 dB.
struct Fader: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float> = -12...12
    private let height: CGFloat = 84

    var body: some View {
        let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", value)).readout()
            ZStack {
                Capsule().fill(.white.opacity(0.10)).frame(width: 4)
                Rectangle().fill(.white.opacity(0.25)).frame(width: 12, height: 1)   // 0 dB mark
                Capsule().fill(accent).frame(width: 4, height: abs(fraction - 0.5) * height)
                    .offset(y: -(fraction - 0.5) * height / 2)
                Circle().fill(.white).frame(width: 14, height: 14).shadow(color: accent.opacity(0.8), radius: 5)
                    .offset(y: (0.5 - fraction) * height)
            }
            .frame(width: 36, height: height + 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = 1 - min(max((drag.location.y - 7) / height, 0), 1)
                value = (range.lowerBound + Float(position) * (range.upperBound - range.lowerBound)).rounded()
            })
            .onTapGesture(count: 2) { value = 0 }
            Text(label).caption()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("EQ \(label) hertz")
        .accessibilityValue("\(Int(value)) decibels")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 1 : -1), range.lowerBound), range.upperBound)
        }
    }
}

struct ContentView: View {
    @ObservedObject var mic: Mic
    @ObservedObject var processor: Processor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if mic.id == nil {
                Text("HyperX SoloCast not connected").foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Card(title: "LEVEL") {
                    MeterPanel(meters: processor.meters)
                    ParameterRow(label: "Gain", value: Binding(get: { mic.gain * 100 }, set: { mic.setGain($0 / 100) }),
                                 range: 0...100, unit: "%")
                }
                Card(title: "NOISE GATE", isOn: $processor.settings.gateOn) {
                    ParameterRow(label: "Threshold", value: $processor.settings.gateThreshold, range: -80...(-20))
                }
                Card(title: "EQUALIZER", isOn: $processor.settings.eqOn) {
                    HStack(spacing: 0) {
                        ForEach(Processor.bands.indices, id: \.self) { index in
                            let hertz = Processor.bands[index]
                            Fader(label: hertz >= 1000 ? "\(Int(hertz / 1000))K" : "\(Int(hertz))",
                                  value: $processor.settings.eqGains[index])
                        }
                    }
                }
                Card(title: "COMPRESSOR", isOn: $processor.settings.compOn) {
                    ParameterRow(label: "Threshold", value: $processor.settings.compThreshold, range: -50...0)
                    ParameterRow(label: "Makeup", value: $processor.settings.makeup, range: 0...24)
                    HStack { Spacer(); ReductionReadout(meters: processor.meters) }
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.14), Color(red: 0.05, green: 0.05, blue: 0.07)],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("SOLOCAST").font(.system(size: 17, weight: .heavy, design: .rounded)).kerning(4).foregroundStyle(.white)
                HStack(spacing: 5) {
                    Circle().fill(processor.routed ? Color.green : .orange).frame(width: 6, height: 6)
                    Text(processor.routed ? "Processed mic: BlackHole 2ch" : "Meter only: BlackHole not installed")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Button { mic.setMuted(!mic.muted) } label: {
                Image(systemName: mic.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(mic.muted ? accent : .white.opacity(0.10)))
                    .shadow(color: mic.muted ? accent.opacity(0.7) : .clear, radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(mic.id == nil)
            .accessibilityLabel(mic.muted ? "Unmute" : "Mute")
        }
    }

    private var footer: some View {
        HStack {
            if mic.id != nil {
                Picker("Sample rate", selection: Binding(get: { mic.rate }, set: mic.setRate)) {
                    ForEach(mic.rates, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }
}

struct SoloCastApp: App {
    @StateObject private var mic = Mic()

    var body: some Scene {
        MenuBarExtra {
            ContentView(mic: mic, processor: mic.processor)
        } label: {
            Image(systemName: mic.muted ? "mic.slash.fill" : "mic.fill")
                .task { mic.startPolling() }   // the label exists from launch, the panel only once opened
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Entry point and self-check

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--check") { check() }
        SoloCastApp.main()
    }

    /// Renders a sine of `inputDecibels` through the chain offline and returns the output peak in dB.
    static func render(_ inputDecibels: Float, _ settings: Settings) throws -> Float {
        let processor = Processor()
        processor.persist = false
        processor.settings = settings
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let amplitude = pow(10, inputDecibels / 20)
        var sample = 0
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frames) {
                let value = amplitude * sin(2 * .pi * 1000 * Float(sample + frame) / 48000)
                for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            sample += Int(frames)
            return noErr
        }
        engine.attach(source)
        processor.wire(engine, from: source, format: format)
        try engine.start()
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var peak: Float = -120
        for _ in 0..<12 {   // about 1 s; only the last block counts, after the dynamics have settled
            _ = try engine.renderOffline(4096, to: buffer)
            peak = peakDecibels(buffer)
        }
        return peak
    }

    /// Self-check: hardware settings on the real mic, then the processing chain offline.
    static func check() -> Never {
        func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
        let mic = Mic()
        mic.refresh()
        guard let id = mic.id else { fail("SoloCast not found") }
        let gainAddress = address(kAudioDevicePropertyVolumeScalar, input: true, element: 1)
        guard !mic.rates.isEmpty, mic.rates.contains(mic.rate), write(id, gainAddress, mic.gain) else {
            fail("could not read or write hardware settings")
        }
        print("OK hardware gain=\(mic.gain) dB=\(mic.decibels) muted=\(mic.muted) rate=\(mic.rate) rates=\(mic.rates)")
        do {
            let flat = try render(-12, Settings())
            guard abs(flat + 12) < 1 else { fail("everything off should pass audio unchanged, got \(flat) dB") }
            let gated = try render(-60, Settings(gateOn: true, gateThreshold: -40))
            guard gated < -80 else { fail("gate should silence -60 dB below a -40 dB threshold, got \(gated) dB") }
            let open = try render(-12, Settings(gateOn: true, gateThreshold: -40))
            guard abs(open + 12) < 1 else { fail("gate should pass -12 dB above a -40 dB threshold, got \(open) dB") }
            let compressed = try render(-3, Settings(compOn: true, compThreshold: -30))
            guard compressed < -9 else { fail("compressor should reduce -3 dB above a -30 dB threshold, got \(compressed) dB") }
            let boosted = try render(-24, Settings(eqOn: true, eqGains: [0, 0, 12, 0, 0]))
            guard boosted > -15 else { fail("EQ +12 dB at 1 kHz should raise a 1 kHz tone, got \(boosted) dB") }
            print("OK processing flat=\(flat) gated=\(gated) open=\(open) compressed=\(compressed) boosted=\(boosted)")
        } catch {
            fail("offline render: \(error)")
        }
        exit(0)
    }
}
