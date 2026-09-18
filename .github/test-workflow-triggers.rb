require 'yaml'

workflows = %w[ci website-image codeql-swift codeql-web].to_h do |name|
  document = YAML.load_file(File.join(__dir__, "workflows/#{name}.yml"))
  [name, document['on'] || document[true]] # Psych also accepts YAML 1.1's boolean `on`.
end

def matches?(patterns, value)
  Array(patterns).reduce(false) do |matched, pattern|
    negative = pattern.start_with?('!')
    glob = pattern.delete_prefix('!').sub(%r{/\*\*\z}, '/**/*')
    File.fnmatch(glob, value, File::FNM_PATHNAME | File::FNM_DOTMATCH) ? !negative : matched
  end
end

{
  'website/src/App.css' => %w[website-image codeql-web],
  'website/package-lock.json' => %w[website-image codeql-web],
  'Sources/S3Workbench/App.swift' => %w[ci codeql-swift],
  'Tests/S3WorkbenchCoreTests/ClientTests.swift' => %w[ci codeql-swift],
  'Package.swift' => %w[ci codeql-swift],
  'Package.resolved' => %w[ci codeql-swift],
  'scripts/package-dmg.sh' => %w[ci codeql-swift],
  'Integration/docker-compose.yml' => %w[ci codeql-swift],
  '.github/workflows/ci.yml' => %w[ci website-image codeql-web],
  '.github/workflows/codeql-swift.yml' => %w[website-image codeql-swift codeql-web],
  'docs/TESTING.md' => []
}.each do |path, expected|
  %w[push pull_request].each do |event|
    actual = workflows.select { |_, triggers| matches?(triggers.fetch(event)['paths'], path) }.keys
    abort "#{event} #{path}: expected #{expected}, got #{actual}" unless actual == expected
  end
end

{ 'v0.8.0' => ['ci'], 'v0.2.0-site' => ['website-image'] }.each do |tag, expected|
  actual = workflows.select { |_, triggers| matches?(triggers.fetch('push')['tags'], tag) }.keys
  abort "#{tag}: expected #{expected}, got #{actual}" unless actual == expected
end

%w[codeql-swift codeql-web].each do |name|
  abort "#{name}: missing full scheduled/manual scan" unless workflows[name].key?('schedule') && workflows[name].key?('workflow_dispatch')
end
puts 'Workflow scope checks passed (web, native, docs, releases and security scans).'
