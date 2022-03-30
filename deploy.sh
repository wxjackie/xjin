#!/bin/bash

# 渲染
hugo

# 提交源仓库
msg="update blog"
echo $#
if [ $# -gt 0 ]
then
    msg=$1
fi
echo "===== Begin push source repo ======="
git add . &&
git commit -m "$msg"
git push

echo "===== Begin push public repo ======="
# 提交博客公开仓库
cd public/
git add . &&
git commit -m "public $msg"
git push

echo "======= All Done! ==========="
