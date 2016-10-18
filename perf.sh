#!/bin/bash -ex

GK=~/workspace/pih-gatekeeper
BAK=~/workspace/pih-store-instance/persist/ucn.bak
CLT=$GK/client_cert


function serve_one {
    echo serving @ `pwd`
    cd $GK
    sudo ./libxld >/dev/null 2>&1 &

    cd $BAK
    ./script init
    ./script start

    cd $GK
    sudo xl create gatekeeper.xl

    sleep 3s

    cd $CLT
    curl -i --cert client.pem:cambridge --cacert ../xen_cert/server.pem "https://10.0.0.254:8443/domain?ip=10.0.0.1&domain=review"
    ## won't be authorized

    cd $BAK/ucn.gatekeeper/data/
    mkdir approved
    mv pending/* approved
    git rm -r pending/*
    git add approved
    cd ../
    git commit -m "approve by script $1"

    cd $CLT
    curl -i --cert client.pem:cambridge --cacert ../xen_cert/server.pem "https://10.0.0.254:8443/domain?ip=10.0.0.1&domain=review"
    ## should return a valid endpoint

    sleep 1.5s

    curl -i --cert client.pem:cambridge --cacert ../xen_cert/server.pem "https://10.0.0.254:8443/domain?ip=10.0.0.1&domain=review"

    wget http://10.0.0.254:8080/log -O log$1
}


function cleanup {
    cd $GK
    echo cleanning @ `pwd`

    sudo kill `pidof libxld` || true

    sudo xl destroy gatekeeper || true
    sudo xl destroy bridge || true
    sudo xl destroy review || true

    cd $BAK
    ./script clean
}

GRN='\033[0;32m'
NC='\033[0m'

case $1 in
    "run")
        for i in `seq 1 $2`; do
            echo -e $GRN-----$i/$2 iteration-----$NC
            serve_one $i
            cleanup
            sleep 5s
        done
        ;;
    "clean")
        cleanup
        ;;
    *)
        echo unknow command $1
        ;;
esac
