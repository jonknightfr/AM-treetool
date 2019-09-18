#!/bin/bash
#
# Description: shell script which will export an AM authentication tree to standard output and re-import
#              from standard input (optionally renaming the tree).
# 
# Usage: amtree.sh ( -i treename | -e treename ) -h <AM host URL> -u <AM admin> -p <AM admin password>"
#
# Examples:
#
#   1) Export a tree called "Login" to a file:
#   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password > login.json
#
#   2) Import a tree a file and rename it to "LoginTree":
#   % cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -u amadmin -p password
#
#   3) Clone a tree called "Login" to a tree called "ClonedLogin":
#   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://openam.example.com/openam -u amadmin -p password
#
#   4) Copy a tree called "Login" to a tree called "ClonedLogin" on another AM instance:
#   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://another.domain.org/openam -u amadmin -p password
#
# Limitations: this tool can't export passwords (including API secrets, etc), so these need to be manually added
#              back to an imported tree or alternatively, export the source tree to a file, edit the file to add
#              the missing fields before importing. Any other dependencies needed for a tree must also exist prior
#              to import, for example inner-trees, scripts, and custom authentication JARs.
#
# Uncomment the following line for debug:
# set -x

AM=""
REALM=""
AMADMIN=""
AMPASSWD=""


function login {
    AREALM=$REALM
    shopt -s nocasematch
    if [[ $AMADMIN == "amadmin" ]]; then
        AREALM=""
    fi
    shopt -u nocasematch
    ADMIN=$(curl -s -k -X POST -H "X-Requested-With:XmlHttpRequest" -H "X-OpenAM-Username:$AMADMIN" -H "X-OpenAM-Password:$AMPASSWD" $AM/json${AREALM}/authenticate | jq .tokenId | sed -e 's/\"//g')
    if [ -z $ADMIN ]; then
        echo "Failed to sign in to AM. Check AM URL, realm, and credentials."
        exit -1
    fi
}


function exportTree {
    TREE=$(curl -f -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees/$1 | jq -c '. | del (._rev)')
    if [ -z "$TREE" ]; then
        echo "Failed to find tree: $1"
        exit -1
    fi

    NODES=$(echo $TREE| jq -r  '.nodes | keys | .[]')

    EXPORTS="{ \"innernodes\":{}, \"nodes\":{}, \"scripts\":{} }"

    for each in $NODES
    do
        TYPE=$(echo $TREE | jq -r --arg NODE "$each" '.nodes | .[$NODE] | .nodeType')
        NODE=$(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$each | jq '. | del (._rev)')
        EXPORTS=$(echo $EXPORTS "{ \"nodes\": { \"$each\": $NODE } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
        # export Page Nodes
        if [ "$TYPE" == "PageNode" ]; then
            PAGES=$(echo $NODE | jq -r '.nodes | keys | .[]')
            for page in $PAGES
            do
                PAGENODEID=$(echo $NODE | jq -r --arg IND "$page" '.nodes[($IND|tonumber)] | ._id')
                PAGENODETYPE=$(echo $NODE | jq -r --arg IND "$page" '.nodes[($IND|tonumber)] | .nodeType')
                PAGENODE=$(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$PAGENODETYPE/$PAGENODEID | jq '. | del (._rev)')
                EXPORTS=$(echo $EXPORTS "{ \"innernodes\": { \"$PAGENODEID\": $PAGENODE } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
            done
        fi
        # Export Scripts
        if [ "$TYPE" == "ScriptedDecisionNode" ]; then
            SCRIPTID=$(echo $NODE | jq -r '.script')
            SCRIPT=$(curl -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/scripts/$SCRIPTID | jq '. | del (._rev)')
            EXPORTS=$(echo $EXPORTS "{ \"scripts\": { \"$SCRIPTID\": $SCRIPT } }" | jq -s 'reduce .[] as $item ({}; . * $item)')
        fi
    done

    EXPORTS=$(echo ${EXPORTS} "{ \"tree\":${TREE} }" | jq -s 'reduce .[] as $item ({}; . * $item)')
    echo $EXPORTS | jq .
}


function importTree {
    TREES=$(</dev/stdin)
    HASHMAP="{}"

    # Scripts
    SCRIPTS=$(echo $TREES | jq -r  '.scripts | keys | .[]')
    for each in $SCRIPTS
    do
        SCRIPT=$(echo $TREES | jq --arg script $each '.scripts[$script]')
        NAME=$(echo $SCRIPT | jq -r '.name')
        echo "Importing script $NAME ($each)"
        RESULT=$(curl -s -k -X PUT --data "$SCRIPT" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/scripts/$each)
        if [ "$(echo $RESULT | jq '._id')" == "null" ]; then
            echo "Error: $RESULT"
            exit -1 
        fi
    done

    # Inner nodes
    NODES=$(echo $TREES | jq -r  '.innernodes | keys | .[]')
    for each in $NODES
    do
        NODE=$(echo $TREES | jq --arg node $each '.innernodes[$node]')
        TYPE=$(echo $NODE | jq -r '._type | ._id')
        NEWUUID=$(uuidgen)
        HASHMAP=$(echo $HASHMAP | jq --arg old $each --arg new $NEWUUID '.map[$old]=$new')
        NEWNODE=$(echo $NODE | jq ._id=\"${NEWUUID}\")
        echo "Importing node $TYPE ($NEWUUID)"
        RESULT=$(curl -s -k -X PUT --data "$NEWNODE" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$NEWUUID)
        if [ "$(echo $RESULT | jq '._id')" == "null" ]; then
            echo "Error: $RESULT"
            exit -1 
        fi
    done

    NODES=$(echo $TREES | jq -r  '.nodes | keys | .[]')
    for each in $NODES
    do
        NODE=$(echo $TREES | jq --arg node $each '.nodes[$node]')
        TYPE=$(echo $NODE | jq -r '._type | ._id')
        NEWUUID=$(uuidgen)
        HASHMAP=$(echo $HASHMAP | jq --arg old $each --arg new $NEWUUID '.map[$old]=$new')
        NEWNODE=$(echo $NODE | jq ._id=\"${NEWUUID}\")
        # Need to re-UUID page nodes
        if [ "$TYPE" == "PageNode" ]; then
            MAP=$(echo $HASHMAP| jq -r  '.map | keys | .[]' ) 
            for each in $MAP
            do
                NEW=$(echo $HASHMAP | jq -r --arg NODE "$each" '.map[$NODE]')
                NEWNODE=$(echo $NEWNODE | sed -e 's/'$each'/'$NEW'/g')
            done        
        fi
        echo "Importing node $TYPE ($NEWUUID)"

        RESULT=$(curl -s -k -X PUT --data "$NEWNODE" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$NEWUUID)
        if [ "$(echo $RESULT | jq '._id')" == "null" ]; then
            echo "Error: $RESULT"
            exit -1 
        fi
    done

    TREE=$(echo $TREES | jq -r  '.tree')
    ID=$1
    TREE=$(echo $TREE | jq --arg id $ID '._id=$id')
    MAP=$(echo $HASHMAP| jq -r  '.map | keys | .[]' ) 
    for each in $MAP
    do
        NEW=$(echo $HASHMAP | jq -r --arg NODE "$each" '.map[$NODE]')
        TREE=$(echo $TREE | sed -e 's/'$each'/'$NEW'/g')
    done
    echo "Importing tree $1"
    curl -s -k -X PUT --data "$TREE" -H "Content-Type:application/json" -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees/$ID > /dev/null
}


function usage {
    echo "Description: Export/import authentication tree and optionally rename the tree during import"
    echo "Usage: $0 ( -i treename | -e treename ) -h <AM host URL> [-r <realm, defaut=/>] -u <AM admin> -p <AM admin password>"
    exit
}


TASK=""
while getopts ":i:e:h:r:u:p:" arg; do
    case $arg in
        i) TASK="import"; TREENAME=$OPTARG;;
        e) TASK="export"; TREENAME=$OPTARG;;
        h) AM=$OPTARG;;
        r) if [ $OPTARG == "/" ]; then REALM=""; else REALM=$OPTARG; fi;;
        u) AMADMIN=$OPTARG;;
        p) AMPASSWD=$OPTARG;;
        *) usage;;
   esac
done

login

if [ "$TASK" == 'import' ]
then
    importTree $TREENAME
elif [ "$TASK" == 'export' ]
then
    exportTree $TREENAME
else
    usage
fi
