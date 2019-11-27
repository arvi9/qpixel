# Web controller. Provides actions that relate to answers. Pretty much the standard set of resources, really - it's
# questions that have a few more actions.
class AnswersController < ApplicationController
  before_action :authenticate_user!, only: [:new, :create, :edit, :update, :destroy, :undelete]
  before_action :set_answer, only: [:edit, :update, :destroy, :undelete]
  @@markdown_renderer = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(), extensions = {})

  def new
    @answer = Answer.new
    @question = Question.find params[:id]
  end

  def self.renderer
    @@markdown_renderer
  end

  def create
    @question = Question.find params[:id]
    @answer = Answer.new answer_params.merge(parent: @question, user: current_user, score: 0,
                                             body: renderer.render(params[:answer][:body], scrubber: AnswerScrubber.new),
                                             body_markdown: params[:answer][:body])
    @question.user.create_notification("New answer to your question '#{@question.title.truncate(50)}'", "/questions/#{@question.id}")
    if @answer.save
      redirect_to url_for(controller: :questions, action: :show, id: params[:id])
    else
      render :new, status: 422
    end
  end

  def edit
    check_your_privilege('Edit', @answer)
  end

  def update
    return unless check_your_privilege('Edit', @answer)
    PostHistory.post_edited(@answer, current_user)
    if @answer.update answer_params.merge(body: renderer.render(params[:answer][:body], scrubber: AnswerScrubber.new),
                                          body_markdown: params[:answer][:body])
      redirect_to url_for(controller: :questions, action: :show, id: @answer.parent.id)
    else
      render :edit
    end
  end

  def destroy
    return unless check_your_privilege('Delete', @answer)
    PostHistory.post_deleted(@answer, current_user)
    unless @answer.update(deleted: true, deleted_at: DateTime.now)
      flash[:error] = "The answer could not be deleted."
    end
    redirect_to url_for(controller: :questions, action: :show, id: @answer.parent.id)
  end

  def undelete
    return unless check_your_privilege('Delete', @answer)
    PostHistory.post_undeleted(@answer, current_user)
    unless @answer.update(deleted: false, deleted_at: nil)
      flash[:error] = "The answer could not be undeleted."
    end
    redirect_to url_for(controller: :questions, action: :show, id: @answer.parent.id)
  end

  private

  def answer_params
    params.require(:answer).permit(:body)
  end

  def set_answer
    @answer = Answer.find params[:id]
  end
end

# Provides a custom HTML sanitization interface to use for cleaning up the HTML in answers.
class AnswerScrubber < Rails::Html::PermitScrubber
  def initialize
    super
    self.tags = %w( a p b i em strong hr h1 h2 h3 h4 h5 h6 blockquote img strike del code pre br ul ol li )
    self.attributes = %w( href title src height width )
  end

  def skip_node?(node)
    node.text?
  end
end
