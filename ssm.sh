#!/bin/bash

# Set the cluster and service names
cluster_name="midecode-ionos"
service_name="nginx1"

# Get the task ARN for the specified service
service_task_arn=($(aws ecs list-tasks --cluster $cluster_name --service-name $service_name --query "taskArns[0]" --output text))
echo $service1_task_arn

# execute the command in the specified task and container 
aws ecs execute-command \
  --cluster $cluster_name \
  --task $service_task_arn \
  --container nginx \
  --interactive \
  --command "/bin/bash"