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


# the admin ui leaves orphaned node instances after deleting a tree and when using the APIs it is very easy to 
# forget to clean-up everything as well. the prune function will iterate through all node types, and then through 
# all instances of each node type. Then it will iterate over all the trees and their nodes and check if any of 
# the auth node type instances are orphaned and remove them.
function prune {
    echo "Analyzing authentication nodes configuration artifacts..."

    #get all the trees and their node references
    #these are all the nodes that are actively in use. every node instance we find in the next step, that is not in this list, is orphaned and will be removed/pruned.
    JTREES=$(curl -s -k -X GET --data "{}" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees?_queryFilter=true)
    ACTIVENODES=($(echo $JTREES| jq -r  '.result|.[]|.nodes|keys|.[]'))
    #echo $ACTIVENODES

    #get all the node instances
    JNODES=$(curl -s -k -X POST --data "{}" -H "iPlanetDirectoryPro:$ADMIN" -H  "Content-Type:application/json" -H "Accept-API-Version:resource=1.0" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes?_action=nextdescendents)
    NODES=($(echo $JNODES| jq -r  '.result|.[]|._id'))
    ORPHANEDNODES=()

    #find all the orphaned nodes
    for NODE in "${NODES[@]}"
    do
        ORPHANED=true
        for ACTIVENODE in "${ACTIVENODES[@]}"
        do
            if [ "$NODE" == "$ACTIVENODE" ] ; then
                ORPHANED=false
                break
            fi
        done
        if [ "$ORPHANED" == "true" ] ; then
            ORPHANEDNODES+=("$NODE")
        fi
    done

    echo
    echo "Total:    ${#NODES[@]}"
    #echo "Active:   ${#ACTIVENODES[@]}"
    echo "Orphaned: ${#ORPHANEDNODES[@]}"
    echo 

    if [[ ${#ORPHANEDNODES[@]} > 0 ]] ; then
        read -p "Do you want to prune (permanently delete) all the orphaned node instances? (N/y): " -n 1 -r
        echo    # (optional) move to a new line
        if [[ $REPLY =~ ^[Yy]$ ]] ; then
            echo -n "Pruning"
            #delete all the orphaned nodes
            for NODE in "${ORPHANEDNODES[@]}"
            do
                echo -n "."
                TYPE=$(echo $JNODES | jq -r --arg id "$NODE" '.result|.[]|select(._id==$id)|._type|._id')
                RESULT=$(curl -s -k -X DELETE -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/nodes/$TYPE/$NODE)
            done
            echo
            echo "Done."
            exit 0
        else
            echo "Done."
            exit 0
        fi
    else
        echo "Nothing to prune."
        exit 0
    fi
}


function exportTree {
    TREE=$(curl -f -s -k -X GET -H "X-Requested-With:XmlHttpRequest" -H "iPlanetDirectoryPro:$ADMIN" $AM/json${REALM}/realm-config/authentication/authenticationtrees/trees/$1 | jq -c '. | del (._rev)')
    if [ -z "$TREE" ]; then
        echo "Failed to find tree: $1"
        exit -1
    fi

    NODES=$(echo $TREE| jq -r  '.nodes | keys | .[]')

    ORIGIN=$(md5<<<$AM$REALM)
    EXPORTS="{ \"origin\":\"$ORIGIN\", \"innernodes\":{}, \"nodes\":{}, \"scripts\":{} }"

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
    echo "Usage: $0 ( -e tree | -i tree | -P ) -h url [-r realm] -u user -p passwd"
    echo
    echo "Export/import/prune authentication trees."
    echo
    echo "Actions/tasks (must specify only one):"
    echo "  -e tree   Export an authentication tree."
    echo "  -i tree   Import an authentication tree."
    echo "  -P        Prune orphaned configuration artifacts left behind after deleting"
    echo "            authentication trees. You will be prompted before any destructive"
    echo "            operations are performed."
    echo 
    echo "Mandatory parameters:"
    echo "  -h url    Access Management host URL, e.g.: https://login.example.com/openam"
    echo "  -u user   Username to login with. Must be an admin user with appropriate"
    echo "            rights to manages authentication trees."
    echo "  -p passwd Password."
    echo
    echo "Optional parameters:"
    echo "  -r realm  Realm. If not specified, the root realm '/' is assumed. Specify"
    echo "            realm as '/parent/child'. If using 'amadmin' as the user, login will"
    echo "            happen against the root realm but subsequent operations will be"
    echo "            performed in the realm specified. For all other users, login and"
    echo "            subsequent operations will occur against the realm specified."
    exit 0
}


TASK=""
while getopts ":i:e:h:r:u:p:P" arg; do
    case $arg in
        i) TASK="import"; TREENAME=$OPTARG;;
        e) TASK="export"; TREENAME=$OPTARG;;
        P) TASK="prune";;
        h) AM=$OPTARG;;
        r) if [ $OPTARG == "/" ]; then REALM=""; else REALM=$OPTARG; fi;;
        u) AMADMIN=$OPTARG;;
        p) AMPASSWD=$OPTARG;;
        *) usage;;
   esac
done

if [ "$TASK" == 'import' ] ; then
    login
    importTree $TREENAME
elif [ "$TASK" == 'export' ] ; then
    login
    exportTree $TREENAME
elif [ "$TASK" == 'prune' ] ; then
    login
    prune
else
    usage
fi
