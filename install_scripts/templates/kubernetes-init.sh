#!/bin/bash

set -e
AIRGAP=0
DAEMON_TOKEN=
GROUP_ID=
LOG_LEVEL=
MIN_DOCKER_VERSION="1.10.3" # k8s min
NO_PROXY=1
PINNED_DOCKER_VERSION="{{ pinned_docker_version }}"
YAML_GENERATE_OPTS=

PUBLIC_ADDRESS=
PRIVATE_ADDRESS=
REGISTRY_BIND_PORT=
SKIP_DOCKER_INSTALL=0
OFFLINE_DOCKER_INSTALL=0
SKIP_DOCKER_PULL=0
TLS_CERT_PATH=
UI_BIND_PORT=8800
USER_ID=

BOOTSTRAP_TOKEN=
BOOTSTRAP_TOKEN_TTL="24h"
KUBERNETES_NAMESPACE="default"
KUBERNETES_VERSION="{{ kubernetes_version }}"
NO_CE_ON_EE="{{ no_ce_on_ee }}"

{% include 'common/common.sh' %}
{% include 'common/prompt.sh' %}
{% include 'common/system.sh' %}
{% include 'common/docker.sh' %}
{% include 'common/docker-version.sh' %}
{% include 'common/docker-install.sh' %}
{% include 'common/replicated.sh' %}
{% include 'common/cli-script.sh' %}
{% include 'common/alias.sh' %}
{% include 'common/ip-address.sh' %}
{% include 'common/proxy.sh' %}
{% include 'common/airgap.sh' %}
{% include 'common/log.sh' %}
{% include 'common/kubernetes.sh' %}
{% include 'common/selinux.sh' %}
{% include 'common/swap.sh' %}

initKubeadmConfig() {
    mkdir -p /opt/replicated
    cat <<EOF > /opt/replicated/kubeadm.conf
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
kubernetesVersion: $KUBERNETES_VERSION
token: $BOOTSTRAP_TOKEN
tokenTTL: ${BOOTSTRAP_TOKEN_TTL}
apiServerExtraArgs:
  service-node-port-range: "3000-60000"
EOF

    # if we have a private address, add it to SANs
    if [ -n "$PRIVATE_ADDRESS" ]; then
          cat <<EOF >> /opt/replicated/kubeadm.conf
apiServerCertSANs:
- $PRIVATE_ADDRESS
EOF
    fi

    # if we have a public address, add it to SANs
    if [ -n "$PUBLIC_ADDRESS" ] && [ -n "$PRIVATE_ADDRESS" ]; then
          cat <<EOF >> /opt/replicated/kubeadm.conf
- $PUBLIC_ADDRESS
EOF
    fi



}

initKube() {
    logStep "Verify Kubelet"
    if ! ps aux | grep -qE "[k]ubelet"; then
        logStep "Initialize Kubernetes"
        initKubeadmConfig
        set +e

        kubeadm init \
            --skip-preflight-checks \
            --config /opt/replicated/kubeadm.conf
        _status=$?
        set -e
        if [ "$_status" -ne "0" ]; then
            printf "${RED}Failed to initialize the kubernetes cluster.${NC}\n" 1>&2
            exit $_status
        fi
    fi
    cp /etc/kubernetes/admin.conf $HOME/admin.conf
    chown $SUDO_USER:$SUDO_USER $HOME/admin.conf


    export KUBECONFIG=/etc/kubernetes/admin.conf
    chmod 444 /etc/kubernetes/admin.conf
    echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> /etc/profile
    echo "source <(kubectl completion bash)" >> /etc/profile
    logSuccess "Kubernetes Master Initialized"
}

maybeGenerateBootstrapToken() {
    if [ -z "$BOOTSTRAP_TOKEN" ]; then
        logStep "generate kubernetes bootstrap token"
        BOOTSTRAP_TOKEN=$(kubeadm token generate)
    fi
    echo "Kubernetes bootstrap token: ${BOOTSTRAP_TOKEN}"
    echo "This token will expire in 24 hours"

    # if kubelet is already running this is another run of the isntall script,
    # so create the token in k8s api
    if ps aux | grep -qE "[k]ubelet"; then
        kubeadm token create $BOOTSTRAP_TOKEN --ttl ${BOOTSTRAP_TOKEN_TTL}
    fi

    logSuccess "bootstrap token set"
}

ensureCNIPlugins() {
    if [ ! -d /tmp/cni-plugins ]; then
        installCNIPlugins
    fi
    logSuccess "CNI configured"
}

weavenetDeploy() {
    logStep "deploy weave network"

    getUrlCmd
    # todo if airgap, copy from pkg
    if [ "$AIRGAP" = "1" ]; then
        cp kubernetes-weave.yml /tmp/weave.yml
    else
        $URLGET_CMD "{{ replicated_install_url }}/{{ kubernetes_weave_path }}?{{ kubernetes_weave_query }}" \
            > /tmp/weave.yml
    fi
    kubectl apply -f /tmp/weave.yml -n kube-system
    logSuccess "weave network deployed"
}

untaintMaster() {
    logStep "remove NoSchedule taint from master node"
    kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- || \
        echo "Taint not found or already removed. The above error can be ignored."
    logSuccess "master taint removed"
}
 
kubernetesDeploy() {
    logStep "deploy replicated components"

    getUrlCmd
    if [ "$AIRGAP" -ne "1" ]; then
        $URLGET_CMD "{{ replicated_install_url }}/{{ kubernetes_generate_path }}?{{ kubernetes_manifests_query }}" \
            > /tmp/kubernetes-yml-generate.sh
    else
        cp kubernetes-yml-generate.sh /tmp/kubernetes-yml-generate.sh
    fi

    logStep "generate manifests"
    getYAMLOpts
    sh /tmp/kubernetes-yml-generate.sh $YAML_GENERATE_OPTS > /tmp/kubernetes.yml
    sh /tmp/kubernetes-yml-generate.sh $YAML_GENERATE_OPTS rook_system_yaml=1 > /tmp/rook-system.yml
    sh /tmp/kubernetes-yml-generate.sh $YAML_GENERATE_OPTS rook_cluster_yaml=1 > /tmp/rook.yml

    kubectl apply -f /tmp/rook-system.yml
    spinnerRookReady # creating the cluster before the operator is ready fails
    kubectl apply -f /tmp/rook.yml
    kubectl apply -f /tmp/kubernetes.yml -n $KUBERNETES_NAMESPACE

    kubectl -n $KUBERNETES_NAMESPACE get pods,svc
    logSuccess "Replicated Daemon"
}

getYAMLOpts() {
    opts=
    if [ "$AIRGAP" = "1" ]; then
        opts=$opts" airgap"
    fi
    if [ -n "$LOG_LEVEL" ]; then
        opts=$opts" log-level=$LOG_LEVEL"
    fi
    if [ -n "$RELEASE_SEQUENCE" ]; then
        opts=$opts" release-sequence=$RELEASE_SEQUENCE"
    fi
    if [ -n "$UI_BIND_PORT" ]; then
        opts=$opts" ui-bind-port=$UI_BIND_PORT"
    fi
    YAML_GENERATE_OPTS="$opts"
}

outro() {
    clear
    echo
    if [ -z "$PUBLIC_ADDRESS" ]; then
      if [ -z "$PRIVATE_ADDRESS" ]; then
        PUBLIC_ADDRESS="<this_server_address>"
      else
        PUBLIC_ADDRESS="$PRIVATE_ADDRESS"
      fi
    fi
    printf "\n"
    printf "\t\t${GREEN}Installation${NC}\n"
    printf "\t\t${GREEN}  Complete ✔${NC}\n"
    printf "\n"
    printf "\nTo access the cluster with kubectl, reload your shell:\n\n"
    printf "\n"
    printf "${GREEN}    bash -l${NC}"
    printf "\n"
    printf "\n"
    printf "\nTo continue the installation, visit the following URL in your browser:\n\n"
    printf "\n"
    printf "    ${GREEN}https://%s:%s\n${NC}" "$PUBLIC_ADDRESS" "$UI_BIND_PORT"
    printf "\n"
    printf "\n"
}


################################################################################
# Execution starts here
################################################################################

require64Bit
requireRootUser
detectLsbDist
detectInitSystem
must_swapoff

while [ "$1" != "" ]; do
    _param="$(echo "$1" | cut -d= -f1)"
    _value="$(echo "$1" | grep '=' | cut -d= -f2-)"
    case $_param in
        airgap)
            # arigap implies "no proxy" and "offline docker"
            AIRGAP=1
            NO_PROXY=1
            OFFLINE_DOCKER_INSTALL=1
            ;;
        bypass-storagedriver-warnings|bypass_storagedriver_warnings)
            BYPASS_STORAGEDRIVER_WARNINGS=1
            ;;
        bootstrap-token|bootrap_token)
            BOOTSTRAP_TOKEN="$_value"
            ;;
        bootstrap-token-ttl|bootrap_token_ttl)
            BOOTSTRAP_TOKEN_TTL="$_value"
            ;;
        docker-version|docker_version)
            PINNED_DOCKER_VERSION="$_value"
            ;;
        http-proxy|http_proxy)
            PROXY_ADDRESS="$_value"
            ;;
        log-level|log_level)
            LOG_LEVEL="$_value"
            ;;
        no-docker|no_docker)
            SKIP_DOCKER_INSTALL=1
            ;;
        no-proxy|no_proxy)
            NO_PROXY=1
            ;;
        public-address|public_address)
            PUBLIC_ADDRESS="$_value"
            ;;
        private-address|private_address)
            PRIVATE_ADDRESS="$_value"
            ;;
        release-sequence|release_sequence)
            RELEASE_SEQUENCE="$_value"
            ;;
        skip-pull|skip_pull)
            SKIP_DOCKER_PULL=1
            ;;
        kubernetes-namespace|kubernetes_namespace)
            KUBERNETES_NAMESPACE="$_value"
            ;;
        ui-bind-port|ui_bind_port)
            UI_BIND_PORT="$_value"
            ;;
        no-ce-on-ee|no_ce_on_ee)
            NO_CE_ON_EE=1
            ;;
        *)
            echo >&2 "Error: unknown parameter \"$_param\""
            exit 1
            ;;
    esac
    shift
done

if [ "$NO_PROXY" != "1" ]; then
    echo $NO_PROXY
    bailNoProxy
fi

if [ -n "$PROXY_ADDRESS" ]; then
    echo $PROXY_ADDRESS
    bailNoProxy
fi

if [ -z "$PUBLIC_ADDRESS" ] && [ "$AIRGAP" -ne "1" ]; then
    printf "Determining service address\n"
    discoverPublicIp

    if [ -n "$PUBLIC_ADDRESS" ]; then
        shouldUsePublicIp
    else
        printf "The installer was unable to automatically detect the service IP address of this machine.\n"
        printf "Please enter the address or leave blank for unspecified.\n"
        promptForPublicIp
    fi
fi

if [ -z "$PRIVATE_ADDRESS" ]; then
    promptForPrivateIp
fi


if [ "$SKIP_DOCKER_INSTALL" != "1" ]; then
    if [ "$OFFLINE_DOCKER_INSTALL" != "1" ]; then
        installDockerK8s "$PINNED_DOCKER_VERSION" "$MIN_DOCKER_VERSION"
    else
        installDocker_1_12_Offline
    fi
    checkDockerDriver
    checkDockerStorageDriver
fi

if [ "$RESTART_DOCKER" = "1" ]; then
    restartDocker
fi

installKubernetesComponents
systemctl enable kubelet && systemctl start kubelet

if [ "$AIRGAP" = "1" ]; then
    logStep "Loading replicated and replicated-ui images from package\n"
    airgapLoadReplicatedImages
    logStep "Loading replicated debian, command, statsd-graphite, and premkit images from package\n"
    airgapLoadSupportImages
    airgapMaybeLoadSupportBundle
    airgapMaybeLoadRetraced
    airgapLoadKubernetesCommonImages
    airgapLoadKubernetesControlImages
fi

ensureCNIPlugins

maybeGenerateBootstrapToken
initKube

kubectl cluster-info
logSuccess "Cluster Initialized"

weavenetDeploy

untaintMaster

spinnerNodeReady

echo
kubectl get nodes
logSuccess "Kubernetes nodes"
echo

echo
kubectl get pods -n kube-system
logSuccess "Kubernetes system"
echo

kubernetesDeploy
spinnerReplicatedReady

# TODO ALIAS --
printf "Installing replicated command alias\n"
installKubernetesCLIFile '$(kubectl get pods -o=jsonpath="{.items[0].metadata.name}" -l tier=master)'
installAliasFile




outro

exit 0
