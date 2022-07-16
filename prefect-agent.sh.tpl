#!/usr/bin/env bash
yum update -y

# install ssm
cd /tmp 
yum install -y https://s3.${region}.amazonaws.com/amazon-ssm-${region}/latest/${linux_type}/amazon-ssm-agent.rpm
systemctl enable amazon-ssm-agent 
systemctl start amazon-ssm-agent

cd /

# install and start start docker
amazon-linux-extras install docker -y
service docker start

# install compiler and deps
yum install gcc python3-devel -y

# install jq
yum install jq -y

# install aws logs
yum install awslogs -y

# update config to ship logs to local region
echo "[plugins]
cwlogs = cwlogs
[default]
region = ${region}" > /etc/awslogs/awscli.conf

# start the logs service
systemctl start awslogsd
systemctl enable awslogsd.service

# prefect agent install
pip3 install prefect

# get API key
result=$(aws secretsmanager get-secret-value --secret-id ${prefect_secret_name} --region ${region})
secret=$(echo $result | jq -r '.SecretString')
PREFECT_API_KEY=$(echo $secret | jq -r '.${prefect_secret_key}')

# create prefect config file
mkdir ~/.prefect
touch ~/.prefect/config.toml
echo "
[cloud.agent]
labels = ${prefect_labels}
" > ~/.prefect/config.toml

# create systemd config
touch /etc/systemd/system/prefect-agent.service
echo "[Unit]
Description=Prefect Docker Agent
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=root
ExecStart=/usr/local/bin/prefect agent docker start -k $PREFECT_API_KEY --api ${prefect_api_address} ${image_pulling} ${flow_logs} ${config_id}
[Install]
WantedBy=multi-user.target " >> /etc/systemd/system/prefect-agent.service

# start prefect agent
systemctl start prefect-agent

# Install recurring docker cleanup job.
touch /etc/systemd/system/docker-cleanup.service
echo "[Unit]
Description=Cleans up docker debris
Wants=docker-cleanup.timer
[Service]
Type=oneshot
ExecStart=/bin/docker system prune --force --all --filter \"until=48h\"
ExecStart=/bin/docker system prune --force --volumes
[Install]
WantedBy=multi-user.target " >> /etc/systemd/system/docker-cleanup.service

touch /etc/systemd/system/docker-cleanup.timer
echo "[Unit]
Description=Runs docker cleanup on schedule
Requires=docker-cleanup.service
[Timer]
Unit=docker-cleanup.service
OnCalendar=00,12:00:00
[Install]
WantedBy=timers.target " >> /etc/systemd/system/docker-cleanup.timer

# start docker cleanup job
systemctl start docker-cleanup.timer

# install cred helper
amazon-linux-extras enable docker
yum install amazon-ecr-credential-helper -y

mkdir ~/.docker
touch ~/.docker/config.json
echo '{
	"credsStore": "ecr-login"
}' >> ~/.docker/config.json
