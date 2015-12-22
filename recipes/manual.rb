#
# Cookbook Name:: haproxy
# Recipe:: manual
#
# Copyright 2014, Heavy Water Operations, LLC.
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

conf = node['haproxy']

include_recipe "haproxy::install_#{conf['install_method']}"

cookbook_file "/etc/default/haproxy" do
  source "haproxy-default"
  owner "root"
  group "root"
  mode 00644
  notifies :restart, "service[haproxy]", :delayed
end

ssl_string  = ""
ssl_string << " ssl crt #{ conf['ssl_termination_pem_file'] }" if conf['ssl_termination']

if conf['enable_admin']
  admin = conf['admin']
  haproxy_lb "admin_local" do
    bind "#{admin['address_bind']}:#{admin['port']}"
    mode 'http'
    params(admin['options'])
  end

  if conf['enable_ssl'] || conf['ssl_termination']

    haproxy_lb 'admin' do
      type 'frontend'
      mode 'http'
      params({
        'http-request' => 'add-header X-Proto https if { ssl_fc }',
        'bind' => "#{conf['ssl_incoming_address']}:#{conf['admin']['port']}#{ ssl_string }",
        'reqadd' => 'X-Forwarded-Proto:\ https',
        'default_backend' => "admin"
      })
    end

    stats_arr = ['enable', 'hide-version', 'realm Haproxy\ Statistics', "auth #{conf['admin']['username']}:#{conf['admin']['password']}"]

    haproxy_lb "admin" do
      type 'backend'
      stats stats_arr
      params(conf['admin']['options'])
    end
  end
end

member_max_conn = conf['member_max_connections']
member_weight = conf['member_weight']

if conf['enable_default_http']
  haproxy_lb 'http' do
    type 'frontend'
    params({
      'maxconn' => conf['frontend_max_connections'],
      'bind' => "#{conf['incoming_address']}:#{conf['incoming_port']}",
      'default_backend' => 'servers-http'
    })
  end
elsif conf['enable_ssl'] || conf['ssl_termination']

  haproxy_lb 'https' do
    type 'frontend'
    mode 'http'
    bind "#{conf['incoming_address']}:#{conf['incoming_port']}"
    params({
      'redirect' => 'scheme https code 301 if !{ ssl_fc }',
      'maxconn' => conf['frontend_ssl_max_connections'],
      'http-request' => 'add-header X-Proto https if { ssl_fc }',
      'bind' => "#{conf['ssl_incoming_address']}:#{conf['ssl_incoming_port']}#{ ssl_string }",
      'reqadd' => 'X-Forwarded-Proto:\ https',
      'default_backend' => "servers-#{conf['mode']}"
    })
  end
end

if conf['enable_default_http'] || conf['ssl_termination']
  member_port = conf['member_port']
  pool = []
  pool << "option httpchk #{conf['httpchk']}" if conf['httpchk']
  servers = conf['members'].map do |member|
    "#{member['hostname']} #{member['ipaddress']}:#{member['port'] || member_port} weight #{member['weight'] || member_weight} maxconn #{member['max_connections'] || member_max_conn} check"
  end
  haproxy_lb "servers-#{conf['mode']}" do
    type 'backend'
    servers servers
    params pool
  end

elsif conf['enable_ssl']
  ssl_member_port = conf['ssl_member_port']
  pool = ['option ssl-hello-chk']
  pool << "option httpchk #{conf['ssl_httpchk']}" if conf['ssl_httpchk']
  servers = conf['members'].map do |member|
    "#{member['hostname']} #{member['ipaddress']}:#{member['ssl_port'] || ssl_member_port} weight #{member['weight'] || member_weight} maxconn #{member['max_connections'] || member_max_conn} check"
  end
  haproxy_lb "servers-#{conf['mode']}" do
    type 'backend'
    mode conf['mode']
    servers servers
    params pool
  end
end

# Re-default user/group to account for role/recipe overrides
node.default['haproxy']['stats_socket_user'] = conf['user']
node.default['haproxy']['stats_socket_group'] = conf['group']


unless conf['global_options'].is_a?(Hash)
  Chef::Log.error("Global options needs to be a Hash of the format: { 'option' => 'value' }. Please set conf['global_options'] accordingly.")
end

haproxy_config "Create haproxy.cfg" do
  notifies :restart, "service[haproxy]", :delayed
end
