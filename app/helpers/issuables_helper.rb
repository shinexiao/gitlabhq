module IssuablesHelper
  def sidebar_gutter_toggle_icon
    sidebar_gutter_collapsed? ? icon('angle-double-left') : icon('angle-double-right')
  end

  def sidebar_gutter_collapsed_class
    "right-sidebar-#{sidebar_gutter_collapsed? ? 'collapsed' : 'expanded'}"
  end

  def multi_label_name(current_labels, default_label)
    if current_labels && current_labels.any?
      title = current_labels.first.try(:title)
      if current_labels.size > 1
        "#{title} +#{current_labels.size - 1} more"
      else
        title
      end
    else
      default_label
    end
  end

  def issuable_json_path(issuable)
    project = issuable.project

    if issuable.kind_of?(MergeRequest)
      namespace_project_merge_request_path(project.namespace, project, issuable.iid, :json)
    else
      namespace_project_issue_path(project.namespace, project, issuable.iid, :json)
    end
  end

  def user_dropdown_label(user_id, default_label)
    return default_label if user_id.nil?
    return "Unassigned" if user_id == "0"

    user = User.find_by(id: user_id)

    if user
      user.name
    else
      default_label
    end
  end

  def project_dropdown_label(project_id, default_label)
    return default_label if project_id.nil?
    return "Any project" if project_id == "0"

    project = Project.find_by(id: project_id)

    if project
      project.name_with_namespace
    else
      default_label
    end
  end

  def milestone_dropdown_label(milestone_title, default_label = "Milestone")
    if milestone_title == Milestone::Upcoming.name
      milestone_title = Milestone::Upcoming.title
    end

    h(milestone_title.presence || default_label)
  end

  def issuable_meta(issuable, project, text)
    output = content_tag :strong, "#{text} #{issuable.to_reference}", class: "identifier"
    output << " opened #{time_ago_with_tooltip(issuable.created_at)} by ".html_safe
    output << content_tag(:strong) do
      author_output = link_to_member(project, issuable.author, size: 24, mobile_classes: "hidden-xs", tooltip: true)
      author_output << link_to_member(project, issuable.author, size: 24, by_username: true, avatar: false, mobile_classes: "hidden-sm hidden-md hidden-lg")
    end
  end

  def issuable_todo(issuable)
    if current_user
      current_user.todos.find_by(target: issuable, state: :pending)
    end
  end

  def issuable_labels_tooltip(labels, limit: 5)
    first, last = labels.partition.with_index{ |_, i| i < limit  }

    label_names = first.collect(&:name)
    label_names << "and #{last.size} more" unless last.empty?

    label_names.join(', ')
  end

  def issuables_state_counter_text(issuable_type, state)
    titles = {
      opened: "Open"
    }

    state_title = titles[state] || state.to_s.humanize

    count =
      Rails.cache.fetch(issuables_state_counter_cache_key(issuable_type, state), expires_in: 2.minutes) do
        issuables_count_for_state(issuable_type, state)
      end

    html = content_tag(:span, state_title)
    html << " " << content_tag(:span, number_with_delimiter(count), class: 'badge')

    html.html_safe
  end

  private

  def sidebar_gutter_collapsed?
    cookies[:collapsed_gutter] == 'true'
  end

  def base_issuable_scope(issuable)
    issuable.project.send(issuable.class.table_name).send(issuable_state_scope(issuable))
  end

  def issuable_state_scope(issuable)
    if issuable.respond_to?(:merged?) && issuable.merged?
      :merged
    else
      issuable.open? ? :opened : :closed
    end
  end

  def issuables_count_for_state(issuable_type, state)
    issuables_finder = public_send("#{issuable_type}_finder")
    issuables_finder.params[:state] = state

    issuables_finder.execute.page(1).total_count
  end

  IRRELEVANT_PARAMS_FOR_CACHE_KEY = %i[utf8 sort page]
  private_constant :IRRELEVANT_PARAMS_FOR_CACHE_KEY

  def issuables_state_counter_cache_key(issuable_type, state)
    opts = params.with_indifferent_access
    opts[:state] = state
    opts.except!(*IRRELEVANT_PARAMS_FOR_CACHE_KEY)

    hexdigest(['issuables_count', issuable_type, opts.sort].flatten.join('-'))
  end
end
