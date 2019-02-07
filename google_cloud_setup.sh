#!/bin/bash +x
usage="usage: google_cloud_setup.sh <command> [NUM_NODES=<num_nodes>]
                [PREFIX=<prefix>] [MACHINE_ZONE=<machine_zone>]
                [MYVALUES_FILE=<myvalues_file>] [MACHINE_TYPE=<machine_type>]
                [CLUSTER_VERSION=<cluster_version>] [DISK_TYPE=<disk_type>]
                [INSTANCE_DISK_SIZE=<disk_size>]

commands:
    get-credential  Get google credentials
    create-cluster  Create a new cluster
    install-chart   Install the Helm chart
    upgrade-chart   Upgrade (Redeploy) the Helm chart
    uninstall-chart Delete the Helm release/chart
    delete-cluster  Delete cluster and perform a cleanup
    help            Show this help

parameters:
    num_nodes       Number of nodes to create in the cluster, default: 2
    prefix          Prefix to add to Cluster and Pod names, default: 'rel'
    myvalues_file   Path to custom helm chart values file, default: 'myvalues.yaml'

    machine_zone    Google Cloud zone, default: 'europe-west1-b'
    machine_type    Google Cloud instance type, default: 'n1-standard-4'
    cluster_version Kubernetes version, default: 1.10
    disk_type       Cloud storage type, default: 'pd-standard'
    disk_size       Google cloud storage size (GB), default: 50

    "


NUM_NODES=${NUM_NODES:-2}
PREFIX=${PREFIX:-rel}
RELEASE_NAME=${PREFIX}-${NUM_NODES}
CLUSTER_NAME=${PREFIX}-${NUM_NODES}

MACHINE_ZONE=europe-west1-b
MYVALUES_FILE=myvalues.yaml

MACHINE_TYPE=n1-standard-4
CLUSTER_VERSION=1.10
INSTANCE_DISK_SIZE=50
DISK_TYPE=pd-standard
DISK_SIZE=10GB

MACHINE_ARCHITECTURE=`uname -m`

if [ ! -f $MYVALUES_FILE ]; then
    echo "Custom Helm values yaml ($MYVALUES_FILE) not found"
    exit 1
fi

function gcloud::check_installed(){
    if ! [ -x "$(command -v gcloud)" ]; then
        echo "Installing Google Cloud SDK"

        if [ ${MACHINE_ARCHITECTURE} == 'x86_64' ]; then
            curl https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-233.0.0-linux-x86_64.tar.gz | tar -xz
        else
            curl https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-233.0.0-linux-x86.tar.gz | tar -xz
        fi

        ./google-cloud-sdk/install.sh
        ./google-cloud-sdk/bin/gcloud init
    fi
}

function helm::check_installed(){
    if ! [ -x "$(command -v helm)" ]; then
        echo "Installing Helm"

        # curl https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash
        source <(curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get)
    fi
}

function gcloud::get_credential(){
    gcloud::check_installed
    gcloud container clusters get-credentials --zone ${MACHINE_ZONE} ${CLUSTER_NAME}
}

function kube::worker::hostnames(){
    # Get a sequence of names; if you want an array, use additional parentheses ($(kube::worker::hostnames))
    kubectl get pods | grep 'worker' | awk '{print $1}'
}

function kube::worker::ips(){
    # Get a sequence of names; if you want an array, use additional parentheses ($(kube::worker::hostnames))
    kubectl get pods -o wide | grep worker | awk '{print $6}'
}

function chart::upgrade(){
    helm::check_installed

    # Install helm chart
    helm upgrade --wait --recreate-pods -f ${MYVALUES_FILE} \
        --timeout 900 --install ${RELEASE_NAME} . \
        --set limits.workers=${NUM_NODES}
}

function join_by(){
    local IFS="$1";
    shift; echo "$*";
}

function gcloud::cleanup(){
    gcloud::check_installed
    gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
    gcloud container clusters delete --quiet --zone ${MACHINE_ZONE}  ${CLUSTER_NAME}
}

case $1 in
    create-cluster)
        # Create a CPU cluster
        gcloud::check_installed
        gcloud container clusters create ${CLUSTER_NAME} \
            --zone=${MACHINE_ZONE} \
            --cluster-version=${CLUSTER_VERSION} \
            --enable-network-policy \
            --machine-type=${MACHINE_TYPE} \
            --num-nodes=${NUM_NODES} \
            --disk-type=${DISK_TYPE} \
            --disk-size=${INSTANCE_DISK_SIZE} \
            --scopes=storage-full

        # Get credential of the cluster
        gcloud container clusters get-credentials --zone ${MACHINE_ZONE} ${CLUSTER_NAME}

        kubectl --namespace kube-system create sa tiller

        kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller

        # Initialize helm to install charts
        helm::check_installed
        helm init --wait --service-account tiller
        ;;

    cleanup-cluster )
        gcloud::check_installed
        gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
        gcloud container clusters delete --quiet --zone ${MACHINE_ZONE}  ${CLUSTER_NAME}
        ;;

    install-chart)
        chart::upgrade

        # setup firewall
        gcloud::check_installed
        export NODE_PORT=$(kubectl get --namespace default -o jsonpath="{.spec.ports[0].nodePort}" services ${RELEASE_NAME}-mlbench-master)
        export NODE_IP=$(gcloud compute instances list|grep $(kubectl get nodes --namespace default -o jsonpath="{.items[0].status.addresses[0].address}") |awk '{print $5}')
        gcloud compute firewall-rules create --quiet ${CLUSTER_NAME} --allow tcp:$NODE_PORT,tcp:$NODE_PORT
        echo "You can access MLBench at the following URL:"
        echo http://$NODE_IP:$NODE_PORT
        ;;

    upgrade-chart)
        chart::upgrade
        ;;


    uninstall-chart)
        gcloud::check_installed
        helm::check_installed
        helm delete --purge ${RELEASE_NAME}
        gcloud compute firewall-rules delete --quiet ${CLUSTER_NAME}
        ;;

    delete-cluster)
        gcloud::cleanup
        ;;

    get-credential)
        gcloud::get_credential
        ;;
    help)
        echo "$usage"
        ;;
    *)
        printf "illegal option: %s\n" "$1" >&2
        echo "$usage" >&2

esac