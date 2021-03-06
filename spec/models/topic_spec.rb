# encoding: UTF-8

require 'spec_helper'
require_dependency 'post_destroyer'

describe Topic do

  it { should validate_presence_of :title }

  it { should belong_to :category }
  it { should belong_to :user }
  it { should belong_to :last_poster }
  it { should belong_to :featured_user1 }
  it { should belong_to :featured_user2 }
  it { should belong_to :featured_user3 }
  it { should belong_to :featured_user4 }

  it { should have_many :posts }
  it { should have_many :topic_users }
  it { should have_many :topic_links }
  it { should have_many :topic_allowed_users }
  it { should have_many :allowed_users }
  it { should have_many :invites }

  it { should rate_limit }

  it_behaves_like "a versioned model"

  context 'slug' do

    let(:title) { "hello world topic" }
    let(:slug) { "hello-world-slug" }

    it "returns a Slug for a title" do
      Slug.expects(:for).with(title).returns(slug)
      Fabricate.build(:topic, title: title).slug.should == slug
    end

    it "returns 'topic' when the slug is empty (say, non-english chars)" do
      Slug.expects(:for).with(title).returns("")
      Fabricate.build(:topic, title: title).slug.should == "topic"
    end

  end

  context 'topic title uniqueness' do

    let!(:topic) { Fabricate(:topic) }
    let(:new_topic) { Fabricate.build(:topic, title: topic.title) }

    context "when duplicates aren't allowed" do
      before do
        SiteSetting.expects(:allow_duplicate_topic_titles?).returns(false)
      end

      it "won't allow another topic to be created with the same name" do
        new_topic.should_not be_valid
      end

      it "won't allow another topic with an upper case title to be created" do
        new_topic.title = new_topic.title.upcase
        new_topic.should_not be_valid
      end

      it "allows it when the topic is deleted" do
        topic.destroy
        new_topic.should be_valid
      end

      it "allows a private message to be created with the same topic" do
        new_topic.archetype = Archetype.private_message
        new_topic.should be_valid
      end
    end

    context "when duplicates are allowed" do
      before do
        SiteSetting.expects(:allow_duplicate_topic_titles?).returns(true)
      end

      it "will allow another topic to be created with the same name" do
        new_topic.should be_valid
      end
    end

  end

  context 'html in title' do

    def build_topic_with_title(title)
      build(:topic, title: title).tap{ |t| t.valid? }
    end

    let(:topic_bold) { build_topic_with_title("Topic with <b>bold</b> text in its title" ) }
    let(:topic_image) { build_topic_with_title("Topic with <img src='something'> image in its title" ) }
    let(:topic_script) { build_topic_with_title("Topic with <script>alert('title')</script> script in its title" ) }

    it "escapes script contents" do
      topic_script.title.should == "Topic with script in its title"
    end

    it "escapes bold contents" do
      topic_bold.title.should == "Topic with bold text in its title"
    end

    it "escapes image contents" do
      topic_image.title.should == "Topic with image in its title"
    end

  end

  context 'fancy title' do
    let(:topic) { Fabricate.build(:topic, title: "\"this topic\" -- has ``fancy stuff''" ) }

    context 'title_fancy_entities disabled' do
      before do
        SiteSetting.stubs(:title_fancy_entities).returns(false)
      end

      it "doesn't change the title to add entities" do
        topic.fancy_title.should == topic.title
      end
    end

    context 'title_fancy_entities enabled' do
      before do
        SiteSetting.stubs(:title_fancy_entities).returns(true)
      end

      it "converts the title to have fancy entities" do
        topic.fancy_title.should == "&ldquo;this topic&rdquo; &ndash; has &ldquo;fancy stuff&rdquo;"
      end
    end


  end


  context 'similar_to' do

    it 'returns blank with nil params' do
      Topic.similar_to(nil, nil).should be_blank
    end

    context 'with a similar topic' do
      let!(:topic) { Fabricate(:topic, title: "Evil trout is the dude who posted this topic") }

      it 'returns the similar topic if the title is similar' do
        Topic.similar_to("has evil trout made any topics?", "i am wondering has evil trout made any topics?").should == [topic]
      end

    end

  end

  context 'post_numbers' do
    let!(:topic) { Fabricate(:topic) }
    let!(:p1) { Fabricate(:post, topic: topic, user: topic.user) }
    let!(:p2) { Fabricate(:post, topic: topic, user: topic.user) }
    let!(:p3) { Fabricate(:post, topic: topic, user: topic.user) }

    it "returns the post numbers of the topic" do
      topic.post_numbers.should == [1, 2, 3]
      p2.destroy
      topic.reload
      topic.post_numbers.should == [1, 3]
    end

  end

  context 'move_posts' do
    let(:user) { Fabricate(:user) }
    let(:another_user) { Fabricate(:evil_trout) }
    let(:category) { Fabricate(:category, user: user) }
    let!(:topic) { Fabricate(:topic, user: user, category: category) }
    let!(:p1) { Fabricate(:post, topic: topic, user: user) }
    let!(:p2) { Fabricate(:post, topic: topic, user: another_user)}
    let!(:p3) { Fabricate(:post, topic: topic, user: user)}
    let!(:p4) { Fabricate(:post, topic: topic, user: user)}

    before do
      # add a like to a post
      PostAction.act(another_user, p4, PostActionType.types[:like])
    end

    context 'success' do

      it "enqueues a job to notify users" do
        topic.stubs(:add_moderator_post)
        Jobs.expects(:enqueue).with(:notify_moved_posts, post_ids: [p2.id, p4.id], moved_by_id: user.id)
        topic.move_posts(user, [p2.id, p4.id], title: "new testing topic name")
      end

      it "adds a moderator post at the location of the first moved post" do
        topic.expects(:add_moderator_post).with(user, instance_of(String), has_entries(post_number: 2))
        topic.move_posts(user, [p2.id, p4.id], title: "new testing topic name")
      end

    end

    context "errors" do

      it "raises an error when one of the posts doesn't exist" do
        lambda { topic.move_posts(user, [1003], title: "new testing topic name") }.should raise_error(Discourse::InvalidParameters)
      end

      it "raises an error and does not create a topic if no posts were moved" do
        Topic.count.tap do |original_topic_count|
          lambda {
            topic.move_posts(user, [], title: "new testing topic name")
          }.should raise_error(Discourse::InvalidParameters)

          expect(Topic.count).to eq original_topic_count
        end
      end
    end

    context "successfully moved" do
      before do
        topic.expects(:add_moderator_post)
        TopicUser.update_last_read(user, topic.id, p4.post_number, 0)
      end

      context "to a new topic" do
        let!(:new_topic) { topic.move_posts(user, [p2.id, p4.id], title: "new testing topic name") }

        it "works correctly" do
          TopicUser.where(user_id: user.id, topic_id: topic.id).first.last_read_post_number.should == p3.post_number

          new_topic.should be_present
          new_topic.featured_user1_id.should == another_user.id
          new_topic.like_count.should == 1
          new_topic.category.should == category
          topic.featured_user1_id.should be_blank
          new_topic.posts.should =~ [p2, p4]

          new_topic.reload
          new_topic.posts_count.should == 2
          new_topic.highest_post_number.should == 2

          p2.reload
          p2.sort_order.should == 1
          p2.post_number.should == 1

          p4.reload
          p4.post_number.should == 2
          p4.sort_order.should == 2

          topic.reload
          topic.featured_user1_id.should be_blank
          topic.like_count.should == 0
          topic.posts_count.should == 2
          topic.posts.should =~ [p1, p3]
          topic.highest_post_number.should == p3.post_number
        end
      end

      context "to an existing topic" do

        let!(:destination_topic) { Fabricate(:topic, user: user ) }
        let!(:destination_op) { Fabricate(:post, topic: destination_topic, user: user) }
        let!(:moved_to) { topic.move_posts(user, [p2.id, p4.id], destination_topic_id: destination_topic.id )}

        it "works correctly" do
          moved_to.should == destination_topic

          # Check out new topic
          moved_to.reload
          moved_to.posts_count.should == 3
          moved_to.highest_post_number.should == 3
          moved_to.featured_user1_id.should == another_user.id
          moved_to.like_count.should == 1
          moved_to.category.should be_blank

          # Posts should be re-ordered
          p2.reload
          p2.sort_order.should == 2
          p2.post_number.should == 2
          p2.topic_id.should == moved_to.id

          p4.reload
          p4.post_number.should == 3
          p4.sort_order.should == 3
          p4.topic_id.should == moved_to.id

          # Check out the original topic
          topic.reload
          topic.posts_count.should == 2
          topic.highest_post_number.should == 3
          topic.featured_user1_id.should be_blank
          topic.like_count.should == 0
          topic.posts_count.should == 2
          topic.posts.should =~ [p1, p3]
          topic.highest_post_number.should == p3.post_number

          # Should update last reads
          TopicUser.where(user_id: user.id, topic_id: topic.id).first.last_read_post_number.should == p3.post_number
        end
      end

      context "moving the first post" do

        let!(:new_topic) { topic.move_posts(user, [p1.id, p2.id], title: "new testing topic name") }

        it "copies the OP, doesn't delete it" do
          new_topic.should be_present
          new_topic.posts.first.raw.should == p1.raw

          new_topic.reload
          new_topic.posts_count.should == 2
          new_topic.highest_post_number.should == 2

          # First post didn't move
          p1.reload
          p1.sort_order.should == 1
          p1.post_number.should == 1
          p1.topic_id == topic.id

          # Second post is in a new topic
          p2.reload
          p2.post_number.should == 2
          p2.sort_order.should == 2
          p2.topic_id == new_topic.id

          topic.reload
          topic.posts.should =~ [p1, p3, p4]
          topic.highest_post_number.should == p4.post_number
        end

      end


    end
  end

  context 'private message' do
    let(:coding_horror) { User.where(username: 'CodingHorror').first }
    let(:evil_trout) { Fabricate(:evil_trout) }
    let(:topic) { Fabricate(:private_message_topic) }

    it "should integrate correctly" do
      Guardian.new(topic.user).can_see?(topic).should be_true
      Guardian.new.can_see?(topic).should be_false
      Guardian.new(evil_trout).can_see?(topic).should be_false
      Guardian.new(coding_horror).can_see?(topic).should be_true
      TopicQuery.new(evil_trout).list_latest.topics.should_not include(topic)

      # invites
      topic.invite(topic.user, 'duhhhhh').should be_false
    end

    context 'invite' do

      it "delegates to topic.invite_by_email when the user doesn't exist, but it's an email" do
        topic.expects(:invite_by_email).with(topic.user, 'jake@adventuretime.ooo')
        topic.invite(topic.user, 'jake@adventuretime.ooo')
      end

      context 'existing user' do
        let(:walter) { Fabricate(:walter_white) }

        context 'by username' do

          it 'adds walter to the allowed users' do
            topic.invite(topic.user, walter.username).should be_true
            topic.allowed_users.include?(walter).should be_true
          end

          it 'creates a notification' do
            lambda { topic.invite(topic.user, walter.username) }.should change(Notification, :count)
          end
        end

        context 'by email' do
          it 'returns true' do
            topic.invite(topic.user, walter.email).should be_true
          end

          it 'adds walter to the allowed users' do
            topic.invite(topic.user, walter.email)
            topic.allowed_users.include?(walter).should be_true
          end

          it 'creates a notification' do
            lambda { topic.invite(topic.user, walter.email) }.should change(Notification, :count)
          end

        end
      end

    end

    context "user actions" do
      let(:actions) { topic.user.user_actions }

      it "should set up actions correctly" do
        ActiveRecord::Base.observers.enable :all

        actions.map{|a| a.action_type}.should_not include(UserAction::NEW_TOPIC)
        actions.map{|a| a.action_type}.should include(UserAction::NEW_PRIVATE_MESSAGE)
        coding_horror.user_actions.map{|a| a.action_type}.should include(UserAction::GOT_PRIVATE_MESSAGE)
      end

    end

    context "other user" do

      before do
        # let! is weird, this test need a refactor
        t = topic
      end

      let(:creator) { PostCreator.new(topic.user, raw: Fabricate.build(:post).raw, topic_id: topic.id )}

      it "sends the other user an email when there's a new post" do
        UserNotifications.expects(:private_message).with(coding_horror, has_key(:post))
        creator.create
      end

      it "doesn't send the user an email when they have them disabled" do
        coding_horror.update_column(:email_private_messages, false)
        UserNotifications.expects(:private_message).with(coding_horror, has_key(:post)).never
        creator.create
      end

    end


  end


  context 'bumping topics' do

    before do
      @topic = Fabricate(:topic, bumped_at: 1.year.ago)
    end


    it 'updates the bumped_at field when a new post is made' do
      @topic.bumped_at.should be_present
      lambda {
        Fabricate(:post, topic: @topic, user: @topic.user)
        @topic.reload
      }.should change(@topic, :bumped_at)
    end

    context 'editing posts' do
      before do
        @earlier_post = Fabricate(:post, topic: @topic, user: @topic.user)
        @last_post = Fabricate(:post, topic: @topic, user: @topic.user)
        @topic.reload
      end

      it "doesn't bump the topic on an edit to the last post that doesn't result in a new version" do
        lambda {
          SiteSetting.expects(:ninja_edit_window).returns(5.minutes)
          @last_post.revise(@last_post.user, 'updated contents', revised_at: @last_post.created_at + 10.seconds)
          @topic.reload
        }.should_not change(@topic, :bumped_at)
      end

      it "bumps the topic when a new version is made of the last post" do
        lambda {
          @last_post.revise(Fabricate(:moderator), 'updated contents')
          @topic.reload
        }.should change(@topic, :bumped_at)
      end

      it "doesn't bump the topic when a post that isn't the last post receives a new version" do
        lambda {
          @earlier_post.revise(Fabricate(:moderator), 'updated contents')
          @topic.reload
        }.should_not change(@topic, :bumped_at)
      end
    end
  end

  context 'moderator posts' do
    before do
      @moderator = Fabricate(:moderator)
      @topic = Fabricate(:topic)
      @mod_post = @topic.add_moderator_post(@moderator, "Moderator did something. http://discourse.org", post_number: 999)
    end

    it 'creates a moderator post' do
      @mod_post.should be_present
      @mod_post.post_type.should == Post.types[:moderator_action]
      @mod_post.post_number.should == 999
      @mod_post.sort_order.should == 999
      @topic.topic_links.count.should == 1
      @topic.reload
      @topic.moderator_posts_count.should == 1
    end
  end


  context 'update_status' do
    before do
      @topic = Fabricate(:topic, bumped_at: 1.hour.ago)
      @topic.reload
      @original_bumped_at = @topic.bumped_at.to_f
      @user = @topic.user
      @user.admin = true
    end

    context 'visibility' do
      context 'disable' do
        before do
          @topic.update_status('visible', false, @user)
          @topic.reload
        end

        it 'should not be visible and have correct counts' do
          @topic.should_not be_visible
          @topic.moderator_posts_count.should == 1
          @topic.bumped_at.to_f.should == @original_bumped_at
        end
      end

      context 'enable' do
        before do
          @topic.update_attribute :visible, false
          @topic.update_status('visible', true, @user)
          @topic.reload
        end

        it 'should be visible with correct counts' do
          @topic.should be_visible
          @topic.moderator_posts_count.should == 1
          @topic.bumped_at.to_f.should == @original_bumped_at
        end
      end
    end

    context 'pinned' do
      context 'disable' do
        before do
          @topic.update_status('pinned', false, @user)
          @topic.reload
        end

        it "doesn't have a pinned_at but has correct dates" do
          @topic.pinned_at.should be_blank
          @topic.moderator_posts_count.should == 1
          @topic.bumped_at.to_f.should == @original_bumped_at
        end
      end

      context 'enable' do
        before do
          @topic.update_attribute :pinned_at, nil
          @topic.update_status('pinned', true, @user)
          @topic.reload
        end

        it 'should enable correctly' do
          @topic.pinned_at.should be_present
          @topic.bumped_at.to_f.should == @original_bumped_at
          @topic.moderator_posts_count.should == 1
        end

      end
    end

    context 'archived' do
      context 'disable' do
        before do
          @topic.update_status('archived', false, @user)
          @topic.reload
        end

        it 'should archive correctly' do
          @topic.should_not be_archived
          @topic.bumped_at.to_f.should == @original_bumped_at
          @topic.moderator_posts_count.should == 1
        end
      end

      context 'enable' do
        before do
          @topic.update_attribute :archived, false
          @topic.update_status('archived', true, @user)
          @topic.reload
        end

        it 'should be archived' do
          @topic.should be_archived
          @topic.moderator_posts_count.should == 1
          @topic.bumped_at.to_f.should == @original_bumped_at
        end

      end
    end

    shared_examples_for 'a status that closes a topic' do
      context 'disable' do
        before do
          @topic.update_status(status, false, @user)
          @topic.reload
        end

        it 'should not be pinned' do
          @topic.should_not be_closed
          @topic.moderator_posts_count.should == 1
          @topic.bumped_at.to_f.should_not == @original_bumped_at
        end

      end

      context 'enable' do
        before do
          @topic.update_attribute :closed, false
          @topic.update_status(status, true, @user)
          @topic.reload
        end

        it 'should be closed' do
          @topic.should be_closed
          @topic.bumped_at.to_f.should == @original_bumped_at
          @topic.moderator_posts_count.should == 1
        end
      end
    end

    context 'closed' do
      let(:status) { 'closed' }
      it_should_behave_like 'a status that closes a topic'
    end

    context 'autoclosed' do
      let(:status) { 'autoclosed' }
      it_should_behave_like 'a status that closes a topic'
    end


  end

  describe 'toggle_star' do

    shared_examples_for "adding a star to a topic" do
      it 'triggers a forum topic user change with true' do
        # otherwise no chance the mock will work
        freeze_time do
          TopicUser.expects(:change).with(@user, @topic.id, starred: true, starred_at: DateTime.now, unstarred_at: nil)
          @topic.toggle_star(@user, true)
        end
      end

      it 'increases the star_count of the forum topic' do
        lambda {
          @topic.toggle_star(@user, true)
          @topic.reload
        }.should change(@topic, :star_count).by(1)
      end

      it 'triggers the rate limiter' do
        Topic::FavoriteLimiter.any_instance.expects(:performed!)
        @topic.toggle_star(@user, true)
      end
    end

    before do
      @topic = Fabricate(:topic)
      @user = @topic.user
    end

    it_should_behave_like "adding a star to a topic"

    describe 'removing a star' do
      before do
        @topic.toggle_star(@user, true)
        @topic.reload
      end

      it 'rolls back the rate limiter' do
        Topic::FavoriteLimiter.any_instance.expects(:rollback!)
        @topic.toggle_star(@user, false)
      end

      it 'triggers a forum topic user change with false' do
        freeze_time do
          TopicUser.expects(:change).with(@user, @topic.id, starred: false, unstarred_at: DateTime.now)
          @topic.toggle_star(@user, false)
        end
      end

      it 'reduces the star_count' do
        lambda {
          @topic.toggle_star(@user, false)
          @topic.reload
        }.should change(@topic, :star_count).by(-1)
      end

      describe 'and adding a star again' do
        before do
          @topic.toggle_star(@user, false)
          @topic.reload
        end
        it_should_behave_like "adding a star to a topic"
      end
    end
  end

  context 'last_poster info' do

    before do
      @user = Fabricate(:user)
      @post = Fabricate(:post, user: @user)
      @topic = @post.topic
    end

    it 'initially has the last_post_user_id of the OP' do
      @topic.last_post_user_id.should == @user.id
    end

    context 'after a second post' do
      before do
        @second_user = Fabricate(:coding_horror)
        @new_post = Fabricate(:post, topic: @topic, user: @second_user)
        @topic.reload
      end

      it 'updates the last_post_user_id to the second_user' do
        @topic.last_post_user_id.should == @second_user.id
        @topic.last_posted_at.to_i.should == @new_post.created_at.to_i
        topic_user = @second_user.topic_users.where(topic_id: @topic.id).first
        topic_user.posted?.should be_true
      end

    end
  end

  describe 'with category' do
    before do
      @category = Fabricate(:category)
    end

    it "should not increase the topic_count with no category" do
      lambda { Fabricate(:topic, user: @category.user); @category.reload }.should_not change(@category, :topic_count)
    end

    it "should increase the category's topic_count" do
      lambda { Fabricate(:topic, user: @category.user, category_id: @category.id); @category.reload }.should change(@category, :topic_count).by(1)
    end
  end

  describe 'meta data' do
    let(:topic) { Fabricate(:topic, meta_data: {hello: 'world'}) }

    it 'allows us to create a topic with meta data' do
      topic.meta_data['hello'].should == 'world'
    end

    context 'updating' do

      context 'existing key' do
        before do
          topic.update_meta_data(hello: 'bane')
        end

        it 'updates the key' do
          topic.meta_data['hello'].should == 'bane'
        end
      end

      context 'new key' do
        before do
          topic.update_meta_data(city: 'gotham')
        end

        it 'adds the new key' do
          topic.meta_data['city'].should == 'gotham'
          topic.meta_data['hello'].should == 'world'
        end

      end


    end

  end

  describe 'after create' do

    let(:topic) { Fabricate(:topic) }

    it 'is a regular topic by default' do
      topic.archetype.should == Archetype.default
      topic.has_best_of.should be_false
      topic.percent_rank.should == 1.0
      topic.should be_visible
      topic.pinned_at.should be_blank
      topic.should_not be_closed
      topic.should_not be_archived
      topic.moderator_posts_count.should == 0
    end

    context 'post' do
      let(:post) { Fabricate(:post, topic: topic, user: topic.user) }

      it 'has the same archetype as the topic' do
        post.archetype.should == topic.archetype
      end
    end
  end

  describe 'versions' do
    let(:topic) { Fabricate(:topic) }

    it "has version 1 by default" do
      topic.version.should == 1
    end

    context 'changing title' do
      before do
        topic.title = "new title for the topic"
        topic.save
      end

      it "creates a new version" do
        topic.version.should == 2
      end
    end

    context 'changing category' do
      let(:category) { Fabricate(:category) }

      before do
        topic.change_category(category.name)
      end

      it "creates a new version" do
        topic.version.should == 2
      end

      context "removing a category" do
        before do
          topic.change_category(nil)
        end

        it "creates a new version" do
          topic.version.should == 3
        end
      end

    end

    context 'bumping the topic' do
      before do
        topic.bumped_at = 10.minutes.from_now
        topic.save
      end

      it "doesn't craete a new version" do
        topic.version.should == 1
      end
    end

  end

  describe 'change_category' do

    before do
      @topic = Fabricate(:topic)
      @category = Fabricate(:category, user: @topic.user)
      @user = @topic.user
    end

    describe 'without a previous category' do

      it 'should not change the topic_count when not changed' do
       lambda { @topic.change_category(nil); @category.reload }.should_not change(@category, :topic_count)
      end

      describe 'changed category' do
        before do
          @topic.change_category(@category.name)
          @category.reload
        end

        it 'changes the category' do
          @topic.category.should == @category
          @category.topic_count.should == 1
        end

      end


      it "doesn't change the category when it can't be found" do
        @topic.change_category('made up')
        @topic.category.should be_blank
      end
    end

    describe 'with a previous category' do
      before do
        @topic.change_category(@category.name)
        @topic.reload
        @category.reload
      end

      it 'increases the topic_count' do
        @category.topic_count.should == 1
      end

      it "doesn't change the topic_count when the value doesn't change" do
        lambda { @topic.change_category(@category.name); @category.reload }.should_not change(@category, :topic_count)
      end

      it "doesn't reset the category when given a name that doesn't exist" do
        @topic.change_category('made up')
        @topic.category_id.should be_present
      end

      describe 'to a different category' do
        before do
          @new_category = Fabricate(:category, user: @user, name: '2nd category')
          @topic.change_category(@new_category.name)
          @topic.reload
          @new_category.reload
          @category.reload
        end

        it "should increase the new category's topic count" do
          @new_category.topic_count.should == 1
        end

        it "should lower the original category's topic count" do
          @category.topic_count.should == 0
        end

      end

      describe 'when the category exists' do
        before do
          @topic.change_category(nil)
          @category.reload
        end

        it "resets the category" do
          @topic.category_id.should be_blank
          @category.topic_count.should == 0
        end

      end

    end

  end

  describe 'scopes' do
    describe '#by_most_recently_created' do
      it 'returns topics ordered by created_at desc, id desc' do
        now = Time.now
        a = Fabricate(:topic, created_at: now - 2.minutes)
        b = Fabricate(:topic, created_at: now)
        c = Fabricate(:topic, created_at: now)
        d = Fabricate(:topic, created_at: now - 2.minutes)
        Topic.by_newest.should == [c,b,d,a]
      end
    end
  end

  describe 'auto-close' do
    context 'a new topic' do
      context 'auto_close_at is set' do
        it 'queues a job to close the topic' do
          Timecop.freeze(Time.zone.now) do
            Jobs.expects(:enqueue_at).with(7.days.from_now, :close_topic, all_of( has_key(:topic_id), has_key(:user_id) ))
            Fabricate(:topic, auto_close_at: 7.days.from_now, user: Fabricate(:admin))
          end
        end

        it 'when auto_close_user_id is nil, it will use the topic creator as the topic closer' do
          topic_creator = Fabricate(:admin)
          Jobs.expects(:enqueue_at).with do |datetime, job_name, job_args|
            job_args[:user_id] == topic_creator.id
          end
          Fabricate(:topic, auto_close_at: 7.days.from_now, user: topic_creator)
        end

        it 'when auto_close_user_id is set, it will use it as the topic closer' do
          topic_creator = Fabricate(:admin)
          topic_closer = Fabricate(:user, admin: true)
          Jobs.expects(:enqueue_at).with do |datetime, job_name, job_args|
            job_args[:user_id] == topic_closer.id
          end
          Fabricate(:topic, auto_close_at: 7.days.from_now, auto_close_user: topic_closer, user: topic_creator)
        end

        it "ignores the category's default auto-close" do
          Timecop.freeze(Time.zone.now) do
            Jobs.expects(:enqueue_at).with(7.days.from_now, :close_topic, all_of( has_key(:topic_id), has_key(:user_id) ))
            Fabricate(:topic, auto_close_at: 7.days.from_now, user: Fabricate(:admin), category: Fabricate(:category, auto_close_days: 2))
          end
        end
      end
    end

    context 'an existing topic' do
      it 'when auto_close_at is set, it queues a job to close the topic' do
        Timecop.freeze(Time.zone.now) do
          topic = Fabricate(:topic)
          Jobs.expects(:enqueue_at).with(12.hours.from_now, :close_topic, has_entries(topic_id: topic.id, user_id: topic.user_id))
          topic.auto_close_at = 12.hours.from_now
          topic.save.should be_true
        end
      end

      it 'when auto_close_at and auto_closer_user_id are set, it queues a job to close the topic' do
        Timecop.freeze(Time.zone.now) do
          topic  = Fabricate(:topic)
          closer = Fabricate(:admin)
          Jobs.expects(:enqueue_at).with(12.hours.from_now, :close_topic, has_entries(topic_id: topic.id, user_id: closer.id))
          topic.auto_close_at = 12.hours.from_now
          topic.auto_close_user = closer
          topic.save.should be_true
        end
      end

      it 'when auto_close_at is removed, it cancels the job to close the topic' do
        Jobs.stubs(:enqueue_at).returns(true)
        topic = Fabricate(:topic, auto_close_at: 1.day.from_now)
        Jobs.expects(:cancel_scheduled_job).with(:close_topic, {topic_id: topic.id})
        topic.auto_close_at = nil
        topic.save.should be_true
        topic.auto_close_user.should be_nil
      end

      it 'when auto_close_user is removed, it updates the job' do
        Timecop.freeze(Time.zone.now) do
          Jobs.stubs(:enqueue_at).with(1.day.from_now, :close_topic, anything).returns(true)
          topic = Fabricate(:topic, auto_close_at: 1.day.from_now, auto_close_user: Fabricate(:admin))
          Jobs.expects(:cancel_scheduled_job).with(:close_topic, {topic_id: topic.id})
          Jobs.expects(:enqueue_at).with(1.day.from_now, :close_topic, has_entries(topic_id: topic.id, user_id: topic.user_id))
          topic.auto_close_user = nil
          topic.save.should be_true
        end
      end

      it 'when auto_close_at value is changed, it reschedules the job' do
        Timecop.freeze(Time.zone.now) do
          Jobs.stubs(:enqueue_at).returns(true)
          topic = Fabricate(:topic, auto_close_at: 1.day.from_now)
          Jobs.expects(:cancel_scheduled_job).with(:close_topic, {topic_id: topic.id})
          Jobs.expects(:enqueue_at).with(3.days.from_now, :close_topic, has_entry(topic_id: topic.id))
          topic.auto_close_at = 3.days.from_now
          topic.save.should be_true
        end
      end

      it 'when auto_close_user_id is changed, it updates the job' do
        Timecop.freeze(Time.zone.now) do
          admin = Fabricate(:admin)
          Jobs.stubs(:enqueue_at).returns(true)
          topic = Fabricate(:topic, auto_close_at: 1.day.from_now)
          Jobs.expects(:cancel_scheduled_job).with(:close_topic, {topic_id: topic.id})
          Jobs.expects(:enqueue_at).with(1.day.from_now, :close_topic, has_entries(topic_id: topic.id, user_id: admin.id))
          topic.auto_close_user = admin
          topic.save.should be_true
        end
      end

      it 'when auto_close_at and auto_close_user_id are not changed, it should not schedule another CloseTopic job' do
        Timecop.freeze(Time.zone.now) do
          Jobs.expects(:enqueue_at).with(1.day.from_now, :close_topic, has_key(:topic_id)).once.returns(true)
          Jobs.expects(:cancel_scheduled_job).never
          topic = Fabricate(:topic, auto_close_at: 1.day.from_now)
          topic.title = 'A new title that is long enough'
          topic.save.should be_true
        end
      end

      it "ignores the category's default auto-close" do
        Timecop.freeze(Time.zone.now) do
          topic = Fabricate(:topic, category: Fabricate(:category, auto_close_days: 14))
          Jobs.expects(:enqueue_at).with(12.hours.from_now, :close_topic, has_entries(topic_id: topic.id, user_id: topic.user_id))
          topic.auto_close_at = 12.hours.from_now
          topic.save.should be_true
        end
      end
    end
  end

  describe '#secure_category?' do
    let(:category){ Category.new }

    it "is true if the category is secure" do
      category.stubs(:secure).returns(true)
      Topic.new(:category => category).should be_secure_category
    end

    it "is false if the category is not secure" do
      category.stubs(:secure).returns(false)
      Topic.new(:category => category).should_not be_secure_category
    end

    it "is false if there is no category" do
      Topic.new(:category => nil).should_not be_secure_category
    end
  end
end
