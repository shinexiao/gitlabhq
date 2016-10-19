require 'spec_helper'

describe Ci::ProcessPipelineService, services: true do
  let(:pipeline) { create(:ci_pipeline, ref: 'master') }
  let(:user) { create(:user) }
  let(:config) { nil }

  before do
    allow(pipeline).to receive(:ci_yaml_file).and_return(config)
  end

  describe '#execute' do
    def all_builds
      pipeline.builds
    end

    def builds
      all_builds.where.not(status: [:created, :skipped])
    end

    def process_pipeline
      described_class.new(pipeline.project, user).execute(pipeline)
    end

    def succeed_pending
      builds.pending.update_all(status: 'success')
    end

    context 'start queuing next builds' do
      before do
        create(:ci_build, :created, pipeline: pipeline, name: 'linux', stage_idx: 0)
        create(:ci_build, :created, pipeline: pipeline, name: 'mac', stage_idx: 0)
        create(:ci_build, :created, pipeline: pipeline, name: 'rspec', stage_idx: 1)
        create(:ci_build, :created, pipeline: pipeline, name: 'rubocop', stage_idx: 1)
        create(:ci_build, :created, pipeline: pipeline, name: 'deploy', stage_idx: 2)
      end

      it 'processes a pipeline' do
        expect(process_pipeline).to be_truthy
        succeed_pending
        expect(builds.success.count).to eq(2)

        expect(process_pipeline).to be_truthy
        succeed_pending
        expect(builds.success.count).to eq(4)

        expect(process_pipeline).to be_truthy
        succeed_pending
        expect(builds.success.count).to eq(5)

        expect(process_pipeline).to be_falsey
      end

      it 'does not process pipeline if existing stage is running' do
        expect(process_pipeline).to be_truthy
        expect(builds.pending.count).to eq(2)

        expect(process_pipeline).to be_falsey
        expect(builds.pending.count).to eq(2)
      end
    end

    context 'custom stage with first job allowed to fail' do
      before do
        create(:ci_build, :created, pipeline: pipeline, name: 'clean_job', stage_idx: 0, allow_failure: true)
        create(:ci_build, :created, pipeline: pipeline, name: 'test_job', stage_idx: 1, allow_failure: true)
      end

      it 'automatically triggers a next stage when build finishes' do
        expect(process_pipeline).to be_truthy
        expect(builds.pluck(:status)).to contain_exactly('pending')

        pipeline.builds.running_or_pending.each(&:drop)
        expect(builds.pluck(:status)).to contain_exactly('failed', 'pending')
      end
    end

    context 'properly creates builds when "when" is defined' do
      before do
        create(:ci_build, :created, pipeline: pipeline, name: 'build', stage_idx: 0)
        create(:ci_build, :created, pipeline: pipeline, name: 'test', stage_idx: 1)
        create(:ci_build, :created, pipeline: pipeline, name: 'test_failure', stage_idx: 2, when: 'on_failure')
        create(:ci_build, :created, pipeline: pipeline, name: 'deploy', stage_idx: 3)
        create(:ci_build, :created, pipeline: pipeline, name: 'production', stage_idx: 3, when: 'manual')
        create(:ci_build, :created, pipeline: pipeline, name: 'cleanup', stage_idx: 4, when: 'always')
        create(:ci_build, :created, pipeline: pipeline, name: 'clear cache', stage_idx: 4, when: 'manual')
      end

      context 'when builds are successful' do
        it 'properly creates builds' do
          expect(process_pipeline).to be_truthy
          expect(builds.pluck(:name)).to contain_exactly('build')
          expect(builds.pluck(:status)).to contain_exactly('pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test')
          expect(builds.pluck(:status)).to contain_exactly('success', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'deploy')
          expect(builds.pluck(:status)).to contain_exactly('success', 'success', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'deploy', 'cleanup')
          expect(builds.pluck(:status)).to contain_exactly('success', 'success', 'success', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:status)).to contain_exactly('success', 'success', 'success', 'success')
          pipeline.reload
          expect(pipeline.status).to eq('success')
        end
      end

      context 'when test job fails' do
        it 'properly creates builds' do
          expect(process_pipeline).to be_truthy
          expect(builds.pluck(:name)).to contain_exactly('build')
          expect(builds.pluck(:status)).to contain_exactly('pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test')
          expect(builds.pluck(:status)).to contain_exactly('success', 'pending')
          pipeline.builds.running_or_pending.each(&:drop)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'test_failure')
          expect(builds.pluck(:status)).to contain_exactly('success', 'failed', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'test_failure', 'cleanup')
          expect(builds.pluck(:status)).to contain_exactly('success', 'failed', 'success', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:status)).to contain_exactly('success', 'failed', 'success', 'success')
          pipeline.reload
          expect(pipeline.status).to eq('failed')
        end
      end

      context 'when test and test_failure jobs fail' do
        it 'properly creates builds' do
          expect(process_pipeline).to be_truthy
          expect(builds.pluck(:name)).to contain_exactly('build')
          expect(builds.pluck(:status)).to contain_exactly('pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test')
          expect(builds.pluck(:status)).to contain_exactly('success', 'pending')
          pipeline.builds.running_or_pending.each(&:drop)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'test_failure')
          expect(builds.pluck(:status)).to contain_exactly('success', 'failed', 'pending')
          pipeline.builds.running_or_pending.each(&:drop)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'test_failure', 'cleanup')
          expect(builds.pluck(:status)).to contain_exactly('success', 'failed', 'failed', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'test_failure', 'cleanup')
          expect(builds.pluck(:status)).to contain_exactly('success', 'failed', 'failed', 'success')
          pipeline.reload
          expect(pipeline.status).to eq('failed')
        end
      end

      context 'when deploy job fails' do
        it 'properly creates builds' do
          expect(process_pipeline).to be_truthy
          expect(builds.pluck(:name)).to contain_exactly('build')
          expect(builds.pluck(:status)).to contain_exactly('pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test')
          expect(builds.pluck(:status)).to contain_exactly('success', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'deploy')
          expect(builds.pluck(:status)).to contain_exactly('success', 'success', 'pending')
          pipeline.builds.running_or_pending.each(&:drop)

          expect(builds.pluck(:name)).to contain_exactly('build', 'test', 'deploy', 'cleanup')
          expect(builds.pluck(:status)).to contain_exactly('success', 'success', 'failed', 'pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:status)).to contain_exactly('success', 'success', 'failed', 'success')
          pipeline.reload
          expect(pipeline.status).to eq('failed')
        end
      end

      context 'when build is canceled in the second stage' do
        it 'does not schedule builds after build has been canceled' do
          expect(process_pipeline).to be_truthy
          expect(builds.pluck(:name)).to contain_exactly('build')
          expect(builds.pluck(:status)).to contain_exactly('pending')
          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.running_or_pending).not_to be_empty

          expect(builds.pluck(:name)).to contain_exactly('build', 'test')
          expect(builds.pluck(:status)).to contain_exactly('success', 'pending')
          pipeline.builds.running_or_pending.each(&:cancel)

          expect(builds.running_or_pending).to be_empty
          expect(pipeline.reload.status).to eq('canceled')
        end
      end

      context 'when listing manual actions' do
        it 'returns only for skipped builds' do
          # currently all builds are created
          expect(process_pipeline).to be_truthy
          expect(manual_actions).to be_empty

          # succeed stage build
          pipeline.builds.running_or_pending.each(&:success)
          expect(manual_actions).to be_empty

          # succeed stage test
          pipeline.builds.running_or_pending.each(&:success)
          expect(manual_actions).to be_one # production

          # succeed stage deploy
          pipeline.builds.running_or_pending.each(&:success)
          expect(manual_actions).to be_many # production and clear cache
        end

        def manual_actions
          pipeline.manual_actions
        end
      end
    end

    context 'when there are manual/on_failure jobs in earlier stages' do
      before do
        builds
        process_pipeline
        builds.each(&:reload)
      end

      context 'when first stage has only manual jobs' do
        let(:builds) do
          [create_build('build', 0, 'manual'),
           create_build('check', 1),
           create_build('test', 2)]
        end

        it 'starts from the second stage' do
          expect(builds.map(&:status)).to eq(%w[skipped pending created])
        end
      end

      context 'when second stage has only manual jobs' do
        let(:builds) do
          [create_build('check', 0),
           create_build('build', 1, 'manual'),
           create_build('test', 2)]
        end

        it 'skips second stage and continues on third stage' do
          expect(builds.map(&:status)).to eq(%w[pending created created])

          builds.first.success
          builds.each(&:reload)

          expect(builds.map(&:status)).to eq(%w[success skipped pending])
        end
      end

      context 'when second stage has only on_failure jobs' do
        let(:builds) do
          [create_build('check', 0),
           create_build('build', 1, 'on_failure'),
           create_build('test', 2)]
        end

        it 'skips second stage and continues on third stage' do
          expect(builds.map(&:status)).to eq(%w[pending created created])

          builds.first.success
          builds.each(&:reload)

          expect(builds.map(&:status)).to eq(%w[success skipped pending])
        end
      end

      def create_build(name, stage_idx, when_value = nil)
        create(:ci_build,
               :created,
               pipeline: pipeline,
               name: name,
               stage_idx: stage_idx,
               when: when_value)
      end
    end

    context 'when failed build in the middle stage is retried' do
      context 'when failed build is the only unsuccessful build in the stage' do
        before do
          create(:ci_build, :created, pipeline: pipeline, name: 'build:1', stage_idx: 0)
          create(:ci_build, :created, pipeline: pipeline, name: 'build:2', stage_idx: 0)
          create(:ci_build, :created, pipeline: pipeline, name: 'test:1', stage_idx: 1)
          create(:ci_build, :created, pipeline: pipeline, name: 'test:2', stage_idx: 1)
          create(:ci_build, :created, pipeline: pipeline, name: 'deploy:1', stage_idx: 2)
          create(:ci_build, :created, pipeline: pipeline, name: 'deploy:2', stage_idx: 2)
        end

        it 'does trigger builds in the next stage' do
          expect(process_pipeline).to be_truthy
          expect(builds.pluck(:name)).to contain_exactly('build:1', 'build:2')

          pipeline.builds.running_or_pending.each(&:success)

          expect(builds.pluck(:name))
            .to contain_exactly('build:1', 'build:2', 'test:1', 'test:2')

          pipeline.builds.find_by(name: 'test:1').success
          pipeline.builds.find_by(name: 'test:2').drop

          expect(builds.pluck(:name))
            .to contain_exactly('build:1', 'build:2', 'test:1', 'test:2')

          Ci::Build.retry(pipeline.builds.find_by(name: 'test:2')).success

          expect(builds.pluck(:name)).to contain_exactly(
            'build:1', 'build:2', 'test:1', 'test:2', 'test:2', 'deploy:1', 'deploy:2')
        end
      end
    end

    context 'creates a builds from .gitlab-ci.yml' do
      let(:config) do
        YAML.dump({
          rspec: {
            stage: 'test',
            script: 'rspec'
          },
          rubocop: {
            stage: 'test',
            script: 'rubocop'
          },
          deploy: {
            stage: 'deploy',
            script: 'deploy'
          }
        })
      end

      # Using stubbed .gitlab-ci.yml created in commit factory
      #

      before do
        stub_ci_pipeline_yaml_file(config)
        create(:ci_build, :created, pipeline: pipeline, name: 'linux', stage: 'build', stage_idx: 0)
        create(:ci_build, :created, pipeline: pipeline, name: 'mac', stage: 'build', stage_idx: 0)
      end

      it 'when processing a pipeline' do
        # Currently we have two builds with state created
        expect(builds.count).to eq(0)
        expect(all_builds.count).to eq(2)

        # Create builds will mark the created as pending
        expect(process_pipeline).to be_truthy
        expect(builds.count).to eq(2)
        expect(all_builds.count).to eq(2)

        # When we builds succeed we will create a rest of pipeline from .gitlab-ci.yml
        # We will have 2 succeeded, 2 pending (from stage test), total 5 (one more build from deploy)
        succeed_pending
        expect(process_pipeline).to be_truthy
        expect(builds.success.count).to eq(2)
        expect(builds.pending.count).to eq(2)
        expect(all_builds.count).to eq(5)

        # When we succeed the 2 pending from stage test,
        # We will queue a deploy stage, no new builds will be created
        succeed_pending
        expect(process_pipeline).to be_truthy
        expect(builds.pending.count).to eq(1)
        expect(builds.success.count).to eq(4)
        expect(all_builds.count).to eq(5)

        # When we succeed last pending build, we will have a total of 5 succeeded builds, no new builds will be created
        succeed_pending
        expect(process_pipeline).to be_falsey
        expect(builds.success.count).to eq(5)
        expect(all_builds.count).to eq(5)
      end
    end
  end
end
