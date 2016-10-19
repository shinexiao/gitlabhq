require 'securerandom'

class Repository
  class CommitError < StandardError; end

  # Files to use as a project avatar in case no avatar was uploaded via the web
  # UI.
  AVATAR_FILES = %w{logo.png logo.jpg logo.gif}

  include Gitlab::ShellAdapter

  attr_accessor :path_with_namespace, :project

  def initialize(path_with_namespace, project)
    @path_with_namespace = path_with_namespace
    @project = project
  end

  def raw_repository
    return nil unless path_with_namespace

    @raw_repository ||= Gitlab::Git::Repository.new(path_to_repo)
  end

  def update_autocrlf_option
    raw_repository.autocrlf = :input if raw_repository.autocrlf != :input
  end

  # Return absolute path to repository
  def path_to_repo
    @path_to_repo ||= File.expand_path(
      File.join(@project.repository_storage_path, path_with_namespace + ".git")
    )
  end

  def exists?
    return @exists unless @exists.nil?

    @exists = cache.fetch(:exists?) do
      begin
        raw_repository && raw_repository.rugged ? true : false
      rescue Gitlab::Git::Repository::NoRepository
        false
      end
    end
  end

  def empty?
    return @empty unless @empty.nil?

    @empty = cache.fetch(:empty?) { raw_repository.empty? }
  end

  #
  # Git repository can contains some hidden refs like:
  #   /refs/notes/*
  #   /refs/git-as-svn/*
  #   /refs/pulls/*
  # This refs by default not visible in project page and not cloned to client side.
  #
  # This method return true if repository contains some content visible in project page.
  #
  def has_visible_content?
    return @has_visible_content unless @has_visible_content.nil?

    @has_visible_content = cache.fetch(:has_visible_content?) do
      branch_count > 0
    end
  end

  def commit(ref = 'HEAD')
    return nil unless exists?
    commit =
      if ref.is_a?(Gitlab::Git::Commit)
        ref
      else
        Gitlab::Git::Commit.find(raw_repository, ref)
      end
    commit = ::Commit.new(commit, @project) if commit
    commit
  rescue Rugged::OdbError
    nil
  end

  def commits(ref, path: nil, limit: nil, offset: nil, skip_merges: false, after: nil, before: nil)
    options = {
      repo: raw_repository,
      ref: ref,
      path: path,
      limit: limit,
      offset: offset,
      after: after,
      before: before,
      # --follow doesn't play well with --skip. See:
      # https://gitlab.com/gitlab-org/gitlab-ce/issues/3574#note_3040520
      follow: false,
      skip_merges: skip_merges
    }

    commits = Gitlab::Git::Commit.where(options)
    commits = Commit.decorate(commits, @project) if commits.present?
    commits
  end

  def commits_between(from, to)
    commits = Gitlab::Git::Commit.between(raw_repository, from, to)
    commits = Commit.decorate(commits, @project) if commits.present?
    commits
  end

  def find_commits_by_message(query, ref = nil, path = nil, limit = 1000, offset = 0)
    ref ||= root_ref

    args = %W(
      #{Gitlab.config.git.bin_path} log #{ref} --pretty=%H --skip #{offset}
      --max-count #{limit} --grep=#{query} --regexp-ignore-case
    )
    args = args.concat(%W(-- #{path})) if path.present?

    git_log_results = Gitlab::Popen.popen(args, path_to_repo).first.lines.map(&:chomp)
    commits = git_log_results.map { |c| commit(c) }
    commits
  end

  def find_branch(name, fresh_repo: true)
    # Since the Repository object may have in-memory index changes, invalidating the memoized Repository object may
    # cause unintended side effects. Because finding a branch is a read-only operation, we can safely instantiate
    # a new repo here to ensure a consistent state to avoid a libgit2 bug where concurrent access (e.g. via git gc)
    # may cause the branch to "disappear" erroneously or have the wrong SHA.
    #
    # See: https://github.com/libgit2/libgit2/issues/1534 and https://gitlab.com/gitlab-org/gitlab-ce/issues/15392
    raw_repo =
      if fresh_repo
        Gitlab::Git::Repository.new(path_to_repo)
      else
        raw_repository
      end

    raw_repo.find_branch(name)
  end

  def find_tag(name)
    tags.find { |tag| tag.name == name }
  end

  def add_branch(user, branch_name, target)
    oldrev = Gitlab::Git::BLANK_SHA
    ref    = Gitlab::Git::BRANCH_REF_PREFIX + branch_name
    target = commit(target).try(:id)

    return false unless target

    GitHooksService.new.execute(user, path_to_repo, oldrev, target, ref) do
      update_ref!(ref, target, oldrev)
    end

    after_create_branch
    find_branch(branch_name)
  end

  def add_tag(user, tag_name, target, message = nil)
    oldrev = Gitlab::Git::BLANK_SHA
    ref    = Gitlab::Git::TAG_REF_PREFIX + tag_name
    target = commit(target).try(:id)

    return false unless target

    options = { message: message, tagger: user_to_committer(user) } if message

    GitHooksService.new.execute(user, path_to_repo, oldrev, target, ref) do
      rugged.tags.create(tag_name, target, options)
    end

    find_tag(tag_name)
  end

  def rm_branch(user, branch_name)
    before_remove_branch

    branch = find_branch(branch_name)
    oldrev = branch.try(:target).try(:id)
    newrev = Gitlab::Git::BLANK_SHA
    ref    = Gitlab::Git::BRANCH_REF_PREFIX + branch_name

    GitHooksService.new.execute(user, path_to_repo, oldrev, newrev, ref) do
      update_ref!(ref, newrev, oldrev)
    end

    after_remove_branch
    true
  end

  def rm_tag(tag_name)
    before_remove_tag

    begin
      rugged.tags.delete(tag_name)
      true
    rescue Rugged::ReferenceError
      false
    end
  end

  def ref_names
    branch_names + tag_names
  end

  def branch_names
    @branch_names ||= cache.fetch(:branch_names) { branches.map(&:name) }
  end

  def branch_exists?(branch_name)
    branch_names.include?(branch_name)
  end

  def ref_exists?(ref)
    rugged.references.exist?(ref)
  end

  def update_ref!(name, newrev, oldrev)
    # We use 'git update-ref' because libgit2/rugged currently does not
    # offer 'compare and swap' ref updates. Without compare-and-swap we can
    # (and have!) accidentally reset the ref to an earlier state, clobbering
    # commits. See also https://github.com/libgit2/libgit2/issues/1534.
    command = %w[git update-ref --stdin -z]
    _, status = Gitlab::Popen.popen(command, path_to_repo) do |stdin|
      stdin.write("update #{name}\x00#{newrev}\x00#{oldrev}\x00")
    end

    return if status.zero?

    raise CommitError.new("Could not update branch #{name.sub('refs/heads/', '')}. Please refresh and try again.")
  end

  # Makes sure a commit is kept around when Git garbage collection runs.
  # Git GC will delete commits from the repository that are no longer in any
  # branches or tags, but we want to keep some of these commits around, for
  # example if they have comments or CI builds.
  def keep_around(sha)
    return unless sha && commit(sha)

    return if kept_around?(sha)

    # This will still fail if the file is corrupted (e.g. 0 bytes)
    begin
      rugged.references.create(keep_around_ref_name(sha), sha, force: true)
    rescue Rugged::ReferenceError => ex
      Rails.logger.error "Unable to create keep-around reference for repository #{path}: #{ex}"
    rescue Rugged::OSError => ex
      raise unless ex.message =~ /Failed to create locked file/ && ex.message =~ /File exists/
      Rails.logger.error "Unable to create keep-around reference for repository #{path}: #{ex}"
    end
  end

  def kept_around?(sha)
    begin
      ref_exists?(keep_around_ref_name(sha))
    rescue Rugged::ReferenceError
      false
    end
  end

  def tag_names
    cache.fetch(:tag_names) { raw_repository.tag_names }
  end

  def commit_count
    cache.fetch(:commit_count) do
      begin
        raw_repository.commit_count(self.root_ref)
      rescue
        0
      end
    end
  end

  def branch_count
    @branch_count ||= cache.fetch(:branch_count) { branches.size }
  end

  def tag_count
    @tag_count ||= cache.fetch(:tag_count) { raw_repository.rugged.tags.count }
  end

  # Return repo size in megabytes
  # Cached in redis
  def size
    cache.fetch(:size) { raw_repository.size }
  end

  def diverging_commit_counts(branch)
    root_ref_hash = raw_repository.rev_parse_target(root_ref).oid
    cache.fetch(:"diverging_commit_counts_#{branch.name}") do
      # Rugged seems to throw a `ReferenceError` when given branch_names rather
      # than SHA-1 hashes
      number_commits_behind = raw_repository.
        count_commits_between(branch.target.sha, root_ref_hash)

      number_commits_ahead = raw_repository.
        count_commits_between(root_ref_hash, branch.target.sha)

      { behind: number_commits_behind, ahead: number_commits_ahead }
    end
  end

  # Keys for data that can be affected for any commit push.
  def cache_keys
    %i(size commit_count
       readme version contribution_guide changelog
       license_blob license_key gitignore koding_yml)
  end

  # Keys for data on branch/tag operations.
  def cache_keys_for_branches_and_tags
    %i(branch_names tag_names branch_count tag_count)
  end

  def build_cache
    (cache_keys + cache_keys_for_branches_and_tags).each do |key|
      unless cache.exist?(key)
        send(key)
      end
    end
  end

  def expire_tags_cache
    cache.expire(:tag_names)
    @tags = nil
  end

  def expire_branches_cache
    cache.expire(:branch_names)
    @branch_names = nil
    @local_branches = nil
  end

  def expire_cache(branch_name = nil, revision = nil)
    cache_keys.each do |key|
      cache.expire(key)
    end

    expire_branch_cache(branch_name)
    expire_avatar_cache(branch_name, revision)

    # This ensures this particular cache is flushed after the first commit to a
    # new repository.
    expire_emptiness_caches if empty?
  end

  def expire_branch_cache(branch_name = nil)
    # When we push to the root branch we have to flush the cache for all other
    # branches as their statistics are based on the commits relative to the
    # root branch.
    if !branch_name || branch_name == root_ref
      branches.each do |branch|
        cache.expire(:"diverging_commit_counts_#{branch.name}")
      end
    # In case a commit is pushed to a non-root branch we only have to flush the
    # cache for said branch.
    else
      cache.expire(:"diverging_commit_counts_#{branch_name}")
    end
  end

  def expire_root_ref_cache
    cache.expire(:root_ref)
    @root_ref = nil
  end

  # Expires the cache(s) used to determine if a repository is empty or not.
  def expire_emptiness_caches
    cache.expire(:empty?)
    @empty = nil

    expire_has_visible_content_cache
  end

  def expire_has_visible_content_cache
    cache.expire(:has_visible_content?)
    @has_visible_content = nil
  end

  def expire_branch_count_cache
    cache.expire(:branch_count)
    @branch_count = nil
  end

  def expire_tag_count_cache
    cache.expire(:tag_count)
    @tag_count = nil
  end

  def lookup_cache
    @lookup_cache ||= {}
  end

  def expire_avatar_cache(branch_name = nil, revision = nil)
    # Avatars are pulled from the default branch, thus if somebody pushes to a
    # different branch there's no need to expire anything.
    return if branch_name && branch_name != root_ref

    # We don't want to flush the cache if the commit didn't actually make any
    # changes to any of the possible avatar files.
    if revision && commit = self.commit(revision)
      return unless commit.raw_diffs(deltas_only: true).
        any? { |diff| AVATAR_FILES.include?(diff.new_path) }
    end

    cache.expire(:avatar)

    @avatar = nil
  end

  def expire_exists_cache
    cache.expire(:exists?)
    @exists = nil
  end

  # Runs code after a repository has been created.
  def after_create
    expire_exists_cache
    expire_root_ref_cache
    expire_emptiness_caches

    repository_event(:create_repository)
  end

  # Runs code just before a repository is deleted.
  def before_delete
    expire_exists_cache

    expire_cache if exists?

    # expire cache that don't depend on repository data (when expiring)
    expire_tags_cache
    expire_tag_count_cache
    expire_branches_cache
    expire_branch_count_cache
    expire_root_ref_cache
    expire_emptiness_caches
    expire_exists_cache

    repository_event(:remove_repository)
  end

  # Runs code just before the HEAD of a repository is changed.
  def before_change_head
    # Cached divergent commit counts are based on repository head
    expire_branch_cache
    expire_root_ref_cache

    repository_event(:change_default_branch)
  end

  # Runs code before pushing (= creating or removing) a tag.
  def before_push_tag
    expire_cache
    expire_tags_cache
    expire_tag_count_cache

    repository_event(:push_tag)
  end

  # Runs code before removing a tag.
  def before_remove_tag
    expire_tags_cache
    expire_tag_count_cache

    repository_event(:remove_tag)
  end

  def before_import
    expire_emptiness_caches
    expire_exists_cache
  end

  # Runs code after a repository has been forked/imported.
  def after_import
    expire_emptiness_caches
    expire_exists_cache
  end

  # Runs code after a new commit has been pushed.
  def after_push_commit(branch_name, revision)
    expire_cache(branch_name, revision)

    repository_event(:push_commit, branch: branch_name)
  end

  # Runs code after a new branch has been created.
  def after_create_branch
    expire_branches_cache
    expire_has_visible_content_cache
    expire_branch_count_cache

    repository_event(:push_branch)
  end

  # Runs code before removing an existing branch.
  def before_remove_branch
    expire_branches_cache

    repository_event(:remove_branch)
  end

  # Runs code after an existing branch has been removed.
  def after_remove_branch
    expire_has_visible_content_cache
    expire_branch_count_cache
    expire_branches_cache
  end

  def method_missing(m, *args, &block)
    if m == :lookup && !block_given?
      lookup_cache[m] ||= {}
      lookup_cache[m][args.join(":")] ||= raw_repository.send(m, *args, &block)
    else
      raw_repository.send(m, *args, &block)
    end
  end

  def respond_to_missing?(method, include_private = false)
    raw_repository.respond_to?(method, include_private) || super
  end

  def blob_at(sha, path)
    unless Gitlab::Git.blank_ref?(sha)
      Blob.decorate(Gitlab::Git::Blob.find(self, sha, path))
    end
  end

  def blob_by_oid(oid)
    Gitlab::Git::Blob.raw(self, oid)
  end

  def readme
    cache.fetch(:readme) { tree(:head).readme }
  end

  def version
    cache.fetch(:version) do
      tree(:head).blobs.find do |file|
        file.name.casecmp('version').zero?
      end
    end
  end

  def contribution_guide
    cache.fetch(:contribution_guide) do
      tree(:head).blobs.find do |file|
        file.contributing?
      end
    end
  end

  def changelog
    cache.fetch(:changelog) do
      file_on_head(/\A(changelog|history|changes|news)/i)
    end
  end

  def license_blob
    return nil unless head_exists?

    cache.fetch(:license_blob) do
      file_on_head(/\A(licen[sc]e|copying)(\..+|\z)/i)
    end
  end

  def license_key
    return nil unless head_exists?

    cache.fetch(:license_key) do
      Licensee.license(path).try(:key)
    end
  end

  def gitignore
    return nil if !exists? || empty?

    cache.fetch(:gitignore) do
      file_on_head(/\A\.gitignore\z/)
    end
  end

  def koding_yml
    return nil unless head_exists?

    cache.fetch(:koding_yml) do
      file_on_head(/\A\.koding\.yml\z/)
    end
  end

  def gitlab_ci_yml
    return nil unless head_exists?

    @gitlab_ci_yml ||= tree(:head).blobs.find do |file|
      file.name == '.gitlab-ci.yml'
    end
  rescue Rugged::ReferenceError
    # For unknow reason spinach scenario "Scenario: I change project path"
    # lead to "Reference 'HEAD' not found" exception from Repository#empty?
    nil
  end

  def head_commit
    @head_commit ||= commit(self.root_ref)
  end

  def head_tree
    @head_tree ||= Tree.new(self, head_commit.sha, nil)
  end

  def tree(sha = :head, path = nil)
    if sha == :head
      if path.nil?
        return head_tree
      else
        sha = head_commit.sha
      end
    end

    Tree.new(self, sha, path)
  end

  def blob_at_branch(branch_name, path)
    last_commit = commit(branch_name)

    if last_commit
      blob_at(last_commit.sha, path)
    else
      nil
    end
  end

  # Returns url for submodule
  #
  # Ex.
  #   @repository.submodule_url_for('master', 'rack')
  #   # => git@localhost:rack.git
  #
  def submodule_url_for(ref, path)
    if submodules(ref).any?
      submodule = submodules(ref)[path]

      if submodule
        submodule['url']
      end
    end
  end

  def last_commit_for_path(sha, path)
    args = %W(#{Gitlab.config.git.bin_path} rev-list --max-count=1 #{sha} -- #{path})
    sha = Gitlab::Popen.popen(args, path_to_repo).first.strip
    commit(sha)
  end

  def next_branch(name, opts = {})
    branch_ids = self.branch_names.map do |n|
      next 1 if n == name
      result = n.match(/\A#{name}-([0-9]+)\z/)
      result[1].to_i if result
    end.compact

    highest_branch_id = branch_ids.max || 0

    return name if opts[:mild] && 0 == highest_branch_id

    "#{name}-#{highest_branch_id + 1}"
  end

  # Remove archives older than 2 hours
  def branches_sorted_by(value)
    case value
    when 'name'
      branches.sort_by(&:name)
    when 'updated_desc'
      branches.sort do |a, b|
        commit(b.target).committed_date <=> commit(a.target).committed_date
      end
    when 'updated_asc'
      branches.sort do |a, b|
        commit(a.target).committed_date <=> commit(b.target).committed_date
      end
    else
      branches
    end
  end

  def tags_sorted_by(value)
    case value
    when 'name'
      VersionSorter.rsort(tags) { |tag| tag.name }
    when 'updated_desc'
      tags_sorted_by_committed_date.reverse
    when 'updated_asc'
      tags_sorted_by_committed_date
    else
      tags
    end
  end

  def contributors
    commits = self.commits(nil, limit: 2000, offset: 0, skip_merges: true)

    commits.group_by(&:author_email).map do |email, commits|
      contributor = Gitlab::Contributor.new
      contributor.email = email

      commits.each do |commit|
        if contributor.name.blank?
          contributor.name = commit.author_name
        end

        contributor.commits += 1
      end

      contributor
    end
  end

  def ref_name_for_sha(ref_path, sha)
    args = %W(#{Gitlab.config.git.bin_path} for-each-ref --count=1 #{ref_path} --contains #{sha})

    # Not found -> ["", 0]
    # Found -> ["b8d95eb4969eefacb0a58f6a28f6803f8070e7b9 commit\trefs/environments/production/77\n", 0]
    Gitlab::Popen.popen(args, path_to_repo).first.split.last
  end

  def refs_contains_sha(ref_type, sha)
    args = %W(#{Gitlab.config.git.bin_path} #{ref_type} --contains #{sha})
    names = Gitlab::Popen.popen(args, path_to_repo).first

    if names.respond_to?(:split)
      names = names.split("\n").map(&:strip)

      names.each do |name|
        name.slice! '* '
      end

      names
    else
      []
    end
  end

  def branch_names_contains(sha)
    refs_contains_sha('branch', sha)
  end

  def tag_names_contains(sha)
    refs_contains_sha('tag', sha)
  end

  def local_branches
    @local_branches ||= raw_repository.local_branches
  end

  alias_method :branches, :local_branches

  def tags
    @tags ||= raw_repository.tags
  end

  def root_ref
    @root_ref ||= cache.fetch(:root_ref) { raw_repository.root_ref }
  end

  def commit_dir(user, path, message, branch, author_email: nil, author_name: nil)
    update_branch_with_hooks(user, branch) do |ref|
      options = {
        commit: {
          branch: ref,
          message: message,
          update_ref: false
        }
      }

      options.merge!(get_committer_and_author(user, email: author_email, name: author_name))

      raw_repository.mkdir(path, options)
    end
  end

  def commit_file(user, path, content, message, branch, update, author_email: nil, author_name: nil)
    update_branch_with_hooks(user, branch) do |ref|
      options = {
        commit: {
          branch: ref,
          message: message,
          update_ref: false
        },
        file: {
          content: content,
          path: path,
          update: update
        }
      }

      options.merge!(get_committer_and_author(user, email: author_email, name: author_name))

      Gitlab::Git::Blob.commit(raw_repository, options)
    end
  end

  def update_file(user, path, content, branch:, previous_path:, message:, author_email: nil, author_name: nil)
    update_branch_with_hooks(user, branch) do |ref|
      options = {
        commit: {
          branch: ref,
          message: message,
          update_ref: false
        },
        file: {
          content: content,
          path: path,
          update: true
        }
      }

      options.merge!(get_committer_and_author(user, email: author_email, name: author_name))

      if previous_path && previous_path != path
        options[:file][:previous_path] = previous_path
        Gitlab::Git::Blob.rename(raw_repository, options)
      else
        Gitlab::Git::Blob.commit(raw_repository, options)
      end
    end
  end

  def remove_file(user, path, message, branch, author_email: nil, author_name: nil)
    update_branch_with_hooks(user, branch) do |ref|
      options = {
        commit: {
          branch: ref,
          message: message,
          update_ref: false
        },
        file: {
          path: path
        }
      }

      options.merge!(get_committer_and_author(user, email: author_email, name: author_name))

      Gitlab::Git::Blob.remove(raw_repository, options)
    end
  end

  def multi_action(user:, branch:, message:, actions:, author_email: nil, author_name: nil)
    update_branch_with_hooks(user, branch) do |ref|
      index = rugged.index
      parents = []
      branch = find_branch(ref)

      if branch
        last_commit = branch.target
        index.read_tree(last_commit.raw_commit.tree)
        parents = [last_commit.sha]
      end

      actions.each do |action|
        case action[:action]
        when :create, :update, :move
          mode =
            case action[:action]
            when :update
              index.get(action[:file_path])[:mode]
            when :move
              index.get(action[:previous_path])[:mode]
            end
          mode ||= 0o100644

          index.remove(action[:previous_path]) if action[:action] == :move

          content = action[:encoding] == 'base64' ? Base64.decode64(action[:content]) : action[:content]
          oid = rugged.write(content, :blob)

          index.add(path: action[:file_path], oid: oid, mode: mode)
        when :delete
          index.remove(action[:file_path])
        end
      end

      options = {
        tree: index.write_tree(rugged),
        message: message,
        parents: parents
      }
      options.merge!(get_committer_and_author(user, email: author_email, name: author_name))

      Rugged::Commit.create(rugged, options)
    end
  end

  def get_committer_and_author(user, email: nil, name: nil)
    committer = user_to_committer(user)
    author = Gitlab::Git::committer_hash(email: email, name: name) || committer

    {
      author: author,
      committer: committer
    }
  end

  def user_to_committer(user)
    Gitlab::Git::committer_hash(email: user.email, name: user.name)
  end

  def can_be_merged?(source_sha, target_branch)
    our_commit = rugged.branches[target_branch].target
    their_commit = rugged.lookup(source_sha)

    if our_commit && their_commit
      !rugged.merge_commits(our_commit, their_commit).conflicts?
    else
      false
    end
  end

  def merge(user, merge_request, options = {})
    our_commit = rugged.branches[merge_request.target_branch].target
    their_commit = rugged.lookup(merge_request.diff_head_sha)

    raise "Invalid merge target" if our_commit.nil?
    raise "Invalid merge source" if their_commit.nil?

    merge_index = rugged.merge_commits(our_commit, their_commit)
    return false if merge_index.conflicts?

    update_branch_with_hooks(user, merge_request.target_branch) do
      actual_options = options.merge(
        parents: [our_commit, their_commit],
        tree: merge_index.write_tree(rugged),
      )

      commit_id = Rugged::Commit.create(rugged, actual_options)
      merge_request.update(in_progress_merge_commit_sha: commit_id)
      commit_id
    end
  end

  def revert(user, commit, base_branch, revert_tree_id = nil)
    source_sha = find_branch(base_branch).target.sha
    revert_tree_id ||= check_revert_content(commit, base_branch)

    return false unless revert_tree_id

    update_branch_with_hooks(user, base_branch) do
      committer = user_to_committer(user)
      source_sha = Rugged::Commit.create(rugged,
        message: commit.revert_message,
        author: committer,
        committer: committer,
        tree: revert_tree_id,
        parents: [rugged.lookup(source_sha)])
    end
  end

  def cherry_pick(user, commit, base_branch, cherry_pick_tree_id = nil)
    source_sha = find_branch(base_branch).target.sha
    cherry_pick_tree_id ||= check_cherry_pick_content(commit, base_branch)

    return false unless cherry_pick_tree_id

    update_branch_with_hooks(user, base_branch) do
      committer = user_to_committer(user)
      source_sha = Rugged::Commit.create(rugged,
        message: commit.message,
        author: {
          email: commit.author_email,
          name: commit.author_name,
          time: commit.authored_date
        },
        committer: committer,
        tree: cherry_pick_tree_id,
        parents: [rugged.lookup(source_sha)])
    end
  end

  def resolve_conflicts(user, branch, params)
    update_branch_with_hooks(user, branch) do
      committer = user_to_committer(user)

      Rugged::Commit.create(rugged, params.merge(author: committer, committer: committer))
    end
  end

  def check_revert_content(commit, base_branch)
    source_sha = find_branch(base_branch).target.sha
    args       = [commit.id, source_sha]
    args << { mainline: 1 } if commit.merge_commit?

    revert_index = rugged.revert_commit(*args)
    return false if revert_index.conflicts?

    tree_id = revert_index.write_tree(rugged)
    return false unless diff_exists?(source_sha, tree_id)

    tree_id
  end

  def check_cherry_pick_content(commit, base_branch)
    source_sha = find_branch(base_branch).target.sha
    args       = [commit.id, source_sha]
    args << 1 if commit.merge_commit?

    cherry_pick_index = rugged.cherrypick_commit(*args)
    return false if cherry_pick_index.conflicts?

    tree_id = cherry_pick_index.write_tree(rugged)
    return false unless diff_exists?(source_sha, tree_id)

    tree_id
  end

  def diff_exists?(sha1, sha2)
    rugged.diff(sha1, sha2).size > 0
  end

  def merged_to_root_ref?(branch_name)
    branch_commit = commit(branch_name)
    root_ref_commit = commit(root_ref)

    if branch_commit
      same_head = branch_commit.id == root_ref_commit.id
      !same_head && is_ancestor?(branch_commit.id, root_ref_commit.id)
    else
      nil
    end
  end

  def merge_base(first_commit_id, second_commit_id)
    first_commit_id = commit(first_commit_id).try(:id) || first_commit_id
    second_commit_id = commit(second_commit_id).try(:id) || second_commit_id
    rugged.merge_base(first_commit_id, second_commit_id)
  rescue Rugged::ReferenceError
    nil
  end

  def is_ancestor?(ancestor_id, descendant_id)
    merge_base(ancestor_id, descendant_id) == ancestor_id
  end

  def search_files(query, ref)
    offset = 2
    args = %W(#{Gitlab.config.git.bin_path} grep -i -I -n --before-context #{offset} --after-context #{offset} -E -e #{Regexp.escape(query)} #{ref || root_ref})
    Gitlab::Popen.popen(args, path_to_repo).first.scrub.split(/^--$/)
  end

  def fetch_ref(source_path, source_ref, target_ref)
    args = %W(#{Gitlab.config.git.bin_path} fetch --no-tags -f #{source_path} #{source_ref}:#{target_ref})
    Gitlab::Popen.popen(args, path_to_repo)
  end

  def create_ref(ref, ref_path)
    fetch_ref(path_to_repo, ref, ref_path)
  end

  def update_branch_with_hooks(current_user, branch)
    update_autocrlf_option

    ref = Gitlab::Git::BRANCH_REF_PREFIX + branch
    target_branch = find_branch(branch)
    was_empty = empty?

    # Make commit
    newrev = yield(ref)

    unless newrev
      raise CommitError.new('Failed to create commit')
    end

    if rugged.lookup(newrev).parent_ids.empty? || target_branch.nil?
      oldrev = Gitlab::Git::BLANK_SHA
    else
      oldrev = rugged.merge_base(newrev, target_branch.target.sha)
    end

    GitHooksService.new.execute(current_user, path_to_repo, oldrev, newrev, ref) do
      update_ref!(ref, newrev, oldrev)

      if was_empty || !target_branch
        # If repo was empty expire cache
        after_create if was_empty
        after_create_branch
      end
    end

    newrev
  end

  def ls_files(ref)
    actual_ref = ref || root_ref
    raw_repository.ls_files(actual_ref)
  end

  def gitattribute(path, name)
    raw_repository.attributes(path)[name]
  end

  def copy_gitattributes(ref)
    actual_ref = ref || root_ref
    begin
      raw_repository.copy_gitattributes(actual_ref)
      true
    rescue Gitlab::Git::Repository::InvalidRef
      false
    end
  end

  def avatar
    return nil unless exists?

    @avatar ||= cache.fetch(:avatar) do
      AVATAR_FILES.find do |file|
        blob_at_branch(root_ref, file)
      end
    end
  end

  private

  def cache
    @cache ||= RepositoryCache.new(path_with_namespace, @project.id)
  end

  def head_exists?
    exists? && !empty? && !rugged.head_unborn?
  end

  def file_on_head(regex)
    tree(:head).blobs.find { |file| file.name =~ regex }
  end

  def tags_sorted_by_committed_date
    tags.sort_by { |tag| tag.target.committed_date }
  end

  def keep_around_ref_name(sha)
    "refs/keep-around/#{sha}"
  end

  def repository_event(event, tags = {})
    Gitlab::Metrics.add_event(event, { path: path_with_namespace }.merge(tags))
  end
end
