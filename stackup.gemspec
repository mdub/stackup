# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "stackup"
  spec.version       = '0.0.1'
  spec.authors       = ["Arvind Kunday "]
  spec.email         = ["arvind.kunday@rea-group.com"]
  spec.summary       = "Tools for deployment to AWS"
  spec.homepage      = "https://git.realestate.com.au/akunday/stackup"
  spec.license       = "MIT"

  spec.files         = Dir["**/*"].reject { |f| File.directory?(f) }
  spec.executables   = spec.files.grep(/^bin/) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "aws-sdk"
  spec.add_dependency "clamp", ">= 1.0.0"

end