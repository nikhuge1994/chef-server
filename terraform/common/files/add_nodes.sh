#!/bin/bash

set -evx

echo -e '\nBEGIN ADD NODES\n'

echo -e '\nBEGIN INSTALL HAB\n'

curl https://raw.githubusercontent.com/habitat-sh/habitat/master/components/hab/install.sh | sudo bash

echo -e '\nBEGIN INSTALL and BINLINK chef-load\n'

hab pkg install chef/chef-load -bf

echo -e '\nBEGIN NODE GENERATION \n'

chef-load generate --config /tmp/chef-load.toml -n 100 --node_name_prefix chef-node

echo -e '\nEND ADD NODES\n'
