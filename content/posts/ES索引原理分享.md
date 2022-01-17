---
title: "ES索引原理分享"
date: 2022-01-27T18:04:02+08:00
draft: true
typora-root-url: ../../static
---
# ES索引原理分享

## 概述

- ElasticSearch 是一个开源的分布式 RESTful 搜索和分析引擎。
- Lucene是一个开源的搜索引擎工具包，由Apache软件基金会支持和提供。
- ElasticSearch基于Lucene构建，并对其进行了扩展，使存储、索引、搜索变得更加灵活、易用。

## 展示使用Demo

ES在一些场景中，可以直接地作为独立的后端服务存在，比如博客和简单搜索引擎。下面实现一个搜索引擎的常用功能之一，自动补全推荐功能的Demo。

只需要一个ES集群，再写入一些**约定结构**的JSON文档即可

- file:///Users/wangxingjin/wxj/workspace/jqueryseo/index.html

补充：completion suggester将数据保存在内存中的有限状态转移机中（FST）；FST实际上是一种图，它可以将词条以压缩和易于检索的方式来存储。

## 使用角度：文档、索引



## 物理结构：节点、分片

## 功能强大 Why

## 高性能 Why

- Lucene实现索引使用的数据结构是FST（Finite State Transducers），优点是内存占用率低，能达到3-20倍的压缩率，模糊查询支持好，查询快，最大的优势还是占用内存小，只有HashMap的十分之一左右；缺点是结构复杂、输入要求有序、更新不易

- 一个合格的词典结构要**查询速度**与**内存占用**兼顾，一般要能做到内存和磁盘结合使用。

- Lucene索引的流程：Term dict index以FST的结构缓存在内存中，从Term dict index查到关键词对应的term dic块位置后，再去磁盘上找term，大大减少了磁盘IO的次数，基本图示如下：

  ![img](/img/es-share/index1.jpg)

- 

### 1. 性能测试指标

### 解释性内容

- 各后缀文件的用途含义

  ![img](/img/es-share/es-file-desc.png)

## 参考

- https://www.6aiq.com/article/1626313129578
- https://zhuanlan.zhihu.com/p/346431188
- https://www.infoq.cn/article/ejeg02vroegvalw4j_ll
- Lucene底层索引原理：https://blog.csdn.net/njpjsoftdev/article/details/54015485
- https://www.jianshu.com/p/b00079460b29
- http://www.nosqlnotes.com/technotes/searchengine/lucene-invertedindex/
- https://juejin.cn/post/6947984489960177677