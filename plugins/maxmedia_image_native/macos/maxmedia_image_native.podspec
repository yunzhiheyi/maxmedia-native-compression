#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint maxmedia_image_native.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'maxmedia_image_native'
  s.version          = '0.1.0'
  s.summary          = 'Native JPEG, PNG and WebP compression for Flutter.'
  s.description      = <<-DESC
Image compression using platform encoders and libwebp on Apple platforms.
                       DESC
  s.homepage         = 'https://maxmax.cc'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'MaxMedia'

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  s.resource_bundles = {'maxmedia_image_native_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'
  s.dependency 'libwebp', '~> 1.5.0'

  s.platform = :osx, '11.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.9'
end
