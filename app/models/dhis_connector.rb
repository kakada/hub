class DHISConnector < Connector
  include Entity

  store_accessor :settings, :url, :username, :password
  validates_presence_of :url

  after_initialize :initialize_defaults, :if => :new_record?

  def human_type
    "DHIS"
  end

  def has_event?
    true
  end

  def properties(context)
    {"dataSets" => Datasets.new(self)}
  end

  def get(relative_uri)
    url = "#{self.url}/api/#{relative_uri}"
    RestClient::Resource.new(url, self.username, self.password).get
  end

  def get_json(relative_uri)
    JSON.parse(get(relative_uri))
  end

  def organisations
    @organisations ||= get_json("organisationUnits.json?paging=false&fields=:all,!organisationUnitGroups,!userGroupAccesses,!attributeValues,!dataSets")["organisationUnits"]
  end

  private

  def initialize_defaults
    self.url = "https://apps.dhis2.org/demo" unless self.url
  end

  class Datasets
    include EntitySet

    def initialize(parent)
      @parent = parent
    end

    def path
      "dataSets"
    end

    def label
      "Datasets"
    end

    def query(filters, context, options)
      forms = datasets(context.user)
      forms.map! { |form| Dataset.new(self, form["id"], form["name"]) }
      forms.sort_by! { |form| form.label.downcase }
      {items: forms}
    end

    def datasets user
      GuissoRestClient.new(connector, user).get("#{connector.url}/api/#{path}.json?paging=all")["dataSets"]
    end

    def entity dataset
      Dataset.new(self, dataset["id"], dataset["name"])
    end

    def find_entity(id, context)
      Dataset.new(self, id)
    end
  end

  class Dataset
    include Entity
    attr_reader :id

    def initialize(parent, id, name = nil, user = nil)
      @parent = parent
      @id = id
      @name = name
      @user = user
    end

    def sub_path
      id
    end

    def properties(context)
      {
        "id" => SimpleProperty.id(@id),
        "name" => SimpleProperty.name(label(context.user))
      }
    end

    def label user = nil
      @label ||= dataset(user || @user)["name"]
    end

    def dataset(user)
      @dataset ||= parent.datasets(user).find { |col| col["id"].to_s == id.to_s }
    end

    def events
      {
        "new_data" => NewDataEvent.new(self)
      }
    end
  end

  class NewDataEvent
    include Event

    def initialize(parent)
      @parent = parent
    end

    def subscribe(*)
      handler = super
      poll unless load_state
      handler
    end

    def label
      "New data"
    end

    def sub_path
      "new_data"
    end

    def poll
      events = []

      max_id = load_state
      today = (Time.now - 1.day).strftime("%Y%m%d")
      url = "formData.json?dataSet=#{@parent.id}&period=#{today}"

      # form scheme
      form = connector.get_json "dataSets/#{parent.id}/form.json"

      # form data
      json_response = connector.get_json(url)
      organisation_units = json_response["organisationUnits"]
      organisation_units.each do |organisation_unit|
        periods = organisation_unit["periods"]
        periods.each do |period|
          dataValues = period["dataValues"]
          if dataValues
            record = initial_form_data(organisation_unit).merge({"dataset" => json_response["label"], "period" => period["period"]})
            dataValues.each do |dataValue|
              record = process_data dataValue, form["groups"][0]["fields"], "", record
              record["id"] = dataValue["id"]

              max_id = dataValue["id"]
              save_state(max_id)
            end

            events.push record
          end
        end if periods
      end if organisation_units

      events
    end

    def initial_form_data organisation_unit
      form_data = {"organisation" => organisation_unit["name"]}

      lat_lng = JSON.parse(organisation_unit["coordinates"]) if organisation_unit["coordinates"]

      if lat_lng
        form_data["lat"] = lat_lng[0]
        form_data["long"] = lat_lng[1]
      end

      form_data
    end

    def process_data(data, children, prefix = "", output = {})
      children.each do |c|
        if c["dataElement"] == data["dataElement"] && c["categoryOptionCombo"] == data["categoryOptionCombo"]
          data_path = "#{prefix}value"
          name = c["label"]
          output[name] = data[data_path]

          break
        end
      end
      output
    end

    def args(context)
      form = connector.get_json "dataSets/#{parent.id}/form.json"
      args = type_children(form, form["groups"][0]["fields"])

      # append manual params
      args["dataset"] = {type: :string}
      args["period"] = {type: :string}
      args["organisation"] = {type: :string}
      args["lat"] = {type: :float}
      args["long"] = {type: :float}

      args["_id"] = {type: :integer}
      args
    end

    def type_children(form, children)
      args = {}
      children.each do |c|
        type = case c["type"]
        when "date"
          {type: :date}
        when "start"
          {type: :datetime, label: "Start"}
        when "end"
          {type: :datetime, label: "End"}
        when "today"
          {type: :date, label: "Today"}
        when "datetime"
          {type: :datetime}
        when "deviceid"
          {type: :string}
        when "geopoint"
          {type: {kind: :struct, members: {lat: :float, lon: :float}}}
        when "select one"
          members = ona_children(form, c).map { |m| {value: m["name"], label: ona_label(m) } }
          {type: {kind: :enum, value_type: :string, members: members}}
        when "select all that apply"
          members = ona_children(form, c).map { |m| {value: m["name"], label: ona_label(m) } }
          {type: {kind: :array, item_type: {kind: :enum, value_type: :string, members: members}}}
        when "group"
          members = type_children(form, c["children"])
          {type: {kind: :struct, members: members}} if members.any?
        when "text", "phonenumber", "string"
          {type: :string}
        when "integer"
          {type: :integer}
        when "INTEGER"
          {type: :integer}
        when "decimal"
          {type: :float}
        when "NUMBER"
          {type: :float}
        when "calculate"
          {type: :string}
        when "repeat"
          members = type_children(form, c["children"])
          {type: {kind: :array, item_type: {kind: :struct, members: members}}}
        when "note", "photo"
          # skip
        else
          raise "Unsupported ONA type: #{c["type"]}"
        end

        if type
          type[:label] ||= ona_label(c)
          args[c["label"]] = type
        end
      end
      args
    end

    def ona_label(obj)
      label = obj["label"]
      if label.is_a?(Hash)
        label["English"]
      else
        label
      end
    end

    def ona_children(form, obj)
      obj["children"] || form["choices"][obj["itemset"]]
    end

    def to_query_string_params organisations
      query_string = ""

      organisations.each do |org|
        query_string += "orgUnit=#{org['id']}"
      end

      query_string
    end
  end

end
