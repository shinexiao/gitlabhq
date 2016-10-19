require 'spec_helper'

describe 'Snippets', feature: true do
  context 'when the project has snippets' do
    let(:project) { create(:empty_project, :public) }
    let!(:snippets) { create_list(:project_snippet, 2, :public, author: project.owner, project: project) }
    before do
      allow(Snippet).to receive(:default_per_page).and_return(1)
      visit snippets_path(username: project.owner.username)
    end

    it_behaves_like 'paginated snippets'
  end
end
