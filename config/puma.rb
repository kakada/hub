on_worker_boot do
  ActiveSupport.on_load(:active_record) do
    ActiveRecord::Base.establish_connection
  end

  PoirotRails::ZMQDevice.reconnect
end
