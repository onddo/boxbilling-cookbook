#
# Cookbook Name:: boxbilling
# Recipe:: default
#
# Copyright 2013, Onddo Labs, Sl.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#==============================================================================
# Install packages needed by the recipe
#==============================================================================

node['boxbilling']['required_packages'].each do |pkg|
  package pkg
end

#==============================================================================
# Initialize autogenerated passwords
#==============================================================================

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

if Chef::Config[:solo]
  if node['boxbilling']['config']['db_password'].nil?
    Chef::Application.fatal!('You must set boxbilling\'s database password in chef-solo mode.')
  else
    db_password = node['boxbilling']['config']['db_password']
  end
  if node['boxbilling']['admin']['pass'].nil?
    Chef::Application.fatal!('You must set boxbilling\'s admin password in chef-solo mode.')
  else
    admin_pass = node['boxbilling']['admin']['pass']
  end
else
  include_recipe 'encrypted_attributes'

  # generate db_password
  if Chef::EncryptedAttribute.exists?(node['boxbilling']['config']['db_password'])
    Chef::EncryptedAttribute.update(node.set['boxbilling']['config']['db_password'])
    db_password = Chef::EncryptedAttribute.load(node['boxbilling']['config']['db_password'])
  else
    db_password = secure_password
    node.set['boxbilling']['config']['db_password'] = Chef::EncryptedAttribute.create(db_password)
  end

  # generate admin_pass
  if Chef::EncryptedAttribute.exists?(node['boxbilling']['admin']['pass'])
    Chef::EncryptedAttribute.update(node.set['boxbilling']['admin']['pass'])
    admin_pass = Chef::EncryptedAttribute.load(node['boxbilling']['admin']['pass'])
  else
    admin_pass = secure_password
    node.set['boxbilling']['admin']['pass'] = Chef::EncryptedAttribute.create(admin_pass)
  end

  node.save
end

#==============================================================================
# Install PHP
#==============================================================================

include_recipe 'php'

if %w{ redhat centos scientific fedora suse amazon oracle }.include?(node['platform'])
  include_recipe 'yum-epel' # required by php-mcrypt
end
node['boxbilling']['php_packages'].each do |pkg|
  package pkg
end

#==============================================================================
# Install IonCube loader
#==============================================================================

ioncube_file = ::File.join(Chef::Config[:file_cache_path], 'ioncube_loaders.tar.gz')

remote_file 'download ioncube' do
  if node['kernel']['machine'] =~ /x86_64/
    source 'http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz'
  else
    source 'http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86.tar.gz'
  end
  path ioncube_file
  action :create_if_missing
end

execute 'install ioncube' do
  command <<-EOF
    cd "$(php -i | awk '$1 == "extension_dir" {print $NF}')" &&
    tar xfz '#{ioncube_file}' --strip-components=1 --no-same-owner --wildcards --no-anchored '*.so' &&
    echo "zend_extension = $(pwd)/ioncube_loader_lin_$(php -v | grep -o '[0-9][.][0-9][0-9]*' | head -1).so" > '#{node['php']['ext_conf_dir']}/20ioncube.ini'
    EOF
  creates ::File.join(node['php']['ext_conf_dir'], '20ioncube.ini')
end

#==============================================================================
# Install MySQL
#==============================================================================

def server_root_password
  if Chef::Config[:solo]
    node['boxbilling']['mysql']['server_root_password']
  else
    Chef::EncryptedAttribute.load(node['boxbilling']['mysql']['server_root_password'])
  end
end

if %w{ localhost 127.0.0.1 }.include?(node['boxbilling']['config']['db_host'])
  include_recipe 'boxbilling::mysql'
  include_recipe 'database::mysql'

  mysql_connection_info = {
    :host => 'localhost',
    :username => 'root',
    :password => server_root_password,
  }

  mysql_database node['boxbilling']['config']['db_name'] do
    connection mysql_connection_info
    action :create
  end

  mysql_database_user node['boxbilling']['config']['db_user'] do
    connection mysql_connection_info
    database_name node['boxbilling']['config']['db_name']
    host 'localhost'
    password db_password
    privileges [:all]
    action :grant
  end
end

#==============================================================================
# Download and extract BoxBilling
#==============================================================================

directory node['boxbilling']['dir'] do
  recursive true
end

basename = ::File.basename(node['boxbilling']['download_url'])
local_file = ::File.join(Chef::Config[:file_cache_path], basename)

remote_file 'download boxbilling' do
  source node['boxbilling']['download_url']
  path local_file
  action :create_if_missing
end

execute 'extract boxbilling' do
  command "unzip -q -u -o '#{local_file}' -d '#{node['boxbilling']['dir']}'"
  creates ::File.join(node['boxbilling']['dir'], 'index.php')
end



#==============================================================================
# Install Apache
#==============================================================================

include_recipe 'apache2::default'
include_recipe 'apache2::mod_php5'
include_recipe 'apache2::mod_rewrite'
include_recipe 'apache2::mod_headers'

# Disable default site
apache_site 'default' do
  enable false
end

# Create virtualhost for BoxBilling
web_app 'boxbilling' do
  template 'apache_vhost.erb'
  docroot node['boxbilling']['dir']
  server_name node['boxbilling']['server_name']
  server_aliases node['boxbilling']['server_aliases']
  headers node['boxbilling']['headers']
  port '80'
  allow_override 'All'
  enable true
end

# Enable ssl
if node['boxbilling']['ssl']
  cert = ssl_certificate 'boxbilling' do
    namespace node['boxbilling']
    notifies :restart, 'service[apache2]'
  end

  include_recipe 'apache2::mod_ssl'

  # Create SSL virtualhost
  web_app 'boxbilling-ssl' do
    template 'apache_vhost.erb'
    docroot node['boxbilling']['dir']
    server_name node['boxbilling']['server_name']
    server_aliases node['boxbilling']['server_aliases']
    headers node['boxbilling']['headers']
    port '443'
    ssl_key cert.key_path
    ssl_cert cert.cert_path
    allow_override 'All'
    enable true
  end
end

#==============================================================================
# Initialize configuration file
#==============================================================================

# set writable directories
%w{ cache log uploads }.map do |data_dir|
  ::File.join('bb-data', data_dir)
end.concat([
  ::File.join('bb-themes', 'boxbilling', 'assets'),
]).each do |dir|
  directory ::File.join(node['boxbilling']['dir'], dir) do
    owner node['apache']['user']
    group node['apache']['group']
    mode 00750
    action :create
  end
end

# set writable files
[
  ::File.join('bb-themes', 'boxbilling', 'config', 'settings.html'),
  ::File.join('bb-themes', 'boxbilling', 'config', 'settings_data.json'),
].each do |dir|
  file ::File.join(node['boxbilling']['dir'], dir) do
    owner node['apache']['user']
    group node['apache']['group']
    mode 00640
    action :touch
  end
end

# set permissions for configuration file
file 'bb-config.php' do
  path ::File.join(node['boxbilling']['dir'], 'bb-config.php')
  owner node['apache']['user']
  group node['apache']['group']
  mode 00640
  action :create_if_missing
  notifies :restart, 'service[apache2]', :immediately
  notifies :create, 'ruby_block[run boxbilling setup]', :immediately
end

# install BoxBilling
ruby_block 'run boxbilling setup' do
  block do
    self.class.send(:include, ::BoxBilling::RecipeHelpers)

    boxbilling_setup(node['boxbilling']['server_name'], {
      :agree => '1',
      :db_host => node['boxbilling']['config']['db_host'],
      :db_name => node['boxbilling']['config']['db_name'],
      :db_user => node['boxbilling']['config']['db_user'],
      :db_pass => db_password,
      :admin_name => node['boxbilling']['admin']['name'],
      :admin_email => node['boxbilling']['admin']['email'],
      :admin_pass => admin_pass,
      :license => node['boxbilling']['config']['license']
    })
  end
  action :nothing
end

# remove installation dir
directory 'install dir' do
  path ::File.join(node['boxbilling']['dir'], 'install')
  recursive true
  action :delete
end

# create configuration file
template 'bb-config.php' do
  path ::File.join(node['boxbilling']['dir'], 'bb-config.php')
  source 'bb-config.php.erb'
  owner node['apache']['user']
  group node['apache']['group']
  mode 00640
  variables(
    :timezone => node['boxbilling']['config']['timezone'],
    :db_host => node['boxbilling']['config']['db_host'],
    :db_name => node['boxbilling']['config']['db_name'],
    :db_user => node['boxbilling']['config']['db_user'],
    :db_password => db_password,
    :url => node['boxbilling']['config']['url'],
    :license => node['boxbilling']['config']['license'],
    :locale => node['boxbilling']['config']['locale'],
    :sef_urls => node['boxbilling']['config']['sef_urls'],
    :debug => node['boxbilling']['config']['debug']
  )
end

# create api configuration file
template 'api-config.php' do
  path ::File.join(node['boxbilling']['dir'], 'bb-modules', 'mod_api', 'api-config.php')
  source 'api-config.php.erb'
  owner node['apache']['user']
  group node['apache']['group']
  mode 00640
  variables(
    config: node['boxbilling']['api_config']
  )
  only_if { node['boxbilling']['api_config'] }
end

# create htaccess file
template 'boxbilling .htaccess' do
  path ::File.join(node['boxbilling']['dir'], '.htaccess')
  source 'htaccess.erb'
  owner node['apache']['user']
  group node['apache']['group']
  mode 00640
  variables(
    :domain => node['boxbilling']['server_name'].gsub(/^www\./, ''),
    :sef_urls => node['boxbilling']['config']['sef_urls']
  )
end

#==============================================================================
# Enable cron for background jobs
#==============================================================================

if node['boxbilling']['cron_enabled']
  cron 'boxbilling cron' do
    user node['apache']['user']
    minute '*/5'
    command "php -f '#{node['boxbilling']['dir']}/bb-cron.php'"
  end
else
  cron 'boxbilling cron' do
    user node['apache']['user']
    command "php -f '#{node['boxbilling']['dir']}/bb-cron.php'"
    action :delete
  end
end

#==============================================================================
# Install API requirements
#==============================================================================

include_recipe 'boxbilling::api'
