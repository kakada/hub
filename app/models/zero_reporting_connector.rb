class ZeroReportingConnector < Connector
  include Entity

  store_accessor :settings, :url, :username, :password
  validates_presence_of :url

  after_initialize :initialize_defaults, :if => :new_record?

  def human_type
    "Zero Reporting"
  end

  def has_actions?
    false
  end

  def properties(context)
    {"reports" => Reports.new(self)}
  end

  def get(relative_uri)
    url = "#{self.url}/#{relative_uri}"
    RestClient::Resource.new(url, self.username, self.password).get
  end

  def get_json(relative_uri)
    JSON.parse(get(relative_uri))
  end

  private

  def initialize_defaults
    self.url = "http://cdcmoh.gov.kh/verboice" unless self.url
  end

  class Reports
    include EntitySet

    def initialize(parent)
      @parent = parent
    end

    def path
      "reports"
    end

    def label
      "Reports"
    end

    def query(filters, context, options)
      forms = reports(context.user)
      forms.map! { |form| WeeklyDisease.new(self, form["id"], form["name"]) }
      forms.sort_by! { |form| form.label.downcase }
      {items: forms}
    end

    def reports user
      GuissoRestClient.new(connector, user).get("#{connector.url}/api/hub/#{path}.json")
    end

    def entity report
      WeeklyDisease.new(self, report["id"], report["name"])
    end

    def find_entity(id, context)
      WeeklyDisease.new(self, id)
    end
  end

  class WeeklyDisease
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

    def label user = nil
      @label ||= report(user || @user)["name"]
    end

    def report(user)
      @report ||= parent.reports(user).find { |col| col["id"].to_s == id.to_s }
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

    def label
      "New data"
    end

    def sub_path
      "new_data"
    end

    def args(context)
      form = connector.get_json "api/hub/reports/#{@parent.id}.json"

      args = type_children(form['reports'])

      # append manual params
      args["dataSet"] = {label: "DataSet", type: :string}
      args["orgUnit"] = {label: "Organization Unit", type: :string}
      args["period"] = {label: "Period", type: :string}
      args["completeDate"] = {label: "Complete Date", type: :string}

      args
    end

    def type_children(children)
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
        else
          {type: :string, label: c["name"]}
        end

        args[c["dhis2_data_element_uuid"]] = type
      end

      args
    end

  end

end
