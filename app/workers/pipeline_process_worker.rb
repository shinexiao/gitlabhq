class PipelineProcessWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default

  def perform(pipeline_id)
    Ci::Pipeline.find_by(id: pipeline_id)
      .try(:process!)
  end
end
