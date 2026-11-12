// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stickflow contributors

#if DEBUG
import AppKit
import SwiftUI
import StickflowCore

/// Debug-only window with sliders for the key `Tuning` values (spec rule 0.2)
/// and, until the settings window exists (stage 4), the user settings too.
@MainActor
final class TuningPanelController {
    private unowned let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        if window == nil {
            let environment = self.environment
            let view = TuningPanelView(
                tuning: environment.tuning,
                preferences: environment.preferences,
                onTuningChange: {
                    environment.stickers.applyPreferences()
                },
                onPreferencesChange: {
                    environment.preferences.persist()
                    environment.stickers.applyPreferences()
                }
            )
            let newWindow = NSWindow(contentViewController: NSHostingController(rootView: view))
            newWindow.title = "Stickflow Tuning"
            newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 400, height: 680))
            newWindow.center()
            window = newWindow
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct TuningPanelView: View {
    @Bindable var tuning: Tuning
    @Bindable var preferences: Preferences
    let onTuningChange: @MainActor () -> Void
    let onPreferencesChange: @MainActor () -> Void

    var body: some View {
        Form {
            settingsSection
            fadeSection
            editSection
            geometrySection
            switchesSection
            animationSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 480)
    }

    // MARK: User settings (move to the settings window in stage 4)

    private var settingsSection: some View {
        Section {
            SliderRow(title: "Paper opacity at rest", value: $preferences.paperOpacity,
                      range: Preferences.paperOpacityRange, onChange: onPreferencesChange)
            SliderRow(title: "Font size", value: $preferences.fontSize,
                      range: Preferences.fontSizeRange, step: 1, onChange: onPreferencesChange)
            Picker(selection: $preferences.sizeClass) {
                ForEach(StickerSizeClass.allCases, id: \.self) { size in
                    Text(verbatim: size.label).tag(size)
                }
            } label: {
                Text(verbatim: "Sticker size")
            }
            .pickerStyle(.segmented)
            .onChange(of: preferences.sizeClass) { onPreferencesChange() }

            Picker(selection: $preferences.editKey) {
                ForEach(EditKey.allCases, id: \.self) { key in
                    Text(verbatim: key.symbol).tag(key)
                }
            } label: {
                Text(verbatim: "Edit key")
            }
            .pickerStyle(.segmented)
            .onChange(of: preferences.editKey) { onPreferencesChange() }

            ToggleRow(title: "Fade under the cursor", isOn: $preferences.fadeEnabled, onChange: onPreferencesChange)
            ToggleRow(title: "Hide from screen sharing", isOn: $preferences.hideFromScreenSharing,
                      onChange: onPreferencesChange)
            ToggleRow(title: "Show over full-screen apps", isOn: $preferences.showOverFullscreen,
                      onChange: onPreferencesChange)
        } header: {
            Text(verbatim: "Settings (temporary home)")
        }
    }

    // MARK: Tuning

    private var fadeSection: some View {
        Section {
            SliderRow(title: "Fade delay, s", value: $tuning.fadeDelay, range: 0...0.6, onChange: onTuningChange)
            SliderRow(title: "Faded opacity", value: $tuning.fadedOpacity, range: 0.05...1, onChange: onTuningChange)
            SliderRow(title: "Fade out, s", value: $tuning.fadeOutDuration, range: 0...0.6, onChange: onTuningChange)
            SliderRow(title: "Fade in, s", value: $tuning.fadeInDuration, range: 0...0.6, onChange: onTuningChange)
            SliderRow(title: "Text opacity at rest", value: $tuning.restTextOpacity, range: 0.3...1,
                      onChange: onTuningChange)
            SliderRow(title: "Done task opacity", value: $tuning.doneTextOpacity, range: 0.1...1,
                      onChange: onTuningChange)
        } header: {
            Text(verbatim: "Rest and fade (4.7)")
        }
    }

    private var editSection: some View {
        Section {
            SliderRow(title: "Edit mode in, s", value: $tuning.editModeInDuration, range: 0...0.5,
                      onChange: onTuningChange)
            SliderRow(title: "Edit mode out, s", value: $tuning.editModeOutDuration, range: 0...0.5,
                      onChange: onTuningChange)
            SliderRow(title: "Key release grace, s", value: $tuning.editKeyReleaseGrace, range: 0...1,
                      onChange: onTuningChange)
            SliderRow(title: "Key proximity, pt", value: $tuning.editKeyProximity, range: 0...40, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Editing idle timeout, s", value: $tuning.editingIdleTimeout, range: 5...120, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Hint dwell, s", value: $tuning.hintDwell, range: 0.2...3, onChange: onTuningChange)
        } header: {
            Text(verbatim: "Edit mode (4.6, 4.8)")
        }
    }

    private var geometrySection: some View {
        Section {
            SliderRow(title: "Anchor inset right, pt", value: $tuning.anchorInsetRight, range: 0...200, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Anchor inset top, pt", value: $tuning.anchorInsetTop, range: 0...300, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Magnet distance, pt", value: $tuning.magnetDistance, range: 0...40, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Max height, pt", value: $tuning.maxPaperHeight, range: 120...600, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Width S, pt", value: $tuning.widthSmall, range: 140...260, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Width M, pt", value: $tuning.widthMedium, range: 180...300, step: 1,
                      onChange: onTuningChange)
            SliderRow(title: "Width L, pt", value: $tuning.widthLarge, range: 220...400, step: 1,
                      onChange: onTuningChange)
        } header: {
            Text(verbatim: "Geometry (4.5, 4.6)")
        }
    }

    private var switchesSection: some View {
        Section {
            ToggleRow(title: "Edit key must be pressed over the sticker",
                      isOn: $tuning.editRequiresKeyPressOverSticker, onChange: onTuningChange)
            ToggleRow(title: "No edit mode while a mouse button is down",
                      isOn: $tuning.suppressEditWhileMouseDown, onChange: onTuningChange)
            ToggleRow(title: "Full screen via window level (spec variant)",
                      isOn: $tuning.fullscreenUsesWindowLevel, onChange: onTuningChange)
            ToggleRow(title: "Return after the title starts a task",
                      isOn: $tuning.newLineAfterTitleIsTodo, onChange: onTuningChange)
        } header: {
            Text(verbatim: "Behaviour variants (rule 0.3)")
        }
    }

    private var animationSection: some View {
        Section {
            Picker(selection: $tuning.animationSlowdown) {
                Text(verbatim: "×1").tag(1.0)
                Text(verbatim: "×3").tag(3.0)
                Text(verbatim: "×10").tag(10.0)
            } label: {
                Text(verbatim: "Slow motion")
            }
            .pickerStyle(.segmented)
            .onChange(of: tuning.animationSlowdown) { onTuningChange() }
        } header: {
            Text(verbatim: "Animation (6.7)")
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let onChange: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: title)
                Spacer()
                Text(verbatim: formatted)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            slider
        }
        .onChange(of: value) { onChange() }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }

    private var formatted: String {
        if let step, step >= 1 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.3f", value)
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let onChange: @MainActor () -> Void

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: title)
        }
        .onChange(of: isOn) { onChange() }
    }
}
#endif
