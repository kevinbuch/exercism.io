class Submission < ActiveRecord::Base

  serialize :liked_by, Array

  belongs_to :user
  belongs_to :exercise

  has_many :comments, order: 'at ASC'

  has_many :submission_viewers
  has_many :viewers, through: :submission_viewers

  has_many :muted_submissions
  has_many :muted_by, through: :muted_submissions, source: :user

  validates :user, presence: true
  validates :exercise, presence: true

  before_create do
    self.state          ||= "pending"
    self.at             ||= Time.now.utc
    self.nit_count      ||= 0
    self.wants_opinions ||= false
    self.is_liked       ||= false

    # Experiment: Cache the iteration number so that we can display it
    # on the dashboard without pulling down all the related versions
    # of the submission.
    # Preliminary testing in development suggests an 80% improvement.
    self.version = Submission.related(self).count + 1

    true
  end

  def self.pending_for(language, exercise=nil)
    raise "FIXME"
    if exercise
      pending.
        and(language: language.downcase).
        and(slug: exercise.downcase)
    else
      pending.
        and(language: language.downcase)
    end
  end

  def self.completed_for(language, slug)
    raise "FIXME"
    done.where(language: language, slug: slug)
  end

  def self.related(submission)
    where(user_id: submission.user.id, 
          exercise_id: submission.exercise.id).
      order('at ASC')
  end

  def self.nitless
    raise "FIXME"
    pending.where(:'nits._id'.exists => false)
  end

  def self.pending
    where(state: 'pending').order(at: :desc)
  end

  def self.done
    where(state: 'done').order(at: :desc)
  end

  def self.on(exercise)
    create(exercise: exercise)
  end

  def self.assignment_completed?(submission)
    related(submission).done.any?
  end

  def self.unmuted_for(username)
    where("muted_by != ?", username)
  end

  def participants
    @participants ||= DeterminesParticipants.determine(user, related_submissions)
  end

  def nits_by_others_count
    nit_count
  end

  def nits_by_others
    comments.select {|nit| nit.user != self.user }
  end

  def nits_by_self_count
    comments.select {|nit| nit.user == self.user }.count
  end

  def discussion_involves_user?
    [nits_by_self_count, nits_by_others_count].min > 0
  end

  def versions_count
    @versions_count ||= Submission.related(self).count
  end

  def related_submissions
    @related_submissions ||= Submission.related(self).to_a
  end

  def no_version_has_nits?
    @no_previous_nits ||= related_submissions.find_index { |v| v.nits_by_others_count > 0 }.nil?
  end

  def some_version_has_nits?
    !no_version_has_nits?
  end

  def this_version_has_nits?
    nits_by_others_count > 0
  end

  def no_nits_yet?
    !this_version_has_nits?
  end

  def older_than?(time)
    self.at.utc < (Time.now.utc - time)
  end

  def assignment
    @assignment ||= trail.assign(slug)
  end

=begin
  def on(exercise)
    self.exercise = Exercise.for(language, slug)
  end
=end

  def supersede!
    if pending? || hibernating? || tweaked?
      self.state = 'superseded'
    end
    self.delete if stashed?
    save
  end

  def submitted?
    true
  end

  def like!(user)
    self.is_liked = true
    liked_by << user.username
    mute(user)
    save
  end

  def unlike!(user)
    liked_by.delete(user.username)
    self.is_liked = liked_by.length > 0
    unmute(user)
    save
  end

  def liked?
    is_liked
  end

  def done?
    state == 'done'
  end

  def pending?
    state == 'pending'
  end

  def stashed?
    state == 'stashed'
  end

  def hibernating?
    state == 'hibernating'
  end

  def tweaked?
    state == 'tweaked'
  end

  def superseded?
    state == 'superseded'
  end

  def wants_opinions?
    wants_opinions
  end

  def enable_opinions!
    self.wants_opinions = true
    self.save
  end

  def disable_opinions!
    self.wants_opinions = false
    self.save
  end

  def muted_by?(user)
    muted_submissions.where(user_id: user.id).exists?
  end

  def mute(user)
    muted_by << user
  end

  def mute!(user)
    mute(user)
    save
  end

  def unmute(user)
    muted_submissions.where(user_id: user.id).destroy_all
  end

  def unmute!(user)
    unmute(user)
    save
  end

  def unmute_all!
    muted_by.clear
    save
  end

  def viewed!(user)
    self.viewers << user unless viewers.include?(user)
  end

  def view_count
    @view_count ||= viewers.count
  end

  private


  def trail
    Exercism.current_curriculum.trails[exercise.language]
  end

  class DeterminesParticipants

    attr_reader :participants

    def self.determine(user, submissions)
      determiner = new(user, submissions)
      determiner.determine
      determiner.participants
    end

    def initialize(user, submissions)
      @user = user
      @submissions = submissions
    end

    def determine
      @participants = Set.new
      @participants.add @user
      @submissions.each do |submission|
        add_submission(submission)
      end
    end

    private

    def add_submission(submission)
      submission.comments.each do |comment|
        add_comment(comment)
      end
    end

    def add_comment(comment)
      @participants.add comment.nitpicker
      comment.mentions.each do |mention| 
        @participants.add mention
      end
    end
  end
end
