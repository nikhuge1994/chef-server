#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2011 Opscode, Inc.
#
# All Rights Reserved

owner = node['private_chef']['user']['username']
group = owner

opscode_org_creator_dir = node['private_chef']['opscode-org-creator']['dir']
opscode_org_creator_etc_dir = File.join(opscode_org_creator_dir, "etc")
opscode_org_creator_log_dir = node['private_chef']['opscode-org-creator']['log_directory']
opscode_org_creator_log_sasl_dir = File.join(node['private_chef']['opscode-org-creator']['log_directory'], "sasl")
[
  opscode_org_creator_dir,
  opscode_org_creator_etc_dir,
  opscode_org_creator_log_dir,
  opscode_org_creator_log_sasl_dir
].each do |dir_name|
  directory dir_name do
    owner owner
    mode node['private_chef']['service_dir_perms']
    recursive true
  end
end

org_creator_config = File.join(opscode_org_creator_etc_dir, "app.config")

template org_creator_config do
  source "opscode-org-creator.config.erb"
  owner owner
  group group
  mode "644"
  variables(node['private_chef']['opscode-org-creator'].to_hash)
  notifies :restart, 'runit_service[opscode-org-creator]' if is_data_master?
end

link "/opt/opscode/embedded/service/opscode-org-creator/rel/org_app/etc/app.config" do
  to org_creator_config
end

link "/opt/opscode/embedded/service/opscode-org-creator/rel/org_app/log" do
  to opscode_org_creator_log_dir
end

template "/opt/opscode/embedded/service/opscode-org-creator/rel/org_app/bin/org_app" do
  source "org_app.erb"
  owner owner
  group group
  mode "0755"
  notifies :restart, 'runit_service[opscode-org-creator]' if is_data_master?
end

component_runit_service "opscode-org-creator"
