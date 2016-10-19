class GlobalMilestone
  include Milestoneish

  attr_accessor :title, :milestones
  alias_attribute :name, :title

  def for_display
    @first_milestone
  end

  def self.build_collection(milestones)
    milestones = milestones.group_by(&:title)

    milestones.map do |title, milestones|
      milestones_relation = Milestone.where(id: milestones.map(&:id))
      new(title, milestones_relation)
    end
  end

  def initialize(title, milestones)
    @title = title
    @name = title
    @milestones = milestones
    @first_milestone = milestones.find {|m| m.description.present? } || milestones.first
  end

  def safe_title
    @title.to_slug.normalize.to_s
  end

  def expired?
    if due_date
      due_date.past?
    else
      false
    end
  end

  def projects
    @projects ||= Project.for_milestones(milestones.select(:id))
  end

  def state
    state = milestones.map { |milestone| milestone.state }

    if state.count('closed') == state.size
      'closed'
    else
      'active'
    end
  end

  def active?
    state == 'active'
  end

  def closed?
    state == 'closed'
  end

  def issues
    @issues ||= Issue.of_milestones(milestones.select(:id)).includes(:project, :assignee, :labels)
  end

  def merge_requests
    @merge_requests ||= MergeRequest.of_milestones(milestones.select(:id)).includes(:target_project, :assignee, :labels)
  end

  def participants
    @participants ||= milestones.includes(:participants).map(&:participants).flatten.compact.uniq
  end

  def labels
    @labels ||= GlobalLabel.build_collection(milestones.includes(:labels).map(&:labels).flatten)
                           .sort_by!(&:title)
  end

  def due_date
    return @due_date if defined?(@due_date)

    @due_date =
      if @milestones.all? { |x| x.due_date == @milestones.first.due_date }
        @milestones.first.due_date
      else
        nil
      end
  end

  def expires_at
    if due_date
      if due_date.past?
        "expired on #{due_date.to_s(:medium)}"
      else
        "expires on #{due_date.to_s(:medium)}"
      end
    end
  end
end
