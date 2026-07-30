//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import audio_session
import flutter_tts
import record_macos

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  AudioSessionPlugin.register(with: registry.registrar(forPlugin: "AudioSessionPlugin"))
  FlutterTtsPlugin.register(with: registry.registrar(forPlugin: "FlutterTtsPlugin"))
  RecordMacOsPlugin.register(with: registry.registrar(forPlugin: "RecordMacOsPlugin"))
}
