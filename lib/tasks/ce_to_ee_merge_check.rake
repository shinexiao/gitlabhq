desc 'Checks if the branch would apply cleanly to EE'
task ce_to_ee_merge_check: :environment do
  Rake::Task['gitlab:dev:ce_to_ee_merge_check'].invoke
end
