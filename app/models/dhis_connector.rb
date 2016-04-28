class DHISConnector < Connector
  include Entity

  store_accessor :settings, :url, :username, :password
  validates_presence_of :url

  after_initialize :initialize_defaults, :if => :new_record?

  def human_type
    "DHIS"
  end

  def has_event?
    false
  end

  def properties(context)
    {"dataSets" => Entries.new(self)}
  end

  def get(relative_uri)
    url = "#{self.url}/api/#{relative_uri}"
    RestClient::Resource.new(url, self.username, self.password).get
  end

  def get_json(relative_uri)
    JSON.parse(get(relative_uri))
  end

  private

  def initialize_defaults
    self.url = "https://apps.dhis2.org/demo" unless self.url
  end

  class Entries
    include EntitySet

    protocol :insert

    def initialize(parent)
      @parent = parent
    end

    def label
      "Data Entry"
    end

    def path
      "dataSets"
    end

    def reflect_entities(context)
    end

    def entity_properties(context)
      diseases = GuissoRestClient.new(connector, context.user).get("#{connector.url}/api/dataSets/QnF4A5MHk4t/form.json")
      {
        dataSet: SimpleProperty.string("DataSet"),
        orgUnit: SimpleProperty.string("OrgUnit"),
        period: SimpleProperty.string("Period"),
        completeDate: SimpleProperty.string("CompleteDate"),
        dataValues: {
          label: diseases["label"],
          type: {
            kind: :struct,
            members: Hash[diseases["groups"][0]["fields"].map do |disease|
              [disease["dataElement"].to_s, {
                label: disease["label"],
                type: disease["type"].downcase.to_sym
              }]
            end]
          }
        }
      }
    end

    def insert(properties, context)
      uri = URI.join(connector.url, 'dhis/api/dataValueSets.json')
      GuissoRestClient.new(connector, context.user).
        post(uri.to_s, properties_as_entry_json(properties).to_json)
    end

    def properties_as_entry_json(properties)
      entry = {}

      entry["dataSet"] = properties["dataSet"] if properties["dataSet"].present?
      entry["orgUnit"] = properties["orgUnit"] if properties["orgUnit"].present?
      entry["period"] = properties["period"] if properties["period"].present?
      entry["completeDate"] =  properties["completeDate"] if properties["completeDate"].present?

      entry["dataValues"] = []

      
      properties["dataValues"].each do |k, v|
        data_element = {dataElement: k, value: v}
        entry["dataValues"].push(data_element)
      end if properties["dataValues"]

      entry
    end

  end

end
