#!/bin/bash

[ -z "$NUM_WORKERS" ] && NUM_WORKERS=1
[ -z "$SERVER_GO_DATA_PATH" ] && SERVER_GO_DATA_PATH="$PWD/godata"
[ -z "$GO_SERVER_SYSTEM_PROPERTIES" ] && GO_SERVER_SYSTEM_PROPERTIES="-Dgo.periodic.gc=true"
[ -z "$GOCD_VERSION" ] && GOCD_VERSION="v17.10.0"
[ -z "$PORT" ] && PORT="8153"
[ -z "$SSL_PORT" ] && SSL_PORT="8154"

MACHINE_IP=$(ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p' | sed -n '1p')
SWARM_MASTER_IP="192.168.65.2"

download_docker_swarm_plugin(){
    if [ ! -f  $SERVER_GO_DATA_PATH/plugins/external/docker-swarm-elastic-agents-2.0.0.jar ]; then
        printf "\n[GoCD Server] Downloading docker swarm plugin.\n"
        curl --create-dirs -L --fail \
        https://github.com/gocd-contrib/docker-swarm-elastic-agents/releases/download/v2.0.0/docker-swarm-elastic-agents-2.0.0.jar \
        -o $SERVER_GO_DATA_PATH/plugins/external/docker-swarm-elastic-agents-2.0.0.jar
    fi
}

init_docker_swarm_master(){
    printf "\n[SWARM CLUSTER] Initializing docker swarm master\n"

    docker node ls 2> /dev/null | grep "Leader"
    if [ $? -ne 0 ]; then
      docker swarm init --advertise-addr=$SWARM_MASTER_IP > /dev/null 2>&1
    fi

    SWARM_TOKEN=$(docker swarm join-token -q worker)

    printf "\n[SWARM CLUSTER] Swarm master IP: ${SWARM_MASTER_IP}\n"

    sleep 5

    if [ ! $(docker ps -q --filter "name=mirror-repo") ]; then
        docker run -d --restart=always -p 4000:5000 --name mirror-repo \
          -v $PWD/rdata:/var/lib/registry \
          -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
          registry:2.5
    fi
}


create_worker_node() {
    printf "\n[SWARM CLUSTER] Required worker nodes: ${NUM_WORKERS}\n"

    for i in $(seq "${NUM_WORKERS}"); do
      printf "\n[SWARM CLUSTER] Starting worker node ${i}\n"

      docker node rm -f $(docker node ls --filter "name=worker-${i}" -q) > /dev/null 2>&1

      docker rm -f $(docker ps -q --filter "name=worker-${i}") > /dev/null 2>&1

      docker run -d --privileged --name worker-${i} --hostname=worker-${i} \
        -p ${i}2375:2375 \
        -p ${i}5000:5000 \
        -p ${i}5001:5001 \
        -p ${i}5601:5601 \
        docker:dind --registry-mirror http://${SWARM_MASTER_IP}:4000 > /dev/null 2>&1

      docker --host=localhost:${i}2375 swarm join --token ${SWARM_TOKEN} ${SWARM_MASTER_IP}:2377
      printf "\n[SWARM CLUSTER] Worker node ${i} started successfully.\n"

    done

    printf "\nDocker swarm cluster info.\n"
    docker node ls
}

copy_config_file(){
    if [ ! -f  $SERVER_GO_DATA_PATH/config/cruise-config.xml ]; then
        printf "\n[GoCD Server] Copying default config file.\n"
        mkdir -p $SERVER_GO_DATA_PATH/config/ && cp $PWD/cruise-config.xml "$_"
    fi
}

start_gocd() {

    copy_config_file
    download_docker_swarm_plugin

    printf "\n[GoCD Server] Starting GoCD server\n"

    docker rm -f $(docker ps -q --filter "name=go-server") > /dev/null 2>&1
    docker run -d \
        -p 8153:$PORT -p 8154:$SSL_PORT \
        -e GO_SERVER_SYSTEM_PROPERTIES=$GO_SERVER_SYSTEM_PROPERTIES \
        -v $SERVER_GO_DATA_PATH:/godata \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --name go-server \
        gocd/gocd-server:$GOCD_VERSION

    docker exec -it go-server chown go:go /var/run/docker.sock
}

wait_till_server_start(){
    printf "\n[GoCD Server] Waiting for server(http://${MACHINE_IP}:${PORT})...\n"

    until $(curl --output /dev/null --silent --head --fail http://${MACHINE_IP}:${PORT}); do
        printf '.'
        sleep 5
    done

    printf "\n[GoCD Server] Server started on http://$MACHINE_IP:$PORT.\n"
}

configure_docker_swarm_plugin(){
    wait_till_server_start

    response_code=$(curl -s -o /dev/null -w "%{http_code}" http://${MACHINE_IP}:${PORT}/go/api/admin/plugin_settings/cd.go.contrib.elastic-agent.docker-swarm -H 'Accept:application/vnd.go.cd.v1+json' -i)

    if [ ${response_code} == 404 ]; then
        printf "[GoCD Server] Creating plugin settings."

        curl -i http://${MACHINE_IP}:${PORT}/go/api/admin/plugin_settings \
        -H 'Accept: application/vnd.go.cd.v1+json' \
        -H 'Content-Type: application/json' \
        -X POST -d '{
          "plugin_id": "cd.go.contrib.elastic-agent.docker-swarm",
          "configuration": [
                {
                    "key": "docker_uri",
                    "value": "unix:///var/run/docker.sock"
                },
                {
                    "key": "go_server_url",
                    "value": "https://'${MACHINE_IP}':'${SSL_PORT}'/go"
                },
                {
                    "key": "max_docker_containers",
                    "value": "5"
                },
                {
                    "key": "enable_private_registry_authentication",
                    "value": "false"
                },
                {
                    "key": "auto_register_timeout",
                    "value": "3"
                }
            ]
        }' > /dev/null 2>&1
        printf "[GoCD Server] Plugin settings successfully created."
    fi
}

clear_containers(){
    printf "\nCleaning docker containers\n"
    docker node rm -f $(docker node ls --filter "name=worker-*" -q) > /dev/null 2>&1
    docker rm -f $(docker ps -q --filter "name=worker-*") > /dev/null 2>&1
    docker rm -f $(docker ps -q --filter "name=go-server") > /dev/null 2>&1
}

{
    init_docker_swarm_master && create_worker_node && start_gocd && configure_docker_swarm_plugin
} || {
    clear_containers
}