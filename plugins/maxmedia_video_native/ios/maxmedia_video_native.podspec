#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint maxmedia_video_native.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'maxmedia_video_native'
  s.version          = '0.1.0'
  s.summary          = 'Native H.264 and HEVC video compression for Flutter.'
  s.description      = <<-DESC
AVAssetReader and AVAssetWriter video compression with bitrate control.
                       DESC
  s.homepage         = 'https://maxmax.cc'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'MaxMedia'
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks = 'AVFoundation', 'Photos', 'PhotosUI'
  s.platform = :ios, '14.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  s.resource_bundles = {'maxmedia_video_native_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
