class GitPushService < BaseService
  attr_accessor :push_data, :push_commits
  include Gitlab::CurrentSettings
  include Gitlab::Access

  # This method will be called after each git update
  # and only if the provided user and project are present in GitLab.
  #
  # All callbacks for post receive action should be placed here.
  #
  # Next, this method:
  #  1. Creates the push event
  #  2. Updates merge requests
  #  3. Recognizes cross-references from commit messages
  #  4. Executes the project's webhooks
  #  5. Executes the project's services
  #  6. Checks if the project's main language has changed
  #
  def execute
    @project.repository.after_create if @project.empty_repo?
    @project.repository.after_push_commit(branch_name, params[:newrev])

    if push_remove_branch?
      @project.repository.after_remove_branch
      @push_commits = []
    elsif push_to_new_branch?
      @project.repository.after_create_branch

      # Re-find the pushed commits.
      if is_default_branch?
        # Initial push to the default branch. Take the full history of that branch as "newly pushed".
        process_default_branch
      else
        # Use the pushed commits that aren't reachable by the default branch
        # as a heuristic. This may include more commits than are actually pushed, but
        # that shouldn't matter because we check for existing cross-references later.
        @push_commits = @project.repository.commits_between(@project.default_branch, params[:newrev])

        # don't process commits for the initial push to the default branch
        process_commit_messages
      end
    elsif push_to_existing_branch?
      # Collect data for this git push
      @push_commits = @project.repository.commits_between(params[:oldrev], params[:newrev])
      process_commit_messages

      # Update the bare repositories info/attributes file using the contents of the default branches
      # .gitattributes file
      update_gitattributes if is_default_branch?
    end

    # Update merge requests that may be affected by this push. A new branch
    # could cause the last commit of a merge request to change.
    update_merge_requests

    perform_housekeeping
  end

  def update_gitattributes
    @project.repository.copy_gitattributes(params[:ref])
  end

  protected

  def update_merge_requests
    UpdateMergeRequestsWorker.perform_async(@project.id, current_user.id, params[:oldrev], params[:newrev], params[:ref])

    EventCreateService.new.push(@project, current_user, build_push_data)
    @project.execute_hooks(build_push_data.dup, :push_hooks)
    @project.execute_services(build_push_data.dup, :push_hooks)
    Ci::CreatePipelineService.new(@project, current_user, build_push_data).execute
    ProjectCacheWorker.perform_async(@project.id)
  end

  def perform_housekeeping
    housekeeping = Projects::HousekeepingService.new(@project)
    housekeeping.increment!
    housekeeping.execute if housekeeping.needed?
  rescue Projects::HousekeepingService::LeaseTaken
  end

  def process_default_branch
    @push_commits = project.repository.commits(params[:newrev])

    # Ensure HEAD points to the default branch in case it is not master
    project.change_head(branch_name)

    # Set protection on the default branch if configured
    if current_application_settings.default_branch_protection != PROTECTION_NONE && !@project.protected_branch?(@project.default_branch)

      params = {
        name: @project.default_branch,
        push_access_levels_attributes: [{
          access_level: current_application_settings.default_branch_protection == PROTECTION_DEV_CAN_PUSH ? Gitlab::Access::DEVELOPER : Gitlab::Access::MASTER
        }],
        merge_access_levels_attributes: [{
          access_level: current_application_settings.default_branch_protection == PROTECTION_DEV_CAN_MERGE ? Gitlab::Access::DEVELOPER : Gitlab::Access::MASTER
        }]
      }

      ProtectedBranches::CreateService.new(@project, current_user, params).execute
    end
  end

  # Extract any GFM references from the pushed commit messages. If the configured issue-closing regex is matched,
  # close the referenced Issue. Create cross-reference Notes corresponding to any other referenced Mentionables.
  def process_commit_messages
    is_default_branch = is_default_branch?

    authors = Hash.new do |hash, commit|
      email = commit.author_email
      next hash[email] if hash.has_key?(email)

      hash[email] = commit_user(commit)
    end

    @push_commits.each do |commit|
      # Keep track of the issues that will be actually closed because they are on a default branch.
      # Hence, when creating cross-reference notes, the not-closed issues (on non-default branches)
      # will also have cross-reference.
      closed_issues = []

      if is_default_branch
        # Close issues if these commits were pushed to the project's default branch and the commit message matches the
        # closing regex. Exclude any mentioned Issues from cross-referencing even if the commits are being pushed to
        # a different branch.
        closed_issues = commit.closes_issues(current_user)
        closed_issues.each do |issue|
          if can?(current_user, :update_issue, issue)
            Issues::CloseService.new(project, authors[commit], {}).execute(issue, commit: commit)
          end
        end
      end

      commit.create_cross_references!(authors[commit], closed_issues)
      update_issue_metrics(commit, authors)
    end
  end

  def build_push_data
    @push_data ||= Gitlab::DataBuilder::Push.build(
      @project,
      current_user,
      params[:oldrev],
      params[:newrev],
      params[:ref],
      push_commits)
  end

  def push_to_existing_branch?
    # Return if this is not a push to a branch (e.g. new commits)
    Gitlab::Git.branch_ref?(params[:ref]) && !Gitlab::Git.blank_ref?(params[:oldrev])
  end

  def push_to_new_branch?
    Gitlab::Git.branch_ref?(params[:ref]) && Gitlab::Git.blank_ref?(params[:oldrev])
  end

  def push_remove_branch?
    Gitlab::Git.branch_ref?(params[:ref]) && Gitlab::Git.blank_ref?(params[:newrev])
  end

  def push_to_branch?
    Gitlab::Git.branch_ref?(params[:ref])
  end

  def is_default_branch?
    Gitlab::Git.branch_ref?(params[:ref]) &&
      (Gitlab::Git.ref_name(params[:ref]) == project.default_branch || project.default_branch.nil?)
  end

  def commit_user(commit)
    commit.author || current_user
  end

  def branch_name
    @branch_name ||= Gitlab::Git.ref_name(params[:ref])
  end

  def update_issue_metrics(commit, authors)
    mentioned_issues = commit.all_references(authors[commit]).issues

    Issue::Metrics.where(issue_id: mentioned_issues.map(&:id), first_mentioned_in_commit_at: nil).
      update_all(first_mentioned_in_commit_at: commit.committed_date)
  end
end
