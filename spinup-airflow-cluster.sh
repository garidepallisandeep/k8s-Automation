#!/bin/bash 
# This script is used to deploy the entire airflow stack to run the data pipeline and is currently intended for poc-ETL-dev project only.
# Script deploys the below components.
# K8s cluster with 2 nodepools.
# Required secrets for airflow stack to function.
# Airflow Webserver, scheduler, worker, redis, postgress, pgbouncer and the corresponding nodeport internal LB and Ingress.
# A vaild domain with google managed https certificate for airflow webserver.
# Make sure you have gcloud, kubectl, terraform and jq installed on your mac before you runthe script.
# SCRIPT USAGE 'bash spinup-airflow-cluster.sh'

# Force the script to run with "bash" as interpreter
if [ -z "$BASH" ]; then
  bash "$(basename "$0")" "$@"
  exit $?
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
WHITE='\033[0;37m'

# Input Validation 
# Validating ETL project
echo
read -p "Enter ETL project name [ default value is 'poc-ETL-dev' ] : " PROJECTID
PROJECTID="${PROJECTID:=poc-ETL-dev}"
if [ "${PROJECTID}" == "poc-ETL-dev" ];then
  :
else
  echo
  echo -e "${RED}Please enter 'poc-ETL-dev',  project poc-ETL is not applicable for this script."
  echo
  exit 0
fi
echo
echo -e "${ORANGE}ETL project name set is to : ${PROJECTID}"
tput sgr0
echo

# Validating ETL environment
read -p "Enter ETL environment [eg : dev/prod default value is 'dev' ] : " ETL_ENV
ETL_ENV="${ETL_ENV:=dev}"
if [ "${ETL_ENV}" == "dev" ];then
  :
else
  echo
  echo -e "${RED}Please enter 'dev' environment 'prod' is not applicable for this script."
  echo
  tput sgr0
  exit 0
fi
echo
echo -e "${ORANGE}ETL environment is set to : ${ETL_ENV}"
tput sgr0
echo

# Validating GKE cluster name
read -p "Enter GKE cluster name (eg : k8s-ETL-dev5): " CLOUDSDK_CONTAINER_CLUSTER
echo
if [[  ( -z $CLOUDSDK_CONTAINER_CLUSTER ) || ( $CLOUDSDK_CONTAINER_CLUSTER =~ ['!@#$%^&*()_+.'] ) ]]; then
    echo -e "${RED}GKE Cluster name cannot be empty nor can contain any special characters such as '!@#$%^&*()_+.'"
    echo
    tput sgr0
    exit 0
else
    :
fi
echo -e "${ORANGE}GKE cluster name is set to : ${CLOUDSDK_CONTAINER_CLUSTER}"
echo
tput sgr0

# Validating GKE cluster Location/zone
read -p "Enter GKE cluster Location/zone [eg : us-east1-c default is us-east1-c ] : " CLOUDSDK_COMPUTE_LOCATION
CLOUDSDK_COMPUTE_LOCATION="${CLOUDSDK_COMPUTE_LOCATION:=us-east1-c}"
echo
locationIsPresent=`gcloud compute zones list | grep "$CLOUDSDK_COMPUTE_LOCATION" | wc -l | sed 's/ //g' `
if [[ ( $locationIsPresent == 0 ) || ( -z $CLOUDSDK_COMPUTE_LOCATION ) ]]; then
    echo -e "${RED}Please enter a valid Location/zone eg us-east1-c"
    echo
    tput sgr0
    exit 0
else
    :
fi
echo -e "${ORANGE}GKE cluster Location/Zone is set to : ${CLOUDSDK_COMPUTE_LOCATION}"
echo
tput sgr0

# Validating Airflow webserver Domain Name
read -p "Enter Airflow webserver Domain Name (eg : <domain-name>.dev.ETL.net): " DOMAIN_NAME
echo
if [[ ( $DOMAIN_NAME =~ ['!@#$%^&*()_+.'] ) || ( -z $DOMAIN_NAME ) || ( "$DOMAIN_NAME"  == *".dev.ETL.net"*)]]; then
    echo -e "${RED}Please enter sub domain name without any special characters such as '!@#$%^&*()_-+.' eg airflow5"
    echo
    tput sgr0
    exit 0
else
    AIRFLOW_FQDN="${DOMAIN_NAME}.dev.ETL.net"
    :
fi
echo -e "${ORANGE}Airflow webserver Domain Name is set to : ${AIRFLOW_FQDN}"
echo
tput sgr0

# Pre-environment settings
AIRFLOW_ADMIN_USERNAME="admin"
PROD_PROJECTID="poc-ETL"
DNS_ZONE="ETL-dns"
REGION=`echo "${CLOUDSDK_COMPUTE_LOCATION}" | cut -f1,2 -d'-'`
CLOUDSDK_COMPUTE_RESOURCE_LABEL="kubernetes-ETL"
TARGET_RESOURCE_CLUSTER="module.gke.google_container_cluster."${CLOUDSDK_CONTAINER_CLUSTER}""
TARGET_RESOURCE_NODE_POOL="module.gke.google_container_node_pool."${CLOUDSDK_CONTAINER_CLUSTER}"-nodepool"
TARGET_RESOURCE_NODE_POOL2="module.gke.google_container_node_pool."${CLOUDSDK_CONTAINER_CLUSTER}"-pool-2"
#BRANCH="develop"

# Ensure we're using the correct gcloud project & k8s cluster
gcloud config set project ${PROJECTID}

# Updating google_container_cluster resource NAME and creating a new file from it.
sed 's/template-cluster/'${CLOUDSDK_CONTAINER_CLUSTER}'/g' ./tfmodules/gke/kubernetes-template.tf > ./tfmodules/gke/gke-k8s-cluster-${CLOUDSDK_CONTAINER_CLUSTER}.tf

# Initializing terraform modules
terraform -chdir=./${ETL_ENV} init 

# Planning terraform for resources "module.gke.google_container_cluster" and "module.gke.google_container_node_pool" only 
terraform -chdir=./${ETL_ENV} plan -target=${TARGET_RESOURCE_CLUSTER} -target=${TARGET_RESOURCE_NODE_POOL} -target=${TARGET_RESOURCE_NODE_POOL2} -var 'cluster_resource_labels='${CLOUDSDK_COMPUTE_RESOURCE_LABEL}'' -var 'gcs_cluster_name='${CLOUDSDK_CONTAINER_CLUSTER}'' -var 'location='${CLOUDSDK_COMPUTE_LOCATION}''

# Applying terraform for resources "module.gke.google_container_cluster" and "module.gke.google_container_node_pool" only 
terraform -chdir=./${ETL_ENV} apply -target=${TARGET_RESOURCE_CLUSTER} -target=${TARGET_RESOURCE_NODE_POOL} -target=${TARGET_RESOURCE_NODE_POOL2} -var 'cluster_resource_labels='${CLOUDSDK_COMPUTE_RESOURCE_LABEL}'' -var 'gcs_cluster_name='${CLOUDSDK_CONTAINER_CLUSTER}'' -var 'location='${CLOUDSDK_COMPUTE_LOCATION}'' 

# Connecting to the newly created cluster
gcloud container clusters get-credentials ${CLOUDSDK_CONTAINER_CLUSTER} --zone ${CLOUDSDK_COMPUTE_LOCATION} --project ${PROJECTID}

# Create pd-ssd storage class in newly created cluster
kubectl create -f ./kubernetes/storgae-class.yaml

# Load latest secrets
bash  ./${ETL_ENV}/get-secrets

AIRFLOW_ADMIN_USER=`cat ./${ETL_ENV}/secrets-repo/kubernetes/airflow_webserver_admin_user`
AIRFLOW_ADMIN_PASSWORD=`cat ./${ETL_ENV}/secrets-repo/kubernetes/airflow_webserver_admin_password`
AIRFLOW_ADMIN_EMAIL=`cat ./${ETL_ENV}/secrets-repo/kubernetes/airflow_webserver_admin_email`

# Create postgress secrets
kubectl --namespace=airflow create secret generic airflow-postgres \
    --from-file=postgres-user=./${ETL_ENV}/secrets-repo/kubernetes/postgres_user \
    --from-file=postgres-host=./${ETL_ENV}/secrets-repo/kubernetes/postgres_host \
    --from-file=postgres-port=./${ETL_ENV}/secrets-repo/kubernetes/postgres_port \
    --from-file=postgres-password=./${ETL_ENV}/secrets-repo/kubernetes/postgres_password \
    --from-file=postgres-analytics-user=./${ETL_ENV}/secrets-repo/kubernetes/postgres_analytics_user \
    --from-file=postgres-analytics-password=./${ETL_ENV}/secrets-repo/kubernetes/postgres_analytics_password \
    --dry-run=client -o yaml | kubectl apply -f -

  # Update deployment yaml files with node pool for nodeaffinity with cluster name and container image based on the env
  sed "s/kubernetes-ETL/$CLOUDSDK_CONTAINER_CLUSTER/g" ./kubernetes/templates/postgres-template.yaml > ./kubernetes/postgres.yaml
  sed "s/kubernetes-ETL/$CLOUDSDK_CONTAINER_CLUSTER/g" ./kubernetes/templates/airflow-redis-template.yaml > ./kubernetes/deployments/airflow-redis.yaml
  sed "s/kubernetes-ETL/$CLOUDSDK_CONTAINER_CLUSTER/g;s/poc-ETL/poc-ETL-$ETL_ENV/g" ./kubernetes/templates/pgbouncer-template.yaml > ./kubernetes/pgbouncer.yaml
  sed "s/kubernetes-ETL/$CLOUDSDK_CONTAINER_CLUSTER/g;s/poc-ETL/poc-ETL-$ETL_ENV/g" ./kubernetes/templates/airflow-webserver-template.yaml > ./kubernetes/deployments/airflow-webserver.yaml
  sed "s/kubernetes-ETL/$CLOUDSDK_CONTAINER_CLUSTER/g;s/poc-ETL/poc-ETL-$ETL_ENV/g" ./kubernetes/templates/airflow-scheduler-template.yaml > ./kubernetes/deployments/airflow-scheduler.yaml
  sed "s/kubernetes-ETL/$CLOUDSDK_CONTAINER_CLUSTER/g;s/poc-ETL/poc-ETL-$ETL_ENV/g" ./kubernetes/templates/airflow-worker-template.yaml > ./kubernetes/deployments/airflow-worker.yaml

# Create postgress deployment [modify nodeselector]
kubectl create -f ./kubernetes/postgres.yaml

# Get Cluster IP of postgres service
postgresClusterIp=`kubectl get service -n airflow airflow-v1-postgres -ojson | jq -r .spec.clusterIP`

# Update the postgres service cluster IP in pgbouncer.ini in keybase
sed "s/postgresServiceClusterIp/$postgresClusterIp/g" ./${ETL_ENV}/secrets-repo/kubernetes/pgbouncer.ini-template > ./${ETL_ENV}/secrets-repo/kubernetes/pgbouncer.ini-${CLOUDSDK_CONTAINER_CLUSTER}

# Create secret pgbouncer-config-v1
kubectl --namespace=airflow create secret generic pgbouncer-config-v1 \
    --from-file=userlist.txt=./${ETL_ENV}/secrets-repo/kubernetes/pgbouncer_user_config \
    --dry-run=client -o yaml | kubectl apply -f -

# Create secret airflow-pgbouncer-v1
kubectl --namespace=airflow create secret generic airflow-pgbouncer-v1 \
    --from-file=pgbouncer.ini=./${ETL_ENV}/secrets-repo/kubernetes/pgbouncer.ini-${CLOUDSDK_CONTAINER_CLUSTER} \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy Pgbouncer in GKE
kubectl create -f ./kubernetes/pgbouncer.yaml

# Sleep for 60 seconds for the LB service to be created on time.
echo -e "${ORANGE}Sleeping for 180 seconds for pgbouncer LB service to be created...."
tput sgr0
sleep 180s

# Get Cluster IP of postgres service
pgBouncerLbIp=`kubectl get service -n airflow airflow-v1-pgbouncer -ojson | jq -r  .status.loadBalancer.ingress | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"`

# Reserve already assigned External IP address for airflow-v1-pgbouncer loadbalancer as static IP
gcloud compute addresses create ${CLOUDSDK_CONTAINER_CLUSTER}-pgbouncer-lb-static-ip --addresses=${pgBouncerLbIp} --region=${REGION}

# Update the postgres service cluster IP in core_sql_alchemy_connection file in keybase
sed "s/pgBouncerLbServiceIp/$pgBouncerLbIp/g" ./${ETL_ENV}/secrets-repo/kubernetes/core_sql_alchemy_connection_template > ./${ETL_ENV}/secrets-repo/kubernetes/core_sql_alchemy_connection_${CLOUDSDK_CONTAINER_CLUSTER}

# Update the postgres service cluster IP in celery_result_backend file in keybase
sed "s/pgBouncerLbServiceIp/$pgBouncerLbIp/g" ./${ETL_ENV}/secrets-repo/kubernetes/celery_result_backend_template > ./${ETL_ENV}/secrets-repo/kubernetes/celery_result_backend_${CLOUDSDK_CONTAINER_CLUSTER}

# Update the postgres cluster name in airflow_core_remote_log_location file in keybase
sed "s/gkeClusterName/$CLOUDSDK_CONTAINER_CLUSTER/g" ./${ETL_ENV}/secrets-repo/kubernetes/airflow_core_remote_log_location_template > ./${ETL_ENV}/secrets-repo/kubernetes/airflow_core_remote_log_location_${CLOUDSDK_CONTAINER_CLUSTER}

# Create rest of the airflow secrets in the new cluster
bash  ./kubernetes/update-k8s-secrets-${ETL_ENV}.sh ${CLOUDSDK_CONTAINER_CLUSTER}

# Deploy redis in GKE
kubectl create -f ./kubernetes/deployments/airflow-redis.yaml

# Deploy airflow-configmap.yaml in GKE
kubectl create -f ./kubernetes/deployments/airflow-configmap.yaml

# Deploy airflow misc deployments in GKE
kubectl create -f ./kubernetes/airflow-misc.yaml 

# Deploy airflow-webserver in GKE
kubectl create -f ./kubernetes/deployments/airflow-webserver.yaml

# Deploy airflow-scheduler in GKE
kubectl create -f ./kubernetes/deployments/airflow-scheduler.yaml

# Deploy airflow-worker in GKE
kubectl create -f ./kubernetes/deployments/airflow-worker.yaml

echo -e "${ORANGE}Sleeping for 360 seconds for all the airflow deployments to be ACTIVE...."
tput sgr0
sleep 360

# Create Airflow user in webserver
airflowWebserverPod=`kubectl get pods -n airflow | grep webserver | awk -F " " '{print $1}' `
echo -e "${GREEN}Creating Airflow Webserver admin user..."
tput sgr0
kubectl exec -it -n airflow ${airflowWebserverPod} -- bash -c "airflow create_user -r Admin -u $AIRFLOW_ADMIN_USER -e $AIRFLOW_ADMIN_EMAIL -f $AIRFLOW_ADMIN_USER -l user -p $AIRFLOW_ADMIN_PASSWORD "

# Reserve static IP for webserver 
gcloud compute addresses create ${CLOUDSDK_CONTAINER_CLUSTER}-webserver-ingress-static-ip --global

# Get the reserved webserver IP address 
webserverStaticIP=`gcloud compute addresses describe ${CLOUDSDK_CONTAINER_CLUSTER}-webserver-ingress-static-ip --global | grep "address:" | awk -F ":" '{print $2}' |  sed 's/ //g' `

# Setting up an A record in project "poc-ETL" under ETL-dns zone
gcloud config set project ${PROD_PROJECTID}
gcloud dns record-sets transaction start --zone=${DNS_ZONE}
gcloud dns record-sets transaction add ${webserverStaticIP} --name=${AIRFLOW_FQDN} --ttl=300 --type=A --zone=${DNS_ZONE}
gcloud dns record-sets transaction execute --zone=${DNS_ZONE}

echo -e "${ORANGE}Sleeping for 120 seconds for the new airflow webserver A record to be ACTIVE...."
tput sgr0
sleep 120s

# Ensure we're setting the correct gcloud project & k8s cluster back
gcloud container clusters get-credentials ${CLOUDSDK_CONTAINER_CLUSTER} --zone ${CLOUDSDK_COMPUTE_LOCATION} --project ${PROJECTID}

# Setting up a Google-managed certificate
sed "s/CERTIFICATE_NAME/$CLOUDSDK_CONTAINER_CLUSTER-webserver/g;s/DOMAIN_NAME1/$AIRFLOW_FQDN/g" ./kubernetes/templates/airflow-webserver-managed-certificate-template.yaml > ./kubernetes/ingress/${CLOUDSDK_CONTAINER_CLUSTER}-webserver-https-cert.yaml
kubectl apply -f ./kubernetes/ingress/backendconfig.yaml
kubectl apply -f ./kubernetes/ingress/${CLOUDSDK_CONTAINER_CLUSTER}-webserver-https-cert.yaml

# Sleeping for 120 seconds for https certificate to be created
echo -e "${ORANGE}Sleeping for 120 seconds for google-managed certificate to be created...."
tput sgr0
sleep 120s

managedCertName=`kubectl describe managedcertificate ${CLOUDSDK_CONTAINER_CLUSTER}-webserver -n airflow | grep "Certificate Name:" | awk -F ":" '{print $2}' |  sed 's/ //g' `

# Create an airflow-v1-webserver Ingress for External Loadbalancer, linking it to the ManagedCertificate created previously.

sed "s/CERTIFICATE_NAME/$managedCertName/g;s/ADDRESS_NAME/$CLOUDSDK_CONTAINER_CLUSTER-webserver-ingress-static-ip/g" ./kubernetes/templates/airflow-webserver-ingress-template.yaml > ./kubernetes/ingress/${CLOUDSDK_CONTAINER_CLUSTER}-airflow-v1-ingress.yaml
kubectl apply -f ./kubernetes/ingress/${CLOUDSDK_CONTAINER_CLUSTER}-airflow-v1-ingress.yaml

# Sleeping for 600 seconds for Ingress and certificates to be created
echo -e "${ORANGE}Sleeping for 600 seconds for Webserver Ingress and certificate to be ACTIVE...."
tput sgr0
sleep 600s

echo
echo -e "${GREEN}Airflow GKE Cluster Stack Deployment complete!"
echo -e "${WHITE}----------------------------------------------"
echo -e "${GREEN}GCP Project: ${WHITE}${PROJECTID}"
echo -e "${GREEN}GKE Cluster: ${WHITE}${CLOUDSDK_CONTAINER_CLUSTER}"
echo -e "${GREEN}GCP Zone: ${WHITE}${CLOUDSDK_COMPUTE_LOCATION}"
echo -e "${GREEN}Airflow Webserver User: ${WHITE}${AIRFLOW_ADMIN_USERNAME}"
echo -e "${GREEN}Airflow Webserver Password: ${WHITE}${AIRFLOW_ADMIN_PASSWORD}"
echo -e "${GREEN}Opening ${WHITE}https://${AIRFLOW_FQDN}/login ${GREEN}on your browser...."
echo
echo -e "${WHITE}NOTE : Please make sure you add domain ${AIRFLOW_FQDN} in 'chrome://net-internals/#hsts' so its added to the HSTS set"
echo
tput sgr0
open https:${AIRFLOW_FQDN}/login