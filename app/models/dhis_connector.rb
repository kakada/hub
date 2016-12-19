class DHISConnector < Connector
  include Entity

  store_accessor :settings, :url, :username, :password
  validates_presence_of :url

  after_initialize :initialize_defaults, :if => :new_record?

  def human_type
    "DHIS"
  end

  def has_events?
    false
  end

  def properties(context)
    {"dataSets" => DataSets.new(self)}
  end

  def get(relative_uri)
    uri = URI.join(self.url, 'api', relative_uri)
    RestClient::Resource.new(uri.to_s, self.username, self.password).get
  end

  def get_json(relative_uri)
    JSON.parse(get(relative_uri))
  end

  private

  def initialize_defaults
    self.url = "https://apps.dhis2.org/demo/" unless self.url
  end

  class DataSets
    include EntitySet

    def initialize(parent)
      @parent = parent
    end

    def path
      "dataSets"
    end

    def label
      "Data Set"
    end

    def query(filters, context, options)
      items = data_sets(context.user)
      items = items.map { |data_set| entity(data_set) }
      {items: items}
    end

    def find_entity(id, context)
      DataSet.new(self, id, nil, context.user)
    end

    def data_sets(user)
      uri = URI.join(connector.url, "api/dataSets.json")
      GuissoRestClient.new(connector, user).get(uri.to_s)["dataSets"] || []
    end

    def data_set(id, user)
      uri = URI.join(connector.url, "api/dataSets/#{id}.json")
      GuissoRestClient.new(connector, user).get(uri.to_s)
    end

    def entity(data_set)
      DataSet.new(self, data_set["id"], data_set["name"])
    end
  end

  class DataSet
    include Entity
    attr_reader :id

    def initialize(parent, id, name = nil, user = nil)
      @parent = parent
      @id = id
      @label = name
      @user = user
    end

    def sub_path
      id
    end

    def label(user = nil)
      @label ||= data_set(user || @user)["name"]
    end

    def properties(context)
      {
        "id" => SimpleProperty.id(@id),
        "name" => SimpleProperty.name(label(context.user)),
        "form" => Forms.new(self),
      }
    end

    def data_set_id
      @id
    end

    def data_set(user)
      @data_set ||= parent.data_sets(user).find { |item| item["id"].to_s == id.to_s }
    end
  end

  class Forms
    include EntitySet
    delegate :data_set_id, to: :@parent

    protocol :insert

    def initialize(parent)
      @parent = parent
    end

    def label
      "Data Entry"
    end

    def path
      "#{@parent.path}/form"
    end

    def reflect_entities(context)
    end

    def entity_properties(context)
      uri = URI.join(connector.url, "api/dataSets/#{@parent.id}/form.json")
      diseases = GuissoRestClient.new(connector, context.user).get(uri.to_s)
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
      dataset_form_uri = URI.join(connector.url, "api/dataSets/#{@parent.id}/form.json")
      form = GuissoRestClient.new(connector, context.user).get(dataset_form_uri.to_s)
      disease_fields = form["groups"][0]["fields"] rescue []

      submit_form_uri = URI.join(connector.url, 'api/dataValueSets.json')
      GuissoRestClient.new(connector, context.user).
        post(submit_form_uri.to_s, properties_as_entry_json(disease_fields, properties).to_json)
    end

    def properties_as_entry_json(disease_fields, properties)
      entry = {}

      entry["dataSet"] = data_set_id
      entry["orgUnit"] = properties["orgUnit"] if properties["orgUnit"].present?
      entry["period"] = properties["period"] if properties["period"].present?
      entry["completeDate"] =  properties["completeDate"] if properties["completeDate"].present?

      entry["dataValues"] = []

      disease_fields.each do |field|
        if properties["dataValues"] && properties["dataValues"].include?(field["dataElement"])
          value = properties["dataValues"][field["dataElement"]]
          data_element = { dataElement: field["dataElement"], value: value.is_a?(String) ? value : "0" } # empty will map as Hash
        else
          data_element = { dataElement: field["dataElement"], value: "0" }
        end

        entry["dataValues"].push(data_element)
      end

      entry
    end
  end

end