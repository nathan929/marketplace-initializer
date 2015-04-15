require 'will_paginate/array'

class ApplicationController < ActionController::Base
  module DefaultURLOptions
    # Adds locale to all links
    def default_url_options
      { :locale => I18n.locale }
    end
  end

  include ApplicationHelper
  include FeatureFlagHelper
  include DefaultURLOptions
  protect_from_forgery
  layout 'application'

  before_filter :force_ssl,
    :check_auth_token,
    :fetch_logged_in_user,
    :fetch_community,
    :redirect_to_marketplace_domain,
    :fetch_community_membership,
    :set_locale,
    :generate_event_id,
    :set_default_url_for_mailer,
    :fetch_chargebee_plan_data,
    :fetch_community_admin_status,
    :fetch_community_plan_expiration_status,
    :warn_about_missing_payment_info
  before_filter :cannot_access_without_joining, :except => [ :confirmation_pending, :check_email_availability]
  before_filter :can_access_only_organizations_communities
  before_filter :check_email_confirmation, :except => [ :confirmation_pending, :check_email_availability_and_validity]

  # This updates translation files from WTI on every page load. Only useful in translation test servers.
  before_filter :fetch_translations if APP_CONFIG.update_translations_on_every_page_load == "true"

  #this shuold be last
  before_filter :push_reported_analytics_event_to_js

  rescue_from RestClient::Unauthorized, :with => :session_unauthorized

  helper_method :root, :logged_in?, :current_user?

  def select_locale(user_locale, locale_param, community_locales, community_default_locale)

    # Use user locale, if community supports it
    user = Maybe(user_locale).select { |locale| community_locales.include?(locale) }.or_else(nil)

    # Use locale from URL param, if community supports it
    param = Maybe(locale_param).select { |locale| community_locales.include?(locale) }.or_else(nil)

    # Use community detauls locale
    community = community_default_locale

    user || param || community
  end

  def set_locale
    user_locale = Maybe(@current_user).locale.or_else(nil)

    # We should fix this -- START
    #
    # There are a couple of controllers (amazon ses bounces, braintree webhooks) that
    # inherit application controller, even though they shouldn't. ApplicationController
    # has a lot of community specific filters and those controllers do not have community.
    # Thus, we need to add this kind of additional logic to make sure whether we have
    # community or not
    #
    m_community = Maybe(@current_community)
    community_locales = m_community.locales.or_else([])
    community_default_locale = m_community.default_locale.or_else("en")
    community_id = m_community[:id].or_else(nil)
    community_backend = I18n::Backend::CommunityBackend.instance

    # Load translations from TranslationService
    if community_id
      community_backend.set_community!(community_id)
      community_translations = TranslationService::API::Api.translations.get(community_id)[:data]
      TranslationServiceHelper.community_translations_for_i18n_backend(community_translations).each { |locale, data|
        # Store community translations to I18n backend.
        #
        # Since the data in data hash is already flatten, we don't want to
        # escape the separators (. dots) in the key
        community_backend.store_translations(locale, data, escape: false)
      }
    end

    # We should fix this -- END

    locale = select_locale(user_locale, params[:locale], community_locales, community_default_locale)

    raise ArgumentError.new("Locale #{locale} not available. Check your community settings") unless available_locales.collect { |l| l[1] }.include?(locale)

    I18n.locale = locale

    # Store to thread the service_name used by current community, so that it can be included in all translations
    ApplicationHelper.store_community_service_name_to_thread(service_name)

    # A hack to get the path where the user is
    # redirected after the locale is changed
    new_path = request.fullpath.clone
    new_path.slice!("/#{params[:locale]}")
    new_path.slice!(0,1) if new_path =~ /^\//
    @return_to = new_path

    Maybe(@current_community).each { |community|
      @community_customization = community.community_customizations.where(locale: locale).first
    }
  end

  #Creates a URL for root path (i18n breaks root_path helper)
  def root
    "#{request.protocol}#{request.host_with_port}/#{params[:locale]}"
  end

  def fetch_logged_in_user
    if person_signed_in?
      @current_user = current_person
    end
  end

  # A before filter for views that only users that are logged in can access
  def ensure_logged_in(warning_message)
    return if logged_in?
    session[:return_to] = request.fullpath
    flash[:warning] = warning_message
    redirect_to login_path and return
  end

  # A before filter for views that only authorized users can access
  def ensure_authorized(error_message)
    if logged_in?
      @person = Person.find(params[:person_id] || params[:id])
      return if current_user?(@person)
    end

    # This is reached only if not authorized
    flash[:error] = error_message
    redirect_to root and return
  end

  def logged_in?
    @current_user.present?
  end

  def current_user?(person)
    @current_user && @current_user.id.eql?(person.id)
  end

  # Saves current path so that the user can be
  # redirected back to that path when needed.
  def save_current_path
    session[:return_to_content] = request.fullpath
  end

  # Before filter to get the current community
  def fetch_community_by_strategy(&block)
    # Pick the community according to the given strategy
    @current_community = block.call

    unless @current_community
      # No community found with the strategy, so redirecting to redirect url, or error page.
      redirect_to Maybe(APP_CONFIG).community_not_found_redirect.or_else {
        no_communities = Community.count == 0

        if no_communities
          new_community_path
        else
          :community_not_found
        end
      }
    end
  end

  # Before filter to get the current community
  def fetch_community
    # store the host of the current request (as sometimes needed in views)
    @current_host_with_port = request.host_with_port

    fetch_community_by_strategy {
      ApplicationController.default_community_fetch_strategy(request.host)
    }
  end

  def redirect_to_marketplace_domain
    return unless @current_community

    host = request.host
    domain = @current_community.domain

    if needs_redirect?(host, domain)
      redirect_to "#{request.protocol}#{domain}#{request.fullpath}", status: :moved_permanently
    end
  end

  def needs_redirect?(host, domain)
    domain.present? && host != domain
  end

  # Fetch community
  #
  # 1. Try to find by domain
  # 2. If there is only one community, use it
  # 3. Otherwise nil
  #
  def self.default_community_fetch_strategy(domain)
    # Find by domain
    by_domain = Community.find_by_domain(domain)

    if by_domain.present?
      return by_domain
    end

    # Find by username
    app_domain = URLUtils.strip_port_from_host(APP_CONFIG.domain)
    ident = domain.chomp(".#{app_domain}")
    by_ident = Community.where(ident: ident).first

    if by_ident.present?
      return by_ident
    end

    # If only one, use it
    count = Community.count

    if count == 1
      return Community.first
    end

    # Not found, return nil
    nil
  end

  # Before filter to check if current user is the member of this community
  # and if so, find the membership
  def fetch_community_membership
    if @current_user
      if @current_user.communities.include?(@current_community)
        @current_community_membership = CommunityMembership.find_by_person_id_and_community_id_and_status(@current_user.id, @current_community.id, "accepted")
        unless @current_community_membership.last_page_load_date && @current_community_membership.last_page_load_date.to_date.eql?(Date.today)
          Delayed::Job.enqueue(PageLoadedJob.new(@current_community_membership.id, request.host))
        end
      end
    end
  end

  # Before filter to direct a logged-in non-member to join tribe form
  def cannot_access_without_joining
    if @current_user && ! (@current_community_membership || @current_user.is_admin?)

      # Check if banned
      if @current_community && @current_user && @current_user.banned_at?(@current_community)
        flash.keep
        redirect_to access_denied_tribe_memberships_path and return
      end

      session[:invitation_code] = params[:code] if params[:code]
      flash.keep
      redirect_to new_tribe_membership_path
    end
  end

  def can_access_only_organizations_communities
    if (@current_community && @current_community.only_organizations) &&
      (@current_user && !@current_user.is_organization)

      sign_out @current_user
      flash[:warning] = t("layouts.notifications.can_not_login_with_private_user")
      redirect_to login_path
    end
  end

  def check_email_confirmation
    # If confirmation is required, but not done, redirect to confirmation pending announcement page
    # (but allow confirmation to come through)
    if @current_community && @current_user && @current_user.pending_email_confirmation_to_join?(@current_community)
      flash[:warning] = t("layouts.notifications.you_need_to_confirm_your_account_first")
      redirect_to :controller => "sessions", :action => "confirmation_pending" unless params[:controller] == 'devise/confirmations'
    end
  end

  def set_default_url_for_mailer
    url = @current_community ? "#{@current_community.full_domain}" : "www.#{APP_CONFIG.domain}"
    ActionMailer::Base.default_url_options = {:host => url}
    if APP_CONFIG.always_use_ssl
      ActionMailer::Base.default_url_options[:protocol] = "https"
    end
  end

  def fetch_community_admin_status
    @is_current_community_admin = @current_user && @current_user.has_admin_rights_in?(@current_community)
  end

  def fetch_community_plan_expiration_status
    @is_community_plan_expired = MarketplaceService::Community::Query.is_plan_expired(@current_community)
  end

  def fetch_chargebee_plan_data
    @pro_biannual_link = APP_CONFIG.chargebee_pro_biannual_link
    @pro_biannual_price = APP_CONFIG.chargebee_pro_biannual_price
    @pro_monthly_link = APP_CONFIG.chargebee_pro_monthly_link
    @pro_monthly_price = APP_CONFIG.chargebee_pro_monthly_price
  end

  # Before filter for PayPal, shows notification if user is not ready for payments
  def warn_about_missing_payment_info
    if @current_user && PaypalHelper.open_listings_with_missing_payment_info?(@current_user.id, @current_community.id)
      settings_link = view_context.link_to(t("paypal_accounts.from_your_payment_settings_link_text"), payment_settings_path(:paypal, @current_user))
      warning = t("paypal_accounts.missing", settings_link: settings_link)
      flash.now[:warning] = warning.html_safe
    end
  end

  private

  def session_unauthorized
    # For some reason, ASI session is no longer valid => log the user out
    clear_user_session
    flash[:error] = t("layouts.notifications.error_with_session")
    ApplicationHelper.send_error_notification("ASI session was unauthorized. This may be normal, if session just expired, but if this occurs frequently something is wrong.", "ASI session error", params)
    redirect_to root_path and return
  end

  def clear_user_session
    @current_user = session[:person_id] = nil
  end

  # this generates the event_id that will be used in
  # requests to cos during this Sharetribe-page view only
  def generate_event_id
    RestHelper.event_id = "#{EventIdHelper.generate_event_id(params)}_#{Time.now.to_f}"
    # The event id is generated here and stored for the duration of this request.
    # The option above stores it to thread which should work fine on mongrel
  end

  def ensure_is_admin
    unless @is_current_community_admin
      flash[:error] = t("layouts.notifications.only_kassi_administrators_can_access_this_area")
      redirect_to root and return
    end
  end

  def ensure_is_superadmin
    unless Maybe(@current_user).is_admin?.or_else(false)
      flash[:error] = t("layouts.notifications.only_kassi_administrators_can_access_this_area")
      redirect_to root and return
    end
  end

  # Does a push to Google Analytics on next page load
  # the reason to go via session is that the actions that cause events
  # often do a redirect.
  # This is still not fool proof as multiple redirects would lose
  def report_analytics_event(params_array)
    session[:analytics_event] = params_array
  end

  # if session has analytics event
  # report that and clean session
  def push_reported_analytics_event_to_js
    if session[:analytics_event]
      @analytics_event = session[:analytics_event]
      session.delete(:analytics_event)
    end
  end

  def fetch_translations
    WebTranslateIt.fetch_translations
  end

  def check_auth_token
    user_to_log_in = UserService::API::AuthTokens::use_token_for_login(params[:auth])
    person = Person.find(user_to_log_in[:id]) if user_to_log_in

    if person
      sign_in(person)
      @current_user = person

      # Clean the URL from the used token
      path_without_auth_token = URLUtils.remove_query_param(request.fullpath, "auth")
      redirect_to path_without_auth_token
    end

  end

  def force_ssl
    # If defined in the config, always redirect to https (unless already using https or coming through Sharetribe proxy)
    if APP_CONFIG.always_use_ssl
      redirect_to("https://#{request.host_with_port}#{request.fullpath}") unless request.ssl? || ( request.headers["HTTP_VIA"] && request.headers["HTTP_VIA"].include?("sharetribe_proxy")) || request.fullpath == "/robots.txt"
    end
  end

  def feature_flags
    @feature_flags ||= FeatureFlagService::API::Api.features.get(community_id: @current_community.id).maybe[:features].or_else(Set.new)
  end
end
