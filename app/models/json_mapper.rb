class JsonMapper
  def initialize(mapping)
    @mapping = mapping
  end

  def map_members(context, members)
    target = {}
    members.each do |key, value|
      mapped_value = map(context, value)
      target[key] = mapped_value unless mapped_value.nil?
    end
    target
  end

  def map(context, mapping = @mapping)
    if mapping.is_a?(String)
      context[mapping]
    elsif mapping.is_a?(Array)
      value = nil
      mapping.each do |key|
        value = context[key] || {}
      end
      value.is_a?(Hash) ? (value.empty? ? context[mapping] : value) : value
    else
      case mapping["type"]
      when "struct"
        map_members(context, mapping["members"])
      when "literal"
        mapping["value"]
      end
    end
  end
end
