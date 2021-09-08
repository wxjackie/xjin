---
title: "Hugo折腾记录"
date: 2021-08-11T09:38:03+08:00
draft: true
---

## 手动发布流程

- 先在content/posts里面新建md，然后编写后，执行`hugo serve -D`可以本地调试，-D参数表示草稿也渲染

- 执行`hugo`会生成静态内容到`public`目录，发布时需要将源文件仓库和`public`目录对应的仓库都更新和push，大致流程命令

  ```shell
  hugo new posts/article.md
  # 编写，并把文章的图片放在static对应目录下
  hugo serve -D   #本地调试
  hugo         #渲染出静态文件到public
  git add . && git commit -m "xxx" && git push
  cd public
  git add . && git commit -m "xxx" && git pus
  ```

## 待解决的问题

- 文章摘要

- about内容

- 排版行距

  

