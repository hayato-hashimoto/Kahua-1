#!/bin/bash
if branch_name=`git symbolic-ref -q HEAD`
then
 branch_name=`expr z\`git symbolic-ref HEAD\` : 'zrefs/heads/\(.*\)'`
else
 branch_name='** detached HEAD **'
fi
echo "git-`git log -1 --date=short --pretty=format:'%ad %h'` ($branch_name)"
