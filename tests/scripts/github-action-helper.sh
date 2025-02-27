#!/usr/bin/env bash

# Copyright 2021 The Rook Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -xeEo pipefail

#############
# VARIABLES #
#############
: "${BLOCK:=$(sudo lsblk --paths | awk '/14G/ {print $1}' | head -1)}"
NETWORK_ERROR="connection reset by peer"
SERVICE_UNAVAILABLE_ERROR="Service Unavailable"
INTERNAL_ERROR="INTERNAL_ERROR"
INTERNAL_SERVER_ERROR="500 Internal Server Error"

#############
# FUNCTIONS #
#############

function install_deps() {
  sudo wget https://github.com/mikefarah/yq/releases/download/3.4.1/yq_linux_amd64 -O /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
}

function print_k8s_cluster_status() {
  kubectl cluster-info
  kubectl get pods -n kube-system
}

function use_local_disk() {
  BLOCK_DATA_PART=${BLOCK}1
  sudo dmsetup version || true
  sudo swapoff --all --verbose
  if mountpoint -q /mnt; then
    sudo umount /mnt
    # search for the device since it keeps changing between sda and sdb
    sudo wipefs --all --force "$BLOCK_DATA_PART"
  else
    # it's the hosted runner!
    sudo sgdisk --zap-all --clear --mbrtogpt -g -- "${BLOCK}"
    sudo dd if=/dev/zero of="${BLOCK}" bs=1M count=10 oflag=direct
    sudo parted -s "${BLOCK}" mklabel gpt
  fi
  sudo lsblk
}

function use_local_disk_for_integration_test() {
  sudo udevadm control --log-priority=debug
  sudo swapoff --all --verbose
  sudo umount /mnt
  sudo sed -i.bak '/\/mnt/d' /etc/fstab
  # search for the device since it keeps changing between sda and sdb
  PARTITION="${BLOCK}1"
  sudo wipefs --all --force "$PARTITION"
  sudo dd if=/dev/zero of="${PARTITION}" bs=1M count=1
  sudo lsblk --bytes
  # add a udev rule to force the disk partitions to ceph
  # we have observed that some runners keep detaching/re-attaching the additional disk overriding the permissions to the default root:disk
  # for more details see: https://github.com/rook/rook/issues/7405
  echo "SUBSYSTEM==\"block\", ATTR{size}==\"29356032\", ACTION==\"add\", RUN+=\"/bin/chown 167:167 $PARTITION\"" | sudo tee -a /etc/udev/rules.d/01-rook.rules
  # for below, see: https://access.redhat.com/solutions/1465913
  block_base="$(basename "${BLOCK}")"
  echo "ACTION==\"add|change\", KERNEL==\"${block_base}\", OPTIONS:=\"nowatch\"" | sudo tee -a /etc/udev/rules.d/99-z-rook-nowatch.rules
  # The partition is still getting reloaded occasionally during operation. See https://github.com/rook/rook/issues/8975
  # Try issuing some disk-inspection commands to jog the system so it won't reload the partitions
  # during OSD provisioning.
  sudo udevadm control --reload-rules || true
  sudo udevadm trigger || true
  time sudo udevadm settle || true
  sudo partprobe || true
  sudo lsblk --noheadings --pairs "${BLOCK}" || true
  sudo sgdisk --print "${BLOCK}" || true
  sudo udevadm info --query=property "${BLOCK}" || true
  sudo lsblk --noheadings --pairs "${PARTITION}" || true
  journalctl -o short-precise --dmesg | tail -40 || true
  cat /etc/fstab || true
}

function create_partitions_for_osds() {
  tests/scripts/create-bluestore-partitions.sh --disk "$BLOCK" --osd-count 2
  sudo lsblk
}

function create_bluestore_partitions_and_pvcs() {
  BLOCK_PART="$BLOCK"2
  DB_PART="$BLOCK"1
  tests/scripts/create-bluestore-partitions.sh --disk "$BLOCK" --bluestore-type block.db --osd-count 1
  tests/scripts/localPathPV.sh "$BLOCK_PART" "$DB_PART"
}

function create_bluestore_partitions_and_pvcs_for_wal(){
  BLOCK_PART="$BLOCK"3
  DB_PART="$BLOCK"1
  WAL_PART="$BLOCK"2
  tests/scripts/create-bluestore-partitions.sh --disk "$BLOCK" --bluestore-type block.wal --osd-count 1
  tests/scripts/localPathPV.sh "$BLOCK_PART" "$DB_PART" "$WAL_PART"
}

function collect_udev_logs_in_background() {
  local log_dir="${1:-"/home/runner/work/rook/rook/tests/integration/_output/tests"}"
  mkdir -p "${log_dir}"
  udevadm monitor --property &> "${log_dir}"/udev-monitor-property.txt &
  udevadm monitor --kernel &> "${log_dir}"/udev-monitor-kernel.txt &
  udevadm monitor --udev &> "${log_dir}"/udev-monitor-udev.txt &
}

function build_rook() {
  build_type=build
  if [ -n "$1" ]; then
    build_type=$1
  fi
  GOPATH=$(go env GOPATH) make clean
  for _ in $(seq 1 3); do
    if ! o=$(make -j"$(nproc)" IMAGES='ceph' "$build_type"); then
      case "$o" in
        *"$NETWORK_ERROR"*)
          echo "network failure occurred, retrying..."
          continue
        ;;
        *"$SERVICE_UNAVAILABLE_ERROR"*)
          echo "network failure occurred, retrying..."
          continue
        ;;
        *"$INTERNAL_ERROR"*)
          echo "network failure occurred, retrying..."
          continue
        ;;
        *"$INTERNAL_SERVER_ERROR"*)
          echo "network failure occurred, retrying..."
          continue
        ;;
        *)
          # valid failure
          exit 1
      esac
    fi
    # no errors so we break the loop after the first iteration
    break
  done
  # validate build
  tests/scripts/validate_modified_files.sh build
  docker images
  if [[ "$build_type" == "build" ]]; then
    docker tag "$(docker images | awk '/build-/ {print $1}')" rook/ceph:local-build
  fi
}

function build_rook_all() {
  build_rook build.all
}

function validate_yaml() {
  cd cluster/examples/kubernetes/ceph

  # create the Rook CRDs and other resources
  kubectl create -f crds.yaml -f common.yaml

  # create the volume replication CRDs
  replication_version=v0.1.0
  replication_url="https://raw.githubusercontent.com/csi-addons/volume-replication-operator/${replication_version}/config/crd/bases"
  kubectl create -f "${replication_url}/replication.storage.openshift.io_volumereplications.yaml"
  kubectl create -f "${replication_url}/replication.storage.openshift.io_volumereplicationclasses.yaml"

  #create the KEDA CRDS
  keda_version=2.4.0
  keda_url="https://github.com/kedacore/keda/releases/download/v${keda_version}/keda-${keda_version}.yaml"
  kubectl apply -f "${keda_url}"

  # skipping folders and some yamls that are only for openshift.
  manifests="$(find . -maxdepth 1 -type f -name '*.yaml' -and -not -name '*openshift*' -and -not -name 'scc*')"
  with_f_arg="$(echo "$manifests" | awk '{printf " -f %s",$1}')" # don't add newline
  # shellcheck disable=SC2086 # '-f manifest1.yaml -f manifest2.yaml etc.' should not be quoted
  kubectl create ${with_f_arg} --dry-run=client
}

function create_cluster_prerequisites() {
  # this might be called from another function that has already done a cd
  ( cd cluster/examples/kubernetes/ceph && kubectl create -f crds.yaml -f common.yaml )
}

function deploy_manifest_with_local_build() {
  if [[ "$USE_LOCAL_BUILD" != "false" ]]; then
    sed -i "s|image: rook/ceph:.*|image: rook/ceph:local-build|g" $1
  fi
  kubectl create -f $1
}

function replace_ceph_image() {
  local file="$1"  # parameter 1: the file in which to replace the ceph image
  local ceph_image="${2:-}"  # parameter 2: the new ceph image to use
  if [[ -z ${ceph_image} ]]; then
    echo "No Ceph image given. Not adjusting manifests."
    return 0
  fi
  sed -i "s|image: .*ceph/ceph:.*|image: ${ceph_image}|g" "${file}"
}

function deploy_cluster() {
  cd cluster/examples/kubernetes/ceph
  deploy_manifest_with_local_build operator.yaml
  sed -i "s|#deviceFilter:|deviceFilter: ${BLOCK/\/dev\/}|g" cluster-test.yaml
  kubectl create -f cluster-test.yaml
  kubectl create -f object-test.yaml
  kubectl create -f pool-test.yaml
  kubectl create -f filesystem-test.yaml
  kubectl create -f rbdmirror.yaml
  kubectl create -f filesystem-mirror.yaml
  kubectl create -f nfs-test.yaml
  deploy_manifest_with_local_build toolbox.yaml
}

function wait_for_prepare_pod() {
  get_pod_cmd=(kubectl --namespace rook-ceph get pod --no-headers)
  timeout=450
  start_time="${SECONDS}"
  while [[ $(( SECONDS - start_time )) -lt $timeout ]]; do
    pod="$("${get_pod_cmd[@]}" --selector=app=rook-ceph-osd-prepare --output custom-columns=NAME:.metadata.name,PHASE:status.phase | awk 'FNR <= 1')"
    if echo "$pod" | grep 'Running\|Succeeded\|Failed'; then break; fi
    echo 'waiting for at least one osd prepare pod to be running or finished'
    sleep 5
  done
  pod="$("${get_pod_cmd[@]}" --selector app=rook-ceph-osd-prepare --output name | awk 'FNR <= 1')"
  kubectl --namespace rook-ceph logs --follow "$pod"
  timeout=60
  start_time="${SECONDS}"
  while [[ $(( SECONDS - start_time )) -lt $timeout ]]; do
    pod="$("${get_pod_cmd[@]}" --selector app=rook-ceph-osd,ceph_daemon_id=0 --output custom-columns=NAME:.metadata.name,PHASE:status.phase)"
    if echo "$pod" | grep 'Running'; then break; fi
    echo 'waiting for OSD 0 pod to be running'
    sleep 1
  done
  # getting the below logs is a best-effort attempt, so use '|| true' to allow failures
  pod="$("${get_pod_cmd[@]}" --selector app=rook-ceph-osd,ceph_daemon_id=0 --output name)" || true
  kubectl --namespace rook-ceph logs "$pod" || true
  job="$(kubectl --namespace rook-ceph get job --selector app=rook-ceph-osd-prepare --output name | awk 'FNR <= 1')" || true
  kubectl -n rook-ceph describe "$job" || true
  kubectl -n rook-ceph describe deployment/rook-ceph-osd-0 || true
}

function wait_for_ceph_to_be_ready() {
  DAEMONS=$1
  OSD_COUNT=$2
  mkdir test
  tests/scripts/validate_cluster.sh "$DAEMONS" "$OSD_COUNT"
  kubectl -n rook-ceph get pods
}

function check_ownerreferences() {
  curl -L https://github.com/kubernetes-sigs/kubectl-check-ownerreferences/releases/download/v0.2.0/kubectl-check-ownerreferences-linux-amd64.tar.gz -o kubectl-check-ownerreferences-linux-amd64.tar.gz
  tar xzvf kubectl-check-ownerreferences-linux-amd64.tar.gz
  chmod +x kubectl-check-ownerreferences
  ./kubectl-check-ownerreferences -n rook-ceph
}

function create_LV_on_disk() {
  sudo sgdisk --zap-all "${BLOCK}"
  VG=test-rook-vg
  LV=test-rook-lv
  sudo pvcreate "$BLOCK"
  sudo vgcreate "$VG" "$BLOCK" || sudo vgcreate "$VG" "$BLOCK" || sudo vgcreate "$VG" "$BLOCK"
  sudo lvcreate -l 100%FREE -n "${LV}" "${VG}"
  tests/scripts/localPathPV.sh /dev/"${VG}"/${LV}
  kubectl create -f cluster/examples/kubernetes/ceph/crds.yaml
  kubectl create -f cluster/examples/kubernetes/ceph/common.yaml
}

function deploy_first_rook_cluster() {
  BLOCK=$(sudo lsblk|awk '/14G/ {print $1}'| head -1)
  create_cluster_prerequisites
  cd cluster/examples/kubernetes/ceph/
  deploy_manifest_with_local_build operator.yaml
  yq w -i -d1 cluster-test.yaml spec.dashboard.enabled false
  yq w -i -d1 cluster-test.yaml spec.storage.useAllDevices false
  yq w -i -d1 cluster-test.yaml spec.storage.deviceFilter "${BLOCK}"1
  kubectl create -f cluster-test.yaml
  deploy_manifest_with_local_build toolbox.yaml
}

function deploy_second_rook_cluster() {
  BLOCK=$(sudo lsblk|awk '/14G/ {print $1}'| head -1)
  cd cluster/examples/kubernetes/ceph/
  NAMESPACE=rook-ceph-secondary envsubst < common-second-cluster.yaml | kubectl create -f -
  sed -i 's/namespace: rook-ceph/namespace: rook-ceph-secondary/g' cluster-test.yaml
  yq w -i -d1 cluster-test.yaml spec.storage.deviceFilter "${BLOCK}"2
  yq w -i -d1 cluster-test.yaml spec.dataDirHostPath "/var/lib/rook-external"
  kubectl create -f cluster-test.yaml
  yq w -i toolbox.yaml metadata.namespace rook-ceph-secondary
  deploy_manifest_with_local_build toolbox.yaml
}

function wait_for_rgw() {
  for _ in {1..120}; do
    if [ "$(kubectl -n "$1" get pod -l app=rook-ceph-rgw --no-headers --field-selector=status.phase=Running|wc -l)" -ge 1 ] ; then
        echo "rgw pod is found"
        break
    fi
    echo "waiting for rgw pods"
    sleep 5
  done
  for _ in {1..120}; do
    if [ "$(kubectl -n "$1" get deployment -l app=rook-ceph-rgw -o yaml | yq read - 'items[0].status.readyReplicas')" -ge 1 ] ; then
        echo "rgw is ready"
        break
    fi
    echo "waiting for rgw becomes ready"
    sleep 5
  done
}

function verify_operator_log_message() {
  local message="$1"  # param 1: the message to verify exists
  local namespace="${2:-rook-ceph}"  # optional param 2: the namespace of the CephCluster (default: rook-ceph)
  kubectl --namespace "$namespace" logs deployment/rook-ceph-operator | grep "$message"
}

function wait_for_operator_log_message() {
  local message="$1"  # param 1: the message to look for
  local timeout="$2"  # param 2: the timeout for waiting for the message to exist
  local namespace="${3:-rook-ceph}"  # optional param 3: the namespace of the CephCluster (default: rook-ceph)
  start_time="${SECONDS}"
  while [[ $(( SECONDS - start_time )) -lt $timeout ]]; do
    if verify_operator_log_message "$message" "$namespace"; then return 0; fi
    sleep 5
  done
  echo "timed out" >&2 && return 1
}

function restart_operator () {
  local namespace="${1:-rook-ceph}"  # optional param 1: the namespace of the CephCluster (default: rook-ceph)
  kubectl --namespace "$namespace" delete pod --selector app=rook-ceph-operator
  # wait for new pod to be running
  get_pod_cmd=(kubectl --namespace "$namespace" get pod --selector app=rook-ceph-operator --no-headers)
  timeout 20 bash -c \
    "until [[ -n \"\$(${get_pod_cmd[*]} --field-selector=status.phase=Running 2>/dev/null)\" ]] ; do echo waiting && sleep 1; done"
  "${get_pod_cmd[@]}"
}

function write_object_to_cluster1_read_from_cluster2() {
  cd cluster/examples/kubernetes/ceph/
  echo "[default]" > s3cfg
  echo "host_bucket = no.way.in.hell" >> ./s3cfg
  echo "use_https = False" >> ./s3cfg
  fallocate -l 1M ./1M.dat
  echo "hello world" >> ./1M.dat
  CLUSTER_1_IP_ADDR=$(kubectl -n rook-ceph get svc rook-ceph-rgw-multisite-store -o jsonpath="{.spec.clusterIP}")
  BASE64_ACCESS_KEY=$(kubectl -n rook-ceph get secrets realm-a-keys -o jsonpath="{.data.access-key}")
  BASE64_SECRET_KEY=$(kubectl -n rook-ceph get secrets realm-a-keys -o jsonpath="{.data.secret-key}")
  ACCESS_KEY=$(echo ${BASE64_ACCESS_KEY} | base64 --decode)
  SECRET_KEY=$(echo ${BASE64_SECRET_KEY} | base64 --decode)
  s3cmd -v -d --config=s3cfg --access_key=${ACCESS_KEY} --secret_key=${SECRET_KEY} --host=${CLUSTER_1_IP_ADDR} mb s3://bkt
  s3cmd -v -d --config=s3cfg --access_key=${ACCESS_KEY} --secret_key=${SECRET_KEY} --host=${CLUSTER_1_IP_ADDR} put ./1M.dat s3://bkt
  CLUSTER_2_IP_ADDR=$(kubectl -n rook-ceph-secondary get svc rook-ceph-rgw-zone-b-multisite-store -o jsonpath="{.spec.clusterIP}")
  timeout 60 bash <<EOF
until s3cmd -v -d --config=s3cfg --access_key=${ACCESS_KEY} --secret_key=${SECRET_KEY} --host=${CLUSTER_2_IP_ADDR} get s3://bkt/1M.dat 1M-get.dat --force; do
  echo "waiting for object to be replicated"
  sleep 5
done
EOF
  diff 1M.dat 1M-get.dat
}

function create_helm_tag() {
  helm_tag="$(cat _output/version)"
  build_image="$(docker images | awk '/build-/ {print $1}')"
  docker tag "${build_image}" "rook/ceph:${helm_tag}"
}

FUNCTION="$1"
shift # remove function arg now that we've recorded it
# call the function with the remainder of the user-provided args
# -e, -E, and -o=pipefail will ensure this script returns a failure if a part of the function fails
$FUNCTION "$@"
