# AM-treetool
A shell script tool to export/import/clone Forgerock AM trees.

## Description:
A shell script which will export an AM authentication tree to standard output and re-import
from standard input (optionally renaming the tree).

## Usage: 
% amtree.sh ( -i treename | -e treename ) -h AM-host-URL -u AM-admin -p AM-admin-password

## Examples:
1) Export a tree called "Login" to a file:
% ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password > login.json

2) Import a tree a file and rename it to "LoginTree":
% cat login.json | ./amtree.sh -i LoginTree -h https://openam.example.com/openam -u amadmin -p password

3) Clone a tree called "Login" to a tree called "ClonedLogin":
% ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://openam.example.com/openam -u amadmin -p password

4) Copy a tree called "Login" to a tree called "ClonedLogin" on another AM instance:
% ./amtree.sh -e Login -h https://openam.example.com/openam -u amadmin -p password | ./amtree.sh -i ClonedLogin -h https://another.domain.org/openam -u amadmin -p password

## Limitations:
This tool can't export passwords (including API secrets, etc), so these need to be manually added back to an imported tree or alternatively, export the source tree to a file, edit the file to add the missing fields before importing. Any other dependencies needed for a tree must also exist prior to import, for example inner-trees, scripts, and custom authentication JARs.
