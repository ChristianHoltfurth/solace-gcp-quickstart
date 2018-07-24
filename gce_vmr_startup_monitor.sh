#!/bin/bash
##Select one of the three below to configure your monitor/primary/backup node
export vmr_role=monitor
#export vmr_role=primary
#export vmr_role=backup
##General section - edit as required
export baseroutername=rhelvmr
export vmradminpass=soladmingce
export vmr_scaling=1000 #1000, 10000 or 100000
export monitor_ip=${baseroutername}0
export primary_ip=${baseroutername}1
export backup_ip=${baseroutername}2
export redundancy_enable=yes
export redundancy_group_password=mysolgrouppass
##General section - no editing required
export redundancy_group_node_${baseroutername}0_connectvia=${monitor_ip}
export redundancy_group_node_${baseroutername}0_nodetype=monitoring
export redundancy_group_node_${baseroutername}1_connectvia=${primary_ip}
export redundancy_group_node_${baseroutername}1_nodetype=message_routing
export redundancy_group_node_${baseroutername}2_connectvia=${backup_ip}
export redundancy_group_node_${baseroutername}2_nodetype=message_routing
if [ "${vmr_role}" == "monitor" ]; then
##values for your monitor node
  export nodetype=monitoring
  export routername=${baseroutername}0
elif [ "${vmr_role}" == "primary" ]; then
##values for your primary node
  export nodetype=message_routing
  export routername=${baseroutername}1
  export system_scaling_maxconnectioncount=${vmr_scaling}
  export configsync_enable=yes
  export redundancy_activestandbyrole=primary
  export redundancy_matelink_connectvia=${backup_ip}
elif [ "${vmr_role}" == "backup" ]; then
##values for your backup node
  export nodetype=message_routing
  export routername=${baseroutername}2
  export configsync_enable=yes
  export redundancy_activestandbyrole=backup
  export system_scaling_maxconnectioncount=${vmr_scaling}
  export redundancy_matelink_connectvia=${primary_ip}
else
  echo "unknown role or singleton selected, disabling redundancy"
  export redundancy_enable=no
  export configsync_enable=no
  unset redundancy_group_node_${baseroutername}0_connectvia
  unset redundancy_group_node_${baseroutername}0_nodetype
  unset redundancy_group_node_${baseroutername}1_connectvia
  unset redundancy_group_node_${baseroutername}1_nodetype
  unset redundancy_group_node_${baseroutername}2_connectvia
  unset redundancy_group_node_${baseroutername}2_nodetype
fi
###
if [ ! -d /var/lib/solace ]; then
  echo "Done, starting install..."
  echo "creating directory..."
  mkdir /var/lib/solace
  cd /var/lib/solace
  yum install -y wget
  LOOP_COUNT=0
  echo "downloading VMR install script..."
  while [ $LOOP_COUNT -lt 3 ]; do
    wget https://raw.githubusercontent.com/ChristianHoltfurth/solace-gcp-quickstart/master/vmr-install.sh
    if [ 0 != `echo $?` ]; then
      ((LOOP_COUNT++))
    else
      break
    fi
  done
  if [ ${LOOP_COUNT} == 3 ]; then
    echo "`date` ERROR: Failed to download initial install script, exiting"
    exit 1
  fi
  chmod +x /var/lib/solace/vmr-install.sh
  bash /var/lib/solace/vmr-install.sh -i https://products.solace.com/download/PUBSUB_DOCKER_EVAL -p ${vmradminpass}
fi
