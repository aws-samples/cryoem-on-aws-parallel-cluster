#!/bin/bash

## Args: 
# argv1 - CRYOSPARC_LICENSE_ID (required)
# argv2 - CRYOSPARC_INSTALL_PATH (default: /shared/cryosparc)
# argv3 - CUDA_INSTALL_PATH (default: /shared/cuda)
# argv4 - CUDA_VERSION (default 11.3.1)
# argv5 - CUDA_LONG_VERSION (default: 11.3.1_465.19.01)
# argv6 - PROJECT_DATA_PATH (default: /fsx)

set +e 
# Log script output to a file to reference later
exec &> >(tee -a "/tmp/post_install.log")

. "/etc/parallelcluster/cfnconfig"

# Get the local commands to run yum and apt
YUM_CMD=$(which yum || echo "")
APT_GET_CMD=$(which apt-get || echo "")

# If we have yum installed, use it to install prerequisites. If not, use apt
if [[ -n $YUM_CMD ]]; then
    wget https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm -P /tmp
    yum install -y /tmp/epel-release-latest-7.noarch.rpm

    yum install -y perl-Switch python3 python3-pip links
    user_test=$(getent passwd ec2-user)
    if [[ -n "${user_test}" ]]; then
        OSUSER=ec2-user
        OSGROUP=ec2-user
    else
        OSUSER=centos
        OSGROUP=centos
    fi
elif [[ -n $APT_GET_CMD ]]; then
    apt-get update
    apt-get install -y libswitch-perl python3 python3-pip links
    OSUSER=ubuntu
    OSGROUP=ubuntu
else
    # If we don't have yum or apt, we couldn't install the prerequisites, so exit
    echo "error can't install package $PACKAGE"
    exit 1;
fi

# Get the cryoSPARC license ID, optional path, and optional versions from the script arguments
CRYOSPARC_LICENSE_ID=$1
CRYOSPARC_INSTALL_PATH=${2:-/shared/cryosparc}
CUDA_INSTALL_PATH=${3:-/shared/cuda}
CUDA_VERSION=${4:-11.3.1}
CUDA_LONG_VERSION=${5:-11.3.1_465.19.01}
PROJECT_DATA_PATH=${6:-/fsx}

/bin/su -c "mkdir -p ${PROJECT_DATA_PATH}/validate-lanes" - ${OSUSER} || chmod 777 ${PROJECT_DATA_PATH}

# Install the AWS CLI
pip3 install --upgrade awscli boto3

set -e

#yum -y update

# Configure AWS
AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | rev | cut -c 2- | rev)
aws configure set default.region "${AWS_DEFAULT_REGION}"
aws configure set default.output json

if [[ "$(cat ${CUDA_INSTALL_PATH}/installed_cuda_version.log 2>/dev/null )" == "${CUDA_LONG_VERSION}" ]]; then 
  echo "Matched previous CUDA version. Using old installer ${CUDA_LONG_VERSION}"
else 
  echo "Installing new version of CUDA ${CUDA_LONG_VERSION} (this may break cryosparc install)"
  # Install CUDA Toolkit
  mkdir -p "${CUDA_INSTALL_PATH}"
  mkdir -p "${CUDA_INSTALL_PATH}_tmp"
  cd "${CUDA_INSTALL_PATH}" || return
  wget "https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/cuda_${CUDA_LONG_VERSION}_linux.run"
fi
echo "${CUDA_LONG_VERSION}" > ${CUDA_INSTALL_PATH}/installed_cuda_version.log

sh ${CUDA_INSTALL_PATH}/cuda_"${CUDA_LONG_VERSION}"_linux.run --tmpdir="${CUDA_INSTALL_PATH}_tmp" --defaultroot="${CUDA_INSTALL_PATH}" --toolkit --toolkitpath="${CUDA_INSTALL_PATH}"/"${CUDA_VERSION}" --samples --silent
#rm cuda_"${CUDA_LONG_VERSION}"_linux.run

# Add CUDA to the path
cat > /etc/profile.d/cuda.sh << 'EOF'
PATH=$PATH:@CUDA_INSTALL_PATH@/@CUDA_VERSION@/bin
EOF
sed -i "s|@CUDA_INSTALL_PATH@|${CUDA_INSTALL_PATH}|g" /etc/profile.d/cuda.sh
sed -i "s|@CUDA_VERSION@|${CUDA_VERSION}|g" /etc/profile.d/cuda.sh
. /etc/profile.d/cuda.sh

# Add CryoSPARC to the path
cat > /etc/profile.d/cryosparc.sh << 'EOF'
PATH=$PATH:@CRYOSPARC_INSTALL_PATH@/cryosparc_master/bin
EOF
sed -i "s|@CRYOSPARC_INSTALL_PATH@|${CRYOSPARC_INSTALL_PATH}|g" /etc/profile.d/cryosparc.sh
. /etc/profile.d/cryosparc.sh

# Condition checks whether /etc/profile.d/cryosparc.sh activated previously install cryosparc
# if not, then we install cryosparc
if [ ! -x "$(command -v "cryosparcm")" ]; then
  echo "Installing fresh CryoSPARC"

  # Download cryoSPARC
  mkdir -p "${CRYOSPARC_INSTALL_PATH}"
  # Need to make sure OSUSER can write to this path
  chown ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}

  cd "${CRYOSPARC_INSTALL_PATH}" || return
  [ -f "${CRYOSPARC_INSTALL_PATH}/cryosparc_master.tar.gz" ] || curl -L "https://get.cryosparc.com/download/master-v4.0.3/${CRYOSPARC_LICENSE_ID}" -o cryosparc_master.tar.gz
  [ -f "${CRYOSPARC_INSTALL_PATH}/cryosparc_worker.tar.gz" ] || curl -L "https://get.cryosparc.com/download/worker-v4.0.3/${CRYOSPARC_LICENSE_ID}" -o cryosparc_worker.tar.gz
  
  # Install cryoSPARC main process
  tar -xf cryosparc_master.tar.gz

  # cryosparc untars with ownership: 1001:1001 by default. re-align permissions to OSUSER
  chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/cryosparc_master

  # Basic configuration for install
  export CRYOSPARC_FORCE_USER=true
  export CRYOSPARC_FORCE_HOSTNAME=true
  export CRYOSPARC_DISABLE_IMPORT_ON_MASTER=true

  # Install Main
  /bin/su -c "cd ${CRYOSPARC_INSTALL_PATH}/cryosparc_master && ./install.sh --license "${CRYOSPARC_LICENSE_ID}" \
      --hostname "${HOSTNAME}" \
      --dbpath "${CRYOSPARC_INSTALL_PATH}"/cryosparc_db \
      --port 45000 \
      --allowroot \
      --yes" - $OSUSER
  
  # Enforce configuration long-term
  echo "export CRYOSPARC_FORCE_USER=true" >> "${CRYOSPARC_INSTALL_PATH}"/cryosparc_master/config.sh
  echo "export CRYOSPARC_FORCE_HOSTNAME=true" >> "${CRYOSPARC_INSTALL_PATH}"/cryosparc_master/config.sh
  echo "export CRYOSPARC_DISABLE_IMPORT_ON_MASTER=true" >> "${CRYOSPARC_INSTALL_PATH}"/cryosparc_master/config.sh

  # Ownership of this path determines how cryosparc is started
  chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/cryosparc_master

  # Start cryoSPARC main package 
  /bin/su -c "${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm start" - ${OSUSER}

  # Install cryoSPARC worker package
  cd "${CRYOSPARC_INSTALL_PATH}" || return
  tar -xf cryosparc_worker.tar.gz
  chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/cryosparc_worker
  /bin/su -c "cd ${CRYOSPARC_INSTALL_PATH}/cryosparc_worker && ./install.sh --license "${CRYOSPARC_LICENSE_ID}" \
      --cudapath "${CUDA_INSTALL_PATH}/${CUDA_VERSION}" \
      --yes" - $OSUSER
  
  #rm "${CRYOSPARC_INSTALL_PATH}"/*.tar.gz
  
  # Once again, re-align permissions
  chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/cryosparc_worker

  # Start cryoSPARC main package 
  /bin/su -c "${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm stop" - ${OSUSER}

else 
  echo "Restoring CryoSPARC with updated Hostname and refreshing paritition connections"

  # Stop any running cryosparc
  systemctl stop cryosparc-supervisor.service || /bin/su -c "${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm stop || echo \"Nothing Running\" " - ${OSUSER}

  # Update hostname to new main
  sed -i "s/^\(.*CRYOSPARC_MASTER_HOSTNAME=\"\).*\"/\1$HOSTNAME\"/g" ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/config.sh

  # Once again, re-align permissions for proper start 
  chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/cryosparc_master
fi
  
# Start cluster
#/bin/su -c "${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm start" - ${OSUSER}

# Confirm Restart CryoSPARC main
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm restart" - ${OSUSER} 

# Stop server in anticipation for service
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm stop" - ${OSUSER} 

# Create the CryoSPARC Systemd service and start at Boot
eval $(cryosparcm env)
cd "${CRYOSPARC_INSTALL_PATH}/cryosparc_master/systemd" || return
# Final alignment on permissions
chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/systemd
env "CRYOSPARC_ROOT_DIR=$CRYOSPARC_ROOT_DIR" ./install_services.sh
systemctl start cryosparc-supervisor.service
systemctl restart cryosparc-supervisor.service
systemctl enable cryosparc-supervisor.service


# Be tolerant of errors on partitions; we can always come back through admin panel and add later
set +e 
echo "Partitions:"
/opt/slurm/bin/scontrol show partitions

echo "Beginning"
# Create cluster config files
for PARTITION in $( /opt/slurm/bin/scontrol show partitions | grep PartitionName | cut -d'=' -f 2 )
do 
  if [ ! -f "${CRYOSPARC_INSTALL_PATH}/${PARTITION}/cluster_info.json" ]; then
    echo "Connecting New Partition: ${PARTITION}"
    case $PARTITION in
    	gpu-t4*)
	    echo "T4 GPU: $PARTITION"
            PARTITION_CACHE_PATH="/scratch"
            PARTITION_CACHE_RESERVE=10000
            PARTITION_CACHE_QUOTA=800000
            PARTITION_RAM_GB_MULTIPLIER=2.0
            SBATCH_EXTRA="#SBATCH --gres=gpu:{{ num_gpu }}"
        ;;
     	gpu-l4*)
	    echo "L4 GPU: $PARTITION"
            PARTITION_CACHE_PATH="/scratch"
            PARTITION_CACHE_RESERVE=10000
            PARTITION_CACHE_QUOTA=800000
            PARTITION_RAM_GB_MULTIPLIER=2.0
            SBATCH_EXTRA="#SBATCH --gres=gpu:{{ num_gpu }}"
        ;;
        gpu-a100*)
	    echo "A100 GPU: $PARTITION"
            PARTITION_CACHE_PATH="/scratch"
            PARTITION_CACHE_RESERVE=10000
            PARTITION_CACHE_QUOTA=800000
            PARTITION_RAM_GB_MULTIPLIER=2.0
            SBATCH_EXTRA="#SBATCH --gres=gpu:{{ num_gpu }}"
        ;;
        cpu*)
	    echo "X86: $PARTITION"
            PARTITION_CACHE_PATH="/scratch"
            PARTITION_CACHE_RESERVE=10000
            PARTITION_CACHE_QUOTA=800000
            PARTITION_RAM_GB_MULTIPLIER=2.0
            SBATCH_EXTRA="#SBATCH --gres=gpu:{{ num_gpu }}"
        ;;
        gpu-a100-spot*)
	    echo "A100 GPU SPOT: $PARTITION"
            PARTITION_CACHE_PATH="/scratch"
            PARTITION_CACHE_RESERVE=10000
            PARTITION_CACHE_QUOTA=800000
            PARTITION_RAM_GB_MULTIPLIER=2.0
            SBATCH_EXTRA="#SBATCH --gres=gpu:{{ num_gpu }}"
        ;;
    esac

    mkdir -p "${CRYOSPARC_INSTALL_PATH}/${PARTITION}"
    cat > "${CRYOSPARC_INSTALL_PATH}/${PARTITION}"/cluster_info.json << EOF
{
"qdel_cmd_tpl": "/opt/slurm/bin/scancel {{ cluster_job_id }}",
"worker_bin_path": "${CRYOSPARC_INSTALL_PATH}/cryosparc_worker/bin/cryosparcw",
"title": "cryosparc-cluster",
"cache_path": "${PARTITION_CACHE_PATH}",
"cache_reserve_mb": ${PARTITION_CACHE_RESERVE},
"cache_quota_mb": ${PARTITION_CACHE_QUOTA},
"qinfo_cmd_tpl": "/opt/slurm/bin/sinfo --format='%.42N %.5D %.15P %.8T %.15C %.5c %.10z %.10m %.15G %.9d %40E'",
"qsub_cmd_tpl": "/opt/slurm/bin/sbatch {{ script_path_abs }}",
"qstat_cmd_tpl": "/opt/slurm/bin/squeue -j {{ cluster_job_id }}",
"send_cmd_tpl": "{{ command }}",
"name": "${PARTITION}"
}
EOF
#sinfo --format='%.8N %.6D %.10P %.6T %.14C %.5c %.6z %.7m %.7G %.9d %20E'

    cat > "${CRYOSPARC_INSTALL_PATH}/${PARTITION}"/cluster_script.sh << EOF
#!/usr/bin/env bash
#### cryoSPARC cluster submission script template for SLURM
## Available variables:
## {{ run_cmd }}            - the complete command string to run the job
## {{ num_cpu }}            - the number of CPUs needed
## {{ num_gpu }}            - the number of GPUs needed.
##                            Note: the code will use this many GPUs starting from dev id 0
##                                  the cluster scheduler or this script have the responsibility
##                                  of setting CUDA_VISIBLE_DEVICES so that the job code ends up
##                                  using the correct cluster-allocated GPUs.
## {{ ram_gb }}             - the amount of RAM needed in GB
## {{ job_dir_abs }}        - absolute path to the job directory
## {{ project_dir_abs }}    - absolute path to the project dir
## {{ job_log_path_abs }}   - absolute path to the log file for the job
## {{ worker_bin_path }}    - absolute path to the cryosparc worker command
## {{ run_args }}           - arguments to be passed to cryosparcw run
## {{ project_uid }}        - uid of the project
## {{ job_uid }}            - uid of the job
## {{ job_creator }}        - name of the user that created the job (may contain spaces)
## {{ cryosparc_username }} - cryosparc username of the user that created the job (usually an email)
## {{ job_type }}           - CryoSPARC job type
##
## What follows is a simple SLURM script:

#SBATCH --job-name cryosparc_{{ project_uid }}_{{ job_uid }}
#SBATCH -n {{ num_cpu }}
${SBATCH_EXTRA}
#SBATCH --partition=${PARTITION}
#SBATCH --mem={{ (ram_gb|float * ram_gb_multiplier|float)|int }}G
#SBATCH --output={{ job_log_path_abs }}
#SBATCH --error={{ job_log_path_abs }}

{{ run_cmd }}
EOF

    #sed -i "s|@PARTITION@|${PARTITION}|g" "${CRYOSPARC_INSTALL_PATH}"/cluster_script.sh
    chown -R ${OSUSER}:${OSGROUP} ${CRYOSPARC_INSTALL_PATH}/${PARTITION}

    # Connect CryoSPARC worker nodes to cluster
    /bin/su -c "cd ${CRYOSPARC_INSTALL_PATH}/${PARTITION} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cluster connect" - ${OSUSER}

    # Individually apply custom_vars
    CLICMD=$(cat << EOT
set_scheduler_target_property(hostname="${PARTITION}",key="custom_vars",value={"ram_gb_multiplier": "${PARTITION_RAM_GB_MULTIPLIER}"})
EOT
)
    /bin/su -c "cd ${CRYOSPARC_INSTALL_PATH}/${PARTITION} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cli '$CLICMD' " - ${OSUSER}
    echo "Done connecting $PARTITION"
  else
    echo "Partition already connected to CryoSPARC: ${PARTITION}"
  fi

done
set -e

# VALIDATE CRYOSPARC
#echo "Validating lanes"
#/bin/su -c "mkdir -p ${PROJECT_DATA_PATH}/validate-lanes" - ${OSUSER}
#/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cluster validate cpu --projects_dir ${PROJECT_DATA_PATH}/validate-lanes" - ${OSUSER}
#/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cluster validate gpu-t4 --projects_dir ${PROJECT_DATA_PATH}/validate-lanes" - ${OSUSER}
#/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cluster validate gpu-a100 --projects_dir ${PROJECT_DATA_PATH}/validate-lanes" - ${OSUSER}
#/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cluster validate gpu-v100 --projects_dir ${PROJECT_DATA_PATH}/validate-lanes" - ${OSUSER}
echo "Enabling All-or-Nothing"
echo "all_or_nothing_batch = True" >> /etc/parallelcluster/slurm_plugin/parallelcluster_slurm_resume.conf

set +e 
echo "Attempting last attempt to update to latest version...if this fails, you may need to manually update head and compute" 

# Update to latest version of CryoSPARC
systemctl stop cryosparc-supervisor.service
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm update" - ${OSUSER}
# Depends on cryosparcm update to pull latest worker to cryosparc_master dir. 
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && cp ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/cryosparc_worker.tar.gz ${CRYOSPARC_INSTALL_PATH}/cryosparc_worker/cryosparc_worker.tar.gz" - ${OSUSER}
# Only update workers if they were installed (continue otherwise)
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_worker/bin/cryosparcw update" - ${OSUSER} || true 
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm stop" - ${OSUSER}
systemctl start cryosparc-supervisor.service
set -e 

echo "CryoSPARC setup complete"
