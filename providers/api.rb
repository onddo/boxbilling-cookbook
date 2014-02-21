
def whyrun_supported?
  true
end

def get_admin_api_token
  db = BoxBilling::Database.new({
    :database => node['boxbilling']['config']['db_name'],
    :user     => node['boxbilling']['config']['db_user'],
    :password => node['boxbilling']['config']['db_password'],
  })
  db.get_admin_api_token || begin
    db.generate_admin_api_token
    db.get_admin_api_token
  end
end

# Remove unnecessary slashes
def filter_path(path)
  path.gsub(/(^\/*|\/*$)/, '').gsub(/\/+/, '/')
end

# Get "primary keys" from data Hash
def filter_keys_from_data(data)
  data.select do |key, value|
    %w{id code type product_id}.include?(key.to_s)
  end
end

# Remove keys generated internally by BoxBilling
def remove_autogenerated_keys_from_data(data)
  data.reject do |key|
    %{id product_id}.include?(key.to_s)
  end
end

# Get the final action string name for a path (from symbol)
# Examples:
#   (admin/client,   :create) -> create
#   (admin/currency, :create) -> create
#   (admin/product,  :create) -> prepare
def get_action_for_path(path, action)
  case action
  when :create
    case path
    when 'admin/product', 'admin/invoice'
      :prepare
    else
      action
    end
  else
    action
  end.to_s
end

# Generate the full URL path, including the action at the end
# Examples:
#   admin/client/create
#   admin/currency/create
#   admin/kb/category_create
def path_with_action(path, action)
  path = filter_path(path)
  slashes = path.count('/')
  joiner = slashes < 2 ? '/' : '_'
  path + joiner + get_action_for_path(path, action)
end

def data_changed?(old, new)
  new.each do |key, value|
    return true if old[key.to_s].to_s != value.to_s
  end
  return false
end

def boxbilling_api_request(args={})
  api_token = get_admin_api_token

  opts = {
    :path => args[:path] || new_resource.path,
    :data => args[:data] || new_resource.data,
    :api_token => api_token,
    :referer => node['boxbilling']['config']['url'],
    :debug => new_resource.debug,
  }
  ignore_errors = args[:ignore_errors].nil? ? new_resource.ignore_errors : args[:ignore_errors]
  if ignore_errors
    begin
      BoxBilling::API.request(opts)
    rescue Exception => e
      Chef::Log.info("Ignored exception: #{e.to_s}") if opts[:debug]
      nil
    end
  else
    BoxBilling::API.request(opts)
  end
end

action :request do
  boxbilling_api_request
end

action :create do
  get_keys = filter_keys_from_data(new_resource.data)
  get_path = path_with_action(new_resource.path, :get)
  read_data = boxbilling_api_request({
    :path => get_path,
    :data => get_keys,
    :ignore_errors => true,
  })

  if read_data.nil?
    converge_by("Create #{new_resource}: #{new_resource.data}") do
      update_keys = remove_autogenerated_keys_from_data(new_resource.data)
      update_path = path_with_action(new_resource.path, :create)
      boxbilling_api_request({
        :path => update_path,
        :data => update_keys,
      })
    end
  else
    if data_changed?(read_data, new_resource.data)
      converge_by("Update #{new_resource}: #{new_resource.data}") do
        update_path = path_with_action(new_resource.path, :update)
        boxbilling_api_request({
          :path => update_path,
          :data => new_resource.data,
        })
      end
    end
  end
end

action :delete do
  get_keys = filter_keys_from_data(new_resource.data)
  get_path = path_with_action(new_resource.path, :get)
  read_data = boxbilling_api_request({
    :path => get_path,
    :data => get_keys,
    :ignore_errors => true,
  })

  unless read_data.nil?
    converge_by("Delete #{new_resource}: #{new_resource.data}") do
      delete_path = path_with_action(new_resource.path, :delete)
      boxbilling_api_request({
        :path => delete_path,
        :data => get_keys,
      })
    end
  end
end
