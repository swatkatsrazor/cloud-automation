#!/bin/bash

source "${GEN3_HOME}/gen3/lib/utils.sh"
gen3_load "gen3/gen3setup"

if ! hostname="$(gen3 api hostname)"; then
    gen3_log_err "could not determine hostname from manifest-global - bailing out"
    return 1
fi
hostname=$(echo $hostname | head -c25)

jobId=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4 ; echo '')

prefix="${hostname//./-}-bucket-manifest-${jobId}"
saName=$(echo "${prefix}-sa" | head -c63)

gen3_create_aws_batch_jenkins() {
  local prefix="${hostname//./-}-bucket-manifest-${jobId}"
  local temp_bucket=$(echo "${prefix}-temp-bucket" | head -c63)
  cat - > "./paramFile.json" <<EOF
{
    "job_id": "${jobId}",
    "bucket_name": "${temp_bucket}"
}
EOF
  gen3_create_aws_batch $@
}


# function to create an job and returns a job id
#
# @param bucket: the input bucket
#
gen3_create_aws_batch() {
  if [[ $# -lt 1 ]]; then
    gen3_log_info "The input bucket is required "
    exit 1
  fi
  bucket=$1
  authz=$2
  if [[ "$authz" != "" ]] && [[ $authz != s3://* ]] && [[ $authz != /* ]]; then
    gen3_log_info "Please provide the absolute path "
    exit 1
  fi
  echo $prefix

  local job_queue=$(echo "${prefix}_queue_job" | head -c63)
  local sqs_name=$(echo "${prefix}-sqs" | head -c63)
  local job_definition=$(echo "${prefix}-batch_job_definition" | head -c63)
  local temp_bucket=$(echo "${prefix}-temp-bucket" | head -c63)
  local iam_instance_profile_role=$(echo "${prefix}-iam_ins_profile_role" | head -c63)
  local aws_batch_service_role=$(echo "${prefix}-aws_service_role" | head -c63)
  local iam_instance_role=$(echo "${prefix}-iam_ins_role" | head -c63)
  local aws_batch_compute_environment_sg=$(echo "${prefix}-compute_env_sg" | head -c63)
  local compute_environment_name=$(echo "${prefix}-compute-env" | head -c63)

  # Get aws credetial of fence_bot iam user
  local access_key=$(gen3 secrets decode fence-config fence-config.yaml | yq -r .AWS_CREDENTIALS.fence_bot.aws_access_key_id)
  local secret_key=$(gen3 secrets decode fence-config fence-config.yaml | yq -r .AWS_CREDENTIALS.fence_bot.aws_secret_access_key)

  if [ "$secret_key" = "null" ]; then
    gen3_log_err "No fence_bot aws credential block in fence_config.yaml"
    return 1
  fi

  gen3 workon default ${prefix}__batch
  gen3 cd

  local accountId=$(gen3_aws_run aws sts get-caller-identity | jq -r .Account)

  mkdir -p $(gen3_secrets_folder)/g3auto/bucketmanifest/
  credsFile="$(gen3_secrets_folder)/g3auto/bucketmanifest/creds.json"
  cat - > "$credsFile" <<EOM
{
  "region": "us-east-1",
  "aws_access_key_id": "$access_key",
  "aws_secret_access_key": "$secret_key"
}
EOM
  gen3 secrets sync "initialize bucketmanifest/creds.json"

  cat << EOF > ${prefix}-job-definition.json
{
    "image": "quay.io/cdis/object_metadata:master",
    "memory": 256,
    "vcpus": 1,
    "environment": [
        {"name": "ACCESS_KEY_ID", "value": "${access_key}"},
        {"name": "SECRET_ACCESS_KEY", "value": "${secret_key}"},
        {"name": "BUCKET", "value": "${bucket}"},
        {"name": "SQS_NAME", "value": "${sqs_name}"}
    ]
}

EOF
  cat << EOF > config.tfvars
container_properties         = "./${prefix}-job-definition.json"
iam_instance_role            = "${iam_instance_role}"
iam_instance_profile_role    = "${iam_instance_profile_role}"
aws_batch_service_role       = "${aws_batch_service_role}"
aws_batch_compute_environment_sg = "${aws_batch_compute_environment_sg}"
role_description             = "${prefix}-role to run aws batch"
batch_job_definition_name    = "${job_definition}"
compute_environment_name     = "${compute_environment_name}"
batch_job_queue_name         = "${job_queue}"
sqs_queue_name               = "${sqs_name}"
output_bucket_name           = "${temp_bucket}"
EOF

  cat << EOF > sa.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "sqs:ListQueues",
            "Resource": "*"
        },
        {
             "Effect": "Allow",
             "Action": "sqs:*",
             "Resource": "arn:aws:sqs:us-east-1:${accountId}:${sqs_name}"
        },
        {
             "Effect": "Allow",
             "Action": "batch:*",
             "Resource": "arn:aws:batch:us-east-1:${accountId}:job-definition/${job_definition}"
        },
        {
             "Effect": "Allow",
             "Action": "batch:*",
             "Resource":"arn:aws:batch:us-east-1:${accountId}:job-queue/${job_queue}"
        },
        {
             "Effect": "Allow",
             "Action": "s3:*",
             "Resource":[
               "arn:aws:s3:::${temp_bucket}",
               "arn:aws:s3:::${temp_bucket}/*"
             ]
        }
    ]
}
EOF

  gen3 tfplan 2>&1
  gen3 tfapply 2>&1
  if [[ $? != 0 ]]; then
    gen3_log_err "Unexpected error running gen3 tfapply."
    return 1
  fi
  sleep 30

  # Create a service account for k8s job for submitting jobs and consuming sqs
  gen3 iam-serviceaccount -c $saName -p sa.json
  if [[ "$authz" != "" ]]; then
    aws s3 cp "$authz" "s3://${temp_bucket}/authz.tsv"
    authz="s3://${temp_bucket}/authz.tsv"
  fi

  # Run k8s jobs to submitting jobs and consuming sqs
  local sqsUrl=$(aws sqs get-queue-url --queue-name $sqs_name | jq -r .QueueUrl)
  gen3 gitops filter $HOME/cloud-automation/kube/services/jobs/bucket-manifest-job.yaml BUCKET $bucket JOB_QUEUE $job_queue JOB_DEFINITION $job_definition SQS $sqsUrl AUTHZ "$authz" OUT_BUCKET $temp_bucket | sed "s|sa-#SA_NAME_PLACEHOLDER#|$saName|g" | sed "s|bucket-manifest#PLACEHOLDER#|bucket-manifest-${jobId}|g" > ./aws-bucket-manifest-${jobId}-job.yaml
  gen3 job run ./aws-bucket-manifest-${jobId}-job.yaml
  gen3_log_info "The job is started. Job ID: ${jobId}"

}

# function to check job status
#
# @param job-id
#
gen3_manifest_generating_status() {
  if [[ $# -lt 1 ]]; then
    gen3_log_info "An jobId is required"
    exit 1
  fi
  jobid=$1
  pod_name=$(g3kubectl get pod | grep aws-bucket-manifest-$jobid | grep -e Completed -e Running | cut -d' ' -f1)
  if [[ $? != 0 ]]; then
    gen3_log_err "The job has not been started. Check it again"
    exit 0
  fi
  g3kubectl logs -f ${pod_name}
}


# Show help
gen3_bucket_manifest_help() {
  gen3 help bucket-manifest
}

# function to list all jobs
gen3_bucket_manifest_list() {
  local search_dir="$HOME/.local/share/gen3/default"
  for entry in `ls $search_dir`; do
    if [[ $entry == *"__batch" ]]; then
      jobid=$(echo $entry | sed -n "s/${hostname//./-}-bucket-manifest-\(\S*\)__batch$/\1/p")
      if [[ $jobid != "" ]]; then
        echo $jobid
      fi
    fi
  done
}

# tear down the infrastructure
gen3_batch_cleanup() {
  if [[ $# -lt 1 ]]; then
    gen3_log_info "Need to provide a job-id "
    exit 1
  fi
  jobId=$1

  local search_dir="$HOME/.local/share/gen3/default"
  local is_jobid=0
  for entry in `ls $search_dir`; do
    if [[ $entry == *"__batch" ]]; then
      item=$(echo $entry | sed -n "s/^.*-\(\S*\)__batch$/\1/p")
      if [[ "$item" == "$jobId" ]]; then
        is_jobid=1
      fi
    fi
  done
  if [[ "$is_jobid" == 0 ]]; then
    gen3_log_err "job id does not exist"
    exit 1
  fi

  local prefix="${hostname//./-}-bucket-manifest-${jobId}"
  local saName=$(echo "${prefix}-sa" | head -c63)
  local temp_bucket=$(echo "${prefix}-temp-bucket" | head -c63)

  gen3_aws_run aws s3 rm "s3://${temp_bucket}" --recursive
  gen3 workon default ${prefix}__batch
  gen3 cd
  gen3_load "gen3/lib/terraform"
  gen3_terraform destroy
  if [[ $? == 0 ]]; then
    gen3 trash --apply
  fi
  
  # Delete service acccount, role and policy attached to it
  role=$(g3kubectl describe serviceaccount $saName | grep Annotations | sed -n "s/^.*:role\/\(\S*\)$/\1/p")
  policyName=$(gen3_aws_run aws iam list-role-policies --role-name $role | jq -r .PolicyNames[0])
  gen3_aws_run aws iam delete-role-policy --role-name $role --policy-name $policyName
  gen3_aws_run aws iam delete-role --role-name $role
  g3kubectl delete serviceaccount $saName

  # Delete creds
  credsFile="$(gen3_secrets_folder)/g3auto/bucketmanifest/creds.json"
  rm -f $credsFile
}

command="$1"
shift
case "$command" in
  'create')
    gen3_create_aws_batch "$@"
    ;;
  'create-jenkins')
    gen3_create_aws_batch_jenkins "$@"
    ;;
  'cleanup')
    gen3_batch_cleanup "$@"
    ;;
  'status')
    gen3_manifest_generating_status "$@"
    ;;
  'list' )
    gen3_bucket_manifest_list
    ;;
  'help')
    gen3_bucket_manifest_help "$@"
    ;;
  *)
    gen3_bucket_manifest_help
    ;;
esac
exit $?
