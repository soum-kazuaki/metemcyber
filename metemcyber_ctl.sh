#! /bin/bash

for f in metemcyber_common.sh; do
    [ -f "${f}" ] && . "${f}"
done

function usage() {
    cat <<EOD | sed -e "s/^  //" >&2
  Usage: $0 [OPTIONS] <PROVIDER> <COMMAND> [ARGS...]

    !Note! : sudo permission is required at COMMAND: init|kill,
             because of removing files created by root@docker.

  PROVIDER:
    -:       shortcut. use current provider.
    pricom:  An enterprise ethereum network on NTT Communications. (Java-based ConsenSys Quorum)
    besu:    BESU sample network.
    ganache: ganache-cli on docker.
    ganache-local: ganache-cli on localhost.
    ganache-gui: ganache GUI on localhost. (GUI must be operated by hand)
    tester:  Web3 EthereumTesterProvider.

  COMMAND:
    init:   initialize and start provider.
        OPTIONAL ARGS:
            demo:       initialize, start provider, and setup demo catalog.
    start:  start(resume) provider.
        OPTIONAL ARGS:
            noisy:      (ganache|ganache-local) show logs from ganache-cli.
    stop:   stop(suspend) provider.
            (besu|ganache*) transactions are suspended.
    kill:   kill provider & metemcyber clients, and cleanup data.
    switch: just switch provider(workspace).
    client: launch metemcyber client.
        ARGS:   see below.
    demo:   launch demo with 3 clients.
        OPTIONAL ARGS:
            stop:       terminate demo clients.

  OPTIONS:
    -h:  show this message and exit.

  ARGS for COMMAND client:
    usage A: ... <PROVIDER> client <alice|bob|carol> [options]
        preset params for user, provider and server are given.
        options are passed to client program.

    usage B: ... <PROVIDER> client <any options you need>
        preset param for provider is given. option -s is required.

  (Examples)
    $0 ganache init demo  : initialize demo catalog with ganache-cli.
    $0 besu start         : start(or resume) provider, besu-sample-networks.
    $0 ganache-local demo : launch 3-clients-demo with ganache-cli running on localhost.
    $0 - client alice -v  : launch client(alice) with current selected provider.
    $0 - client -f ~/.ethereum/keystore/your_keyfile_generated_by_geth
                          : launch client with the account generated by geth.
    $0 kill               : kill all programs and clean up data.

EOD
    exit 255
}


#### minimal setup and defines. ####

PROGNAME=`basename $0`
## switch to the directory on which this script is placed.
WORKDIR=`cd \`dirname $0\` && pwd`
cd "${WORKDIR}" || exit 255
WORKDIR="."  ## overwrite with related-path (for docker envieonments).

METEMCYBER_IMAGE=metemcyber-python
IMAGE_DEPENDENCIES="requirements/common.txt demo/Dockerfile"
WORKSPACE="${WORKDIR}/workspace"
ENV_FILE="${WORKSPACE}/environments"
ENV_FOR_DOCKER="${WORKSPACE}/docker.env"
PROVIDER_CTL="${WORKSPACE}/provider_ctl"
SETTINGS="./metemcyber.settings"
DEMO_DATAVOLUME="demo/storage"
BUCKETNAME="metemcyber_pricom"

if [ -e "${WORKSPACE}" ] && [ ! -L "${WORKSPACE}" ]; then
    echo >&2 "Workspace directory (not symlink) exists: ${WORKSPACE}"
    echo >&2 "Please rename or remove it."
    exit 255;
fi


## export for PROVIDER_CTL.
export WORKSPACE ENV_FILE


#### parse args. ####

## options for myself.
while getopts 'h' OPT; do
    case ${OPT} in
        h|?)    usage;;
    esac
done
shift $((${OPTIND} - 1))

PROVIDER="$1"
COMMAND="$2"
shift 2
LEFT_ARGS="$*" ## pass through

[ -z ${COMMAND} ] && echo >&2 "missing COMMAND" && usage
[ -z ${PROVIDER} ] && echo >&2 "missing PROVIDER" && usage

if [ "${PROVIDER}" = "-" ]; then
    [ ! -L "${WORKSPACE}" ] && echo >&2 "no provider selected." && exit 255
    tmp=`readlink "${WORKSPACE}" 2>/dev/null`
    PROVIDER="${tmp##*.}"
fi
case "${PROVIDER}" in
    pricom|besu|ganache|ganache-local|ganache-gui|tester) ;;
    *)
        echo >&2 "invalid provider: ${PROVIDER}"
        exit 255
        ;;
esac

error=0
case "${COMMAND}" in
    init)
        case "${LEFT_ARGS}" in
            demo|'')    ;;
            *)  error=1;;
        esac;;
    start)
        case "${LEFT_ARGS}" in
            '') ;;
            noisy)
                case "${PROVIDER}" in
                    ganache|ganache-local)  ;;
                    *)  error=1;;
                esac;;
            *)  error=1;;
        esac;;
    stop|kill|switch)
        case "${LEFT_ARGS}" in
            '') ;;
            *)  error=1;;
        esac;;
    demo)
        case "${LEFT_ARGS}" in
            stop|'')    ;;
            *)          error=1;;
        esac;;
    client|test)    ;;
    *)
        echo >&2 "invalid COMMAND: ${COMMAND}"
        exit 255
        ;;
esac
[ "${error}" != "0" ] \
    && echo >&2 "${COMMAND}: un-expected args: ${LEFT_ARGS}" \
    && exit 255


#### switch workspace. ####

current_workspace=`readlink "${WORKSPACE}" 2>/dev/null`
new_workspace="${WORKSPACE}.${PROVIDER}"
if [ ! -d "${new_workspace}" ]; then
    echo >&2 "internal error: ${new_workspace} is missing. not yet supported?"
    exit 255
fi
if [ "${current_workspace}" != "${new_workspace}" ]; then
    echo >&2 "switching workspace, '${current_workspace}' to '${new_workspace}'"
    rm -f "${WORKSPACE}"
    ln -s "${new_workspace}" "${WORKSPACE}" || exit 255
fi

if [ "${COMMAND}" = "switch" ]; then
    echo "current workspace is ${WORKSPACE} symlinked from ${new_workspace}."
    if [ -f "${ENV_FILE}" ]; then
        echo "environments file: ${ENV_FILE}"
        echo "----"
        cat "${ENV_FILE}"
        echo "----"
    else
        echo "environments file does not exist. (not yet initialized)"
    fi
    exit 0
fi

[ -f "${ENV_FILE}" ] && source "${ENV_FILE}" ## load before killing


#### kick provider controller script. (only for init|strt|stop|kill) ####
#### ENV_FILE will be updated. ####

case "${COMMAND}" in
    init|start|stop|kill)
        if [ ! -f "${PROVIDER_CTL}" ]; then
            echo >&2 "internal error: ${PROVIDER_CTL} is missing. not yet supported?"
            exit 255;
        fi
        cmd="${PROVIDER_CTL} ${COMMAND} ${LEFT_ARGS}"
        echo "eval command: ${cmd}"
        eval "${cmd}"
        _r=$?
        if [ ${_r} -ne 0 ]; then
            echo >&2 "command failed. (retcode=${_r})"
            echo >&2 "aborting..."
            exit 255;
        fi
        ;;
esac


#### load environments. ####

[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"  ## reload for updated


## setup variables, especially based on provider environments.
workdir_local=`pwd`
workdir_container=/usr/src/myapp
if [ -z "${PROVIDER_URL}" -a -n "${PROVIDER_HOST}" ]; then
    if [ -n "${PROVIDER_PORT}" ]; then
        PROVIDER_URL="http://${PROVIDER_HOST}:${PROVIDER_PORT}"
    else
        PROVIDER_URL="http://${PROVIDER_HOST}"
    fi
fi
[ -n "${DOCKER_NETWORK}" ] && _netopt="--network ${DOCKER_NETWORK}"
_envopt="--env-file ${ENV_FOR_DOCKER}"  # require init_docker_env()
docker_cmd="docker run -it --rm ${_netopt} ${_envopt} \
    -v ${workdir_local}:${workdir_container} \
    -w ${workdir_container}"


#### preset params. (for demo) ####

webhook_port_alice=51001
webhook_port_bob=51002
webhook_port_carol=51003
webhook_port_freeaddr=51004
tmux_demo_session=metemcyber_demo


#### define control functions. ####

function _name_to_eoa() {
    case $1 in
        alice)  echo ${ALICE_EOA_ADDRESS}; return;;
        bob)    echo ${BOB_EOA_ADDRESS}; return;;
        carol)  echo ${CAROL_EOA_ADDRESS}; return;;
    esac
    echo $1
}

function create_network() {
    case "${DOCKER_NETWORK}" in
        besu-sample-networks) ## out of our control.
            return 0
            ;;
        '') return 0
            ;;
    esac
    (docker network list | grep -qw "${DOCKER_NETWORK}") || \
        docker network create "${DOCKER_NETWORK}" || exit 255
}

function remove_network() {
    case "${DOCKER_NETWORK}" in
        besu-sample-networks) ## out of our control.
            return 0
            ;;
        '') return 0
            ;;
    esac
    docker network list | grep -qw "${DOCKER_NETWORK}"
    [ $? -ne 0 ] || docker network remove "${DOCKER_NETWORK}" || exit 255
}

function build_image() {
    ## build metemcyber docker image if needed.
    newest_dependency=`ls -1t ${IMAGE_DEPENDENCIES} |head -1`
    dependency_ts=`get_mtime "${newest_dependency}"`
    [ ${dependency_ts} -eq 0 ] && echo >&2 "missing ${newest_dependency}" && exit 255
    image_ts_string=`
        docker inspect -f '{{json .Metadata.LastTagTime}}' ${METEMCYBER_IMAGE} \
            2>/dev/null | tr -d '"'`
    [ -n "${image_ts_string}" ] || image_ts_string=` \
        docker inspect -f '{{.Created}}' ${METEMCYBER_IMAGE} 2>/dev/null`
    [ -n "${image_ts_string}" ] && \
        image_ts=`datestr_to_sec "${image_ts_string}"`

    if [ -z "${image_ts}" ] || [ ${image_ts} -lt ${dependency_ts} ]; then
        ## not yet built    or image is older than dependency
        docker build -t ${METEMCYBER_IMAGE} -f ./demo/Dockerfile . || exit 255
    fi
}

function init_docker_env() {
    ts_envfile=`get_mtime "${ENV_FILE}"`
    ts_setting=`get_mtime "${SETTINGS}"`
    ts_dockenv=`get_mtime "${ENV_FOR_DOCKER}"`
    [ ${ts_envfile} -le ${ts_dockenv} -a ${ts_setting} -le ${ts_dockenv} ] \
        && return
    echo "initializing ${ENV_FOR_DOCKER}."
    cat "${SETTINGS}" "${ENV_FILE}" 2>/dev/null > "${ENV_FOR_DOCKER}"
}

function cleanup_docker_env() {
    rm -f "${ENV_FOR_DOCKER}"
}

function setup_demo() {
    init_docker_env
    ## apply demo assets.
    launch_client carol -vv -g -d -i setup_demo_catalog.in
}

function launch_client() {
    name=$1
    shift
    left_args="$*"

    init_docker_env
    [ -z ${PROVIDER_URL} ] || prov_opt="-p ${PROVIDER_URL}"
    case "${name}" in
        alice|bob|carol)
            case "${name}" in
                alice)  webhook=${webhook_port_alice}
                        name=${ALICE_EOA_ADDRESS}
                        key=${ALICE_PRIVATE_KEY}
                        ;;
                bob)    webhook=${webhook_port_bob}
                        name=${BOB_EOA_ADDRESS}
                        key=${BOB_PRIVATE_KEY}
                        ;;
                carol)  webhook=${webhook_port_carol}
                        name=${CAROL_EOA_ADDRESS}
                        key=${CAROL_PRIVATE_KEY}
                        ;;
            esac
            [ -z "${name}" ] && echo >&2 "not yet initialized" && exit 255
            cmd="${docker_cmd} --name ${name} -p ${webhook}:${webhook} \
                ${METEMCYBER_IMAGE}:latest \
                python3 src/client.py -u ${name} -k ${key} ${prov_opt} \
                -s http://${name}:${webhook} ${left_args}"
            ;;
        *)
            opt_f=0
            opt_s=0
            opt_u=0
            client_opts="${prov_opt}"
            for token in ${name} ${left_args}; do
                case ${token} in
                    -f|--keyfile)       opt_f=1; continue;;
                    -s|--server)        opt_s=1; continue;;
                    -u|--user)          opt_u=1; continue;;
                esac
                if [ ${opt_f} -eq 1 ]; then
                    opt_f=0
                    docker_volume_ext="-v `cd \`dirname ${token}\` && pwd`:/tmp/keystore"
                    client_opts+=" -f /tmp/keystore/`basename ${token}`"
                    addr=`jq .address "${token}" | sed -e 's/^"/0x/' -e 's/"$//'`
                    [ -z "${addr}" ] && echo >&2 "invalid keyfile: ${token}" && exit 255
                    continue
                elif [ ${opt_s} -eq 1 ]; then
                    opt_s=0
                    hp=${token##*/}
                    host=${hp%:*}
                    webhook=${hp##*:}
                    client_opts+=" -s ${token}"
                    continue
                elif [ ${opt_u} -eq 1 ]; then
                    opt_u=0
                    client_opts+=" -u ${token}"
                    [ -z "${addr}" ] && addr=${token}
                    continue
                else
                    client_opts+=" ${token}"
                fi
            done
            [ -z "${host}" -a -z "${addr}" ] && echo >&2 "missing option -s nor -f" && exit 255
            [ -z "${host}" ] && host=${addr}
            if [ -z "${webhook}" ] ; then
                webhook=${webhook_port_freeaddr}
                client_opts+=" -s http://${host}:${webhook}"
            fi
            cmd="${docker_cmd} ${docker_volume_ext} \
                --name ${host} -p ${webhook}:${webhook} ${METEMCYBER_IMAGE}:latest \
                python3 src/client.py ${client_opts}"
            ;;
    esac
    echo ${cmd}
    eval ${cmd}
}

function kill_client() {
    echo "killing metemcyber client container."
    targets=`docker ps -q -f ancestor="${METEMCYBER_IMAGE}"`
    [ -n "${targets}" ] && docker kill ${targets}
}

function cleanup_client_datafiles() {
    echo "cleaning up client data."
    pushd "${WORKSPACE}" >/dev/null || exit 255
    tgts="\
        trusted_users.tsv \
        registered_token.tsv \
        dissemination \
        gasUsed.*.log \
        tx-shelf.db \
        "
    [ "${PROVIDER}" = "pricom" ] || tgts+=" config.ini"
    targets=`ls -d ${tgts} 2>/dev/null`
    [ -z "${targets}" ] && popd >/dev/null && return 0

    sudo rm -rf ${targets} ### XXX Oops, how can i avoid sudo...
    popd >/dev/null
}

function launch_demo_tmux() {
    tgt=${tmux_demo_session}

    # Create a new session (tmux)
    tmux new -d -s ${tgt}
    tmux set-option -g mouse on
    tmux set-option -s set-clipboard off

    # For copy mode bindings with mouse
    tmux bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'copy-mode -e'"
    tmux set-option -g mode-keys vi
    tmux bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -i -sel clip > /dev/null"

    tmux split-window -v -t ${tgt}.0
    tmux split-window -h
    tmux split-window -h
    tmux select-layout main-horizontal
    tmux select-pane -t ${tgt}.0
    tmux split-window -h

    # HACK: prevent layout collapse
    sleep 1

    tmux send-keys -t ${tgt}.0 "./${PROGNAME} ${PROVIDER} client alice -d -g" C-m
    tmux send-keys -t ${tgt}.1 "./${PROGNAME} ${PROVIDER} client bob -g" C-m
    tmux send-keys -t ${tgt}.2 "./${PROGNAME} ${PROVIDER} client carol -d -v -g" C-m
    #tmux send-keys -t name.3 'source venv/bin/activate && python exchange_operator.py 3' C-m
    ## wait carol and launch fileserver on carol.
    eoa=`_name_to_eoa carol`
    cmd_delayed_fs_carol=`cat <<EOD | sed -e "s/^ *//"
        source metemcyber_common.sh;
        while [ 1 ]; do container_is_running ${METEMCYBER_IMAGE}:latest "${eoa}" && break; sleep 1; done;
        ./${PROGNAME} ${PROVIDER}
EOD
`
    tmux send-keys -t ${tgt}.4 "${cmd_delayed_fs_carol}" C-m

    # show tmux
    tmux attach -t ${tgt}.0
}

function start_provider() {
    cmd="${PROVIDER_CTL} start"
    echo "eval command: ${cmd}"
    eval "${cmd}" || exit 255
    wait_provider_ready "${PROVIDER_FROM_LOCAL}" || exit 255
}

case "${COMMAND}" in
    demo)
        case "${PROVIDER}" in
            tester)
                echo >&2 "tester(EthereumTesterProvider) does not support multiple client."
                echo >&2 "please try '${PROGNAME} tester client alice -d [-v]'."
                exit 1
                ;;
        esac
        case "${LEFT_ARGS}" in
            stop)
                kill_client
                tmux kill-session -t ${tmux_demo_session}
                ;;
            '')
                build_image
                start_provider
                launch_demo_tmux
                ;;
        esac
        ;;
    init)
        cleanup_client_datafiles
        create_network
        build_image
        start_provider
        for arg in ${LEFT_ARGS}; do
            case "${arg}" in
                demo)   setup_demo;;
            esac
        done
        ;;
    client)
        case "${PROVIDER}" in
            tester) ## start with clean condition at anytime.
                cleanup_client_datafiles
                ;;
        esac
        build_image
        launch_client ${LEFT_ARGS}
        ;;
    kill)
        kill_client
        tmux kill-session -t ${tmux_demo_session} 2>/dev/null
        cleanup_client_datafiles
        cleanup_docker_env
        remove_network
        ;;
    test)
        start_provider
        t_net=${PROVIDER//-/_}
        cmd="truffle test --network='${t_net}' ${LEFT_ARGS}"
        echo "eval command: ${cmd}"
        eval "${cmd}"
        ;;
esac
