import Foundation
import IMGLYEditor
import IMGLYEngine

/// Transcribes the scene's audible content into an SRT or VTT file, with cue timings relative to the page
/// timeline, or `nil` when the audio holds no speech.
///
/// Declared here rather than shared with the editor: the editor's
/// `EditorConfiguration.Builder.captionsGeneration(_:)` takes a plain function type, so this is the
/// plugin's own name for it and nothing about transcription reaches the editor's module.
public typealias CaptionsGenerator = @MainActor (_ engine: Engine) async throws -> URL?

/// A plugin that adds automatic caption generation to the editor.
///
/// Registering it adds a **Generate Automatically** action to the Add Captions sheet that transcribes
/// the scene's audible content via the given ``TranscriptionProvider`` and creates styled, time-synced
/// captions.
///
/// The action appears in the Add Captions sheet, so the editor configuration must register
/// `Dock.Buttons.captions()` to open it. The Video Editor Starter Kit's
/// `VideoEditorConfiguration` already does.
///
/// ```swift
/// Editor(settings)
///   .imgly.configuration {
///     VideoEditorConfiguration()
///     AutoCaptionsPlugin(provider: GatewayTranscriptionProvider(apiKey: "sk_…"))
///   }
/// ```
@MainActor
public final class AutoCaptionsPlugin: EditorConfiguration {
  /// Creates the plugin.
  /// - Parameters:
  ///   - provider: The speech-to-text backend, e.g. the built-in ``GatewayTranscriptionProvider``.
  ///   - options: Language and subtitle formatting options passed to the provider.
  public init(provider: any TranscriptionProvider, options: TranscriptionOptions = .init()) {
    let generate: CaptionsGenerator = { engine in
      try await AutoCaptionsGenerator.generateCaptionsFile(engine: engine, provider: provider, options: options)
    }
    super.init { builder in
      builder.captionsGeneration(generate)
    }
  }
}
