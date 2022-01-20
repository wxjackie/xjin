---
title: "ES索引原理分享"
date: 2022-01-27T18:04:02+08:00
draft: true
typora-root-url: ../../static
---
# ES索引原理分享

## 1. 入门
### 简介

- ElasticSearch 是一个开源的分布式 RESTful 搜索和分析引擎。
- Lucene是一个开源的搜索引擎工具包，由Apache软件基金会支持和提供。
- ElasticSearch基于Lucene构建，并对其进行了扩展，使存储、索引、搜索变得更加灵活、易用。

### 使用场景

- 

## 2. Demo

ES在一些场景中，可以直接地作为独立的后端服务存在，比如博客和简单搜索引擎。下面实现一个搜索引擎的常用功能之一，自动补全推荐功能的Demo。

只需要一个ES集群，再写入一些**约定结构**的JSON文档即可

- file:///Users/wangxingjin/wxj/workspace/jqueryseo/index.html

补充：completion suggester将数据保存在内存中的有限状态转移机中（FST）；FST实际上是一种图，它可以将词条以压缩和易于检索的方式来存储。

## 使用角度：文档、索引



## 物理结构：节点、分片

discovery.zen代表 elasticsearch 的自动节点发现机制，而且 elasticsearch还是一个基于 p2p 的系统。

首先它它会通过以广播的方式去寻找存在的节点，然后再通过多播协议来进行节点之间的通信，于此同时也支持点对点的交互操作。

## 功能强大 Why

## 高性能 Why

- Lucene实现索引使用的数据结构是FST（Finite State Transducers），优点是内存占用率低，能达到3-20倍的压缩率，模糊查询支持好，查询快，最大的优势还是占用内存小，只有HashMap的十分之一左右；缺点是结构复杂、输入要求有序、更新不易

- 一个合格的词典结构要**查询速度**与**内存占用**兼顾，一般要能做到内存和磁盘结合使用。

- Lucene索引的流程：Term dict index以FST的结构缓存在内存中，从Term dict index查到关键词对应的term dic块位置后，再去磁盘上找term，大大减少了磁盘IO的次数，基本图示如下：

- ![img](https://static001.infoq.cn/resource/image/17/be/175213f151b8a7bb6816b0fd1d17b9be.png)

- 

  ![img](/img/es-share/index1.jpg)

- ![img](http://www.nosqlnotes.com/wp-content/uploads/2018/09/lucene-inverted-index-3.png)

### 1. 性能测试指标

### 解释性内容

- 各后缀文件的用途含义

  ![img](/img/es-share/es-file-desc.png)

## 参考

- https://www.6aiq.com/article/1626313129578
- https://zhuanlan.zhihu.com/p/346431188
- https://www.infoq.cn/article/ejeg02vroegvalw4j_ll
- Lucene底层索引原理：https://blog.csdn.net/njpjsoftdev/article/details/54015485
- FST数据结构详解：https://www.shenyanchao.cn/blog/2018/12/04/lucene-fst/
- 跳表详解：https://www.jianshu.com/p/9d8296562806
- http://www.nosqlnotes.com/technotes/searchengine/lucene-invertedindex/
  - Lucene系列：http://www.nosqlnotes.com/author/zteny/
- https://juejin.cn/post/6947984489960177677
- ES节点、分片选举和recovery：https://jiekun.dev/posts/2020-03-14-elasticsearch%E8%8A%82%E7%82%B9%E9%80%89%E4%B8%BE%E5%88%86%E7%89%87%E5%8F%8Arecovery/