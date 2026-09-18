def allowed_gitflow?(base, head, same_repository)
  case base
  when 'main'
    same_repository && head.match?(%r{\A(release|hotfix)/.+\z})
  when 'develop'
    head.match?(%r{\A(feature|bugfix|chore|dependabot)/.+\z}) ||
      (same_repository && (head == 'main' || head.match?(%r{\A(release|hotfix)/.+\z})))
  when %r{\Arelease/.+\z}
    head.match?(%r{\A(bugfix|hotfix)/.+\z}) || (same_repository && head == 'main')
  when %r{\Ahotfix/.+\z}
    head.match?(%r{\Abugfix/.+\z})
  else
    false
  end
end

if ARGV == ['--test']
  [
    ['develop', 'feature/search', true, true],
    ['develop', 'feature/search', false, true],
    ['develop', 'bugfix/search', true, true],
    ['develop', 'chore/ci', true, true],
    ['develop', 'agent/search', true, false],
    ['develop', 'dependabot/github_actions/checkout-7', true, true],
    ['develop', 'main', true, true],
    ['develop', 'main', false, false],
    ['develop', 'release/0.8.0', true, true],
    ['develop', 'hotfix/0.7.1', true, true],
    ['develop', 'release/0.8.0', false, false],
    ['develop', 'feature/', true, false],
    ['main', 'release/0.8.0', true, true],
    ['main', 'release/0.2.0-site', true, true],
    ['main', 'hotfix/0.7.1', true, true],
    ['main', 'release/0.8.0', false, false],
    ['main', 'develop', true, false],
    ['main', 'feature/search', true, false],
    ['main', 'dependabot/npm/react-19', true, false],
    ['release/0.8.0', 'bugfix/search', true, true],
    ['release/0.8.0', 'hotfix/0.7.1', true, true],
    ['release/0.8.0', 'main', true, true],
    ['release/0.8.0', 'feature/search', true, false],
    ['hotfix/0.7.1', 'bugfix/search', true, true],
    ['other', 'feature/search', true, false]
  ].each do |base, head, same_repository, expected|
    abort "Unexpected Gitflow routing: #{head} -> #{base}" unless
      allowed_gitflow?(base, head, same_repository) == expected
  end
  puts 'Gitflow routing checks passed.'
else
  allowed = allowed_gitflow?(
    ENV.fetch('GITHUB_BASE_REF'), ENV.fetch('GITHUB_HEAD_REF'),
    ENV.fetch('HEAD_REPOSITORY') == ENV.fetch('GITHUB_REPOSITORY')
  )
  abort 'Invalid Gitflow PR destination. Follow the branch table in CONTRIBUTING.md.' unless allowed
  puts 'Gitflow PR destination is valid.'
end
