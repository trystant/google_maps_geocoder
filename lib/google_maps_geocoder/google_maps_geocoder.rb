require 'active_support'
require 'active_support/core_ext/string/inflections'
require 'logger'
require 'net/http'
require 'rack'
require 'curb'
# A simple PORO wrapper for geocoding with Google Maps.
#
# @example
#   chez_barack = GoogleMapsGeocoder.new '1600 Pennsylvania Ave'
#   chez_barack.formatted_address
#     => "1600 Pennsylvania Avenue Northwest, President's Park,
#         Washington, DC 20500, USA"
# rubocop:disable Metrics/ClassLength
# rubocop:disable Metrics/AbcSize
class GoogleMapsGeocoder
  # Error handling for google statuses
  class GeocodingError < StandardError
    # Initialize an error class wrapping the error returned by Google Maps.
    #
    # @return [GeocodingError] the geocoding error
    def initialize(response_json = '')
      @json = response_json
      super
    end

    # Returns the GeocodingError's content.
    #
    # @return [String] the geocoding error's content
    def message
      "Google returned:\n#{@json.inspect}"
    end
  end

  class ZeroResultsError < GeocodingError; end
  class QueryLimitError < GeocodingError; end
  class RequestDeniedError < GeocodingError; end
  class InvalidRequestError < GeocodingError; end
  class UnknownError < GeocodingError; end

  ERROR_STATUSES = { zero_results: 'ZERO_RESULTS',
                     query_limit: 'OVER_QUERY_LIMIT',
                     request_denied: 'REQUEST_DENIED',
                     invalid_request: 'INVALID_REQUEST',
                     unknown: 'UNKNOWN_ERROR' }.freeze

  GOOGLE_ADDRESS_SEGMENTS = %i[
    city
    country_long_name
    country_short_name
    county
    lat
    lng
    neighborhood
    bounds
    postal_code
    state_long_name
    state_short_name
  ].freeze
  GOOGLE_API_URI = 'https://maps.googleapis.com/maps/api/geocode/json'.freeze

  ALL_ADDRESS_SEGMENTS = (
    GOOGLE_ADDRESS_SEGMENTS + %i[
      formatted_address formatted_street_address
    ]
  ).freeze

  # Returns the complete formatted address with standardized abbreviations.
  #
  # @return [String] the complete formatted address
  # @example
  #   chez_barack.formatted_address
  #     => "1600 Pennsylvania Avenue Northwest, President's Park,
  #         Washington, DC 20500, USA"
  attr_reader :formatted_address

  # Returns the formatted street address with standardized abbreviations.
  #
  # @return [String] the formatted street address
  # @example
  #   chez_barack.formatted_street_address
  #     => "1600 Pennsylvania Avenue"
  attr_reader :formatted_street_address
  # Self-explanatory
  attr_reader(*GOOGLE_ADDRESS_SEGMENTS)

  def bulk_addresses
    @addresses
  end
  # Geocodes the specified address and wraps the results in a GoogleMapsGeocoder
  # object.
  #
  # @param data [String] a geocodable address
  # @return [GoogleMapsGeocoder] the Google Maps result for the specified
  #   address
  # @example
  #   chez_barack = GoogleMapsGeocoder.new '1600 Pennsylvania Ave'

  def initialize(data)
    initialize_single_address(data) if data.is_a?(String)
    initialize_multiple_addresses(data) if data.is_a?(Hash)
  end

  # initialization for single address
  def initialize_single_address(data)
    @json = data.is_a?(String) ? json_from_url(data) : data
    handle_error if @json.blank? || @json['status'] != 'OK'
    set_attributes_from_json
    logger.info('GoogleMapsGeocoder') do
      "Geocoded \"#{data}\" => \"#{formatted_address}\""
    end
  end

  # initialization for multiple addresses
  def initialize_multiple_addresses(data)
    @addresses = {}
    json_results = bulk_json_from_urls(data)
    json_results.keys.each do |key|
      id = key.to_s.to_i
      @json = json_results[key]
      bulk_attributes_from_json_for(@json)
      @addresses[id] = @json
      @json = nil
    end
    @addresses
  end

  # Fetches the neighborhood
  def fetch_neighborhood
    return unless bounds.is_a?(Array) && bounds.size == 4
    uri = URI.parse neighborhood_url
    logger.debug('GoogleMapsGeocoder') { uri }
    response = http(uri).request(Net::HTTP::Get.new(uri.request_uri))
    results = ActiveSupport::JSON.decode response.body
    results['results'].map { |e| e['address_components'] }
                      .compact
                      .flatten
                      .select { |e| e['types'].include?('neighborhood') }
                      .map { |e| e['long_name'] }.uniq
  end

  # Returns true if the address Google returns is an exact match.
  #
  # @return [boolean] whether the Google Maps result is an exact match
  # @example
  #   chez_barack.exact_match?
  #     => true
  def exact_match?
    !partial_match?
  end

  # Returns true if the address Google returns isn't an exact match.
  #
  # @return [boolean] whether the Google Maps result is a partial match
  # @example
  #   GoogleMapsGeocoder.new('1600 Pennsylvania Washington').partial_match?
  #     => true
  def partial_match?
    @json['results'][0]['partial_match'] == true
  end

  private

  def self.error_class_name(key)
    "google_maps_geocoder/#{key}_error".classify.constantize
  end
  private_class_method :error_class_name

  def api_key
    @api_key ||= "&key=#{ENV['GOOGLE_MAPS_API_KEY']}" if
      ENV['GOOGLE_MAPS_API_KEY']
  end

  def http(uri)
    c = Curl::Easy.new(uri.to_s) do |curl|
      curl.ssl_verify_peer = false
      curl.verbose = false
    end
    c.perform
    c
  end

  def json_from_url(url)
    uri = URI.parse query_url(url)

    logger.debug('GoogleMapsGeocoder') { uri }

    response = http(uri)
    ActiveSupport::JSON.decode response.body_str
  end

  def bulk_json_from_urls(urls)
    urls.keys.each do |id|
      urls[id] = URI.parse(query_url(urls[id])).to_s
    end
    make_requests(urls)
  end

  def make_requests(urls) # rubocop:disable Metrics/MethodLength
    results = {}, easy_options = { follow_location: true }
    multi_options = { pipeline: Curl::CURLPIPE_MULTIPLEX } unless ENV['CI']
    Curl::Multi.get(urls.values, easy_options, multi_options) do |easy|
      begin
        results[urls.key(easy.last_effective_url)] =
          ActiveSupport::JSON.decode(easy.body_str)
      rescue StandardError => error
        p "error: #{error}"
      end
    end
    results
  end # rubocop:enable Metrics/MethodLength

  def handle_error
    status = @json['status']
    message = GeocodingError.new(@json).message
    # for status codes see https://developers.google.com/maps/documentation/geocoding/intro#StatusCodes
    ERROR_STATUSES.each do |key, value|
      next unless status == value
      raise GoogleMapsGeocoder.send(:error_class_name, key), message
    end
  end

  def logger
    @logger ||= Logger.new STDERR
  end

  def parse_address_component_type(type, name = 'long_name')
    address_component = @json['results'][0]['address_components'].detect do |ac|
      ac['types'] && ac['types'].include?(type)
    end
    address_component && address_component[name]
  end

  def parse_city
    parse_address_component_type('sublocality') ||
      parse_address_component_type('locality')
  end

  def parse_country_long_name
    parse_address_component_type('country')
  end

  def parse_country_short_name
    parse_address_component_type('country', 'short_name')
  end

  def parse_county
    parse_address_component_type('administrative_area_level_2')
  end

  def parse_bounds
    northeast =  @json['results'][0]['geometry']['viewport']['northeast']
    southwest =  @json['results'][0]['geometry']['viewport']['southwest']
    [
      northeast['lat'],
      northeast['lng'],
      southwest['lat'],
      southwest['lng']
    ]
  end

  def parse_formatted_address
    @json['results'][0]['formatted_address']
  end

  def parse_formatted_street_address
    "#{parse_address_component_type('street_number')} "\
    "#{parse_address_component_type('route')}"
  end

  def parse_lat
    @json['results'][0]['geometry']['location']['lat']
  end

  def parse_lng
    @json['results'][0]['geometry']['location']['lng']
  end

  def parse_postal_code
    parse_address_component_type('postal_code')
  end

  def parse_neighborhood
    parse_address_component_type('neighborhood')
  end

  def parse_state_long_name
    parse_address_component_type('administrative_area_level_1')
  end

  def parse_state_short_name
    parse_address_component_type('administrative_area_level_1', 'short_name')
  end

  def query_url(query)
    "#{GOOGLE_API_URI}?address=#{Rack::Utils.escape query}&sensor=false"\
    "#{api_key}"
  end

  def neighborhood_url
    "#{GOOGLE_API_URI}?sensor=false"\
    "&latlng=#{@lat},#{@lng}"\
    '&componentRestrictions=neighborhood'\
    "#{api_key}"
  end

  def bulk_attributes_from_json_for(object)
    ALL_ADDRESS_SEGMENTS.each do |segment|
      begin
        object['results'][0][segment.to_s] = send("parse_#{segment}")
      rescue StandardError => error
        p "Error #{error}"
      end
    end
  end

  def set_attributes_from_json
    ALL_ADDRESS_SEGMENTS.each do |segment|
      instance_variable_set :"@#{segment}", send("parse_#{segment}")
    end
  end
end

# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/AbcSize
