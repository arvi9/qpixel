# Web controller. Provides actions that relate to answers. Pretty much the standard set of resources, really - it's
# questions that have a few more actions.
class AnswersController < ApplicationController
  before_action :authenticate_user!, only: [:new, :create, :edit, :update, :destroy, :undelete, :convert_to_comment]
  before_action :set_answer, only: [:edit, :update, :destroy, :undelete, :convert_to_comment]
  before_action :verify_moderator, only: [:convert_to_comment]
  before_action :check_if_answer_locked, only: [:edit, :update, :destroy, :undelete, :convert_to_comment]

  def new
    @answer = Answer.new
    @question = Question.find params[:id]
  end

  def create
    @question = Question.find params[:id]

    @answer = Answer.new(answer_params.merge(parent: @question, user: current_user, score: 0,
                                             body: helpers.post_markdown(:answer, :body_markdown),
                                             last_activity: DateTime.now, last_activity_by: current_user,
                                             category: @question.category))

    recent_second_level_posts = Post.where(created_at: 24.hours.ago..Time.zone.now, user: current_user)
                                    .where(post_type_id: second_level_post_types).count

    max_slps = SiteSetting[if current_user.privilege?('unrestricted')
                             'RL_SecondLevelPosts'
                           else
                             'RL_NewUserSecondLevelPosts'
                           end]

    post_limit_msg = if current_user.privilege? 'unrestricted'
                       "You may only post #{max_slps} answers per day."
                     else
                       "You may only post #{max_slps} answers per day. " \
                       'Once you have some well-received posts, that limit will increase.'
                     end

    if recent_second_level_posts >= max_slps
      @answer.errors.add :base, post_limit_msg
      AuditLog.rate_limit_log(event_type: 'second_level_post', related: @question, user: current_user,
                              comment: "limit: #{max_slps}\n\npost:\n#{@answer.attributes_print}")
      render :new, status: :bad_request
      return
    end

    unless current_user.id == @question.user.id
      @question.user.create_notification("New answer to your question '#{@question.title.truncate(50)}'",
                                         share_question_url(@question))
    end
    if @answer.save
      @question.update(last_activity: DateTime.now, last_activity_by: current_user)
      unless current_user.id == @question.user.id
        @question.user.create_notification("New answer to your question '#{@question.title.truncate(50)}'",
                                           share_question_url(@question))
      end
      redirect_to url_for(controller: :questions, action: :show, id: params[:id])
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    can_post_in_category = @answer.parent.category.present? &&
                           (@answer.parent.category.min_trust_level || -1) <= current_user&.trust_level
    unless current_user&.has_post_privilege?('edit_posts', @answer) && can_post_in_category
      return update_as_suggested_edit
    end

    if params[:answer][:body_markdown] == @answer.body_markdown
      flash[:danger] = "No changes were saved because you didn't edit the post."
      return redirect_to question_path(@answer.parent)
    end

    before = @answer.body_markdown
    if @answer.update(answer_params.merge(body: helpers.post_markdown(:answer, :body_markdown),
                                          last_activity: DateTime.now, last_activity_by: current_user,
                                          last_edited_at: DateTime.now, last_edited_by: current_user,
                                          license_id: @answer.license_id))
      PostHistory.post_edited(@answer, current_user, before: before,
                              after: params[:answer][:body_markdown], comment: params[:edit_comment])
      redirect_to share_answer_path(qid: @answer.parent_id, id: @answer.id)
    else
      render :edit
    end
  end

  def update_as_suggested_edit
    return if check_edits_limit! @answer

    if params[:answer][:body_markdown] == @answer.body_markdown
      flash[:danger] = "No changes were saved because you didn't edit the post."
      return redirect_to question_path(@answer.parent)
    end

    updates = {
      post: @answer,
      user: current_user,
      community: @answer.community,
      body: helpers.post_markdown(:answer, :body_markdown),
      body_markdown: params[:answer][:body_markdown] == @answer.body_markdown ? nil : params[:answer][:body_markdown],
      comment: params[:edit_comment],
      active: true, accepted: false,
      decided_at: nil, decided_by: nil,
      rejected_comment: nil
    }

    @edit = SuggestedEdit.new(updates)
    if @edit.save
      @answer.user.create_notification("Edit suggested on your answer to #{@answer.parent.title.truncate(50)}",
                                       share_answer_url(qid: @answer.parent_id, id: @answer.id))
      redirect_to share_answer_path(qid: @answer.parent_id, id: @answer.id)
    else
      @answer.errors = @edit.errors
      render :edit
    end
  end

  def destroy
    unless check_your_privilege('flag_curate', @answer, false)
      flash[:danger] = helpers.ability_err_msg(:flag_curate, 'delete this answer')
      redirect_to(question_path(@answer.parent)) && return
    end

    if @answer.deleted
      flash[:danger] = "Can't delete a deleted answer."
      redirect_to(question_path(@answer.parent)) && return
    end

    if @answer.update(deleted: true, deleted_at: DateTime.now, deleted_by: current_user,
                      last_activity: DateTime.now, last_activity_by: current_user)
      PostHistory.post_deleted(@answer, current_user)
    else
      flash[:danger] = "Can't delete this answer right now. Try again later."
    end
    redirect_to question_path(@answer.parent)
  end

  def undelete
    unless check_your_privilege('flag_curate', @answer, false)
      flash[:danger] = flash[:danger] = helpers.ability_err_msg(:flag_curate, 'undelete this answer')
      redirect_to(question_path(@answer.parent)) && return
    end

    unless @answer.deleted
      flash[:danger] = "Can't undelete an undeleted answer."
      redirect_to(question_path(@answer.parent)) && return
    end

    if @answer.deleted_by.is_moderator && !current_user.is_moderator
      flash[:danger] = 'You cannot undelete this post deleted by a moderator.'
      redirect_to(question_path(@answer.parent)) && return
    end

    if @answer.update(deleted: false, deleted_at: nil, deleted_by: nil,
                      last_activity: DateTime.now, last_activity_by: current_user)
      PostHistory.post_undeleted(@answer, current_user)
    else
      flash[:danger] = "Can't undelete this answer right now. Try again later."
    end
    redirect_to question_path(@answer.parent)
  end

  def convert_to_comment
    text = @answer.body_markdown
    comments = helpers.split_words_max_length(text, 500)
    created = comments.map do |c|
      Comment.create(user: @answer.user, post_id: params[:post_id], community: @answer.community, content: c)
    end
    @answer.update(deleted: true, deleted_at: DateTime.now, deleted_by: current_user)
    AuditLog.moderator_audit(event_type: 'convert_to_comment', related: @answer, user: current_user,
                             comment: created.map(&:id).join(', '))
    render json: { success: true, comments: created.map(&:id) }
  end

  private

  def answer_params
    params.require(:answer).permit(:body_markdown, :license_id)
  end

  def set_answer
    @answer = Answer.find params[:id]
  end

  def check_if_answer_locked
    check_if_locked(@answer)
  end
end
