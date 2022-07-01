# Cryo-EM on AWS ParallelCluster

This GitHub repository contains resources to deploy the solution described in the [HPC Blog for CryoSparc on AWS ParallelCLuster|<blog-url>]

![Architecture](images/CryoSPARC-on-AWSParallelCluster.png)

This solution includes the following resources:
* YAML configuration file for AWS ParallelCluster
* Post-install script to install CryoSPARC
* Policy file that allows automatic data export back to FSx

There are several prerequisites to fulfill before deploying this solution. You'll use the outputs of these prerequisites to fill in the values <between angle brackets> in the AWS ParallelCluster configuration file.

## Prerequisite: CryoSPARC license from Structura

First, you’ll need to ![request a license from Structura](https://cryosparc.com/download). It can take a day or two to obtain the license, so request it before you get started. 

Paste the license id as an input to the ParallelCluster configuration file.

## Prerequisites: Networking, Security, and Compute Availability

A typical use of a default VPC has public and private subnets balanced across multiple Availability Zones (AZs). However, HPC clusters (like ParallelCluster) usually prefer a single-AZ so they can keep communication latency low and use Cluster Placement Groups. For the compute nodes, you can create a large private subnet with a relatively large number of IP addresses. Then, you can create a public subnet with minimal IP addresses, since it will only contain the head node.  

HPC EC2 instances like the ![P4d family](https://aws.amazon.com/ec2/instance-types/p4/) aren’t available in every AZ. That means we need to determine which AZ in a given Region has all the compute families we need. We can do that with the ![AWS CLI](https://aws.amazon.com/cli/) ![describe-instance-type-offerings](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-type-offerings.html) command. The easiest way to do this is to just below into ![CloudShell](https://us-west-2.console.aws.amazon.com/cloudshell), which provides a shell environment ready to issue AWS CLI commands in a few minutes. After the CloudShell environment is provisioned, copy and paste the text into the shell, and provide your desired region in the bracketed placeholder.


```bash
aws ec2 describe-instance-type-offerings \
--location-type availability-zone \
--region <region> \
--filters Name=instance-type,Values=p4d.24xlarge \
--query "InstanceTypeOfferings[*].Location" \
--output text
```

Using the output showing which AZs have the compute instances you need, you can create your VPC and subnets. Populate the <REGION>, <SMALL-PUBLIC-SUBNET-ID>, and <LARGE-PRIVATE-SUBNET-ID> inputs in the configuration file.

You’ll also need to create an EC2 SSH key pair so that you can SSH into the head node once your cluster has been deployed, and populate the <EC2-KEY-PAIR-NAME> input in the configuration file.

## Prerequisite: Data Transfer 

Create a new S3 bucket for your input data. Replace the <S3-BUCKET> placeholders in the ParallelCluster configuration file with the name of your bucket.

The data transfer mechanism to move data from instruments into S3 depends on the connectivity in the lab environment and the volume of data to be transferred. We recommend ![AWS DataSync](https://aws.amazon.com/datasync/), which easily automates secure data transfer from on-premises into the cloud with minimal development effort. ![Storage Gateway File Gateway](https://aws.amazon.com/storagegateway/file/) is another viable option, especially if lab connectivity is limited or continued two-way access from on-premises to the transferred data sets is required. Both DataSync and Storage Gateway ![can be bandwidth throttled](https://docs.aws.amazon.com/datasync/latest/userguide/working-with-task-executions.html) to protect non-HPC business-critical network constraints. 

Alternatively, you can use the ![AWS S3 CLI](https://docs.aws.amazon.com/cli/latest/reference/s3/) to transfer individual files, or use partner solution to get started quickly.


## Prerequisite: IAM Permissions

While ParallelCluster creates its own least-privilege roles and policies by default, many Enterprises limit their AWS account users’ access to IAM actions. ParallelCluster also supports using or adding pre-created IAM resources, which you can request to be pre-created for you by your IT services team. The required permissions and roles are ![provided in the ParallelCluster documentation](https://docs.aws.amazon.com/parallelcluster/latest/ug/iam-roles-in-parallelcluster-v3.html) and use the parallel-cluster-cryosparc-custom-roles.yaml, which has additional IAM fields, to help you get started quickly.

You can provision your FSx file system as persistent or scratch. Persistent file systems can automatically export data back to Amazon S3, but scratch file systems don’t. The example in this GitHub repo uses scratch, since it is provisioning a benchmark environment rather than a production environment. If you want to integrate a data export task into the ParallelCluster job scheduler so that every time a job completes, a data export is run transparently in the background, this requires additional IAM Policy statements to be attached to the instance profile of the head node. The policy is in the file FSxLustreDataRepoTasksPolicy.yml. Make sure the role that you’re using to execute your ParallelCluster provisioning includes this policy if you intend to run the export.

## Let's build!

### Upload artifacts to S3

Upload the parallel-cluster-cryosparc.yaml configuration file (with all of the <placeholders> filled in) and the parallel-cluster-post-install.sh script to your S3 bucket.

### Environment
We recommend using ![AWS CloudShell](https://aws.amazon.com/cloudshell/) to quickly set up an environment that already has the credentials and command line tools you'll need to get started. ![The AWS CloudShell Console](https://console.aws.amazon.com/cloudshell) already has credentials to your AWS account, the AWS CLI, and Python installed. If you're not using CloudShell, make sure you have these installed in your local environment before continuing.

### Install ParallelCluster
Follow the instructions in the ![AWS ParallelCluster documentation](https://docs.aws.amazon.com/parallelcluster/latest/ug/install-v3-virtual-environment.html) to install AWS ParallelCluster into a virtual environment

### Copy the ParallelCluster config file from S3
Copy config file from S3

```bash
aws s3api get-object --bucket cryosparc-parallel-cluster --key parallel-cluster-cryosparc.yaml parallel-cluster-cryosparc.yaml
```

If you were starting from scratch, you would run pcluster config to generate a config file. For this solution, we're providing that config file for you, so you can create the cluster immediately using the create-cluster command.

```bash
pcluster create-cluster --cluster-name cryosparc-cluster --cluster-configuration parallel-cluster-cryosparc.yaml 
```

Check the status of the cluster creation using the pcluster CLI or using the ![AWS CloudFormation console](https://console.aws.amazon.com/cloudformation/)

```bash
pcluster describe-cluster --cluster-name cryosparc-cluster
```

Hint: If you're having trouble with the stack rolling back due to a failure provisioning the head node first verify that your public subnet automatically creates Ipv4 addresses and allows DNS. If you're still having issues, re-create the cluster using the ```--rollback-on-failure false``` flag. This will keep CloudFormation from immediately de-provisioning the resources in the cluster. Search for "HeadNode" in the list of Stack resources. Click on the instance ID link. Check the box to the left of the node, and select Actions > Monitor and troubleshoot > Get system log. 

Once your cluster has been provisioned, you are ready to continue using AWS ParallelCluster to run your cryoSPARC jobs as described ![in their documentation](https://guide.cryosparc.com/deploy/cryosparc-on-aws)!


## Clean Up

To clean up your cluster, use ParallelCluster's delete-cluster command to de-provision the underlying resources in your cluster.

```bash
pcluster delete-cluster --cluster-name cryosparc-cluster
```

Once the cluster has been deleted, you can delete the files you uploaded to S3 and the S3 bucket itself, along with the data transfer solution you chose in the prerequisite sections.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

