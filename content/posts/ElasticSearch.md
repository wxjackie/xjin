---
title: "ElasticSearch学习笔记（一）"
date: 2021-09-08T09:58:44+08:00
draft: true
typora-root-url: ../../static
---

## 逻辑设计与物理设计

逻辑设计：用于索引和搜索的基本单位是文档，可以类似的认为是关系数据库中的一行。文档以类型来分组，类型包含若干文档（ElasticSearch 6.x 版本废弃掉 Type ，建议的是每个类型的数据单独放在一个索引），类似关系数据库的数据表包含若干行。一个或多个类型存在于同一索引中，索引是更大的容器，类似关系数据库中的数据库。

物理设计：ES将每个索引划分为若干分片，每份分片可以在集群中不同服务器间迁移，通常情况下无论ElasticSearch是单台还是多台服务器，应用与ElasticSearch的交互基本保持不变。

![image-20210928114737412](/img/es-intro/logic-physic-view.png)

