require 'spec_helper'

describe API::API, api: true  do
  include ApiHelpers

  let(:user1) { create(:user, can_create_group: false) }
  let(:user2) { create(:user) }
  let(:user3) { create(:user) }
  let(:admin) { create(:admin) }
  let(:avatar_file_path) { File.join(Rails.root, 'spec', 'fixtures', 'banana_sample.gif') }
  let!(:group1) { create(:group, avatar: File.open(avatar_file_path)) }
  let!(:group2) { create(:group, :private) }
  let!(:project1) { create(:project, namespace: group1) }
  let!(:project2) { create(:project, namespace: group2) }
  let!(:project3) { create(:project, namespace: group1, path: 'test', visibility_level: Gitlab::VisibilityLevel::PRIVATE) }

  before do
    group1.add_owner(user1)
    group2.add_owner(user2)
  end

  describe "GET /groups" do
    context "when unauthenticated" do
      it "returns authentication error" do
        get api("/groups")
        expect(response).to have_http_status(401)
      end
    end

    context "when authenticated as user" do
      it "normal user: returns an array of groups of user1" do
        get api("/groups", user1)
        expect(response).to have_http_status(200)
        expect(json_response).to be_an Array
        expect(json_response.length).to eq(1)
        expect(json_response.first['name']).to eq(group1.name)
      end
    end

    context "when authenticated as  admin" do
      it "admin: returns an array of all groups" do
        get api("/groups", admin)
        expect(response).to have_http_status(200)
        expect(json_response).to be_an Array
        expect(json_response.length).to eq(2)
      end
    end

    context "when using skip_groups in request" do
      it "returns all groups excluding skipped groups" do
        get api("/groups", admin), skip_groups: [group2.id]

        expect(response).to have_http_status(200)
        expect(json_response).to be_an Array
        expect(json_response.length).to eq(1)
      end
    end
  end

  describe "GET /groups/:id" do
    context "when authenticated as user" do
      it "returns one of user1's groups" do
        project = create(:project, namespace: group2, path: 'Foo')
        create(:project_group_link, project: project, group: group1)

        get api("/groups/#{group1.id}", user1)

        expect(response).to have_http_status(200)
        expect(json_response['id']).to eq(group1.id)
        expect(json_response['name']).to eq(group1.name)
        expect(json_response['path']).to eq(group1.path)
        expect(json_response['description']).to eq(group1.description)
        expect(json_response['visibility_level']).to eq(group1.visibility_level)
        expect(json_response['avatar_url']).to eq(group1.avatar_url)
        expect(json_response['web_url']).to eq(group1.web_url)
        expect(json_response['projects']).to be_an Array
        expect(json_response['projects'].length).to eq(2)
        expect(json_response['shared_projects']).to be_an Array
        expect(json_response['shared_projects'].length).to eq(1)
        expect(json_response['shared_projects'][0]['id']).to eq(project.id)
      end

      it "does not return a non existing group" do
        get api("/groups/1328", user1)
        expect(response).to have_http_status(404)
      end

      it "does not return a group not attached to user1" do
        get api("/groups/#{group2.id}", user1)

        expect(response).to have_http_status(404)
      end
    end

    context "when authenticated as admin" do
      it "returns any existing group" do
        get api("/groups/#{group2.id}", admin)
        expect(response).to have_http_status(200)
        expect(json_response['name']).to eq(group2.name)
      end

      it "does not return a non existing group" do
        get api("/groups/1328", admin)
        expect(response).to have_http_status(404)
      end
    end

    context 'when using group path in URL' do
      it 'returns any existing group' do
        get api("/groups/#{group1.path}", admin)
        expect(response).to have_http_status(200)
        expect(json_response['name']).to eq(group1.name)
      end

      it 'does not return a non existing group' do
        get api('/groups/unknown', admin)
        expect(response).to have_http_status(404)
      end

      it 'does not return a group not attached to user1' do
        get api("/groups/#{group2.path}", user1)

        expect(response).to have_http_status(404)
      end
    end
  end

  describe 'PUT /groups/:id' do
    let(:new_group_name) { 'New Group'}

    context 'when authenticated as the group owner' do
      it 'updates the group' do
        put api("/groups/#{group1.id}", user1), name: new_group_name, request_access_enabled: true

        expect(response).to have_http_status(200)
        expect(json_response['name']).to eq(new_group_name)
        expect(json_response['request_access_enabled']).to eq(true)
      end

      it 'returns 404 for a non existing group' do
        put api('/groups/1328', user1)

        expect(response).to have_http_status(404)
      end
    end

    context 'when authenticated as the admin' do
      it 'updates the group' do
        put api("/groups/#{group1.id}", admin), name: new_group_name

        expect(response).to have_http_status(200)
        expect(json_response['name']).to eq(new_group_name)
      end
    end

    context 'when authenticated as an user that can see the group' do
      it 'does not updates the group' do
        put api("/groups/#{group1.id}", user2), name: new_group_name

        expect(response).to have_http_status(403)
      end
    end

    context 'when authenticated as an user that cannot see the group' do
      it 'returns 404 when trying to update the group' do
        put api("/groups/#{group2.id}", user1), name: new_group_name

        expect(response).to have_http_status(404)
      end
    end
  end

  describe "GET /groups/:id/projects" do
    context "when authenticated as user" do
      it "returns the group's projects" do
        get api("/groups/#{group1.id}/projects", user1)

        expect(response).to have_http_status(200)
        expect(json_response.length).to eq(2)
        project_names = json_response.map { |proj| proj['name' ] }
        expect(project_names).to match_array([project1.name, project3.name])
      end

      it "does not return a non existing group" do
        get api("/groups/1328/projects", user1)
        expect(response).to have_http_status(404)
      end

      it "does not return a group not attached to user1" do
        get api("/groups/#{group2.id}/projects", user1)

        expect(response).to have_http_status(404)
      end

      it "should only return projects to which user has access" do
        project3.team << [user3, :developer]

        get api("/groups/#{group1.id}/projects", user3)

        expect(response).to have_http_status(200)
        expect(json_response.length).to eq(1)
        expect(json_response.first['name']).to eq(project3.name)
      end
    end

    context "when authenticated as admin" do
      it "should return any existing group" do
        get api("/groups/#{group2.id}/projects", admin)
        expect(response).to have_http_status(200)
        expect(json_response.length).to eq(1)
        expect(json_response.first['name']).to eq(project2.name)
      end

      it "should not return a non existing group" do
        get api("/groups/1328/projects", admin)
        expect(response).to have_http_status(404)
      end
    end

    context 'when using group path in URL' do
      it 'should return any existing group' do
        get api("/groups/#{group1.path}/projects", admin)

        expect(response).to have_http_status(200)
        project_names = json_response.map { |proj| proj['name' ] }
        expect(project_names).to match_array([project1.name, project3.name])
      end

      it 'does not return a non existing group' do
        get api('/groups/unknown/projects', admin)
        expect(response).to have_http_status(404)
      end

      it 'does not return a group not attached to user1' do
        get api("/groups/#{group2.path}/projects", user1)

        expect(response).to have_http_status(404)
      end
    end
  end

  describe "POST /groups" do
    context "when authenticated as user without group permissions" do
      it "does not create group" do
        post api("/groups", user1), attributes_for(:group)
        expect(response).to have_http_status(403)
      end
    end

    context "when authenticated as user with group permissions" do
      it "creates group" do
        group = attributes_for(:group, { request_access_enabled: false })

        post api("/groups", user3), group
        expect(response).to have_http_status(201)

        expect(json_response["name"]).to eq(group[:name])
        expect(json_response["path"]).to eq(group[:path])
        expect(json_response["request_access_enabled"]).to eq(group[:request_access_enabled])
      end

      it "does not create group, duplicate" do
        post api("/groups", user3), { name: 'Duplicate Test', path: group2.path }
        expect(response).to have_http_status(400)
        expect(response.message).to eq("Bad Request")
      end

      it "returns 400 bad request error if name not given" do
        post api("/groups", user3), { path: group2.path }
        expect(response).to have_http_status(400)
      end

      it "returns 400 bad request error if path not given" do
        post api("/groups", user3), { name: 'test' }
        expect(response).to have_http_status(400)
      end
    end
  end

  describe "DELETE /groups/:id" do
    context "when authenticated as user" do
      it "removes group" do
        delete api("/groups/#{group1.id}", user1)
        expect(response).to have_http_status(200)
      end

      it "does not remove a group if not an owner" do
        user4 = create(:user)
        group1.add_master(user4)
        delete api("/groups/#{group1.id}", user3)
        expect(response).to have_http_status(403)
      end

      it "does not remove a non existing group" do
        delete api("/groups/1328", user1)
        expect(response).to have_http_status(404)
      end

      it "does not remove a group not attached to user1" do
        delete api("/groups/#{group2.id}", user1)

        expect(response).to have_http_status(404)
      end
    end

    context "when authenticated as admin" do
      it "removes any existing group" do
        delete api("/groups/#{group2.id}", admin)
        expect(response).to have_http_status(200)
      end

      it "does not remove a non existing group" do
        delete api("/groups/1328", admin)
        expect(response).to have_http_status(404)
      end
    end
  end

  describe "POST /groups/:id/projects/:project_id" do
    let(:project) { create(:project) }
    before(:each) do
      allow_any_instance_of(Projects::TransferService).
        to receive(:execute).and_return(true)
      allow(Project).to receive(:find).and_return(project)
    end

    context "when authenticated as user" do
      it "does not transfer project to group" do
        post api("/groups/#{group1.id}/projects/#{project.id}", user2)
        expect(response).to have_http_status(403)
      end
    end

    context "when authenticated as admin" do
      it "transfers project to group" do
        post api("/groups/#{group1.id}/projects/#{project.id}", admin)
        expect(response).to have_http_status(201)
      end
    end
  end
end
