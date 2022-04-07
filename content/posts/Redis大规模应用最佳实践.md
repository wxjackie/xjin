---
title: "Redis大规模应用最佳实践"
date: 2022-03-16T10:57:03+08:00
draft: false
tags: ["Redis", "最佳实践"]
categories: ["中间件"]
summary: 介绍Redis在大规模应用时需要注意的事项和使用建议。
typora-root-url: ../../static
---

> 自从工作以来，我个人一直专注于Redis相关的公有云、私有云、容器化开发，积累了不少经验，也踩过不少坑。这里根据近期组内的分享和个人经验来做个总结，希望能够通过一篇文章阐明Redis在大规模应用时的最佳实践。

## 架构选型

下面简单介绍Redis常用的、原生的高可用架构模式：**哨兵模式和集群模式**。具体高可用机制的细节和非高可用的模式不在该部分的讨论范围内。

### 哨兵模式

由一组Redis Sentinel管理若干组Redis主从实例，每组Redis主从在哨兵中体现为一个Group，当Master故障，Sentinel会做自动的故障主从切换，将同Group内其中一个可用的Slave提升成Master，满足了基本的高可用要求。基本架构如图所示：

客户端访问哨兵模式Redis有两种方式，下面都以简单的Jedis客户端举例：
- 使用Jedis类，需要Redis服务方提供出VIP的机制，保证VIP始终指向最新的Master（需要一个额外的管控服务去做这件事，因此对于哨兵模式仍建议使用JedisSentinel）
- 使用JedisSentinel类，客户端配置Redis Sentinel的地址和对应的主从Group名称，即客户端通过Sentinel感知Redis主从，无需引入VIP。

![redis-sentinel-mode](/img/redis-best-practice/redis-sentinel-mode.png)

通常，一组Redis Sentinel管理成百上千组Redis主从是没有问题的，但实际线上使用时，可以根据不同租户（如果是云服务商）、不同重要程度的Redis进行分组使用独立的Redis Sentinel组。哨兵模式的缺点是，它本质上还是一个单点结构，不是分布式的，无法支持水平扩展。下面介绍Redis 3.0后官方引入的分布式架构：Redis Cluster。

### 集群模式

`Redis Cluster`是自3.0版本后原生支持的集群化方案，也是目前建议线上使用的模式。

分布式存储中需要提供维护节点元数据信息的机制，常见的元数据维护方式分为：集中式和P2P式，Redis采用的Gossip协议的原理就是节点彼此不断通信交换信息，一段时间后所有的节点都会知道集群完整信息，Redis Cluster中的Gossip除了交换槽信息，还交换主从状态/节点故障等，Redis Cluster的自动故障切换也是基于此实现的。如下图所示，Redis Cluster可以分为多个分片（一般最少3个），分片数是可以伸缩的，即支持水平扩展。

![redis-cluster-mode](/img/redis-best-practice/redis-cluster-mode.png)

客户端访问Redis Cluster有两种方式，仍以Jedis举例：

- 使用JedisCluster类：这个类是Jedis专为RedisCluster设计的Smart Client，使用时配置Redis Cluster中多个节点的地址信息，客户端会自动感知到整个Redis集群的拓扑，包括缓存槽分布，确定key和分片的映射关系。
- 使用Jedis类：对于一些老的业务仍使用单点模式客户端（如Jedis），但由于容量问题Redis需要更换为Redis Cluster。这种情况需要为Redis Cluster前置Proxy + LoadBalance服务，便可以用单点的模式向外提供服务。社区中有多个可用的Proxy，比如Envoy也有Redis Cluster Filter，这里不再赘述。

## 内存管理

## 性能

## 容器化

## 运维与安全

## 巧用数据结构

- geohash用于地理位置
- zset用于排行榜等
- bitmap
- 布隆过滤器

