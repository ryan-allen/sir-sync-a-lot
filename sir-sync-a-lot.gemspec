# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "sir-sync-a-lot"

Gem::Specification.new do |s|
  s.name        = "sir-sync-a-lot"
  s.version     = SirSyncalot::VERSION
  s.authors     = ["Ryan Allen"]
  s.email       = ["ryan@yeahnah.org"]
  s.homepage    = "https://github.com/ryan-allen/sir-sync-a-lot"
  s.summary     = %q{Baby got backups!}
  s.description = %q{Optimised S3 backup tool. Uses linux's find and xargs to find updated files as to not exaust your disk IO.}

  s.rubyforge_project = "sir-sync-a-lot"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  # specify any dependencies here; for example:
  # s.add_development_dependency "rspec"
  s.add_runtime_dependency "aws-s3"
end
