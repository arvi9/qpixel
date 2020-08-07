# Web controller. Provides authenticated actions for use by administrators.
class AdminController < ApplicationController
  before_action :verify_admin
  before_action :verify_global_admin, only: [:admin_email, :send_admin_email, :new_site, :create_site, :setup]

  def index; end

  def error_reports
    @reports = if params[:uuid].present?
                 ErrorLog.where(uuid: params[:uuid])
               elsif current_user.is_global_admin
                 ErrorLog.all
               else
                 ErrorLog.where(community: RequestContext.community)
               end.order(created_at: :desc).paginate(page: params[:page], per_page: 50)
  end

  def privileges
    @privileges = Privilege.all.user_sort({ term: params[:sort], default: :threshold },
                                          rep: :threshold, name: :name)
                           .paginate(page: params[:page], per_page: 20)
  end

  def show_privilege
    @privilege = Privilege.find_by name: params[:name]
    respond_to do |format|
      format.json { render json: @privilege }
    end
  end

  def update_privilege
    @privilege = Privilege.find_by name: params[:name]
    pre = @privilege.threshold
    @privilege.update(threshold: params[:threshold]) &&
      AuditLog.admin_audit(event_type: 'privilege_threshold_update', related: @privilege, user: current_user,
                           comment: "from <<#{pre}>>\nto <<#{params[:threshold]}>>")
    render json: { status: 'OK', privilege: @privilege }, status: 202
  end

  def admin_email; end

  def send_admin_email
    Thread.new do
      AdminMailer.with(body_markdown: params[:body_markdown], subject: params[:subject]).to_moderators.deliver_now
    end
    AuditLog.admin_audit(event_type: 'send_admin_email', user: current_user,
                         comment: "Subject: #{params[:subject]}")
    flash[:success] = 'Your email is being sent.'
    redirect_to admin_path
  end

  def audit_log
    @logs = AuditLog.where.not(log_type: ['user_annotation', 'user_history'])
                    .user_sort({ term: params[:sort], default: :created_at },
                               age: :created_at, type: :log_type, event: :event_type,
                               related: Arel.sql('related_type DESC, related_id DESC'), user: :user_id)
                    .paginate(page: params[:page], per_page: 100)
    render layout: 'without_sidebar'
  end

  def new_site
    @new_community = Community.new
  end

  def create_site
    @new_community = Community.create(name: params[:community][:name], host: params[:community][:host])

    # Run Seeds
    Rails.application.load_seed

    # Manage Site Settings
    settings = SiteSetting.for_community_id(@new_community.id)
    settings.find_by(name: 'SiteName').update(value: @new_community.name)

    # Audit Log
    AuditLog.admin_audit(event_type: 'new_site', related: @new_community, user: current_user,
                         comment: "<<Community #{@new_community.attributes_print}>>")

    # Clear cache
    Rails.cache.clear

    # Render template
    render
  end

  def setup; end

  def setup_save
    settings = SiteSetting.for_community_id(@community.id)
    default_settings = SiteSetting.for_community_id(Community.first.id)

    # Set settings from config page
    settings.find_by(name: 'SiteCategoryHeaderDefaultColor').update(value: params[:primary_color])
    settings.find_by(name: 'SiteLogoPath').update(value: params[:logo_url])
    settings.find_by(name: 'SiteAdSlogan').update(value: params[:ad_slogan])
    settings.find_by(name: 'MathJaxEnabled').update(value: params[:mathjax])
    settings.find_by(name: 'SyntaxHighlightingEnabled').update(value: params[:syntax_highlighting])
    settings.find_by(name: 'ChatLink').update(value: params[:chat_link])
    settings.find_by(name: 'AnalyticsURL').update(value: params[:analytics_url])
    settings.find_by(name: 'AnalyticsSiteId').update(value: params[:analytics_id])
    settings.find_by(name: 'AllowContentTransfer').update(value: params[:content_transfer])

    # Auto-load settings
    settings.find_by(name: 'AdminBadgeCharacter')
            .update(value: default_settings.find_by(name: 'AdminBadgeCharacter').value)
    settings.find_by(name: 'ModBadgeCharacter')
            .update(value: default_settings.find_by(name: 'ModBadgeCharacter').value)
    settings.find_by(name: 'SEApiClientId')
            .update(value: default_settings.find_by(name: 'SEApiClientId').value)
    settings.find_by(name: 'SEApiClientSecret')
            .update(value: default_settings.find_by(name: 'SEApiClientSecret').value)
    settings.find_by(name: 'SEApiKey')
            .update(value: default_settings.find_by(name: 'SEApiKey').value)
    settings.find_by(name: 'AdministratorContactEmail')
            .update(value: default_settings.find_by(name: 'AdministratorContactEmail').value)

    # Generate meta tags
    tags = [
      'discussion', 'support', 'feature-request', 'bug',
      'status-completed', 'status-declined', 'status-review', 'status-planned', 'status-deferred'
    ]
    Tag.create(tags.map { |t| { name: t, community_id: @community.id, tag_set: TagSet.meta } })

    # Set Meta tags as required/mod-only
    meta_category = Category.where(name: 'Meta').last
    meta_category.required_tags << Tag.where(name: ['discussion', 'support', 'feature-request', 'bug'])
    meta_category.moderator_tags << Tag.where(name: ['status-completed', 'status-declined', 'status-review',
                                                     'status-planned', 'status-deferred'])

    # Clear cache
    Rails.cache.clear

    # Audit Log
    AuditLog.admin_audit(event_type: 'setup_site', related: @new_community, user: current_user,
                         comment: 'Site Settings updated via /admin/setup')

    render
  end
end
