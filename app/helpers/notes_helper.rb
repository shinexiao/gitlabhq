module NotesHelper
  def note_target_fields(note)
    if note.noteable
      hidden_field_tag(:target_type, note.noteable.class.name.underscore) +
        hidden_field_tag(:target_id, note.noteable.id)
    end
  end

  def note_editable?(note)
    Ability.can_edit_note?(current_user, note)
  end

  def note_supports_slash_commands?(note)
    Notes::SlashCommandsService.supported?(note, current_user)
  end

  def noteable_json(noteable)
    {
      id: noteable.id,
      class: noteable.class.name,
      resources: noteable.class.table_name,
      project_id: noteable.project.id,
    }.to_json
  end

  def diff_view_data
    return {} unless @comments_target

    @comments_target.slice(:noteable_id, :noteable_type, :commit_id)
  end

  def diff_view_line_data(line_code, position, line_type)
    return if @diff_notes_disabled

    use_legacy_diff_note = @use_legacy_diff_notes
    # If the controller doesn't force the use of legacy diff notes, we
    # determine this on a line-by-line basis by seeing if there already exist
    # active legacy diff notes at this line, in which case newly created notes
    # will use the legacy technology as well.
    # We do this because the discussion_id values of legacy and "new" diff
    # notes, which are used to group notes on the merge request discussion tab,
    # are incompatible.
    # If we didn't, diff notes that would show for the same line on the changes
    # tab, would show in different discussions on the discussion tab.
    use_legacy_diff_note ||= begin
      discussion = @grouped_diff_discussions[line_code]
      discussion && discussion.legacy_diff_discussion?
    end

    data = {
      line_code: line_code,
      line_type: line_type,
    }

    if use_legacy_diff_note
      discussion_id = LegacyDiffNote.discussion_id(
        @comments_target[:noteable_type],
        @comments_target[:noteable_id] || @comments_target[:commit_id],
        line_code
      )

      data.merge!(
        note_type: LegacyDiffNote.name,
        discussion_id: discussion_id
      )
    else
      discussion_id = DiffNote.discussion_id(
        @comments_target[:noteable_type],
        @comments_target[:noteable_id] || @comments_target[:commit_id],
        position
      )

      data.merge!(
        position: position.to_json,
        note_type: DiffNote.name,
        discussion_id: discussion_id
      )
    end

    data
  end

  def link_to_reply_discussion(discussion, line_type = nil)
    return unless current_user

    data = discussion.reply_attributes.merge(line_type: line_type)

    button_tag 'Reply...', class: 'btn btn-text-field js-discussion-reply-button',
                           data: data, title: 'Add a reply'
  end

  def preload_max_access_for_authors(notes, project)
    user_ids = notes.map(&:author_id)
    project.team.max_member_access_for_user_ids(user_ids)
  end

  def preload_noteable_for_regular_notes(notes)
    ActiveRecord::Associations::Preloader.new.preload(notes.select { |note| !note.for_commit? }, :noteable)
  end

  def note_max_access_for_user(note)
    note.project.team.human_max_access(note.author_id)
  end

  def discussion_diff_path(discussion)
    return unless discussion.diff_discussion?

    if discussion.for_merge_request? && discussion.active?
      diffs_namespace_project_merge_request_path(discussion.project.namespace, discussion.project, discussion.noteable, anchor: discussion.line_code)
    elsif discussion.for_commit?
      namespace_project_commit_path(discussion.project.namespace, discussion.project, discussion.noteable, anchor: discussion.line_code)
    end
  end
end
