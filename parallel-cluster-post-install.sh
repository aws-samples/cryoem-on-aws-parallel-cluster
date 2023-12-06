#!/bin/bash

# Log script output to a file to reference later
set +e
exec &> >(tee -a "/tmp/post_install.log")

. "/etc/parallelcluster/cfnconfig"

# Get the local commands to run yum and apt
YUM_CMD=$(which yum)
APT_GET_CMD=$(which apt-get)

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
CRYOSPARC_LICENSE_ID=$2
CRYOSPARC_INSTALL_PATH=${3:-/shared/cryosparc}
CUDA_INSTALL_PATH=${4:-/shared/cuda}
CUDA_VERSION=${5:-11.3.1}
CUDA_LONG_VERSION=${6:-11.3.1_465.19.01}
CRYOSPARC_VERSION=${7:-latest}

# Install the AWS CLI
pip3 install --upgrade awscli boto3

yum -y update

# Configure AWS
AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | rev | cut -c 2- | rev)
aws configure set default.region "${AWS_DEFAULT_REGION}"
aws configure set default.output json

# Install CUDA Toolkit
mkdir -p "${CUDA_INSTALL_PATH}"
cd "${CUDA_INSTALL_PATH}" || return
wget "https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/cuda_${CUDA_LONG_VERSION}_linux.run"
sh cuda_"${CUDA_LONG_VERSION}"_linux.run --defaultroot="${CUDA_INSTALL_PATH}" --toolkit --toolkitpath="${CUDA_INSTALL_PATH}"/"${CUDA_VERSION}" --samples --silent
rm cuda_"${CUDA_LONG_VERSION}"_linux.run

# Add CUDA to the path
cat > /etc/profile.d/cuda.sh << 'EOF'
PATH=$PATH:@CUDA_INSTALL_PATH@/@CUDA_VERSION@/bin
EOF
sed -i "s|@CUDA_INSTALL_PATH@|${CUDA_INSTALL_PATH}|g" /etc/profile.d/cuda.sh
sed -i "s|@CUDA_VERSION@|${CUDA_VERSION}|g" /etc/profile.d/cuda.sh
. /etc/profile.d/cuda.sh

# Download cryoSPARC
mkdir -p "${CRYOSPARC_INSTALL_PATH}"
cd "${CRYOSPARC_INSTALL_PATH}" || return
curl -L "https://get.cryosparc.com/download/master-${CRYOSPARC_VERSION}/${CRYOSPARC_LICENSE_ID}" -o cryosparc_master.tar.gz
curl -L "https://get.cryosparc.com/download/worker-${CRYOSPARC_VERSION}/${CRYOSPARC_LICENSE_ID}" -o cryosparc_worker.tar.gz

# Install cryoSPARC master process
tar -xf cryosparc_master.tar.gz
chown -R ${OSUSER}:${OSGROUP} /shared/cryosparc
cd cryosparc_master || return
/bin/su -c "\"${CRYOSPARC_INSTALL_PATH}\"/cryosparc_master/install.sh \
    --license \"${CRYOSPARC_LICENSE_ID}\" \
    --hostname \"${HOSTNAME}\" \
    --dbpath \"${CRYOSPARC_INSTALL_PATH}\"/cryosparc_db \
    --port 45000 \
    --yes" - ${OSUSER}

# Add CryoSPARC to the path
cat > /etc/profile.d/cryosparc.sh << 'EOF'
PATH=$PATH:@CRYOSPARC_INSTALL_PATH@/cryosparc_master/bin
EOF
sed -i "s|@CRYOSPARC_INSTALL_PATH@|${CRYOSPARC_INSTALL_PATH}|g" /etc/profile.d/cryosparc.sh
. /etc/profile.d/cryosparc.sh

echo "export CRYOSPARC_FORCE_HOSTNAME=true" >> "${CRYOSPARC_INSTALL_PATH}"/cryosparc_master/config.sh
echo "export CRYOSPARC_DISABLE_IMPORT_ON_MASTER=true" >> "${CRYOSPARC_INSTALL_PATH}"/cryosparc_master/config.sh

# Install cryoSPARC work package
cd "${CRYOSPARC_INSTALL_PATH}" || return
tar -xf cryosparc_worker.tar.gz
chown -R ${OSUSER}:${OSGROUP} /shared/cryosparc
cd cryosparc_worker || return
/bin/su -c "\"${CRYOSPARC_INSTALL_PATH}\"/cryosparc_worker/install.sh \
    --license \"${CRYOSPARC_LICENSE_ID}\" \
    --cudapath \"${CUDA_INSTALL_PATH}/${CUDA_VERSION}\" \
    --yes" - ${OSUSER}

# Clean up
rm "${CRYOSPARC_INSTALL_PATH}"/*.tar.gz

# Start cluster
/bin/su -c "${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm start" - ${OSUSER}

# Create cluster config files
for PARTITION in gpu-t4 gpu-a100 gpu-v100 cpu gpu-a100-spot
do
    cat > "${CRYOSPARC_INSTALL_PATH}"/cluster_info.json << 'EOF'
{
"qdel_cmd_tpl": "scancel {{ cluster_job_id }}",
"worker_bin_path": "@CRYOSPARC_INSTALL_PATH@/cryosparc_worker/bin/cryosparcw",
"title": "cryosparc-cluster",
"cache_path": "/scratch",
"qinfo_cmd_tpl": "sinfo",
"qsub_cmd_tpl": "sbatch {{ script_path_abs }}",
"qstat_cmd_tpl": "squeue -j {{ cluster_job_id }}",
"send_cmd_tpl": "{{ command }}",
"name": "@PARTITION@"
}
EOF

sed -i "s|@CRYOSPARC_INSTALL_PATH@|${CRYOSPARC_INSTALL_PATH}|g" "${CRYOSPARC_INSTALL_PATH}"/cluster_info.json
sed -i "s|@PARTITION@|${PARTITION}|g" "${CRYOSPARC_INSTALL_PATH}"/cluster_info.json

cat > "${CRYOSPARC_INSTALL_PATH}"/cluster_script.sh << 'EOF'
#!/bin/bash
#SBATCH --job-name=cryosparc_{{ project_uid }}_{{ job_uid }}
#SBATCH --output={{ job_log_path_abs }}
#SBATCH --error={{ job_log_path_abs }}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task={{ num_cpu }}
#SBATCH --gres=gpu:{{ num_gpu }}
#SBATCH --partition=@PARTITION@
{{ run_cmd }}
EOF

sed -i "s|@PARTITION@|${PARTITION}|g" "${CRYOSPARC_INSTALL_PATH}"/cluster_script.sh

# Connect CryoSPARC worker nodes to cluster
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm cluster connect" - ${OSUSER}
 done

# Restart CryoSPARC master
/bin/su -c "cd ${CRYOSPARC_INSTALL_PATH} && ${CRYOSPARC_INSTALL_PATH}/cryosparc_master/bin/cryosparcm restart" - ${OSUSER}
