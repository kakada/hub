class ResourceMapConnector < Connector
  include Entity

  store_accessor :settings, :url, :username, :password
  after_initialize :initialize_defaults, :if => :new_record?

  def properties(context)
    {"collections" => Collections.new(self)}
  end

  private

  def initialize_defaults
    self.url = "https://resourcemap.instedd.org" unless self.url
  end

  class Collections
    include EntitySet

    def initialize(parent)
      @parent = parent
    end

    def path
      "collections"
    end

    def label
      "Collections"
    end

    def query(filters, context, options)
      items = collections(context.user)
      items = items.map { |collection| entity(collection) }
      {items: items}
    end

    def find_entity(id, context)
      Collection.new(self, id, nil, context.user)
    end

    def collections(user)
      GuissoRestClient.new(connector, user).get("#{connector.url}/api/v2/collections.json")
    end

    def collection(id, user)
      GuissoRestClient.new(connector, user).get("#{connector.url}/api/v2/collections/#{id}.json")
    end

    def entity(collection)
      Collection.new(self, collection["id"], collection["name"])
    end
  end

  class Collection
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
      @label ||= collection(user || @user)["name"]
    end

    def properties(context)
      {
        "id" => SimpleProperty.id(@id),
        "name" => SimpleProperty.name(label(context.user)),
        "sites" => Sites.new(self),
      }
    end

    def collection_id
      @id
    end

    def collection(user)
      @collection ||= parent.collections(user).find { |col| col["id"].to_s == id.to_s }
    end

    def user
      @user
    end
  end

  class Sites
    include EntitySet
    delegate :collection_id, to: :@parent

    protocol :insert, :update, :delete

    def initialize(parent)
      @parent = parent
    end

    def label
      "Sites"
    end

    def path
      "#{@parent.path}/sites"
    end

    def reflect_entities(context)
    end

    def entity_properties(context)
      layers = GuissoRestClient.new(connector, context.user).get("#{connector.url}/api/v2/collections/#{@parent.id}/layers.json")
      {
        id: SimpleProperty.integer("ID"),
        name: SimpleProperty.string("Name"),
        lat: SimpleProperty.float("Latitude"),
        long: SimpleProperty.float("Longitude"),
        layers: {
          label: "Layers",
          type: {
            kind: :struct,
            members: Hash[layers.map do |layer|
              [layer["id"].to_s, {
                label: layer["name"],
                type: {
                  kind: :struct,
                  members: Hash[
                    (layer["fields"] || []).map do |field|
                      [field["code"].to_s, field_properties(field)]
                    end
                  ]
                }
              }]
            end]
          }
        }
      }
    end

    def query(filters, context, options)
      page = (options[:page] || 1).to_i
      sites = internal_query(filters, context, page)

      layers = GuissoRestClient.new(connector, context.user).get("#{connector.url}/api/v2/collections/#{@parent.id}/layers.json")
      layers_by_field_code = index_layers_by_field_code(layers)

      items = sites_to_ui(sites["sites"], layers_by_field_code)
      result = {}
      result[:items] = items
      result[:next_page] = page + 1 if has_more_pages?(sites, page)
      result
    end

    def insert(properties, context)
      GuissoRestClient.new(connector, context.user).
        post("#{connector.url}/api/v2/collections/#{@parent.id}/sites.json",
          site: properties_as_site_json(properties).to_json)
    end

    def update(filters, properties, context)
      for_each_site_id(filters, context) do |id|
        GuissoRestClient.new(connector, context.user).
          post("#{connector.url}/api/v2/sites/#{id}/partial_update.json",
            site: properties_as_site_json(properties).to_json)
      end
    end

    def delete(filters, context)
      for_each_site_id(filters, context) do |id|
        GuissoRestClient.new(connector, context.user).
          delete("#{connector.url}/api/v2/sites/#{id}.json")
      end
    end

    def for_each_site_id(filters, context)
      page = 1

      while true
        sites = internal_query(filters, context, page)
        sites["sites"].each do |site|
          yield site["id"]
        end

        break unless has_more_pages?(sites, page)

        page += 1
      end
    end

    def properties_as_site_json(properties)
      site = {}

      site["name"] = properties["name"] if properties["name"].present?
      site["lat"] = properties["lat"].to_f if properties["lat"].present?
      site["lng"] = properties["long"].to_f if properties["long"].present?

      site_properties = site["properties"] = {}

      layers = properties["layers"]
      if layers
        layers.each do |layer_id, fields|
          if fields
            fields.each do |field_code, value|
              site_properties[field_code] = value
            end
          end
        end
      end

      if site_properties.empty?
        site.delete "properties"
      end

      site
    end

    def field_properties(field)
      h = {}
      h[:label] = field["name"]
      case field["kind"]
      when "numeric"
        if field["config"] && field["config"]["allows_decimals"] == 'true'
          h[:type] = :float
        else
          h[:type] = :integer
        end
      # TODO: missing select one, select many and hierarchy fields
      else
        h[:type]= :string
      end
      h
    end

    def filters_as_query(filters)
      query = {}

      query["name"] = filters["name"] if filters["name"].present?
      query["lat"] = filters["lat"] if filters["lat"].present?
      query["lng"] = filters["long"] if filters["long"].present?

      layers = filters["layers"]
      if layers
        layers.each do |layer_id, fields|
          if fields
            fields.each do |field_code, value|
              query[field_code] = value
            end
          end
        end
      end

      query
    end

    def sites_to_ui(sites, layers_by_field_code)
      sites.map { |site| site_to_ui(site, layers_by_field_code) }
    end

    def site_to_ui(site, layers_by_field_code)
      ui = {}

      ui["id"] = site["id"]
      ui["name"] = site["name"]
      ui["lat"] = site["lat"] if site["lat"].present?
      ui["long"] = site["long"] if site["long"].present?
      ui_layers = ui["layers"] = {}

      properties = site["properties"]
      if properties
        properties.each do |field_code, value|
          layer_id = layers_by_field_code[field_code]
          if layer_id
            layer_properties = ui_layers[layer_id.to_s] ||= {}
            layer_properties[field_code] = value
          end
        end
      end

      ui
    end

    def index_layers_by_field_code(layers)
      index = {}
      layers.each do |layer|
        fields = layer["fields"]
        if fields
          fields.each do |field|
            index[field["code"]] = layer["id"]
          end
        end
      end
      index
    end

    def internal_query(filters, context, page)
      url_query = filters_as_query(filters)
      url_query[:page] = page unless page == 1

      if url_query.empty?
        url_query = ""
      else
        url_query = "?#{url_query.to_query}"
      end

      GuissoRestClient.new(connector, context.user).
        get("#{connector.url}/api/v2/collections/#{@parent.id}.json#{url_query}")
    end

    def has_more_pages?(sites, page)
      total = sites["count"]
      total > page * 50
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
      max_id = load_state
      url = "#{connector.url}/api/v2/collections/#{parent.collection_id}/sites/feed.json"
      url << %(?offset_id=#{max_id.to_i + 1}) if max_id

      form = form parent.parent.user

      all_data = GuissoRestClient.new(connector, parent.parent.user).get(url)['sites']

      events = all_data.map do |data|
        output = process_data(data, form[:layers][:type][:members])
        output['_id'] =  data['id']
        output
      end

      return [] if events.empty?

      max_id = events.max_by { |o| o["_id"] }["_id"]
      save_state(max_id)
      events
    end

    def process_data(data, layers, output = {})
      output = output.merge(process_meta_data(data))
      layers.each do |layer_id, fields|
        if fields
          fields[:type][:members].each do |field_id, field_value|
            output[['layers', "#{layer_id}", "#{field_id}"]] = data['properties'][field_id] if data['properties']
          end
        end
      end
      output
    end

    def process_meta_data(data, output = {})
      output["name"] = data["name"] if data["name"].present?
      output["lat"] = data["lat"].to_f if data["lat"].present?
      output["long"] = data["lng"].to_f if data["lng"].present?
      output
    end

    def args(context)
      form context.user
    end

    def form user
      layers = GuissoRestClient.new(connector, user).get("#{connector.url}/api/v2/collections/#{parent.collection_id}/layers.json")
      {
        id: SimpleProperty.integer("ID"),
        name: SimpleProperty.string("Name"),
        lat: SimpleProperty.float("Latitude"),
        long: SimpleProperty.float("Longitude"),
        layers: {
          label: "Layers",
          type: {
            kind: :struct,
            members: Hash[layers.map do |layer|
              [layer["id"].to_s, {
                label: layer["name"],
                type: {
                  kind: :struct,
                  members: Hash[
                    (layer["fields"] || []).map do |field|
                      [field["id"].to_s, parent.field_properties(field)]
                    end
                  ]
                }
              }]
            end]
          }
        }
      }
    end
  end

end
