# encoding: UTF-8
#
# Cookbook Name:: boxbilling
# Recipe:: default
# Author:: Raul Rodriguez (<raul@onddo.com>)
# Author:: Xabier de Zuazo (<xabier@zuazo.org>)
# Copyright:: Copyright (c) 2014-2015 Onddo Labs, SL.
# License:: Apache License, Version 2.0
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

Chef::Recipe.send(:include, Chef::EncryptedAttributesHelpers)
Chef::Recipe.send(:include, ::BoxBilling::RecipeHelpers)
Chef::Resource.send(:include, ::BoxBilling::RecipeHelpers)
recipe = self

#==============================================================================
# Configure PHP
#==============================================================================

node.default['php']['directives']['date.timezone'] =
  node['boxbilling']['config']['timezone']

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

self.encrypted_attributes_enabled = node['boxbilling']['encrypt_attributes']

db_password = encrypted_attribute_write(%w(boxbilling config db_password)) do
  secure_password
end
admin_pass = encrypted_attribute_write(%w(boxbilling admin pass)) do
  secure_password
end
salt = encrypted_attribute_write(%w(boxbilling config salt)) do
  secure_password
end

#==============================================================================
# Install MySQL
#==============================================================================

if %w( localhost 127.0.0.1 ).include?(node['boxbilling']['config']['db_host'])
  include_recipe 'boxbilling::mysql'
  include_recipe 'database::mysql'

  mysql_connection_info = {
    host: 'localhost',
    username: 'root',
    password: encrypted_attribute_read(
      %w( boxbilling mysql server_root_password )
    )
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
# Install Web Server
#==============================================================================

if %w(apache nginx).include?(boxbilling_web_server)
  include_recipe "boxbilling::_#{boxbilling_web_server}"
end

#==============================================================================
# Install PHP
#==============================================================================

include_recipe 'php' # also included in ::_apache

if %w(centos scientific suse amazon oracle).include?(node['platform'])
  include_recipe 'yum-epel' # required by php-mcrypt
end
node['boxbilling']['php_packages'].each do |pkg|
  package pkg
end

#==============================================================================
# Download and extract BoxBilling
#==============================================================================

directory node['boxbilling']['dir'] do
  recursive true
end

basename = "BoxBilling-#{boxbilling_version}.zip"
local_file = ::File.join(Chef::Config[:file_cache_path], basename)

remote_file 'download boxbilling' do
  source node['boxbilling']['download_url']
  path local_file
  action :create_if_missing
end

execute 'extract boxbilling' do
  command "unzip -q -o '#{local_file}' -d '#{node['boxbilling']['dir']}'"
  only_if { recipe.boxbilling_update? || recipe.boxbilling_fresh_install? }
  notifies :run, 'execute[update boxbilling]' if recipe.boxbilling_update?
end

#==============================================================================
# Initialize configuration file
#==============================================================================

themes =
  if boxbilling_lt4?
    %w( boxbilling )
  else
    %w( boxbilling huraga )
  end

# set writable directories
writable_dirs = %w( cache log uploads ).map do |data_dir|
  ::File.join('bb-data', data_dir)
end
writable_dirs += themes.map do |theme_dir|
  ::File.join('bb-themes', theme_dir, 'assets')
end

writable_dirs.each do |dir|
  directory ::File.join(node['boxbilling']['dir'], dir) do
    recursive true
    owner boxbilling_web_user
    group boxbilling_web_group
    mode 00750
    action :create
  end
end

# set writable files
writable_files = themes.map do |theme_dir|
  ::File.join('bb-themes', theme_dir, 'config', 'settings_data.json')
end

writable_files.each do |dir|
  file ::File.join(node['boxbilling']['dir'], dir) do
    owner boxbilling_web_user
    group boxbilling_web_group
    mode 00640
    action :touch
  end
end

# create configuration file
template 'bb-config.php' do
  path ::File.join(node['boxbilling']['dir'], 'bb-config.php')
  if recipe.boxbilling_lt4?
    source 'bb3/bb-config.php.erb'
  else
    source 'bb4/bb-config.php.erb'
  end
  owner boxbilling_web_user
  group boxbilling_web_group
  mode 00640
  variables(
    timezone: node['boxbilling']['config']['timezone'],
    db_host: node['boxbilling']['config']['db_host'],
    db_name: node['boxbilling']['config']['db_name'],
    db_user: node['boxbilling']['config']['db_user'],
    db_password: db_password,
    url: node['boxbilling']['config']['url'],
    license: node['boxbilling']['config']['license'],
    locale: node['boxbilling']['config']['locale'],
    sef_urls: node['boxbilling']['config']['sef_urls'],
    debug: node['boxbilling']['config']['debug'],
    salt: salt,
    api: node['boxbilling']['api_config'] || {}
  )
end

# create api configuration file
template 'api-config.php' do
  path ::File.join(node['boxbilling']['dir'], 'bb-modules', 'mod_api',
                   'api-config.php')
  source 'api-config.php.erb'
  owner boxbilling_web_user
  group boxbilling_web_group
  mode 00640
  variables(
    config: node['boxbilling']['api_config']
  )
  only_if { recipe.boxbilling_lt4? }
end

# create htaccess file
template 'boxbilling .htaccess' do
  path ::File.join(node['boxbilling']['dir'], '.htaccess')
  source 'htaccess.erb'
  owner boxbilling_web_user
  group boxbilling_web_group
  mode 00640
  variables(
    domain: node['boxbilling']['server_name'].gsub(/^www\./, ''),
    sef_urls: node['boxbilling']['config']['sef_urls'],
    boxbilling_lt4: recipe.boxbilling_lt4?
  )
  only_if { boxbilling_web_server == 'apache' }
end

# create database content
mysql_database 'create database content' do
  database_name node['boxbilling']['config']['db_name']
  connection(
    host: node['boxbilling']['config']['db_host'],
    username: node['boxbilling']['config']['db_user'],
    password: db_password
  )
  sql do
    structure_sql =
        ::File.join(node['boxbilling']['dir'], 'install', 'structure.sql')
    content_sql =
        ::File.join(node['boxbilling']['dir'], 'install', 'content.sql')
    sql = ::File.open(structure_sql).read
    ::File.exist?(content_sql) ? sql + ::File.open(content_sql).read : sql
  end
  action :query
  only_if { recipe.boxbilling_database_empty? }
  notifies :restart, "service[#{boxbilling_web_service}]", :immediately
  notifies :create, 'boxbilling_api[create admin user]', :immediately
end

# create admin user
boxbilling_api 'create admin user' do
  path 'guest/staff'
  data(
    email: node['boxbilling']['admin']['email'],
    password: admin_pass
  )
  ignore_failure true
  action :nothing
end

# remove installation dir
directory 'install dir' do
  path ::File.join(node['boxbilling']['dir'], 'install')
  recursive true
  action :delete
end

#==============================================================================
# Enable cron for background jobs
#==============================================================================

if node['boxbilling']['cron_enabled']
  cron 'boxbilling cron' do
    user boxbilling_web_user
    minute '*/5'
    command "php -f '#{node['boxbilling']['dir']}/bb-cron.php'"
  end
else
  cron 'boxbilling cron' do
    user boxbilling_web_user
    command "php -f '#{node['boxbilling']['dir']}/bb-cron.php'"
    action :delete
  end
end

#==============================================================================
# Update BoxBilling
#==============================================================================

execute 'update boxbilling' do
  cwd node['boxbilling']['dir']
  command 'php bb-update.php >> bb-data/log/update.log'
  action :nothing
  notifies :run, 'execute[clear cache]'
end

execute 'clear cache' do
  cache_files = ::File.join(node['boxbilling']['dir'], 'bb-data', 'cache', '*')
  command "rm -rf '#{cache_files}'"
  action :nothing
end

#==============================================================================
# Install API requirements
#==============================================================================

include_recipe 'boxbilling::api'
