#!/usr/bin/env bash

# "To provide additional docker-compose args, set the COMPOSE var. Ex:
# COMPOSE="-f FILE_PATH_HERE"

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

ERROR() {
    echo -e "\e[101m\e[97m[ERROR]\e[49m\e[39m" "$@"
}

WARNING() {
    echo -e "\e[101m\e[97m[WARNING]\e[49m\e[39m" "$@"
}

INFO() {
    echo -e "\e[104m\e[97m[INFO]\e[49m\e[39m" "$@"
}

exists() {
    type "$1" > /dev/null 2>&1
}

TIUP_CLUSTER_ROOT=${TIUP_CLUSTER_ROOT:-""}

# Change directory to the source directory of this script. Taken from:
# https://stackoverflow.com/a/246128/3858681
pushd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

HELP=0
INIT_ONLY=0
DEV=""
COMPOSE=${COMPOSE:-""}
SUBNET=${SUBNET:-"172.19.0.0/24"}
RUN_AS_DAEMON=0
POSITIONAL=()

while [[ $# -gt 0 ]]
do
    key="$1"

    case $key in
        -h|--help)
            HELP=1
            shift # past argument
            ;;
        --init-only)
            INIT_ONLY=1
            shift # past argument
            ;;
        --dev)
            if [ ! "$TIUP_CLUSTER_ROOT" ]; then
                export TIUP_CLUSTER_ROOT="$(cd ../ && pwd)"
                INFO "TIUP_CLUSTER_ROOT is not set, defaulting to: $TIUP_CLUSTER_ROOT"
            fi
            INFO "Running docker-compose with dev config"
            DEV="-f docker-compose.dev.yml"
            shift # past argument
            ;;
        --compose)
            COMPOSE="-f $2"
            shift # past argument
            shift # past value
            ;;
        --subnet)
            SUBNET="$2"
            shift # past argument
            shift # past value
            ;;
        -d|--daemon)
            INFO "Running docker-compose as daemon"
            RUN_AS_DAEMON=1
            shift # past argument
            ;;
        *)
            POSITIONAL+=("$1")
            ERROR "unknown option $1"
            shift # past argument
            ;;
    esac
done

# comment because ERROR:
# ./up.sh: line 79: POSITIONAL[@]: unbound variable]
# set -- "${POSITIONAL[@]}" # restore positional parameters

if [ "${HELP}" -eq 1 ]; then
    echo "Usage: $0 [OPTION]"
    echo "  --help                                                Display this message"
    echo "  --init-only                                           Initializes ssh-keys, but does not call docker-compose"
    echo "  --daemon                                              Runs docker-compose in the background"
    echo "  --dev                                                 Mounts dir at host's TIUP_CLUSTER_ROOT to /tiup-cluster on tiup-cluster-control container, syncing files for development"
    echo "  --compose PATH                                        Path to an additional docker-compose yml config."
    echo "  --subnet SUBNET                                       Subnet in 24 bit netmask"
    echo "To provide multiple additional docker-compose args, set the COMPOSE var directly, with the -f flag. Ex: COMPOSE=\"-f FILE_PATH_HERE -f ANOTHER_PATH\" ./up.sh --dev"
    exit 0
fi

exists ssh-keygen || { ERROR "Please install ssh-keygen (apt-get install openssh-client)"; exit 1; }
exists perl || { ERROR "Please install perl (apt-get install perl)"; exit 1; }

# Generate SSH keys for the control node
if [ ! -f ./secret/node.env ]; then
    INFO "Generating key pair"
    mkdir -p secret
    ssh-keygen -t rsa -N "" -f ./secret/id_rsa

    INFO "Generating ./secret/control.env"
    { echo "# generated by tiup-cluster/docker/up.sh, parsed by tiup-cluster/docker/control/bashrc";
      echo "# NOTE: newline is expressed as ↩";
      echo "SSH_PRIVATE_KEY=$(perl -p -e "s/\n/↩/g" < ./secret/id_rsa)";
      echo "SSH_PUBLIC_KEY=$(cat ./secret/id_rsa.pub)"; } >> ./secret/control.env

    INFO "Generating ./secret/node.env"
    { echo "# generated by tiup-cluster/docker/up.sh, parsed by the \"tutum/debian\" docker image entrypoint script";
      echo "ROOT_PASS=root";
      echo "AUTHORIZED_KEYS=$(cat ./secret/id_rsa.pub)"; } >> ./secret/node.env
else
    INFO "No need to generate key pair"
fi

# Make sure folders referenced in control Dockerfile exist and don't contain leftover files
rm -rf ./control/tiup-cluster
mkdir -p ./control/tiup-cluster/tiup-cluster
# Copy the tiup-cluster directory if we're not mounting the TIUP_CLUSTER_ROOT
if [ -z "${DEV}" ]; then
    # Dockerfile does not allow `ADD ..`. So we need to copy it here in setup.
    INFO "Copying .. to control/tiup-cluster"
    (
        # TODO support exclude-ignore, check version of tar support this.
        # https://www.gnu.org/software/tar/manual/html_section/tar_48.html#IDX408
        # (cd ..; tar --exclude=./docker --exclude=./.git --exclude-ignore=.gitignore -cf - .)  | tar Cxf ./control/tiup-cluster -
        (cd ..; tar --exclude=./docker --exclude=./.git -cf - .)  | tar Cxf ./control/tiup-cluster -
    )
else
    INFO "Build tiup-cluster in $TIUP_CLUSTER_ROOT"
    (cd $TIUP_CLUSTER_ROOT;make failpoint-enable;GOOS=linux GOARCH=amd64 make cluster dm;make failpoint-disable)
fi

if [ "${INIT_ONLY}" -eq 1 ]; then
    exit 0
fi

if [ ${SUBNET##*/} -ne 24 ]; then
    ERROR "Only subnet mask of 24 bits are currently supported"
    exit 1
fi

exists docker ||
    { ERROR "Please install docker (https://docs.docker.com/engine/installation/)";
      exit 1; }
exists docker-compose ||
    { ERROR "Please install docker-compose (https://docs.docker.com/compose/install/)";
      exit 1; }

exist_network=$(docker network ls | awk '{if($2 == "tiops") print $1}')
if [[ "$exist_network" == "" ]]; then
    ipprefix=${SUBNET%.*}
    docker network create --gateway "${ipprefix}.1" --subnet "${SUBNET}" tiops
else
    echo "Skip create tiup-cluster network"
    SUBNET=$(docker network inspect -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}" tiops)
    if [ ${SUBNET##*/} -ne 24 ]; then
        ERROR "Only subnet mask of 24 bits are currently supported"
        exit 1
    fi
    ipprefix=${SUBNET%.*}
fi

sed "s/__IPPREFIX__/$ipprefix/g" docker-compose.yml.tpl > docker-compose.yml
sed "s/__IPPREFIX__/$ipprefix/g" docker-compose.dm.yml.tpl > docker-compose.dm.yml
sed -i '/TIUP_TEST_IP_PREFIX/d' ./secret/control.env
echo "TIUP_TEST_IP_PREFIX=$ipprefix" >> ./secret/control.env

INFO "Running \`docker-compose build\`"
# shellcheck disable=SC2086
docker-compose -f docker-compose.yml ${COMPOSE} ${DEV} build

INFO "Running \`docker-compose up\`"
if [ "${RUN_AS_DAEMON}" -eq 1 ]; then
    # shellcheck disable=SC2086
    docker-compose -f docker-compose.yml ${COMPOSE} ${DEV} up -d
    INFO "All containers started, run \`docker ps\` to view"
else
    INFO "Please run \`docker exec -it tiup-cluster-control bash\` in another terminal to proceed"
    # shellcheck disable=SC2086
    docker-compose -f docker-compose.yml ${COMPOSE} ${DEV} up
fi

popd
