#!/bin/bash
URL=""
USERNAME=admin
PASSWORD=admin
LOG_FILE=install.log
SWAP_FILE=swap
SOLACE_HOME=`pwd`
fstype=xfs
#cloud init vars
#array of all available cloud init variables to attempt to detect and pass to docker image creation
#see http://docs.solace.com/Solace-VMR-Set-Up/Initializing-Config-Keys-With-Cloud-Init.htm
cloud_init_vars=( routername nodetype service_semp_port system_scaling_maxconnectioncount configsync_enable redundancy_activestandbyrole redundancy_enable redundancy_group_password redundancy_matelink_connectvia service_redundancy_firstlistenport )

# check if routernames contain any dashes or underscores and abort execution, if that is the case.
if [[ $routername == *"-"* || $routername == *"_"* || $baseroutername == *"-"* || $baseroutername == *"_"* ]]; then
  echo "Dashes and underscores are not allowed in routername(s), aborting..." | tee -a ${LOG_FILE}
  exit -1
fi

#remove all dashes and underscores from routernames
#[ ! -z "${routername}" ] && routername=${routername/-/}
#[ ! -z "${routername}" ] && routername=${routername/_/}
#[ ! -z "${baseroutername}" ] && baseroutername=${baseroutername/-/}
#[ ! -z "${baseroutername}" ] && baseroutername=${baseroutername/_/}

if [ ! -z "${baseroutername}" ]; then
  cloud_init_vars+=( redundancy_group_node_${baseroutername}0_nodetype )
  cloud_init_vars+=( redundancy_group_node_${baseroutername}0_connectvia )
  cloud_init_vars+=( redundancy_group_node_${baseroutername}1_nodetype )
  cloud_init_vars+=( redundancy_group_node_${baseroutername}1_connectvia )
  cloud_init_vars+=( redundancy_group_node_${baseroutername}2_nodetype )
  cloud_init_vars+=( redundancy_group_node_${baseroutername}2_connectvia )
fi


while [[ $# -gt 1 ]]
do
  key="$1"
  case $key in
      -i|--url)
        URL="$2"
        shift # past argument
      ;;
      -l|--logfile)
        LOG_FILE="$2"
        shift # past argument
      ;;
      -p|--password)
        PASSWORD="$2"
        shift # past argument
      ;;
      -u|--username)
        USERNAME="$2"
        shift # past argument
      ;;
      *)
            # unknown option
      ;;
  esac
  shift # past argument or value
done

echo "`date` INFO: Validate we have been passed a VMR url" | tee -a ${LOG_FILE}
# -----------------------------------------------------
if [ -z "$URL" ]
then
      echo "USAGE: vmr-install.sh --url <Solace Docker URL>" | tee -a ${LOG_FILE}
      exit 1
else
      echo "`date` INFO: VMR URL is ${URL}" | tee -a ${LOG_FILE}
fi

echo "`date` INFO:Get repositories up to date" &>> ${LOG_FILE}
# ---------------------------------------

yum -y update &>> ${LOG_FILE}
yum -y install lvm2 &>> ${LOG_FILE}

echo "`date` INFO:Set up Docker Repository" &>> ${LOG_FILE}
# -----------------------------------
tee /etc/yum.repos.d/docker.repo <<-EOF
[dockerrepo]
name=Docker Repository
baseurl=https://yum.dockerproject.org/repo/main/centos/7/
enabled=1
gpgcheck=1
gpgkey=https://yum.dockerproject.org/gpg
EOF
echo "`date` INFO:/etc/yum.repos.d/docker.repo =\n `cat /etc/yum.repos.d/docker.repo`"  &>> ${LOG_FILE}

echo "`date` INFO:Intall Docker" &>> ${LOG_FILE}
# -------------------------
yum -y install docker-engine &>> ${LOG_FILE}

echo "`date` INFO:Configure Docker as a service" | tee -a ${LOG_FILE}
# ----------------------------------------
if [ ! -d /etc/systemd/system/docker.service.d ]; then
  mkdir /etc/systemd/system/docker.service.d | tee -a install.log
  tee /etc/systemd/system/docker.service.d/docker.conf <<-EOF
[Service]
  ExecStart=
  ExecStart=/usr/bin/dockerd --iptables=false --storage-driver=devicemapper
EOF
fi
echo "`date` INFO:/etc/systemd/system/docker.service.d =\n `cat /etc/systemd/system/docker.service.d/docker.conf`" | tee -a ${LOG_FILE}

systemctl enable docker | tee -a ${LOG_FILE}
systemctl start docker | tee -a ${LOG_FILE}

echo "`date` INFO:Set up swap for < 6GB machines" | tee -a ${LOG_FILE}
# -----------------------------------------
cat /proc/meminfo | grep MemTotal
MEM_SIZE=$(cat /proc/meminfo | grep MemTotal | sed 's/[^0-9]*//g') | tee -a ${LOG_FILE}
if [ ${MEM_SIZE} -lt 6087960 ]; then
  echo "`date` WARN: Not enough memory: ${MEM_SIZE} Creating 2GB Swap space" | tee -a ${LOG_FILE}
  mkdir /var/lib/solace | tee -a ${LOG_FILE}
  dd if=/dev/zero of=/var/lib/solace/swap count=2048 bs=1MiB | tee -a ${LOG_FILE}
  mkswap -f /var/lib/solace/swap | tee -a ${LOG_FILE}
  chmod 0600 /var/lib/solace/swap | tee -a ${LOG_FILE}
  swapon -f /var/lib/solace/swap | tee -a ${LOG_FILE}
  grep -q 'solace\/swap' /etc/fstab || sudo sh -c 'echo "/var/lib/solace/swap none swap sw 0 0" >> /etc/fstab' | tee -a ${LOG_FILE}
else
   echo "`date` INFO: Memory size is " ${MEM_SIZE} | tee -a ${LOG_FILE}
fi

echo "`date` Format persistent volume" | tee -a ${LOG_FILE}
sudo mkfs.${fstype} -q /dev/sdb

echo "`date` Pre-Define Solace required infrastructure" | tee -a ${LOG_FILE}
# -----------------------------------------------------
docker volume create --name=jail \
  --opt type=${fstype} --opt device=/dev/sdb | tee -a ${LOG_FILE}
docker volume create --name=var \
  --opt type=${fstype} --opt device=/dev/sdb | tee -a ${LOG_FILE}
docker volume create --name=internalSpool \
  --opt type=${fstype} --opt device=/dev/sdb | tee -a ${LOG_FILE}
docker volume create --name=adbBackup \
  --opt type=${fstype} --opt device=/dev/sdb | tee -a ${LOG_FILE}
docker volume create --name=softAdb \
  --opt type=${fstype} --opt device=/dev/sdb | tee -a ${LOG_FILE}

echo "`date` INFO:Get and load the Solace Docker url" | tee -a ${LOG_FILE}
# ------------------------------------------------

if [ ! -f /tmp/soltr-docker.tar.gz ]; then
  LOOP_COUNT=0
  while [ $LOOP_COUNT -lt 3 ]; do
    wget -O /tmp/soltr-docker.tar.gz -nv -a ${LOG_FILE} ${URL}
    if [ 0 != `echo $?` ]; then
      ((LOOP_COUNT++))
    else
      break
    fi
  done
  if [ ${LOOP_COUNT} == 3 ]; then
    echo "`date` ERROR: Failed to download VMR Docker image exiting"
    exit 1
  fi

  docker load -i /tmp/soltr-docker.tar.gz | tee -a ${LOG_FILE}
  docker images | tee -a ${LOG_FILE}
fi

echo "`date` INFO:Create a Docker instance from Solace Docker image" | tee -a ${LOG_FILE}
# -------------------------------------------------------------
VMR_TYPE=`docker images | grep solace | awk '{print $1}'`
VMR_VERSION=`docker images | grep solace | awk '{print $2}'`
echo "VMR image retrieved is: ${VMR_TYPE}"
echo "VMR version retrieved is: ${VMR_VERSION}"

SOLACE_CLOUD_INIT="--env SERVICE_SSH_PORT=2222"
[ ! -z "${USERNAME}" ] && SOLACE_CLOUD_INIT=${SOLACE_CLOUD_INIT}" --env username_admin_globalaccesslevel=${USERNAME}"
[ ! -z "${PASSWORD}" ] && SOLACE_CLOUD_INIT=${SOLACE_CLOUD_INIT}" --env username_admin_password=${PASSWORD}"
for var_name in "${cloud_init_vars[@]}"; do
  [ ! -z ${!var_name} ] && SOLACE_CLOUD_INIT=${SOLACE_CLOUD_INIT}" --env $var_name=${!var_name}"
done

echo "SOLACE_CLOUD_INIT set to:" | tee -a ${LOG_FILE}
echo ${SOLACE_CLOUD_INIT} | tee -a ${LOG_FILE}

# Set container limits according to scaling tier requirements
if [ ${vmr_scaling} == "100" ]; then
  export shm_size="2g"
  export ulimit_nofile="2448:6592" 
elif [ ${vmr_scaling} == "1000" ]; then
  export shm_size="2g"
  export ulimit_nofile="2448:10192" 
elif [ ${vmr_scaling} == "10000" ]; then
  export shm_size="2g"
  export ulimit_nofile="2448:42192" 
elif [ ${vmr_scaling} == "100000" ]; then
  export shm_size="3.3g"
  export ulimit_nofile="2448:222192" 
elif [ ${vmr_scaling} == "200000" ]; then
  export shm_size="3.3g"
  export ulimit_nofile="2448:422192" 
else
  export shm_size="2g"
  export ulimit_nofile="2448:6592" 
fi

docker create \
   --uts=host \
   --shm-size ${shm_size} \
   --ulimit core=-1 \
   --ulimit memlock=-1 \
   --ulimit nofile=${ulimit_nofile} \
   --publish 80:80 \
   --publish 443:443 \
   --publish 8080:8080 \
   --publish 9443:9443 \
   --publish 55555:55555 \
   --publish 55003:55003 \
   --publish 55443:55443 \
   --publish 8741:8741 \
   --publish 8300:8300 \
   --publish 8301:8301 \
   --publish 8302:8302 \
   --cap-add=IPC_LOCK \
   --cap-add=SYS_NICE \
   --net=host \
   --restart=always \
   -v jail:/usr/sw/jail \
   -v var:/usr/sw/var \
   -v internalSpool:/usr/sw/internalSpool \
   -v adbBackup:/usr/sw/adb \
   -v softAdb:/usr/sw/internalSpool/softAdb \
   ${SOLACE_CLOUD_INIT} \
   --name=solace ${VMR_TYPE}:${VMR_VERSION} | tee -a ${LOG_FILE}

#
docker ps -a | tee -a ${LOG_FILE}

echo "`date` INFO:Construct systemd for VMR" | tee -a ${LOG_FILE}
# --------------------------------------
tee /etc/systemd/system/solace-docker-vmr.service <<-EOF
[Unit]
  Description=solace-docker-vmr
  Requires=docker.service
  After=docker.service
[Service]
  Restart=always
  ExecStart=/usr/bin/docker start -a solace
  ExecStop=/usr/bin/docker stop solace
[Install]
  WantedBy=default.target
EOF
echo "`date` INFO:/etc/systemd/system/solace-docker-vmr.service =/n `cat /etc/systemd/system/solace-docker-vmr.service`" | tee -a ${LOG_FILE}

echo "`date` INFO: Start the VMR"
# --------------------------
systemctl daemon-reload | tee -a ${LOG_FILE}
systemctl enable solace-docker-vmr | tee -a ${LOG_FILE}
systemctl start solace-docker-vmr | tee -a ${LOG_FILE}

echo "adding firewall rules..."
iptables -w -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 8080 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 9443 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 55555 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 55003 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 55443 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 8741 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 8300 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 8301 -j ACCEPT
iptables -w -A INPUT -p tcp -m tcp --dport 8302 -j ACCEPT

echo "`date` INFO: Install is complete"
