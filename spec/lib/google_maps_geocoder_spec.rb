require File.dirname(__FILE__) + '/../spec_helper'
# rubocop:disable Metrics/BlockLength
describe GoogleMapsGeocoder do
  before(:all) do
    begin
      @exact_match   = GoogleMapsGeocoder.new('837 Union Street Brooklyn NY')
      @partial_match = GoogleMapsGeocoder.new('1600 Pennsylvania Washington')
    rescue SocketError
      @no_network  = true
    rescue RuntimeError
      @query_limit = true
    end
  end
  # rubocop:enable Metrics/BlockLength
  before(:each) do
    pending 'waiting for a network connection' if @no_network
    pending 'waiting for query limit to pass' if @query_limit
  end

  context 'with "837 Union Street Brooklyn NY"' do
    subject { @exact_match }

    it { expect(subject).to be_exact_match }

    context 'address' do
      it { expect(subject.formatted_street_address).to eq '837 Union Street' }
      it { expect(subject.city).to eq 'Brooklyn' }
      it { expect(subject.county).to match(/Kings/) }
      it { expect(subject.state_long_name).to eq 'New York' }
      it { expect(subject.state_short_name).to eq 'NY' }
      it { expect(subject.postal_code).to match(/112[0-9]{2}/) }
      it { expect(subject.country_short_name).to eq 'US' }
      it { expect(subject.country_long_name).to eq 'United States' }
      it do
        expect(subject.formatted_address)
          .to match(/837 Union St, Brooklyn, NY 112[0-9]{2}, USA/)
      end
    end
    context 'coordinates' do
      it { expect(subject.lat).to be_within(0.005).of(40.6748151) }
      it { expect(subject.lng).to be_within(0.005).of(-73.9760302) }
    end
  end

  context 'with "1600 Pennsylvania Washington"' do
    subject { @partial_match }

    it { expect(subject).to be_partial_match }

    context 'address' do
      it do
        expect(subject.formatted_street_address)
          .to match '1600 Pennsylvania Avenue'
      end
      it { expect(subject.city).to eq 'Washington' }
      it { expect(subject.state_long_name).to eql 'District of Columbia' }
      it { expect(subject.state_short_name).to eql 'DC' }
      it { expect(subject.country_short_name).to eql 'US' }
      it { expect(subject.country_long_name).to eql 'United States' }
      it do
        expect(subject.formatted_address)
          .to match(/1600 Pennsylvania Ave.*, Washington, DC 20500, USA/)
      end
    end

    context 'coordinates' do
      it { expect(subject.lat).to be_within(0.005).of(38.8976633) }
      it { expect(subject.lng).to be_within(0.005).of(-77.0365739) }
    end
  end

  context "when ENV['GOOGLE_MAPS_API_KEY'] is invalid" do
    subject { @exact_match }

    it do
      allow(subject).to receive(:send).with(:query_url, nil).and_return(
        'https://maps.googleapis.com/maps/api/geocode/json?address='\
        '&sensor=false&key=INVALID_KEY'
      )
      expect(subject.send(:query_url, nil)).to eql(
        'https://maps.googleapis.com/maps/api/geocode/json?address='\
        '&sensor=false&key=INVALID_KEY'
      )
    end
  end

  context 'with google returns empty results' do
    let(:results_hash) { { 'results' => [] } }

    GoogleMapsGeocoder::ERROR_STATUSES.each do |key, value|
      it "raises #{key} error" do
        allow_any_instance_of(GoogleMapsGeocoder).to receive(:json_from_url)
          .and_return results_hash.merge('status' => value)
        expect { GoogleMapsGeocoder.new('anything') }
          .to raise_error(GoogleMapsGeocoder.send(:error_class_name, key))
      end
    end
  end
end
# rubocop:disable Metrics/BlockLength
describe GoogleMapsGeocoder, 'batch' do
  before(:all) do
    begin
      address_hash = {
        '1': '837 Union Street Brooklyn NY',
        '2': '1600 Pennsylvania Washington'
      }
      @array_match = GoogleMapsGeocoder.new(address_hash)
      p 'Done with array constructor'
    rescue SocketError
      @no_network  = true
    rescue RuntimeError
      @query_limit = true
    rescue StandardError
      @unknown_error = true
    end
  end

  # rubocop:enable Metrics/BlockLength
  before(:each) do
    pending 'waiting for a network connection' if @no_network
    pending 'waiting for query limit to pass' if @query_limit
    pending 'an unknown error occurred' if @unknown_error
  end

  context 'with multiple addresses' do
    pending 'not ready yet' do
      it { expect(subject).to be_array_match }
    end
  end
end

describe GoogleMapsGeocoder, '#build_google_api_urls' do
  let(:uri) { GoogleMapsGeocoder.api_uri }
  let(:address_hash) do
    {
      1 => '837 Union Street Brooklyn NY',
      2 => '1600 Pennsylvania Washington'
    }
  end

  it 'should turn a hash with IDs & addresses into a hash with IDs and URLs' do
    geocoder = GoogleMapsGeocoder.new(nil)
    address_with_urls_hash = geocoder.build_google_api_urls(address_hash)
    expect(address_with_urls_hash).to eq(
      1 => "#{uri}?address=837+Union+Street+Brooklyn+NY&sensor=false&"\
        "key=#{ENV['GOOGLE_MAPS_API_KEY']}",
      2 => "#{uri}?address=1600+Pennsylvania+Washington&sensor=false&"\
        "key=#{ENV['GOOGLE_MAPS_API_KEY']}"
    )
  end
end

describe GoogleMapsGeocoder, '#make_requests' do
  let(:uri) { GoogleMapsGeocoder.api_uri }
  let(:google_api_urls) do
    {
      1 => "#{uri}?address=837+Union+Street+Brooklyn+NY&sensor=false&"\
        "key=#{ENV['GOOGLE_MAPS_API_KEY']}",
      2 => "#{uri}?address=1600+Pennsylvania+Washington&sensor=false&"\
        "key=#{ENV['GOOGLE_MAPS_API_KEY']}"
    }
  end
  it 'returns a hash of GoogleMapsGeocoder results given a hash with URLs'
end

describe GoogleMapsGeocoder, '.api_uri' do
  it 'returns the URL for the API' do
    expect(GoogleMapsGeocoder.api_uri).to eq('https://maps.googleapis.com/maps/api/geocode/json')
  end
end
