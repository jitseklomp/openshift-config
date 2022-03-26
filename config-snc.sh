#!/bin/bash
# This script sets up a single node cluster (SNC) which was created by 
# the Cloud Installer (https://cloud.redhat.com/openshift/assisted-installer/clusters/~new)
#
# First, you have to install the SNC in your network. Then you are logging into it with kubeadmin
# THEN you can let this script run, which will create PVs in the VM and configures the 
# internal registry to use one of the PVs for storing everything.
# 
# Please see README.MD for more details.
#
set -e -u -o pipefail

declare HOST=192.168.2.23 # set it to your IP
declare USER=core
declare NUM_PVs=30
declare KUBECONFIG=""
declare OC=oc

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare COMMAND="help"


valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    persistent-volumes|registry|operators|ci|create-users|all)
      COMMAND=$1
      shift
      ;;
    -h|--host-name)
      HOST=$2
      shift 2
      ;;
    -u|--user-name)
      USER=$2
      shift 2
      ;;
    -k|--kubeconfig)
      KUBECONFIG=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *) 
      break
  esac
done


function generate_pv() {
  local pvdir="${1}"
  local name="${2}"
cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
  labels:
    volume: ${name}
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
    - ReadWriteMany
    - ReadOnlyMany
  hostPath:
    path: ${pvdir}
  persistentVolumeReclaimPolicy: Recycle
EOF
}

function setup_pv_dirs() {
    local dir="${1}"
    local count="${2}"

    ssh $USER@$HOST 'sudo bash -x -s' <<EOF
    for pvsubdir in \$(seq -f "pv%04g" 1 ${count}); do
        mkdir -p "${dir}/\${pvsubdir}"
    done
    if ! chcon -R -t svirt_sandbox_file_t "${dir}" &> /dev/null; then
        echo "Failed to set SELinux context on ${dir}"
    fi
    chmod -R 777 ${dir}
EOF
}

function create_pvs() {
    local pvdir="${1}"
    local count="${2}"

    setup_pv_dirs "${pvdir}" "${count}"

    for pvname in $(seq -f "pv%04g" 1 ${count}); do
        if ! $OC get pv "${pvname}" &> /dev/null; then
            generate_pv "${pvdir}/${pvname}" "${pvname}" | $OC create -f -
        else
            echo "persistentvolume ${pvname} already exists"
        fi
    done
}

command.help() {
  cat <<-EOF
  Provides some functions to make an OpenShift Single Node Cluster usable. 
  
  NOTE: First, you need to install an OpenShift Single Node Cluster (CRC or SNO). Then you
  have to log into it using the kubeadmin credentials provided. 

  oc login -u kubeadmin -p <your kubeadmin hash> https://api.crc.testing:6443

  And THEN you can issue this script.
  

  Usage:
      config-snc.sh [command] [options]
  
  Example:
      config-snc.sh all -h 192.168.2.23
  
  COMMANDS:
      persistant-volumes             Setup 30 persistant volumes on SNC host
      registry                       Setup internal image registry to use a PVC and accept requests
      operators                      Install gitops and pipeline operators
      ci                             Install Nexus and Gogs in a ci namespace
      create-users                   Creates two users: admin/admin123 and devel/devel
      all                            call all modules
      help                           Help about this command

  OPTIONS:
      -h --host-name                 SNC host name
      -u --user-name                 SNC user name (Default: $USER)
      -k --kubeconfig                kubeconfig file to be used
      
EOF
}

# This command creates 30 PVs on the master host node
command.persistent-volumes() {
    info "Creating $NUM_PVs persistent volumes on $HOST:/mnt/pv-data/pv00XX"
    create_pvs "/mnt/pv-data" $NUM_PVs
}

command.registry() {
    info "Binding internal image registry to a persistent volume and make it manageable"
    # Apply registry pvc to bound with pv0001
    cat > /tmp/claim.yaml <<EOF 
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: snc-image-registry-storage	
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  selector:
    matchLabels:
      volume: "pv0001"
EOF

    cat /tmp/claim.yaml | $OC apply -f -
    
    # Add registry storage to pvc
    $OC patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "add", "path": "/spec/storage/pvc", "value": {"claim": "snc-image-registry-storage"}}]' --type=json
    
    # Remove emptyDir as storage for registry
    #oc patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "remove", "path": "/spec/storage/emptyDir"}]' --type=json

    # set registry to Managed in order to make use of it!
    $OC patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'
}

command.operators() {
  info "Installing openshift-gitops and openshift-pipelines operators"

    cat << EOF > /tmp/operators.yaml 
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops
  namespace: openshift-operators 
spec:
  channel: stable 
  name: openshift-gitops-operator
  source: redhat-operators 
  sourceNamespace: openshift-marketplace 
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines
  namespace: openshift-operators 
spec:
  channel: stable 
  name: openshift-pipelines-operator-rh
  source: redhat-operators 
  sourceNamespace: openshift-marketplace 

EOF

    cat /tmp/operators.yaml | $OC apply -f -
}

command.ci() {
    info "Initialising a CI project in OpenShift with Nexus and GOGS installed"
    $OC get ns ci 2>/dev/null  || {
      info "Creating CI project" 
      $OC new-project ci > /dev/null

      $OC apply -f "$SCRIPT_DIR/support/nexus.yaml" --namespace ci
      $OC apply -f "$SCRIPT_DIR/support/gogs.yaml" --namespace ci
      GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}')
      info "Gogs Hostname: $GOGS_HOSTNAME"

      info "Initiatlizing git repository in Gogs and configuring webhooks"
      sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" support/gogs-configmap.yaml | $OC apply --namespace ci -f - 
      $OC rollout status deployment/gogs --namespace ci
      $OC create -f support/gogs-init-taskrun.yaml --namespace ci
    }
}

command.create-users() {
    info "Creating an admin and a developer user."
    $OC get secret htpass-secret -n openshift-config 2>/dev/null || {
      info "No htpass provider availble, creating new one"
      # create a secret
      $OC create secret generic htpass-secret --from-file=htpasswd="$SCRIPT_DIR/support/htpasswd" -n openshift-config

      # create the CR
      $OC apply -f "$SCRIPT_DIR/support/htpasswd-cr.yaml" -n openshift-config
    } && {
      info "Changing existing htpass-secret file to add devel/devel and admin/admin123"
      $OC get secret htpass-secret -ojsonpath={.data.htpasswd} -n openshift-config | base64 --decode > /tmp/users.htpasswd
      
      info "Existing users"
      cat /tmp/users.htpasswd 
      echo >> /tmp/users.htpasswd

      htpasswd -bB /tmp/users.htpasswd admin admin123
      htpasswd -bB /tmp/users.htpasswd devel devel

      cat /tmp/users.htpasswd

      $OC create secret generic htpass-secret --from-file=htpasswd=/tmp/users.htpasswd --dry-run=client -o yaml -n openshift-config | oc replace -f -

    }

    # we want admin be cluster-admin
    $OC adm policy add-cluster-role-to-user cluster-admin admin
}


command.all() {
    command.persistant-volumes
    command.registry
    command.create-users
    command.operators
    command.ci
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  # setup OC command
  if [ -n "$KUBECONFIG" ]; then
    info "Using kubeconfig $KUBECONFIG"
    OC="oc --kubeconfig $KUBECONFIG"
  else
    info "Using default kubeconfig"
    OC="oc"
  fi 

  cd "$SCRIPT_DIR"
  $fn
  return $?
}

main

