# =============================================================================
# 01-create-ec2.ps1  -  Create the "workstation" EC2 server used for Stage A
# =============================================================================
# What this script does (in order):
#   1. Finds your current public IP (so only YOU can SSH into the server).
#   2. Creates an SSH key pair and saves the private key on your computer.
#   3. Creates a Security Group (a firewall) allowing SSH only from your IP.
#   4. Creates an IAM Role + Instance Profile so the server can call AWS
#      without storing any access keys on it.
#   5. Launches a t3.medium Ubuntu 24.04 server with a 20 GB disk.
#
# Region is always us-east-1. Run from PowerShell:  .\scripts\01-create-ec2.ps1
# =============================================================================

$ErrorActionPreference = "Stop"
$Region      = "us-east-1"
$Name        = "demo-workstation"                 # Name tag shown in the console
$KeyName     = "demo-key"                         # SSH key pair name in AWS
$KeyFile     = "$HOME\.ssh\demo-key.pem"          # Where the private key is saved
$SgName      = "demo-workstation-sg"              # Security group name
$RoleName    = "demo-workstation-role"            # IAM role name
$ProfileName = "demo-workstation-profile"         # Instance profile name
$InstanceType = "t3.medium"                       # 2 vCPU, 4 GB RAM (about $0.04/hour)

# --- 1. Find my public IP ----------------------------------------------------
$MyIp = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
Write-Host "Your public IP is $MyIp"

# --- 2. SSH key pair ----------------------------------------------------------
# The private key is written to $KeyFile. Never share or commit this file.
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
aws ec2 create-key-pair --region $Region --key-name $KeyName `
    --query KeyMaterial --output text | Out-File -Encoding ascii $KeyFile
# Make the key readable only by the current user (ssh refuses keys that are too open).
icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null

# --- 3. Security group (firewall) --------------------------------------------
# Uses the default VPC. Only port 22 (SSH) from your IP is allowed in.
$VpcId = aws ec2 describe-vpcs --region $Region --filters Name=isDefault,Values=true `
    --query "Vpcs[0].VpcId" --output text
$SgId = aws ec2 create-security-group --region $Region --group-name $SgName `
    --description "SSH from my IP only" --vpc-id $VpcId --query GroupId --output text
aws ec2 authorize-security-group-ingress --region $Region --group-id $SgId `
    --protocol tcp --port 22 --cidr "$MyIp/32" | Out-Null

# --- 4. IAM role so the server can use AWS without access keys ----------------
# Trust policy = "EC2 is allowed to assume this role".
$Trust = "$env:TEMP\ec2-trust.json"
@'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
'@ | Set-Content -Encoding ascii $Trust
aws iam create-role --role-name $RoleName --assume-role-policy-document file://$Trust | Out-Null
# DEMO ONLY: admin rights are needed later so Terraform can build EKS. Remove after the project.
aws iam attach-role-policy --role-name $RoleName --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-instance-profile --instance-profile-name $ProfileName | Out-Null
aws iam add-role-to-instance-profile --instance-profile-name $ProfileName --role-name $RoleName
Start-Sleep -Seconds 15   # IAM needs a few seconds to become usable everywhere

# --- 5. Launch the server ------------------------------------------------------
# AMI = the operating system image. This public AWS parameter always points at the
# latest official Ubuntu 24.04 image.
$AmiId = aws ssm get-parameter --region $Region `
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id `
    --query Parameter.Value --output text

$BlockDevices = "$env:TEMP\ec2-disk.json"
@'
[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]
'@ | Set-Content -Encoding ascii $BlockDevices

$InstanceId = aws ec2 run-instances --region $Region --image-id $AmiId `
    --instance-type $InstanceType --key-name $KeyName --security-group-ids $SgId `
    --iam-instance-profile Name=$ProfileName `
    --block-device-mappings file://$BlockDevices `
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
    --query "Instances[0].InstanceId" --output text
# HttpTokens=required turns on IMDSv2, a safer way for the server to read its own metadata.

aws ec2 wait instance-running --region $Region --instance-ids $InstanceId
$PublicIp = aws ec2 describe-instances --region $Region --instance-ids $InstanceId `
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text

Write-Host "Instance: $InstanceId"
Write-Host "Public IP: $PublicIp"
Write-Host "Connect:   ssh -i $KeyFile ubuntu@$PublicIp"
