# IMGLYPluginAutoCaptions

Automatic caption generation for the [IMG.LY CreativeEditor SDK](https://img.ly/products/creative-sdk) video editor on iOS.

Registering the plugin surfaces a primary **Generate Automatically** action in the editor's Add Captions sheet. Tapping it transcribes the scene's audible content — every non-muted audio block and video clip — and lands in Edit Captions with styled, time-synced captions.

## Installation

Add the `IMGLYPluginAutoCaptions` package via Swift Package Manager using this repository's URL, or add the `IMGLYPluginAutoCaptions` pod via CocoaPods.

## Usage

Compose the plugin into your editor configuration alongside the captions dock button — captions are an opt-in editor feature, so the plugin only adds the generate action to the captions sheet. `VideoEditorConfiguration` comes from the video Starter Kit (the base you copy into your project and build on):

```swift
import IMGLYPluginAutoCaptions

Editor(settings).imgly.configuration {
  VideoEditorConfiguration { builder in
    builder.dock { dock in
      dock.modify { _, items in
        items.addLast { Dock.Buttons.captions() }
      }
    }
  }
  AutoCaptionsPlugin(provider: GatewayTranscriptionProvider(apiKey: "sk_…"))
}
```

## Transcription providers

The built-in ``GatewayTranscriptionProvider`` runs the ElevenLabs Scribe v2 speech-to-text model through the [IMG.LY AI Gateway](https://img.ly/) (`gateway.img.ly`). The gateway handles provider routing, billing, and asset storage, so you only supply an IMG.LY API key (`sk_…`) from the IMG.LY Dashboard — no separate speech-to-text account, no proxy server to host, and no third-party credentials shipping in your app.

To integrate any other speech-to-text service, implement the ``TranscriptionProvider`` protocol — a single `transcribe(audio:mimeType:options:)` method that turns a staged audio file into an SRT string:

```swift
struct MyTranscriptionProvider: TranscriptionProvider {
  let name = "My Speech-to-Text"

  func transcribe(audio: URL, mimeType: String, options: TranscriptionOptions) async throws -> String {
    // `audio` is one audible block's whole source track, staged in a temporary
    // file. Stream it — `URLSession.upload(for:fromFile:)` does that for you —
    // rather than reading it into memory, and return SRT text.
  }
}
```

## License

The CreativeEditor SDK is a commercial product. Get your license at [img.ly](https://img.ly/pricing).
