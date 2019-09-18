# AM-treetool
A shell script tool to export/import/clone Forgerock AM trees.

## Description:
A shell script which will export an AM authentication tree from any realm (default: /) to standard output and re-import into any realm from standard input (optionally renaming the tree). The tool will include scripts. Requires curl, jq, and uuidgen to be installed and available.


## Usage: 
% amtree.sh ( -i treename | -e treename ) -h AM-host-URL [-r realm] -u AM-admin -p AM-admin-password

## Examples:
1) Export a tree called "Login" from the root realm to a file:

   % ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password > login.json
   % ./amtree.sh -e Login -h https://openam.example.com/openam -r / -u amadmin -p password > login.json

2) Import a tree into the root or a sub-realm from a file and rename it to "LoginTree":

   % cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -u amadmin -p password
   % cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -r /parent/child -u amadmin -p password

3) Clone a tree called "Login" to a tree called "ClonedLogin":

% ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://openam.example.com/openam -u amadmin -p password

4) Copy a tree called "Login" to a tree called "ClonedLogin" on another AM instance:

% ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://another.domain.org/openam -u amadmin -p password

## Limitations:
This tool can't export passwords (including API secrets, etc), so these need to be manually added back to an imported tree or alternatively, export the source tree to a file, edit the file to add the missing fields before importing. Any other dependencies than scripts needed for a tree must also exist prior to import, for example inner-trees and custom authentication JARs. Currently, scripts are NOT given a new UUID on import; an option to allow re-UUID-ing scripts might be added in the future.
