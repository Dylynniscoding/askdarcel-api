# frozen_string_literal: true

class ServicesController < ApplicationController
  # wrap_parameters is not useful for nested JSON requests because it does not
  # wrap nested resources. It is unclear if the Rails team considers this to be
  # a bug or a feature: https://github.com/rails/rails/issues/17216
  # wrap_parameters is in fact harmful here because the strong params permit
  # method will reject the wrapped parameter if you don't use it.

  wrap_parameters false

  before_action :read_site_id_string, only: [:index]

  def index
    # use SFSG as default site
    matching_services = find_services(
      params[:category_id],
      params[:eligibility_id],
      @site_id_string
    )

    render json: ServicesWithResourceLitePresenter.present(matching_services)
  end

  def read_site_id_string
    @site_id_string = params[:site_id] || Site.find_by(site_code: 'sfsg').id.to_s
  end

  def find_services(category_id, eligibility_id, site_id)
    # TODO: be able to parse both categories and eligibilities at once
    if category_id
      find_by_category(category_id, site_id)
    elsif eligibility_id
      find_by_eligibility(eligibility_id, site_id)
    else
      find_all(site_id)
    end
  end

  # Include services if they:
  # - are part of a resource matching the requested site
  # - have any of the requested tags
  # Sort by relevancy (i.e. number of matching tags).
  def find_by_category(category_id_string, site_id)
    find_by_tag("categories_services", "category_id", category_id_string, site_id)
  end

  def find_by_eligibility(eligibility_id_string, site_id)
    find_by_tag("eligibilities_services", "eligibility_id", eligibility_id_string, site_id)
  end

  def show
    service = services.find(params[:id])
    render json: ServicesWithResourcePresenter.present(service)
  end

  def translate_params
    {
      contents: [params[:html]],
      target_language_code: params[:target_language],
      parent: "projects/#{Rails.configuration.x.google.project_id}"
    }
  end

  def translate_html
    require "google/cloud/translate/v3"

    client = ::Google::Cloud::Translate::V3::TranslationService::Client.new
    request = ::Google::Cloud::Translate::V3::TranslateTextRequest.new(translate_params)
    response = client.translate_text request
    response.translations[0].translated_text
  rescue Google::Cloud::ResourceExhaustedError
    error = StandardError.new "We're sorry, we've hit our PDF translation limit for the day. Please try again tomorrow. Contact \
support with any questions."
    raise error
  end

  def html_input
    html = params[:html]
    languages = %w[en es tl zh-TW vi ar ru]

    if languages.include? params[:target_language]
      unless Rails.configuration.x.google.translate_credentials
        raise "PDF translation service is not enabled right now. Please contact support or try again later."
      end

      html = translate_html
    end

    html
  end

  def html_to_pdf
    unless Rails.configuration.x.pdfcrowd.enabled
      raise "Dynamic PDF generation is not enabled right now. Please contact support or try again later."
    end

    send_data PdfCrowdClient.client.convertString(html_input),
              { type: "application/pdf",
                disposition: "attachment; filename*=UTF-8''#{ERB::Util.url_encode('translation.pdf')} }" }
  rescue StandardError => e
    Raven.capture_exception(e)
    render plain: e.to_s, status: 500
  end

  def featured
    category_id = params[:category_id]
    featured_services = services.includes(
      resource: [
        :addresses, :phones, :categories, :notes,
        { schedule: :schedule_days,
          services: [:notes, :categories, :addresses, :eligibilities, { schedule: :schedule_days }] }
      ]
    ).where(featured_by_category_join_string, category_id)

    render json: ServicesWithResourcePresenter.present(featured_services)
  end

  def create
    services_params = clean_services_params
    services = services_params.map { |s| Service.new(s) }
    services.each { |s| s.status = :approved }
    if services.any?(&:invalid?)
      render status: :bad_request, json: { services: services.select(&:invalid?).map(&:errors) }
    else
      Service.transaction { services.each(&:save!) }
      render status: :created, json: { services: services.map { |s| ServicesPresenter.present(s) } }
    end
  end

  def certify
    service = Service.find params[:service_id]
    service.certified = true
    service.certified_at = Time.now
    service.save!
    render status: :ok
  end

  def pending
    pending_services = services.includes(
      resource: [
        :addresses, :phones, :categories, :notes,
        { schedule: :schedule_days,
          services: [:notes, :categories, :addresses, :eligibilities, { schedule: :schedule_days }] }
      ]
    ).pending
    render json: ServicesWithResourcePresenter.present(pending_services)
  end

  def approve
    service = Service.find params[:service_id]
    if service.pending?
      service.approved!
      render status: :ok
    elsif service.approved?
      render status: :not_modified
    else
      render status: :precondition_failed
    end
  end

  def reject
    service = Service.find params[:service_id]
    if service.pending?
      service.rejected!
      render status: :ok
    elsif service.rejected?
      render status: :not_modified
    else
      render status: :precondition_failed
    end
  end

  def destroy
    service = Service.find params[:id]
    if service.approved?
      service.inactive!
      remove_from_algolia(service)
      render status: :ok
    else
      render status: :precondition_failed
    end
  end

  def count
    render json: Service.all.count
  end

  def site_code
    params[:site_id] ? Site.find_by(id: params[:site_id]).site_code : "sfsg"
  end

  def eligibility_names
    eligibilities = params[:eligibility_id].split(",")
    Eligibility.where(id: eligibilities).map(&:name)
  end

  def category_names
    categories = params[:category_id].split(",")
    Category.where(id: categories).map(&:name)
  end

  def tag_conjunction
    params[:match_all_tags].nil? ? " OR " : " AND "
  end

  def eligibilities_filter
    params[:eligibility_id] ? eligibility_names.map { |name| "eligibilities:'#{name}'<score=1>" }.join(tag_conjunction) : ""
  end

  def categories_filter
    params[:category_id] ? category_names.map { |name| "categories:'#{name}'<score=1>" }.join(tag_conjunction) : ""
  end

  def filter_string
    sites_service_string = format("associated_sites:'%<site_code>s' AND type: 'service'", site_code: site_code)
    eligibility_string = eligibilities_filter.empty? ? "" : " AND (#{eligibilities_filter})"
    category_string = categories_filter.empty? ? "" : " AND (#{categories_filter})"
    sites_service_string + eligibility_string + category_string
  end

  def free_text_query
    params[:text] ? CGI.unescape(params[:text]) : ""
  end

  def algolia_query_geoloc
    Service.index.search(
      free_text_query,
      filters: filter_string,
      sumOrFiltersScores: true,
      aroundLatLng: format("%<lat>s, %<long>s", lat: params[:lat], long: params[:long]),
      hitsPerPage: 1000
    )
  end

  def algolia_query
    Service.index.search(
      free_text_query,
      filters: filter_string,
      sumOrFiltersScores: true,
      hitsPerPage: 1000
    )
  end

  def algolia_search
    params[:lat] && params[:long] ? algolia_query_geoloc : algolia_query
  end

  # Use algolia search to get results.
  def search
    ordered_service_ids = algolia_search['hits'].map { |x| x['id'] }
    # in the event where the Algolia index is out of sync with Rails,
    # find the ids that exist first with `Service.where(id: query_ids).ids`,
    # (`Service.find` will raise a RecordNotFound error otherwise)
    existing_ids = Service.where(id: ordered_service_ids).ids
    # we need to preserve the Algolia order of these ids, which `Service.where(id: X)` does not guarantee
    matching_services = ordered_service_ids.select { |id| existing_ids.include?(id) }.map { |id| Service.find(id) }
    render json: { services: ServicesWithResourceLitePresenter.present(matching_services) }
  end

  private

  def remove_from_algolia(service)
    service.remove_from_index!
  rescue StandardError
    Rails.logger.error "failed to remove service #{service.id} from algolia index"
  end

  def services
    Service.includes(:notes, :categories, :eligibilities, :addresses, :documents, schedule: :schedule_days)
  end

  # Clean raw request params for interoperability with Rails APIs.
  def clean_services_params
    services_params = params.require(:services).map { |s| permit_service_params(s) }
    resource_id = params.require(:resource_id)
    services_params.each { |s| transform_service_params!(s, resource_id) }
  end

  # Filter out all the attributes that are unsafe for users to set, including
  # all :id keys besides category ids and Service's :status.
  def permit_service_params(service_params) # rubocop:disable Metrics/MethodLength
    service_params.permit(
      :alternate_name,
      :application_process,
      :eligibility,
      :email,
      :fee,
      :interpretation_services,
      :long_description,
      :name,
      :required_documents,
      :url,
      :wait_time,
      schedule: [{ schedule_days: %i[day opens_at closes_at open_time open_day close_time close_day] }],
      notes: [:note],
      categories: [:id],
      addresses: %i[id address_1 city state_province postal_code],
      eligibilities: [:id]
    )
  end

  # Transform parameters for creating a single service in-place.
  #
  # Rails doesn't accept the same format for nested parameters when creating
  # models as the format we output when serializing to JSON. In particular, the
  # Model#new method expects the key for nested resources to have a suffix of
  # "_attributes"; e.g. "notes_attributes", not "notes".
  #
  # This method transforms all keys representing nested resources into
  # #{key}_attribute.
  def transform_service_params!(service, resource_id)
    if service.key? :schedule
      schedule = service[:schedule_attributes] = service.delete(:schedule)
      schedule[:schedule_days_attributes] = schedule.delete(:schedule_days) if schedule.key? :schedule_days
    end

    transform_nested_objects(service, resource_id)
    # Unlike other nested resources, don't create new categories; associate
    # with the existing ones.
    service['category_ids'] = service.delete(:categories).collect { |h| h[:id] } if service.key? :categories
    service['eligibility_ids'] = service.delete(:eligibilities).collect { |h| h[:id] } if service.key? :eligibilities
  end

  def transform_nested_objects(service, resource_id)
    service[:addresses_attributes] = service.delete(:addresses) if service.key? :addresses
    service[:notes_attributes] = service.delete(:notes) if service.key? :notes
    service[:resource_id] = resource_id
  end

  def resource
    @resource ||= Resource.find params[:resource_id] if params[:resource_id]
  end

  def featured_by_category_join_string
    <<~'SQL'
      services.id IN (
        (
          SELECT services.id
            FROM services
            INNER JOIN categories_services ON services.id = categories_services.service_id
            WHERE categories_services.category_id = ?
            AND categories_services.feature_rank > 0
            ORDER BY categories_services.feature_rank
        )
      )
    SQL
  end

  def find_services_eager_load_resources
    services
      .includes(
        resource: [
          :addresses, :phones, :categories, :notes,
          { schedule: :schedule_days }
        ]
      )
  end

  def find_tag_count_per_service(tag_table_name, tag_id_name, user_input_tag_ids, user_input_site_id)
    # Subquery to get service id + count of matching queried tags on that service
    # - injects tag and site query, sanitizes user SQL input (.where)
    # - filters out (.where) rows that don't match our tags or site to get an accurate count
    # - aggregates by service id (.group)
    # - note that we assume there are no tag-service row dups
    services.select("services.id AS service_id, COUNT(#{tag_table_name}.#{tag_id_name}) AS n_tags")
            .joins("INNER JOIN #{tag_table_name} ON services.id = #{tag_table_name}.service_id")
            .joins("INNER JOIN resources_sites ON services.resource_id = resources_sites.resource_id")
            .where(
              "#{tag_table_name}.#{tag_id_name} in (?) AND resources_sites.site_id = (?)",
              (user_input_tag_ids.split ","),
              user_input_site_id
            )
            .group("services.id")
  end

  def find_by_tag(tag_table_name, tag_id_name, user_input_tag_ids, user_input_site_id)
    # Main query:
    # eager load resource fields to save view time
    # sort results, starting with the one(s) matching the most categories
    tag_counts_sanitized_sql = find_tag_count_per_service(
      tag_table_name,
      tag_id_name,
      user_input_tag_ids,
      user_input_site_id
    ).to_sql
    find_services_eager_load_resources
      .joins("INNER JOIN (#{tag_counts_sanitized_sql})"\
             " AS n_tags_per_service ON services.id = n_tags_per_service.service_id")
      .order("n_tags_per_service.n_tags DESC, services.name ASC")
  end

  def find_all(user_input_site_id)
    find_services_eager_load_resources
      .joins("INNER JOIN resources_sites ON services.resource_id = resources_sites.resource_id")
      .where(
        "resources_sites.site_id = (?)",
        user_input_site_id
      )
  end
end
