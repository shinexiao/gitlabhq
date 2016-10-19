module AvatarsHelper
  def author_avatar(commit_or_event, options = {})
    user_avatar(options.merge({
      user: commit_or_event.author,
      user_name: commit_or_event.author_name,
      user_email: commit_or_event.author_email,
      css_class: 'hidden-xs'
    }))
  end

  def user_avatar(options = {})
    avatar_size = options[:size] || 16
    user_name = options[:user].try(:name) || options[:user_name]
    css_class = options[:css_class] || ''
    
    avatar = image_tag(
      avatar_icon(options[:user] || options[:user_email], avatar_size),
      class: "avatar has-tooltip s#{avatar_size} #{css_class}",
      alt: "#{user_name}'s avatar",
      title: user_name,
      data: { container: 'body' }
    )

    if options[:user]
      link_to(avatar, user_path(options[:user]))
    elsif options[:user_email]
      mail_to(options[:user_email], avatar)
    end
  end
end
