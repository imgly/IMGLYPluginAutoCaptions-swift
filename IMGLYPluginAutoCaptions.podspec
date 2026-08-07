Pod::Spec.new do |s|
  s.name              = 'IMGLYPluginAutoCaptions'
  s.version           = '1.79.0'
  s.summary           = 'Automatic caption generation plugin for the IMG.LY Creative Editor SDK.'

  s.homepage          = 'https://img.ly'
  s.license           = { type: 'Commercial', file: 'LICENSE.md' }
  s.author            = { 'IMG.LY GmbH' => 'contact@img.ly' }
  s.changelog         = 'https://img.ly/docs/cesdk/changelog/'

  s.source            = { git: 'https://github.com/imgly/IMGLYPluginAutoCaptions-swift.git', tag: s.version.to_s }
  s.source_files      = ["Sources/#{s.name}/**/*.{swift}"]

  s.swift_version     = '6.3.1'
  s.cocoapods_version = '>= 1.11.2'
  s.platform          = :ios, '16.0'

  s.dependency 'IMGLYUI', s.version.to_s

  s.pod_target_xcconfig = {
    'SWIFT_OBJC_INTERFACE_HEADER_NAME' => '',
    'SWIFT_INSTALL_OBJC_HEADER' => 'NO'
  }

  s.frameworks = %w[Foundation SwiftUI]
end
