FactoryGirl.define do
  factory :group_member do
    access_level { GroupMember::OWNER }
    group
    user

    trait(:guest)     { access_level GroupMember::GUEST }
    trait(:reporter)  { access_level GroupMember::REPORTER }
    trait(:developer) { access_level GroupMember::DEVELOPER }
    trait(:master)    { access_level GroupMember::MASTER }
    trait(:owner)     { access_level GroupMember::OWNER }
  end
end
