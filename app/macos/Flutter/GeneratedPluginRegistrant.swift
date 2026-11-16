//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import audio_session
import cryptography_flutter
import flutter_secure_storage_darwin
import just_audio
import mobile_scanner
import record_darwin

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  AudioSessionPlugin.register(with: registry.registrar(forPlugin: "AudioSessionPlugin"))
  CryptographyFlutterPlugin.register(with: registry.registrar(forPlugin: "CryptographyFlutterPlugin"))
  FlutterSecureStorageDarwinPlugin.register(with: registry.registrar(forPlugin: "FlutterSecureStorageDarwinPlugin"))
  JustAudioPlugin.register(with: registry.registrar(forPlugin: "JustAudioPlugin"))
  MobileScannerPlugin.register(with: registry.registrar(forPlugin: "MobileScannerPlugin"))
  RecordDarwinPlugin.register(with: registry.registrar(forPlugin: "RecordDarwinPlugin"))
}
