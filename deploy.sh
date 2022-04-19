#!/bin/bash
set -eu
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
git commit -m "$msg $(hostname)"
git push

echo "===== Begin push public repo ======="
# 提交博客公开仓库
cd public/
git add . &&
git commit -m "public $msg $(hostname)"
git push -ff

echo "======= All Done! ==========="
