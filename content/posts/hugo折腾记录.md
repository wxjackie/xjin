---
title: "Hugo折腾记录"
date: 2021-08-11T09:38:03+08:00
draft: true
typora-root-url: ../../static
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

## 图片管理

- 可以尝试直接把图片放到posts下面，这样是否本地和远程都能访问？

## 主题管理

- papermod安装使用：https://github.com/adityatelange/hugo-PaperMod/wiki/Installation
- 文章前置设置，可参考：https://bore.vip/archives/dd06a4b1/#LoveIt%E4%B8%BB%E9%A2%98%E5%AE%98%E6%96%B9%E5%89%8D%E7%BD%AE%E5%8F%82%E6%95%B0

## 样式调整

- `css/_variables.scss`里面的`$global-line-height: 1.8rem;`
- `css/_page/_single.scss`中的`.author`的`display: none;`

## 博客收集

- https://shuzang.github.io/ 使用loveit，更新频繁。
- https://hugoloveit.com/ loveit主题官网
- https://www.nashome.cn/categories/hugo/ 参考hugo一些功能实现

## 待解决的问题

- 文章摘要

- about内容

- 排版行距

  

